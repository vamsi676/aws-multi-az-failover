output "sns_topic_arn" {
  description = "Alerts SNS topic ARN."
  value       = aws_sns_topic.alerts.arn
}

output "kms_key_arn" {
  description = "KMS key that encrypts the SNS topic (Step Functions needs GenerateDataKey/Decrypt)."
  value       = aws_kms_key.sns.arn
}

output "alarm_name" {
  description = "Name of the HealthyHostCount alarm."
  value       = aws_cloudwatch_metric_alarm.no_healthy_hosts.alarm_name
}

output "alarm_arn" {
  description = "ARN of the HealthyHostCount alarm (EventBridge rule filter)."
  value       = aws_cloudwatch_metric_alarm.no_healthy_hosts.arn
}
