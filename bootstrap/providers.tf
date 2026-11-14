provider "aws" {
  region = var.aws_region
  # Local runs use a named profile; leave it null to use environment credentials.
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = "aws-multi-az-failover"
      ManagedBy = "terraform"
      Owner     = var.owner
    }
  }
}
