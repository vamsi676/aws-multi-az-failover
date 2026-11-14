variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "active_asg_name" {
  description = "ASG in the normally active AZ (failover source)."
  type        = string
}

variable "standby_asg_name" {
  description = "ASG in the standby AZ (failover target)."
  type        = string
}

variable "asg_arns" {
  description = "ARNs of both ASGs (scale_asg may only change these)."
  type        = list(string)
}

variable "active_az" {
  description = "AZ of the active ASG."
  type        = string
}

variable "standby_az" {
  description = "AZ of the standby ASG."
  type        = string
}

variable "target_group_arn" {
  description = "NLB target group shared by both ASGs."
  type        = string
}

variable "sns_topic_arn" {
  description = "Alerts topic for success/skipped/failed notifications."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key of the alerts topic (Step Functions needs it to publish)."
  type        = string
}

variable "alarm_arn" {
  description = "HealthyHostCount alarm that triggers the failover."
  type        = string
}

variable "codedeploy_app" {
  description = "CodeDeploy application name (precheck deployment guard)."
  type        = string
}

variable "deployment_group" {
  description = "CodeDeploy deployment group name (precheck deployment guard)."
  type        = string
}

variable "max_checks" {
  description = "Max target-health checks, 30s apart, before the failover gives up."
  type        = number
  default     = 30
}

variable "bedrock_model_arn" {
  description = "Model or inference profile ARN used by the AI reporter states."
  type        = string
}

variable "bedrock_resource_arns" {
  description = "ARNs bedrock:InvokeModel is scoped to (profile + underlying foundation models)."
  type        = list(string)
}

variable "bedrock_max_tokens" {
  description = "Max output tokens for the AI report/analysis (keeps cost low)."
  type        = number
  default     = 600
}
