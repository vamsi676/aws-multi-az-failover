variable "aws_profile" {
  description = "Named AWS CLI profile for local runs. Null = use environment credentials."
  type        = string
  default     = null
}

variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for all resource names."
  type        = string
  default     = "mazf"
}

variable "owner" {
  description = "Value of the Owner tag."
  type        = string
}

variable "allowed_cidr" {
  description = "Your public IP as a /32; the only source allowed to reach the NLB."
  type        = string
  # Hidden in plan output: CI logs and PR comments of a public repo are public.
  sensitive = true
}

variable "alert_email" {
  description = "Email subscribed to the alerts SNS topic (confirm the subscription email)."
  type        = string
  sensitive   = true
}

variable "artifacts_bucket_name" {
  description = "Artifacts bucket created by bootstrap (output artifacts_bucket_name)."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "azs" {
  description = "[active AZ, standby AZ]."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "bedrock_model_id" {
  description = "Bedrock model ID or inference profile ID (newer models need a profile, e.g. us.amazon.nova-lite-v1:0). The request body uses the Amazon Nova messages-v1 format."
  type        = string
  default     = "us.amazon.nova-lite-v1:0"
}

variable "github_repository" {
  description = "owner/repo allowed to use the CI AI analyzer role (CI passes github.repository)."
  type        = string
}

variable "github_owner_id" {
  description = "Numeric GitHub owner ID (immutable OIDC subject)."
  type        = string
}

variable "github_repo_id" {
  description = "Numeric GitHub repository ID (immutable OIDC subject)."
  type        = string
}

variable "schedule_stop_expression" {
  description = "Night stop (EventBridge Scheduler expression)."
  type        = string
  default     = "cron(0 22 * * ? *)"
}

variable "schedule_start_expression" {
  description = "Morning start (EventBridge Scheduler expression)."
  type        = string
  default     = "cron(0 7 * * ? *)"
}

variable "schedule_timezone" {
  description = "IANA time zone for the schedules."
  type        = string
  default     = "UTC"
}
