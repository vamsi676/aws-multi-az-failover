# ---------------------------------------------------------------------------
# Step Functions role (shared by the failover and, later, failback machines)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "sfn_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "sfn" {
  name               = "${var.name_prefix}-sfn"
  description        = "Step Functions failover/failback state machines"
  assume_role_policy = data.aws_iam_policy_document.sfn_trust.json
}

data "aws_iam_policy_document" "sfn" {
  statement {
    sid       = "InvokeOurLambdas"
    actions   = ["lambda:InvokeFunction"]
    resources = flatten([for f in aws_lambda_function.this : [f.arn, "${f.arn}:*"]])
  }

  statement {
    sid       = "PublishAlerts"
    actions   = ["sns:Publish"]
    resources = [var.sns_topic_arn]
  }

  # The topic is encrypted with a customer-managed key.
  statement {
    sid       = "UseTopicKey"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [var.kms_key_arn]
  }

  # CloudWatch Logs delivery for state machine logging (these APIs need "*").
  statement {
    sid = "LogDelivery"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "sfn" {
  name   = "state-machine"
  role   = aws_iam_role.sfn.id
  policy = data.aws_iam_policy_document.sfn.json
}

resource "aws_cloudwatch_log_group" "failover" {
  name              = "/aws/vendedlogs/states/${var.name_prefix}-failover"
  retention_in_days = 7
}

resource "aws_sfn_state_machine" "failover" {
  name     = "${var.name_prefix}-failover"
  type     = "STANDARD"
  role_arn = aws_iam_role.sfn.arn

  definition = templatefile("${path.module}/../../statemachines/failover.asl.json", {
    source_asg        = var.active_asg_name
    target_asg        = var.standby_asg_name
    source_az         = var.active_az
    target_az         = var.standby_az
    precheck_arn      = aws_lambda_function.this["precheck"].arn
    scale_asg_arn     = aws_lambda_function.this["scale_asg"].arn
    check_targets_arn = aws_lambda_function.this["check_targets"].arn
    sns_topic_arn     = var.sns_topic_arn
    target_group_arn  = var.target_group_arn
    codedeploy_app    = var.codedeploy_app
    deployment_group  = var.deployment_group
    max_checks        = var.max_checks
  })

  logging_configuration {
    level                  = "ERROR"
    include_execution_data = true
    log_destination        = "${aws_cloudwatch_log_group.failover.arn}:*"
  }

  depends_on = [aws_iam_role_policy.sfn]
}

# ---------------------------------------------------------------------------
# EventBridge: alarm -> ALARM starts the failover state machine
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "alarm" {
  name        = "${var.name_prefix}-alarm-to-failover"
  description = "HealthyHostCount alarm entered ALARM: start the failover state machine"

  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    resources     = [var.alarm_arn]
    detail = {
      state = { value = ["ALARM"] }
    }
  })
}

data "aws_iam_policy_document" "events_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "events" {
  name               = "${var.name_prefix}-events-start-failover"
  description        = "EventBridge: start the failover state machine"
  assume_role_policy = data.aws_iam_policy_document.events_trust.json
}

data "aws_iam_policy_document" "events" {
  statement {
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.failover.arn]
  }
}

resource "aws_iam_role_policy" "events" {
  name   = "start-failover"
  role   = aws_iam_role.events.id
  policy = data.aws_iam_policy_document.events.json
}

resource "aws_cloudwatch_event_target" "failover" {
  rule     = aws_cloudwatch_event_rule.alarm.name
  arn      = aws_sfn_state_machine.failover.arn
  role_arn = aws_iam_role.events.arn
}

# ---------------------------------------------------------------------------
# Failback (manual, scripts/start_failback.sh): same pattern, reverse direction.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "failback" {
  name              = "/aws/vendedlogs/states/${var.name_prefix}-failback"
  retention_in_days = 7
}

resource "aws_sfn_state_machine" "failback" {
  name     = "${var.name_prefix}-failback"
  type     = "STANDARD"
  role_arn = aws_iam_role.sfn.arn

  definition = templatefile("${path.module}/../../statemachines/failback.asl.json", {
    source_asg        = var.standby_asg_name
    target_asg        = var.active_asg_name
    source_az         = var.standby_az
    target_az         = var.active_az
    precheck_arn      = aws_lambda_function.this["precheck"].arn
    scale_asg_arn     = aws_lambda_function.this["scale_asg"].arn
    check_targets_arn = aws_lambda_function.this["check_targets"].arn
    sns_topic_arn     = var.sns_topic_arn
    target_group_arn  = var.target_group_arn
    codedeploy_app    = var.codedeploy_app
    deployment_group  = var.deployment_group
    max_checks        = var.max_checks
  })

  logging_configuration {
    level                  = "ERROR"
    include_execution_data = true
    log_destination        = "${aws_cloudwatch_log_group.failback.arn}:*"
  }

  depends_on = [aws_iam_role_policy.sfn]
}
