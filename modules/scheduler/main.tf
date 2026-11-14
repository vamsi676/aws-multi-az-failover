data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# ---------------------------------------------------------------------------
# State machine that performs the stop/start steps in a safe order
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
  name               = "${var.name_prefix}-scheduler-sfn"
  description        = "Night stop / morning start state machine"
  assume_role_policy = data.aws_iam_policy_document.sfn_trust.json
}

data "aws_iam_policy_document" "sfn" {
  statement {
    sid       = "ToggleFailoverRule"
    actions   = ["events:DisableRule", "events:EnableRule"]
    resources = [var.event_rule_arn]
  }

  statement {
    sid       = "MuteAlarm"
    actions   = ["cloudwatch:DisableAlarmActions", "cloudwatch:EnableAlarmActions", "cloudwatch:DescribeAlarms"]
    resources = [var.alarm_arn]
  }

  statement {
    sid       = "ScaleOurAsgs"
    actions   = ["autoscaling:SetDesiredCapacity"]
    resources = var.asg_arns
  }

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
  name   = "scheduler-steps"
  role   = aws_iam_role.sfn.id
  policy = data.aws_iam_policy_document.sfn.json
}

resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/vendedlogs/states/${var.name_prefix}-scheduler"
  retention_in_days = 7
}

resource "aws_sfn_state_machine" "this" {
  name     = "${var.name_prefix}-scheduler"
  type     = "STANDARD"
  role_arn = aws_iam_role.sfn.arn

  definition = templatefile("${path.module}/../../statemachines/scheduler.asl.json", {
    asg_a_name      = var.asg_a_name
    asg_b_name      = var.asg_b_name
    event_rule_name = var.event_rule_name
    alarm_name      = var.alarm_name
  })

  logging_configuration {
    level                  = "ERROR"
    include_execution_data = true
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
  }

  depends_on = [aws_iam_role_policy.sfn]
}

# ---------------------------------------------------------------------------
# EventBridge Scheduler: two schedules start the state machine
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "scheduler_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.name_prefix}-scheduler-invoke"
  description        = "EventBridge Scheduler: start the scheduler state machine"
  assume_role_policy = data.aws_iam_policy_document.scheduler_trust.json
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.this.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "start-scheduler-sfn"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

resource "aws_scheduler_schedule_group" "this" {
  name = var.name_prefix
}

locals {
  schedules = {
    night-stop    = { expression = var.stop_expression, action = "stop" }
    morning-start = { expression = var.start_expression, action = "start" }
  }
}

resource "aws_scheduler_schedule" "this" {
  for_each = local.schedules

  name                         = "${var.name_prefix}-${each.key}"
  group_name                   = aws_scheduler_schedule_group.this.name
  description                  = "Start ${aws_sfn_state_machine.this.name} with action=${each.value.action}"
  schedule_expression          = each.value.expression
  schedule_expression_timezone = var.timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sfn_state_machine.this.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ action = each.value.action })

    retry_policy {
      maximum_retry_attempts = 3
    }
  }
}
