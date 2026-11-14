variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "ami_ssm_parameter" {
  description = "Public SSM parameter that holds the AMI ID (resolved at every launch)."
  type        = string
  default     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

variable "subnet_a_id" {
  description = "Subnet for ASG-a (active AZ)."
  type        = string
}

variable "subnet_b_id" {
  description = "Subnet for ASG-b (standby AZ)."
  type        = string
}

variable "instance_sg_id" {
  description = "Security group for the instances."
  type        = string
}

variable "target_group_arn" {
  description = "NLB target group both ASGs register into."
  type        = string
}

variable "table_arn" {
  description = "DynamoDB table the app may access."
  type        = string
}

variable "artifacts_bucket_arn" {
  description = "S3 bucket holding CodeDeploy bundles under releases/."
  type        = string
}
