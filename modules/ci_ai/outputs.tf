output "role_arn" {
  description = "ARN of the CI AI analyzer role."
  value       = aws_iam_role.this.arn
}
