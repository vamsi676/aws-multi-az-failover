provider "aws" {
  region = var.aws_region
  # Local runs use a named profile; in GitHub Actions it stays null and OIDC
  # credentials come from the environment.
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = "aws-multi-az-failover"
      ManagedBy = "terraform"
      Owner     = var.owner
    }
  }
}
