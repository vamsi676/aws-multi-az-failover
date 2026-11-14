variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "asg_a_name" {
  description = "Primary ASG (started in the morning)."
  type        = string
}

variable "asg_b_name" {
  description = "Standby ASG (also stopped at night)."
  type        = string
}

variable "asg_arns" {
  description = "ARNs of both ASGs."
  type        = list(string)
}

variable "event_rule_name" {
  description = "EventBridge rule that starts the failover (disabled at night)."
  type        = string
}

variable "event_rule_arn" {
  description = "ARN of that rule."
  type        = string
}

variable "alarm_name" {
  description = "HealthyHostCount alarm (actions muted at night)."
  type        = string
}

variable "alarm_arn" {
  description = "ARN of that alarm."
  type        = string
}

variable "stop_expression" {
  description = "EventBridge Scheduler expression for the night stop."
  type        = string
  default     = "cron(0 22 * * ? *)"
}

variable "start_expression" {
  description = "EventBridge Scheduler expression for the morning start."
  type        = string
  default     = "cron(0 7 * * ? *)"
}

variable "timezone" {
  description = "IANA time zone for both schedules."
  type        = string
  default     = "UTC"
}
