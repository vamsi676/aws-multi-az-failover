variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "github_repository" {
  description = "owner/repo whose pull_request jobs may assume the role."
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

variable "bedrock_resource_arns" {
  description = "Model / inference profile ARNs the role may invoke."
  type        = list(string)
}
