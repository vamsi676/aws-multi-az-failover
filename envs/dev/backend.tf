# Remote state in the bootstrap state bucket with S3 native locking (no DynamoDB lock table).
# The bucket name (and local profile) come from backend.hcl:
#   terraform init -backend-config=backend.hcl
terraform {
  backend "s3" {
    key          = "envs/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
