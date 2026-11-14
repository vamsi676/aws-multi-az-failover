data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# ---------------------------------------------------------------------------
# KMS key for the SNS topic.
# The AWS-managed aws/sns key cannot be used with CloudWatch alarms: its key policy
# cannot be edited to let cloudwatch.amazonaws.com use it. A customer-managed key can.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "sns_key" {
  # Account root: lets IAM policies in this account grant use of the key
  # (the Step Functions role gets kms:GenerateDataKey/Decrypt through its IAM policy).
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudWatchAlarmsPublish"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_kms_key" "sns" {
  description             = "${var.name_prefix} alerts SNS topic"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.sns_key.json
}

resource "aws_kms_alias" "sns" {
  name          = "alias/${var.name_prefix}-alerts"
  target_key_id = aws_kms_key.sns.key_id
}

# ---------------------------------------------------------------------------
# SNS topic + email subscription
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name              = "${var.name_prefix}-alerts"
  kms_master_key_id = aws_kms_key.sns.arn
}

data "aws_iam_policy_document" "topic" {
  statement {
    sid       = "AccountOwner"
    actions   = ["sns:Publish", "sns:Subscribe", "sns:GetTopicAttributes", "sns:ListSubscriptionsByTopic"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudWatchAlarms"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.topic.json
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---------------------------------------------------------------------------
# Alarm: no healthy target behind the NLB.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "no_healthy_hosts" {
  alarm_name        = "${var.name_prefix}-no-healthy-hosts"
  alarm_description = "No healthy Taskboard target behind the NLB (triggers automatic failover)."

  namespace   = "AWS/NetworkELB"
  metric_name = "HealthyHostCount"
  dimensions = {
    LoadBalancer = var.nlb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  # Maximum over the minute: the alarm fires only if there was NO healthy host
  # at any point in the period (fewer false alarms from one missed datapoint).
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  # No data (e.g. NLB metrics stop) is treated as "no healthy host".
  treat_missing_data = "breaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}
