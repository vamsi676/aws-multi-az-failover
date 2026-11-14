output "aws_region" {
  description = "Region (used by scripts)."
  value       = var.aws_region
}

output "name_prefix" {
  description = "Name prefix (used by scripts)."
  value       = var.name_prefix
}

output "nlb_dns_name" {
  description = "Public DNS name of the NLB."
  value       = module.nlb.nlb_dns_name
}

output "app_url" {
  description = "Taskboard URL."
  value       = "http://${module.nlb.nlb_dns_name}"
}

output "nlb_arn_suffix" {
  description = "NLB ARN suffix (CloudWatch dimension)."
  value       = module.nlb.nlb_arn_suffix
}

output "target_group_arn" {
  description = "Target group ARN."
  value       = module.nlb.target_group_arn
}

output "target_group_arn_suffix" {
  description = "Target group ARN suffix (CloudWatch dimension)."
  value       = module.nlb.target_group_arn_suffix
}

output "asg_a_name" {
  description = "Active ASG (AZ a)."
  value       = module.compute.asg_a_name
}

output "asg_b_name" {
  description = "Standby ASG (AZ b)."
  value       = module.compute.asg_b_name
}

output "table_name" {
  description = "DynamoDB table name."
  value       = module.data.table_name
}

output "artifacts_bucket_name" {
  description = "Artifacts bucket for app bundles."
  value       = data.aws_s3_bucket.artifacts.bucket
}

output "codedeploy_app_name" {
  description = "CodeDeploy application."
  value       = module.deploy.app_name
}

output "codedeploy_deployment_group_name" {
  description = "CodeDeploy deployment group."
  value       = module.deploy.deployment_group_name
}

output "sns_topic_arn" {
  description = "Alerts SNS topic."
  value       = module.monitoring.sns_topic_arn
}

output "alarm_name" {
  description = "HealthyHostCount alarm."
  value       = module.monitoring.alarm_name
}

output "failover_state_machine_arn" {
  description = "Failover state machine."
  value       = module.failover.failover_state_machine_arn
}
