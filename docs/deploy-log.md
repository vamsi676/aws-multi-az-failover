# Deploy log

Every command run during the end-to-end build, why it was run, what the output meant, and any
error plus its fix. Account IDs, emails and IPs are redacted.

Conventions: `$P` = `--profile <aws-profile>`; commands run from the repo root unless a `cd` is shown.

---

## Pre-flight

| Command | Why | Result / meaning |
|---|---|---|
| `aws sts get-caller-identity $P` | Confirm which IAM principal Terraform will use | `arn:aws:iam::<acct>:user/<user>`: the right personal account |
| `gh auth status` | Phase 3 needs gh for PRs, environments, variables | Logged in, scopes `repo`, `workflow` (enough to push workflows and set variables) |
| `git remote -v` | Where Phase 3 pushes | `github.com/<owner>/aws-multi-az-failover` |
| `curl -s https://checkip.amazonaws.com` | `allowed_cidr` must match my current IP | Matches `envs/dev/terraform.tfvars` |
| `which session-manager-plugin` | Interactive SSM sessions need it | Not installed: we use SSM **Run Command** instead (no plugin needed) |

---

## Phase 0: bootstrap

| Command | Why | Result / meaning |
|---|---|---|
| `cd bootstrap && terraform plan -out=tfplan` | Preview; first run uses **local** state (backend block commented) | `Plan: 22 to add, 0 to change, 0 to destroy`: all new, nothing replaced |
| `terraform apply tfplan` | Create buckets, budget, OIDC provider, roles | `Apply complete! Resources: 22 added`. Lifecycle configs took ~56s (S3 lifecycle is eventually consistent; the provider waits) |
| write `backend.hcl` (bucket + profile), uncomment `backend.tf` | Tell Terraform where the remote state goes | — |
| `terraform init -migrate-state -force-copy -backend-config=backend.hcl` | Copy local state into the bucket it describes (`-force-copy` = auto "yes") | `Successfully configured the backend "s3"`; `s3://<state-bucket>/bootstrap/terraform.tfstate` exists (≈56 KB) |
| `terraform plan -detailed-exitcode` | Prove remote state matches reality | `No changes`. Local `terraform.tfstate*` left in place (gitignored, stale; delete by hand) |
| `aws s3api get-bucket-versioning / get-public-access-block / get-bucket-lifecycle-configuration` | Done-criteria checks | Versioning `Enabled`; 4× `True`; rule `expire-releases 30` days |
| `aws budgets describe-budget --budget-name mazf-monthly` | Budget visible | `10.0 MONTHLY` |
| `aws iam get-role --role-name mazf-gha-plan / mazf-gha-deploy` | Check trust conditions | `sub = repo:<owner>/<repo>:pull_request` and `...:environment:dev`, `aud = sts.amazonaws.com` |

**Error:** `aws ... $P` failed with `Unknown options: --profile <p>`.
**Cause:** zsh does not word-split unquoted variables, so `$P` was passed as ONE argument.
**Fix:** `export AWS_PROFILE=<p> AWS_REGION=us-east-1 AWS_PAGER=""` once, then plain `aws ...`.

**Phase 0 result: PASS** (buckets, budget, roles visible).

---

## Phase 1: infra

| Command | Why | Result / meaning |
|---|---|---|
| set `artifacts_bucket_name` in `envs/dev/terraform.tfvars`; copy `backend.hcl` | Wire envs/dev to the bootstrap buckets | — |
| `cd envs/dev && terraform init -reconfigure -backend-config=backend.hcl` | Connect to remote state key `envs/dev/terraform.tfstate` | `Successfully configured the backend "s3"` |
| `terraform plan -out=tfplan` | Preview | `Plan: 32 to add, 0 to change, 0 to destroy` |
| `terraform apply tfplan` | Create the stack | `32 added`. ASGs in seconds; **NLB took 2m32s** (slowest resource). CodeDeploy group created after the ASGs (it needs their names) |
| `scripts/status.sh` | Read-only overview | ASG-a desired 1 / InService 1 (us-east-1a), ASG-b 0/0; target `initial` (`Elb.InitialHealthChecking`) then `unhealthy` |
| `aws ssm describe-instance-information` | Is the SSM agent registered? | `PingStatus = Online`: role + public IP + egress 443 work |
| `aws ssm send-command --document-name AWS-RunShellScript` (cloud-init status, systemctl, python, curl) then `get-command-invocation` | Verify user_data without SSH | `status: done`, `codedeploy-agent active`, `nginx active`, `Python 3.11.18`, `healthz=404` (no app yet = expected), IMDS call **without token = 401** (IMDSv2 enforced) |

**Phase 1 result: PASS.**

---

## Phase 2: Taskboard app

| Command | Why | Result / meaning |
|---|---|---|
| `uv venv --python 3.11 .venv` | Local Python matching the instances (3.11) | `Python 3.11.12` |
| `uv pip compile app/requirements.in --python-version 3.11 --python-platform x86_64-manylinux2014` | Pin exact versions resolved **for the instance platform**, not for the Mac | fastapi 0.162.7, uvicorn 0.54.0, boto3 1.44.3, pydantic-core 2.50.4 ... |
| `ruff check . && ruff format --check .` | Lint/format | First run: `I001 import block un-sorted`: ruff did not know `taskboard` is first-party. **Fix:** `src = ["app"]` in `ruff.toml` |
| `cd app && pytest -q` | Unit tests with DynamoDB mocked by moto | `16 passed` |
| `bash -n` on hooks/scripts, `terraform validate` | Syntax checks | OK |
| `PYTHON=.venv/bin/python scripts/build_app.sh` | Build bundle with vendored Linux wheels | `dist/taskboard-<sha>.zip`, 20 MB, contains `_pydantic_core.cpython-311-x86_64-linux-gnu.so` (Linux binary built on a Mac via `--platform`) |
| `terraform plan` (envs/dev) | user_data now writes `/etc/taskboard/taskboard.env` (TABLE_NAME, region) | `0 to add, 1 to change, 0 to destroy`: launch template updated **in place** (new version) |
| `terraform apply tfplan` | — | `1 changed` |
| `aws autoscaling start-instance-refresh --auto-scaling-group-name mazf-asg-a --preferences MinHealthyPercentage=0,InstanceWarmup=60` | The running instance was launched from LT v1 (no env file). Instance refresh is the right tool for **launch template** changes | `Pending -> InProgress 50% -> 100% -> Successful` in ~4 min (terminate old, launch new, warm-up) |
| `aws ssm send-command ... cloud-init status --wait; cat /etc/taskboard/taskboard.env` | Do not deploy before user_data finished | `status: done`, env file present, agent active |
| `scripts/deploy_app.sh dist/taskboard-<sha>.zip` | Upload to `releases/<sha>.zip`, `aws deploy create-deployment`, `aws deploy wait deployment-successful` | `Succeeded` in **23 s** |
| `aws elbv2 describe-target-health` | Wait for the NLB to see the app | `unhealthy -> healthy` within ~20 s (2 checks × 10 s) |
| `curl /healthz`, `/api/meta`, POST/PATCH `/api/tasks`, `/`, `/status` | Done-criteria | 200 + `cache-control: no-store`; meta shows `us-east-1a` + version; 4×201, PATCH 200 |
| `aws dynamodb scan --table-name mazf-tasks` | Prove the data lives in DynamoDB, not on the instance | All 4 tasks present, one `in_progress` |

**Phase 2 result: PASS.**

---

## Phase 3: CI/CD

| Command | Why | Result / meaning |
|---|---|---|
| `uvx checkov -d . --framework terraform` | See findings before CI does | 22 failures, all cost decisions (no KMS CMK, no flow/access logs), design decisions (public IP, TCP 80) or false positives (SG referenced via module input). Each skipped **with a reason** in `.checkov.yaml` -> `194 passed, 0 failed` |
| `gh api -X PUT repos/<repo>/environments/dev` with `reviewers` | Environment `dev` with me as required reviewer | **Error 422:** "billing plan supports the required reviewers protection rule". Free plan: environment protection rules only on **public** repos (`wait_timer` also 422). Created `dev` without reviewer, limited to branch `main`, until decided |
| `gh variable set ...` (9 vars) | CI needs role ARNs, state bucket, artifacts bucket, CodeDeploy names, `TF_VAR_*` | Values piped from `terraform output` (never typed or committed) |
| `git push` + `gh pr create` (PR #1) | Run CI | fmt/validate/tflint/checkov ✅, ruff+pytest ✅, build ✅, **plan ❌** |
| `gh run view --log-failed` | Why did plan fail? | `Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity` |
| `gh api repos/<repo>/actions/oidc/customization/sub` | Which `sub` does GitHub send? | `use_immutable_subject: true`, prefix `repo:<owner>@<owner_id>/<repo>@<repo_id>`: the trust policy expected `repo:<owner>/<repo>:pull_request`, so no match |
| *(approved exception)* `bootstrap/`: add `github_owner_id`, `github_repo_id`; trust accepts both subject forms; `terraform plan` / `apply` | Fix the trust policy | `0 to add, 2 to change, 0 to destroy` (two roles, in place) |
| scan `git log --all -p` for account ID, IP, profile, bucket names, keys, email | Before making the repo public | Only hit: the git **author email** in commit metadata (accepted) |
| `gh repo edit --visibility public`, then PUT environment with reviewer | Required reviewers are free on public repos | `required_reviewers: [<me>]`, branch policy `main` |
| `git push` (PR #1 re-runs) | — | All 4 checks ✅; PR comment "Terraform plan: envs/dev (success) **No changes**", 12-digit numbers masked |
| `gh pr merge 1 --merge` | `workflow_dispatch` only works for workflows on the default branch; `dev` only allows `main` | Merged |
| header text change -> PR #2 -> CI ✅ -> `gh pr merge 2` | Test plan #5 | — |
| `gh workflow run deploy.yml --ref main -f target=app` | Deploy the change through CI | Run status `waiting` = **paused for the required reviewer** |

**Lesson:** GitHub OIDC subjects can be "immutable" (`owner@id/repo@id`). Check
`gh api repos/<owner>/<repo>/actions/oidc/customization/sub` before writing trust policies.
| *(I clicked "Approve and deploy" on environment `dev`)* `gh run watch <id>` | Wait for the approved deploy | `success`: build bundle -> CodeDeploy via OIDC deploy role |
| `curl <nlb>/api/meta`, `curl <nlb>/` | Is the new version live? | `version: 126ae74` (the merge commit) and the new header **"Taskboard · Multi-AZ"**: **test #5 PASS** |
| build a bundle whose `validate_service.sh` does `exit 1` (file restored right after the build), `scripts/deploy_app.sh dist/taskboard-bad-validate.zip` | Test #6: bad deploy rollback | Deployment `Failed` (`HEALTH_CONSTRAINTS`; `ValidateService` exit 1, stderr shown). CodeDeploy started rollback deployment automatically (`creator: codeDeployRollback`) |
| `aws deploy wait deployment-successful --deployment-id <rollback-id>` | Did the rollback work? | `Succeeded` with `releases/126ae74.zip`; NLB serves `126ae74`, `/healthz` 200, 4 tasks intact: **test #6 PASS** |
| `gh run view <id> --log` for the last 4 runs, grep for account ID / IP | The repo is now public, so Actions logs are public | Account ID visible in all 4 (role ARN echoed in `with:` inputs), my IP in 2 (`env:` echo) |
| `gh secret set AWS_PLAN_ROLE_ARN / AWS_DEPLOY_ROLE_ARN / ALLOWED_CIDR / ALERT_EMAIL`; workflows use `secrets.*`; `allowed_cidr` + `alert_email` are `sensitive = true` | Secrets are masked (`***`) in logs; sensitive Terraform values print as `(sensitive value)` in plans and PR comments | Done. **Manual follow-up (blocked for me as destructive):** delete the old run logs and the 3 old repo variables |

**Phase 3 result: PASS** (PR checks green + plan comment; app change deployed by `deploy.yml` after approval; bad deploy rolled back).

**Lessons:** (1) on a public repo, use **secrets** (not variables) for anything you would not print; (2) free GitHub plan: environment protection rules need a public repo.

---

## Phase 4: monitoring

| Command | Why | Result / meaning |
|---|---|---|
| `terraform plan` (envs/dev) | KMS key + alias, SNS topic + policy + email subscription, alarm | `6 to add, 1 to change, 0 to destroy`. The "change" is only the SG rule's `cidr_ipv4` becoming `(sensitive value)` (no real change). Cost: KMS key ≈ $1/month, alarm $0.10/month |
| `terraform apply tfplan` | — | `6 added, 1 changed` |
| `aws sns list-subscriptions-by-topic` | Email needs a human click | `PendingConfirmation` -> *(I clicked "Confirm subscription")* -> real subscription ARN |
| `aws cloudwatch describe-alarms` | Initial state | `INSUFFICIENT_DATA` -> `OK` (first datapoints arrived) |
| `scripts/simulate_outage.sh` | SSM Run Command `systemctl stop taskboard` on the ASG-a instance | `Success inactive` at 16:09:06Z |
| poll target health / `curl /healthz` / alarm state every 15s | Watch the chain | target `unhealthy` at +30s; `/healthz` **502** (nginx up, app down; with all targets unhealthy the NLB "fails open" and still sends traffic); alarm **ALARM at 16:16:12** (+7 min) |
| `aws cloudwatch get-metric-statistics HealthyHostCount` + alarm history `stateReasonData` | Why 7 minutes, not 2-3? | Datapoints for 16:10 and 16:11 were already 0, but the alarm evaluated them only at 16:16: **NLB metrics reach CloudWatch ~4-5 min late**. Detection time = metric delay + 2 periods |
| `scripts/simulate_outage.sh --restore` | Start the service again | `active`; `/healthz` 200 immediately; alarm back to `OK` after ~5.5 min (same metric delay) |
| `aws cloudwatch get-metric-statistics AWS/SNS NumberOfNotificationsDelivered / Failed` | Did the emails go out? | Delivered 1 (OK on creation) + 1 (ALARM); Failed 0 |

**Phase 4 result: PASS** (stop app -> alarm ALARM -> email).

**Lesson:** a CloudWatch alarm on NLB metrics will not fire faster than the metric arrives (~4-5 min
here), so expect a total RTO of roughly 7-10 minutes in Phase 5, not 2-3.

---

## Phase 5: failover
