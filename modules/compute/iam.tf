data "aws_partition" "current" {}

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.name_prefix}-instance"
  description        = "Taskboard instances: SSM, CodeDeploy bundles, DynamoDB table"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

# Session Manager access instead of SSH; also used by SSM Run Command (outage simulation).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "instance" {
  statement {
    sid = "TasksTable"
    actions = [
      "dynamodb:DescribeTable",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Scan",
      "dynamodb:Query",
    ]
    resources = [var.table_arn]
  }

  # The CodeDeploy agent downloads bundles with the instance role.
  statement {
    sid       = "ReadReleases"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${var.artifacts_bucket_arn}/releases/*"]
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "app-access"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name_prefix}-instance"
  role = aws_iam_role.instance.name
}
