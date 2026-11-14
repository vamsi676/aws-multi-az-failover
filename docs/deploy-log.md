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

| Command | Why | Result / meaning |
|---|---|---|
| `pytest -q` in `lambda/` | Unit tests for precheck / scale_asg / check_targets (boto3 clients replaced by small fakes) | `10 passed` |
| render ASL with dummy values, `aws stepfunctions validate-state-machine-definition` | Catch ASL/JSONata mistakes **before** apply (read-only API) | `result: OK`, no diagnostics |
| `terraform init` (adds `hashicorp/archive` 2.8.1), `terraform providers lock -platform=darwin_arm64 -platform=linux_amd64` | `archive_file` zips each Lambda; lock hashes for Mac and CI | — |
| checkov | New Lambda/log-group checks | 24 failures across 8 generic checks (DLQ, VPC, X-Ray, 1-year retention, ...). Each skipped with a concrete reason -> `322 passed, 0 failed` |
| `terraform plan` | 3 Lambdas (+roles, logs), SFN role, state machine, EventBridge rule + role | `23 to add, 0 to change, 0 to destroy` |
| `terraform apply tfplan` | — | `23 added` |
| background monitor: `curl /api/meta` every 2 s -> `watch.log` | Measure real downtime like `/status` does | — |
| `scripts/simulate_outage.sh` | **Test #1** (happy path) | service stopped 16:32:12Z |
| poll alarm / executions / ASGs | Watch the chain | ALARM ~16:39:13 -> execution started **the same second** (EventBridge) -> ASG-b desired 1 -> SUCCEEDED 16:41:25; ASG-a desired 0 |
| `aws stepfunctions get-execution-history` | Timeline | Precheck 3.8 s, ScaleUp 3 s, **4 checks × 30 s** until healthy, ScaleDown 0.5 s, Notify. Execution total ≈ 2m12s |
| `curl /api/meta`, `/api/tasks` | Same data in the new AZ? | `us-east-1b`, new instance, version `126ae74`, **same 4 tasks** (DynamoDB is regional) |
| `aws deploy list-deployments` / `get-deployment` | **Test #7** fresh-instance deploy | Deployment `creator: autoscaling`, `releases/126ae74.zip`, `Succeeded`: the CodeDeploy launch hook gave the new instance the last good revision; no launch/terminate loop |
| `awk` over `watch.log` | Measured RTO | first failure 16:32:13 -> first 200 from 1b 16:40:48 = **8m35s** (≈7 min detection, ≈1.5 min failover) |
| `aws stepfunctions start-execution --input '{}'` while on AZ-b | **Test #3** split-brain guard | `Init -> Precheck -> ShouldProceed -> NotifySkipped -> Skipped`; nothing scaled |
| `start-execution --input '{"overrides":{"target_asg":"mazf-asg-does-not-exist"}}'` | **Test #4** failure path | `FAILED`, `ValueError: Auto Scaling group not found`; `Precheck -> NotifyFailure -> Failed`; ASGs unchanged |
| `aws cloudwatch get-metric-statistics AWS/SNS NumberOfNotificationsDelivered` | Were the emails sent? | 4 delivered (ALARM, SUCCEEDED, SKIPPED, FAILED), 0 failed |

**Phase 5 result: PASS** (automatic failover to us-east-1b with the same tasks, success email; tests #3, #4, #7 also PASS).

**Lessons:** EventBridge starts the state machine within a second of the alarm; almost all of the
RTO is detection (NLB metric delay). The standby needed ~2 min (boot + user_data + CodeDeploy hook)
before the NLB marked it healthy.

---

## Phase 6: failback

| Command | Why | Result / meaning |
|---|---|---|
| generate `failback.asl.json` from the failover ASL (texts changed), `validate-state-machine-definition` | Same proven flow, reverse direction (source = ASG-b, target = ASG-a) | `OK` |
| `terraform plan` / `apply` | Failback state machine + log group (reuses Lambdas and SFN role) | `2 to add, 0 to change, 0 to destroy` |
| `scripts/start_failback.sh` | **Test #2** | `SUCCEEDED` in ~1m37s: Precheck -> scale ASG-a to 1 -> 3 checks (≈1.5 min: boot + user_data + CodeDeploy launch hook) -> scale ASG-b to 0 -> email |
| `curl /api/meta`, `/api/tasks`; ASGs | Back on the primary AZ with the same data? | `us-east-1a`, new instance; ASG-a 1 / ASG-b 0; all tasks there, **including edits made on the board while it ran in 1b** |
| monitor log (`curl` every 2 s) | Any downtime during failback? | **0 failed requests.** For ~50 s both instances were healthy and the NLB alternated 1a/1b; then 1b drained (30 s deregistration delay) |
| rename failback states (`ScaleUpPrimary`, `PrimaryHealthy`, `ScaleDownStandby`), `terraform apply` | Clear execution history | `0 to add, 1 to change, 0 to destroy` (in-place) |

**Phase 6 result: PASS** (back on us-east-1a, same tasks, email).

**Lesson:** a *planned* move (failback) has zero downtime because the new target is healthy before the
old one is removed. An *unplanned* failover's downtime is mostly detection time.

---

## Phase 7: Bedrock

| Command | Why | Result / meaning |
|---|---|---|
| `aws bedrock list-inference-profiles` / `list-foundation-models` | Which small models can we call? | Nova Micro/Lite, Claude Haiku 4.5/5.5 profiles ACTIVE. Chose **`us.amazon.nova-lite-v1:0`** (cheap, no Anthropic first-use form) |
| `aws bedrock-runtime converse --model-id us.amazon.nova-lite-v1:0` | Is model access enabled? | `"Bedrock ok"`, 10 tokens: no console action needed |
| python script adds `WriteIncidentReport` / `AnalyzeFailure` to both ASLs; `validate-state-machine-definition` | Bedrock via the optimized `bedrock:invokeModel` integration (Nova `messages-v1` body) | First attempt crashed locally: Python `%` formatting clashed with JSONata `{% %}`; rebuilt the strings by concatenation. Both ASLs `OK` |
| `terraform plan` / `apply` | SFN Bedrock IAM (one profile + its foundation model), new `mazf-ci-ai-analyze` role (envs/dev, so bootstrap stays untouched) | `2 to add, 4 to change, 0 to destroy` |
| `start-execution` with a bad ASG name | Failure path with AI | `Precheck -> AnalyzeFailure -> NotifyFailure -> Failed`; analysis named the bad ASG and suggested `aws autoscaling describe-auto-scaling-groups` |
| `scripts/simulate_outage.sh` (16:55:35Z) | Real failover with AI report (done-criteria) | ALARM 17:03:12 -> SUCCEEDED; `WriteIncidentReport` took **1.5 s**; email had SUMMARY / TIMELINE / DURATION / NEXT STEPS |
| compare AI timeline with `get-execution-history` | **Test #8a** | All timestamps match. AI said 131.8 s vs email 133.4 s: the facts were computed in `WriteIncidentReport`, the email 1.6 s later in `NotifySuccess` (not a hallucination) |
| `scripts/start_failback.sh` | Failback with AI report | SUCCEEDED; report wrote "Alarm-to-recovery time is **unknown**" (no alarm on a manual run): the "do not guess" rule works |
| `terraform apply -var bedrock_model_id=us.amazon.nova-doesnotexist-v1:0`, then failure path + planned failover + failback | **Test #8c** (state machines) | All three behaved exactly as before; AI parts said `(AI ... unavailable: Bedrock.ValidationException. The facts above are complete.)` |
| `terraform apply` (default model) + `plan -detailed-exitcode` | Restore | `exit 0` = no drift |
| `gh secret set AWS_AI_ROLE_ARN`, `gh variable set BEDROCK_MODEL_ID` | Inputs for the `ai-analyze` job | — |
| PR #6 (Phase 7) | CI with logs + ai-analyze | All green; `ai-analyze` **skipped** (nothing failed) |
| draft PR #7 with `read_capacity_units = 5` on a PAY_PER_REQUEST table | **Test #8b** | AI comment posted. **But** `terraform validate` had passed: see next row |
| analysis of PR #7 logs | Why did validate pass? | **Bug:** GitHub's default shell is `bash -e` **without pipefail**, so `terraform validate \| tee` hid the failure (and `deploy_app.sh \| tee` could hide a failed deploy). **Fix (PR #8):** `defaults.run.shell: bash` -> `-eo pipefail` |
| re-run PR #7 after the fix | — | Now fails at `terraform fmt` (first real error); AI: "Run `terraform fmt`": correct |
| `gh variable set BEDROCK_MODEL_ID` to a bad ID, `gh run rerun` | **Test #8c** (CI) | Every job result identical except `ai-analyze` success -> failure; run conclusion unchanged. Warning text was empty (CLI error starts with a newline) -> fixed with `tr -s '\n' ' '` |
| restore `BEDROCK_MODEL_ID`, `gh pr close 7` | Cleanup | Test PR closed, not merged |

**Phase 7 result: PASS** (AI report in failover email; AI comment on a failing PR; a wrong model ID never
breaks failover or CI).

**Lessons:** (1) always set `shell: bash` in GitHub Actions when piping to `tee`; (2) keep AI off the
recovery path: own timeout + Catch + a complete plain-text fallback; (3) give the model a facts JSON and
tell it to write "unknown"; it then does.

---

## Phase 8 (optional): scheduler

| Command | Why | Result / meaning |
|---|---|---|
| design | Scaling to 0 would fire our own alarm and the failover would scale the standby back up | A small state machine does the steps **in order**; 2 EventBridge Scheduler schedules only start it with `{"action":"stop"\|"start"}` |
| `validate-state-machine-definition`, `terraform plan` / `apply` | Scheduler state machine, 2 schedules, group, roles | `9 to add, 0 to change, 0 to destroy`. checkov: `CKV_AWS_297` (schedule CMK) skipped, input has no secrets |
| `terraform apply -var 'schedule_stop_expression=at(17:33)' -var 'schedule_start_expression=at(17:39)'` | Prove the schedules really fire | `0 add, 2 change`. 17:33 stop: rule DISABLED, actions off, ASGs 0/0; 17:39 start: ASG-a 1 |
| watch rule / alarm / targets | **Found a bug** | The start path re-armed after **1 minute** because the alarm still showed a **stale OK** (metrics ~5 min late). No failover happened only because the NLB publishes **no** datapoints while the target group is empty |
| `get-metric-statistics HealthyHostCount` | Why no ALARM during the 7-min stop? | Datapoints missing 17:34-17:39 (empty target group = no metric); CloudWatch evaluated older `1.0` points, so OK. Contrast Phase 4: registered-but-unhealthy target = `0` datapoints = ALARM |
| fix `scheduler.asl.json`: poll `elasticloadbalancingv2:describeTargetHealth` every minute; re-arm only when healthy **7 minutes in a row AND** alarm OK (cap 30 min) | Never trust a fresh OK | ASL `OK`; `terraform apply` (schedules kept on the test values) `0 add, 3 change`; committed `cf0c43d` |
| `aws stepfunctions start-execution --input '{"action":"stop"}'` (17:52) | **Manual stop test** (your request) | `DisableFailoverRule -> MuteAlarm -> ScaleDownPrimary -> ScaleDownStandby`; rule DISABLED, actions **False**, ASGs 0/0; watched 12 min: failover executions **7 -> 7** |
| `start-execution --input '{"action":"start"}'` (18:04) | **Manual start test** | Alarm went **ALARM at 18:05:40** (rule disabled: no failover). Target healthy 18:06:24. Polls: streak 0..5 with ALARM, streak 6 with OK (**still waited**), streak 7 + OK -> rule ENABLED, actions True at 18:12:37. Failover executions **still 7** |
| `terraform plan` / `apply` with defaults | Revert schedules (your request) | Plan touched **only the 2 schedules** (expression + timezone UTC -> America/New_York), `0 add, 2 change, 0 destroy`; now `cron(0 22 * * ? *)` / `cron(0 7 * * ? *)` ENABLED; drift check exit 0 |

**Phase 8 result: PASS** (schedules visible and fire correctly; stop never triggers a failover;
start re-arms only after the app is really healthy).

**Lesson:** an alarm state is only as fresh as its metric. Before re-arming automation, check the
source of truth (target health) for longer than metric delay + alarm periods.

---

## Remaining test plan items

| Command | Why | Result / meaning |
|---|---|---|
| `aws autoscaling suspend-processes --auto-scaling-group-name mazf-asg-a --scaling-processes Launch HealthCheck ReplaceUnhealthy`; `aws ec2 stop-instances` (18:13) | **Test #9** instance failure (stop, not terminate) | Target `unhealthy` in ~45 s (registered target -> `0` datapoints); alarm **ALARM 18:21**; failover execution #8 SUCCEEDED; app on `us-east-1b` |
| `aws autoscaling resume-processes`, `scripts/start_failback.sh` | Undo test #9 | Suspended list empty; stopped instance `Terminating`; failback SUCCEEDED; back on `us-east-1a`, 5 tasks |
| `terraform plan -destroy -out=destroy.tfplan` (envs/dev) | **Test #10** (read-only part) | `0 to add, 0 to change, 74 to destroy`, all from envs/dev modules; **nothing** from bootstrap (state/artifacts buckets, gha roles, OIDC provider, budget). Saved plan removed; **destroy not run** (needs your OK) |

**Test #9: PASS. Test #10: plan verified; destroy waits for approval.**

---

## Teardown

| Command | Why | Result / meaning |
|---|---|---|
| `terraform plan -destroy -out=destroy.tfplan` (envs/dev) | Rule: stop if anything from bootstrap is in the plan | `74 to destroy`, all from envs/dev modules; bootstrap matches: none |
| `terraform apply destroy.tfplan` | Destroy envs/dev | `74 destroyed` in 4m17s |
| `aws ec2 describe-instances / elbv2 describe-load-balancers / describe-target-groups / autoscaling / describe-addresses / describe-vpcs / describe-network-interfaces / stepfunctions / dynamodb` | Nothing left? | All **0**. KMS key `PendingDeletion` (7 days, no charge). Bootstrap buckets still there |
| `gh api -X DELETE repos/<repo>/actions/runs/<id>/logs` ×4 | Remove logs that showed the account ID / IP | API `204`; `GET .../logs` now **404** for all 4 (`gh run view --log` still showed one from the **local gh cache**) |
| `gh variable delete AWS_PLAN_ROLE_ARN / AWS_DEPLOY_ROLE_ARN / ALLOWED_CIDR` | Replaced by secrets in Phase 4 | Deleted; secrets unchanged |
| `rm bootstrap/terraform.tfstate bootstrap/terraform.tfstate.backup`, `terraform -chdir=bootstrap plan -detailed-exitcode` | Stale local copies from before the S3 migration | Removed; bootstrap plan exit 0 (remote state intact) |
