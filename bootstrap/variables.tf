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

variable "budget_email" {
  description = "Email address that receives AWS Budget alerts."
  type        = string
}

variable "budget_limit_usd" {
  description = "Monthly cost budget in USD."
  type        = number
  default     = 10
}

variable "github_owner" {
  description = "GitHub user or organization that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (without the owner)."
  type        = string
}

variable "github_owner_id" {
  description = "Numeric GitHub owner ID (gh api users/<owner> -q .id), used in immutable OIDC subjects."
  type        = string
}

variable "github_repo_id" {
  description = "Numeric GitHub repository ID (gh api repos/<owner>/<repo> -q .id), used in immutable OIDC subjects."
  type        = string
}
