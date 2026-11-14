variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "asg_names" {
  description = "ASGs in the deployment group (both, so a deployment never targets zero instances)."
  type        = list(string)
}

variable "instance_role_arn" {
  description = "Instance role CodeDeploy may pass when it works with the launch template."
  type        = string
}
