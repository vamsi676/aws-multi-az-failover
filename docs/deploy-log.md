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
