# aws-multi-az-failover

Taskboard, a small Python web app running in two AWS Availability Zones behind one Network Load
Balancer. When the active AZ has no healthy target, Step Functions fails over to the standby AZ
automatically. Built with Terraform as a hands-on learning project. See [CLAUDE.md](CLAUDE.md)
for the full design and phase plan.

## Project summary

Built and deployed a multi-AZ Python app on AWS (Terraform, 74 resources) with event-driven
failover via CloudWatch, EventBridge, Step Functions and Lambda (measured RTO 8m35s, zero-downtime
failback), CodeDeploy releases with auto-rollback, GitHub Actions CI/CD over OIDC, and Amazon
Bedrock for AI incident reports and CI failure analysis.

## Layout

| Path | What |
|---|---|
| `bootstrap/` | Long-lived: Terraform state bucket, artifacts bucket, budget, GitHub OIDC roles |
| `envs/dev/` | Per-session stack (destroy after every session) |
| `modules/` | `network`, `nlb`, `data`, `compute`, `deploy` |
| `scripts/status.sh` | Read-only status of the running stack |

## Prerequisites

Terraform >= 1.11, AWS CLI v2, `jq`, the Session Manager plugin for the AWS CLI, and an AWS
profile with admin rights for the bootstrap step.

## 1. Bootstrap (once)

`bootstrap/` creates the state bucket it later stores its own state in, so the first apply uses
local state and then migrates:

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars        # fill in
terraform init
terraform plan -out=tfplan && terraform apply tfplan

cp backend.hcl.example backend.hcl                  # bucket = $(terraform output -raw state_bucket_name)
# uncomment the backend "s3" block in backend.tf
terraform init -migrate-state -backend-config=backend.hcl
rm terraform.tfstate terraform.tfstate.backup
```

To rebuild bootstrap from zero later, reverse it: comment the backend block out again,
`terraform init -migrate-state` back to local, then remove `prevent_destroy` before any destroy.

## 2. Dev stack (every session)

```bash
cd envs/dev
cp backend.hcl.example backend.hcl                  # same state bucket
cp terraform.tfvars.example terraform.tfvars        # allowed_cidr, artifacts_bucket_name
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan && terraform apply tfplan
AWS_PROFILE=<profile> ../../scripts/status.sh
```

Destroy at the end of every session (the NLB and public IPv4 addresses cost money even when idle):

```bash
terraform plan -destroy -out=destroy.tfplan && terraform apply destroy.tfplan
```
