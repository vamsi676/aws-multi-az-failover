output "nlb_arn" {
  description = "NLB ARN."
  value       = aws_lb.this.arn
}

output "nlb_arn_suffix" {
  description = "NLB ARN suffix (CloudWatch LoadBalancer dimension)."
  value       = aws_lb.this.arn_suffix
}

output "nlb_dns_name" {
  description = "Public DNS name of the NLB."
  value       = aws_lb.this.dns_name
}

output "target_group_arn" {
  description = "Target group ARN (both ASGs attach to it)."
  value       = aws_lb_target_group.this.arn
}

output "target_group_arn_suffix" {
  description = "Target group ARN suffix (CloudWatch TargetGroup dimension)."
  value       = aws_lb_target_group.this.arn_suffix
}
