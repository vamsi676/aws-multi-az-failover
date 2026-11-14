output "asg_a_name" {
  description = "Active ASG name (AZ a)."
  value       = aws_autoscaling_group.this["a"].name
}

output "asg_b_name" {
  description = "Standby ASG name (AZ b)."
  value       = aws_autoscaling_group.this["b"].name
}

output "asg_a_arn" {
  description = "Active ASG ARN."
  value       = aws_autoscaling_group.this["a"].arn
}

output "asg_b_arn" {
  description = "Standby ASG ARN."
  value       = aws_autoscaling_group.this["b"].arn
}

output "instance_role_arn" {
  description = "IAM role ARN of the instances (CodeDeploy needs iam:PassRole on it)."
  value       = aws_iam_role.instance.arn
}

output "launch_template_id" {
  description = "Launch template ID."
  value       = aws_launch_template.this.id
}
