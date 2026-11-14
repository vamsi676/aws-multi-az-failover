# Chicken-and-egg: this stack creates the state bucket, so the FIRST apply runs with
# local state, then migrated (done). Steps used:
#   1. cp backend.hcl.example backend.hcl and set bucket = <state_bucket_name output>
#   2. Uncomment the block below
#   3. terraform init -migrate-state -backend-config=backend.hcl   (answer "yes")
#   4. rm terraform.tfstate terraform.tfstate.backup
#
terraform {
  backend "s3" {
    key          = "bootstrap/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
