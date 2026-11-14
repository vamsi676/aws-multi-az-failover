output "state_bucket_name" {
  description = "S3 bucket for Terraform remote state (put this in backend.hcl)."
  value       = aws_s3_bucket.state.bucket
}

output "artifacts_bucket_name" {
  description = "S3 bucket for CodeDeploy app bundles (envs/dev var artifacts_bucket_name)."
  value       = aws_s3_bucket.artifacts.bucket
}

output "artifacts_bucket_arn" {
  description = "ARN of the artifacts bucket."
  value       = aws_s3_bucket.artifacts.arn
}

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "gha_plan_role_arn" {
  description = "Role assumed by CI on pull requests (repo variable in Phase 3)."
  value       = aws_iam_role.gha_plan.arn
}

output "gha_deploy_role_arn" {
  description = "Role assumed by deploy/destroy workflows in environment dev (Phase 3)."
  value       = aws_iam_role.gha_deploy.arn
}

output "budget_name" {
  description = "Name of the monthly AWS Budget."
  value       = aws_budgets_budget.monthly.name
}
