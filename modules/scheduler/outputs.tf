output "state_machine_arn" {
  description = "Scheduler state machine ARN."
  value       = aws_sfn_state_machine.this.arn
}

output "schedule_names" {
  description = "EventBridge Scheduler schedule names."
  value       = [for s in aws_scheduler_schedule.this : s.name]
}
