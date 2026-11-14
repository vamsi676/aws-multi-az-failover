variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "alert_email" {
  description = "Email address subscribed to the alerts topic."
  type        = string
  sensitive   = true
}

variable "nlb_arn_suffix" {
  description = "NLB ARN suffix (LoadBalancer dimension)."
  type        = string
}

variable "target_group_arn_suffix" {
  description = "Target group ARN suffix (TargetGroup dimension)."
  type        = string
}
