variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the target group."
  type        = string
}

variable "subnet_ids" {
  description = "Public subnet IDs, one per AZ."
  type        = list(string)
}

variable "nlb_sg_id" {
  description = "Security group attached to the NLB (must be set at creation)."
  type        = string
}

variable "health_check_path" {
  description = "HTTP path used by the target group health check."
  type        = string
  default     = "/healthz"
}

variable "deregistration_delay" {
  description = "Seconds to drain a target before deregistering (default 300 is slow for failover)."
  type        = number
  default     = 30
}
