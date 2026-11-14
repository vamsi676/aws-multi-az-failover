output "failover_state_machine_arn" {
  description = "Failover state machine ARN."
  value       = aws_sfn_state_machine.failover.arn
}

output "lambda_function_names" {
  description = "Lambda function names by key."
  value       = { for k, f in aws_lambda_function.this : k => f.function_name }
}

output "event_rule_name" {
  description = "EventBridge rule that starts the failover."
  value       = aws_cloudwatch_event_rule.alarm.name
}
