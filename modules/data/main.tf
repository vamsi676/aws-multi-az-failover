# Regional table: data survives an AZ failover because DynamoDB is not tied to one AZ.
resource "aws_dynamodb_table" "tasks" {
  name         = "${var.name_prefix}-tasks"
  billing_mode = "PAY_PER_REQUEST"
  read_capacity_units = 5
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  # No server_side_encryption block: DynamoDB always encrypts at rest, and without the
  # block it uses the AWS-owned key (free). The stack is destroyed after every session,
  # so no PITR and no deletion protection.

  tags = {
    Name = "${var.name_prefix}-tasks"
  }
}
