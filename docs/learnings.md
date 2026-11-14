# Learnings

## Phase 0: bootstrap

- A Terraform `backend` block cannot use variables, and the state bucket cannot hold state before it
  exists. Solution: apply with local state first, then `terraform init -migrate-state` into S3.
- Terraform >= 1.11 locks state with an S3 object (`use_lockfile = true`); no DynamoDB lock table needed.
- GitHub OIDC: the role trust policy checks the token's `sub` claim. Pull requests send
  `repo:<owner>/<repo>:pull_request`; jobs in an environment send `repo:<owner>/<repo>:environment:<name>`.
- PowerUserAccess has no IAM rights, so the deploy role gets IAM only on `<prefix>-*` names, plus an
  explicit Deny on its own `gha-*` roles so it cannot escalate its own permissions.

## Phase 1: infra

- No NAT Gateway means instances need public IPs to reach SSM/CodeDeploy/S3. Public IPv4 costs
  $0.005/hr each, and the security group (port 80 from the NLB SG only) is what keeps them private.
- ASG `health_check_type = "EC2"` on purpose: with `ELB`, the ASG would replace the instance in the
  same AZ and the failover would never trigger.
- `image_id = "resolve:ssm:..."` in the launch template resolves the newest AL2023 AMI at each launch,
  without Terraform drift.
- NLB target group deregistration delay defaults to 300s; 30s makes failover faster.

## Phase 2: app

- Vendor wheels for the *instance* platform on any laptop: `pip install --target vendor --platform manylinux2014_x86_64 --python-version 3.11 --only-binary=:all:`.
- A launch template change does not touch running instances; an ASG **instance refresh** does.
- CodeDeploy hooks must be idempotent: ApplicationStop runs on fresh instances where nothing is installed yet.

## Phase 3: CI/CD

- GitHub may issue **immutable OIDC subjects** (`repo:owner@id/repo@id:...`); check `actions/oidc/customization/sub` before writing trust policies.
- Free GitHub plan: environment protection rules (required reviewers) only on public repos.
- Public repo = public Actions logs: put role ARNs, IPs and emails in **secrets**, mark them `sensitive` in Terraform.
- GitHub's default `run:` shell is `bash -e` without pipefail: `cmd | tee log` hides failures. Use `defaults.run.shell: bash`.

## Phase 4: monitoring

- SNS topics encrypted with the AWS-managed key cannot receive CloudWatch alarms; use a CMK that allows `cloudwatch.amazonaws.com`.
- NLB metrics arrive ~4-5 min late, so the alarm fires ~7 min after the app stops.
- With all targets unhealthy the NLB "fails open" (still forwards); with **no** registered targets it publishes no `HealthyHostCount` at all.

## Phase 5-6: failover / failback

- EventBridge starts the state machine within a second of ALARM; detection dominates the RTO (8m35s measured).
- Scale the old side down only after the new side is healthy: a planned failback had zero failed requests.
- JSONata `Assign` variables make per-step timestamps easy to collect for the notification.

## Phase 7: Bedrock

- AI must never be on the recovery path: short timeout, own Catch, complete plain-text fallback.
- Give the model a facts JSON and an explicit "write unknown, do not guess" rule.
- Inference profile IDs (`us.amazon.nova-lite-v1:0`) work in Step Functions as an inference-profile ARN; IAM needs the profile ARN plus the foundation model in every region it routes to.

## Phase 8: scheduler

- Turning capacity off fires your own failover alarm: disable the EventBridge rule and mute the alarm *before* scaling to 0.
- Do not trust an "OK" alarm right after starting: it can be stale. Wait for N healthy minutes (> metric delay + alarm periods) before re-arming.
