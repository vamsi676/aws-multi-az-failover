data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  lambdas = {
    precheck      = "Failover precheck: split-brain, concurrent execution and deployment guards"
    scale_asg     = "Set desired capacity of one ASG"
    check_targets = "Are the instances of one ASG healthy in the NLB target group?"
  }

  state_machine_arn_pattern = "arn:${local.partition}:states:${local.region}:${local.account_id}:stateMachine:${var.name_prefix}-*"
  deployment_group_arn      = "arn:${local.partition}:codedeploy:${local.region}:${local.account_id}:deploymentgroup:${var.codedeploy_app}/${var.deployment_group}"
}

data "archive_file" "lambda" {
  for_each = local.lambdas

  type        = "zip"
  source_dir  = "${path.module}/../../lambda/${each.key}"
  output_path = "${path.module}/../../dist/lambda/${each.key}.zip"
  excludes    = ["__pycache__"]
}

resource "aws_cloudwatch_log_group" "lambda" {
  for_each = local.lambdas

  name              = "/aws/lambda/${var.name_prefix}-${replace(each.key, "_", "-")}"
  retention_in_days = 7
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  for_each = local.lambdas

  name               = "${var.name_prefix}-lambda-${replace(each.key, "_", "-")}"
  description        = each.value
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

# ---- one least-privilege policy per function ----
data "aws_iam_policy_document" "precheck" {
  statement {
    sid       = "ReadAsgs"
    actions   = ["autoscaling:DescribeAutoScalingGroups"]
    resources = ["*"] # Describe* does not support resource-level permissions
  }

  statement {
    sid       = "ListOwnExecutions"
    actions   = ["states:ListExecutions"]
    resources = [local.state_machine_arn_pattern]
  }

  statement {
    sid       = "ListDeployments"
    actions   = ["codedeploy:ListDeployments"]
    resources = [local.deployment_group_arn]
  }
}

data "aws_iam_policy_document" "scale_asg" {
  statement {
    sid       = "ReadAsgs"
    actions   = ["autoscaling:DescribeAutoScalingGroups"]
    resources = ["*"]
  }

  statement {
    sid       = "ScaleOurAsgsOnly"
    actions   = ["autoscaling:SetDesiredCapacity"]
    resources = var.asg_arns
  }
}

data "aws_iam_policy_document" "check_targets" {
  statement {
    sid = "ReadHealth"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "elasticloadbalancing:DescribeTargetHealth",
    ]
    resources = ["*"]
  }
}

locals {
  lambda_policies = {
    precheck      = data.aws_iam_policy_document.precheck.json
    scale_asg     = data.aws_iam_policy_document.scale_asg.json
    check_targets = data.aws_iam_policy_document.check_targets.json
  }
}

resource "aws_iam_role_policy" "lambda" {
  for_each = local.lambdas

  name   = "function"
  role   = aws_iam_role.lambda[each.key].id
  policy = local.lambda_policies[each.key]
}

data "aws_iam_policy_document" "lambda_logs" {
  for_each = local.lambdas

  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda[each.key].arn}:*"]
  }
}

resource "aws_iam_role_policy" "lambda_logs" {
  for_each = local.lambdas

  name   = "logs"
  role   = aws_iam_role.lambda[each.key].id
  policy = data.aws_iam_policy_document.lambda_logs[each.key].json
}

resource "aws_lambda_function" "this" {
  for_each = local.lambdas

  function_name    = "${var.name_prefix}-${replace(each.key, "_", "-")}"
  description      = each.value
  role             = aws_iam_role.lambda[each.key].arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.lambda[each.key].output_path
  source_code_hash = data.archive_file.lambda[each.key].output_base64sha256
  timeout          = 30
  memory_size      = 128

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda[each.key].name
  }

  depends_on = [
    aws_iam_role_policy.lambda,
    aws_iam_role_policy.lambda_logs,
  ]
}
