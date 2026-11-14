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
