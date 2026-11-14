# Runbook

All commands run from the repo root with `export AWS_PROFILE=<profile> AWS_REGION=us-east-1 AWS_PAGER=""`.
Names and ARNs come from `terraform -chdir=envs/dev output`.

## Start again next time

`bootstrap/` (state + artifacts buckets, budget, OIDC roles) stays; only `envs/dev` is rebuilt.

1. `aws sts get-caller-identity` (right account/profile).
2. Your IP changes often: `curl -s https://checkip.amazonaws.com` -> update `allowed_cidr` in
   `envs/dev/terraform.tfvars` **and** `gh secret set ALLOWED_CIDR` (CI plans use the secret).
3. `cd envs/dev && terraform init -backend-config=backend.hcl && terraform plan -out=tfplan`
   -> expect **74 to add, 0 to destroy** -> `terraform apply tfplan` (~5 min; the NLB is slowest).
4. **Confirm the new SNS subscription email** (every rebuild creates a new subscription).
5. Wait ~3 min for cloud-init, then deploy the app (a new deployment group has no revision yet):
   `PYTHON=.venv/bin/python scripts/build_app.sh && scripts/deploy_app.sh dist/taskboard-<sha>.zip`
   (or the `deploy` workflow with `app`, approve environment `dev`).
6. `scripts/status.sh` -> ASG-a 1 InService, target healthy, alarm OK; open the app URL.
   The DynamoDB table is new, so the board starts empty.
7. CI's `ai-analyze` role (`mazf-ci-ai-analyze`) only exists while envs/dev is up; its ARN does
   not change, so the `AWS_AI_ROLE_ARN` secret stays valid.
8. While the stack is up the night schedule runs (22:00 stop / 07:00 start, America/New_York).
9. End of session: `terraform plan -destroy -out=destroy.tfplan` (check nothing from bootstrap)
   -> `terraform apply destroy.tfplan`. The KMS key goes to `PendingDeletion` for 7 days (no charge).

## Daily use

| Task | Command |
|---|---|
| Status (ASGs, targets, alarm, executions, deployments) | `scripts/status.sh` |
| Build + deploy the app from your laptop | `scripts/build_app.sh && scripts/deploy_app.sh dist/taskboard-<sha>.zip` |
| Deploy through CI | GitHub -> Actions -> `deploy` -> Run workflow (`app` / `infra` / `both`) -> approve environment `dev` |
| Simulate an outage | `scripts/simulate_outage.sh` (stops `taskboard` on ASG-a via SSM Run Command) |
| Undo a simulated outage without failover | `scripts/simulate_outage.sh --restore` |
| Fail back to us-east-1a | `scripts/start_failback.sh` |
| Stop / start the app outside the schedule | `aws stepfunctions start-execution --state-machine-arn <scheduler_state_machine_arn> --input '{"action":"stop"}'` (or `"start"`) |

## What to expect

- Detection is the slow part: NLB metrics reach CloudWatch ~4-5 min late, plus 2 alarm periods.
  Measured unplanned RTO: **8m35s** (≈7 min detection + ≈1.5 min failover).
- A planned failback has **zero** failed requests (new AZ is healthy before the old one is removed).
- If the target group has **no registered target at all**, the NLB publishes no `HealthyHostCount`
  datapoints and the alarm can stay `OK` for a while (CloudWatch looks back to older datapoints).
  The alarm reacts fastest when the instance is running but the app is unhealthy (our outage test).
- Night schedule (EventBridge Scheduler, America/New_York): 22:00 stop, 07:00 start. The stop
  disables the failover rule and mutes the alarm first; the start re-arms them only after the
  target has been healthy for 7 straight minutes and the alarm is OK (max 30 min wait).

## Test plan

| # | Test | How | Pass when |
|---|---|---|---|
| 1 | Failover (happy path) | add tasks, open `/` and `/status`, `scripts/simulate_outage.sh` | alarm email -> execution SUCCEEDED -> board on us-east-1b with the same tasks -> success email (with AI report). Record RTO from `/status` |
| 2 | Failback | `scripts/start_failback.sh` | back on us-east-1a, same tasks, email |
| 3 | Split-brain guard | while on AZ-b: `aws stepfunctions start-execution --state-machine-arn <failover> --input '{}'` | `NotifySkipped`, "skipped" email, nothing scaled |
| 4 | Failure path | `start-execution --input '{"overrides":{"target_asg":"mazf-asg-does-not-exist"}}'` | `AnalyzeFailure -> NotifyFailure -> Failed`, FAILED email with AI analysis |
| 5 | Deploy | change the app -> PR -> CI green -> merge -> `deploy` workflow (`app`) -> approve | new version in `/api/meta` |
| 6 | Bad deploy rollback | bundle whose `ValidateService` exits 1 -> `scripts/deploy_app.sh` | deployment Failed, automatic rollback Succeeded, previous version served |
| 7 | Fresh-instance deploy | run test 1 | CodeDeploy deployment with `creator: autoscaling` Succeeded for the new instance; no launch/terminate loop |
| 8 | Bedrock | compare the AI timeline with `get-execution-history`; PR with a broken `.tf`; wrong model ID (`-var bedrock_model_id=...` / repo variable `BEDROCK_MODEL_ID`) | timeline matches; AI PR comment; failover and CI behave the same, AI text says "unavailable" |
| 9 | Instance failure (optional) | suspend `Launch`, `HealthCheck`, `ReplaceUnhealthy` on ASG-a; stop (not terminate) the AZ-a instance | failover to 1b; resume the processes afterwards |
| 10 | Cleanup | failback, then `terraform -chdir=envs/dev plan -destroy` (confirm nothing from `bootstrap/`), then `terraform destroy` in `envs/dev` or the `destroy` workflow | only envs/dev resources destroyed |

Never test by **terminating** the active instance: ASG-a would relaunch in the same AZ while the
failover also starts.

## When something goes wrong

| Symptom | Check |
|---|---|
| Board shows "Connection lost" | `scripts/status.sh`; target health; `curl <nlb>/healthz` (502 = app down behind nginx) |
| Failover did not start | alarm state; EventBridge rule `mazf-alarm-to-failover` **enabled**? (the night schedule disables it) |
| Failover FAILED email | the AI analysis + Step Functions execution history; ASG desired values; target health |
| Deployment failed | `aws deploy get-deployment-target ...` lifecycle events; `/var/log/aws/codedeploy-agent/` via SSM |
| CI plan cannot assume role | `gh api repos/<owner>/<repo>/actions/oidc/customization/sub` vs the role trust policy |
