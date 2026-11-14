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
