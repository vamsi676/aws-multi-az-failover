data "aws_partition" "current" {}

resource "aws_codedeploy_app" "this" {
  name             = "${var.name_prefix}-app"
  compute_platform = "Server"
}

# ---------------------------------------------------------------------------
# Service role
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "codedeploy_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codedeploy" {
  name               = "${var.name_prefix}-codedeploy"
  description        = "CodeDeploy service role for the Taskboard deployment group"
  assume_role_policy = data.aws_iam_policy_document.codedeploy_trust.json
}

resource "aws_iam_role_policy_attachment" "codedeploy" {
  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSCodeDeployRole"
}

# Required when the ASGs use a launch template.
data "aws_iam_policy_document" "codedeploy_launch_template" {
  statement {
    sid       = "LaunchTemplate"
    actions   = ["ec2:RunInstances", "ec2:CreateTags"]
    resources = ["*"]
  }

  statement {
    sid       = "PassInstanceRole"
    actions   = ["iam:PassRole"]
    resources = [var.instance_role_arn]
  }
}

resource "aws_iam_role_policy" "codedeploy_launch_template" {
  name   = "launch-template"
  role   = aws_iam_role.codedeploy.id
  policy = data.aws_iam_policy_document.codedeploy_launch_template.json
}

# ---------------------------------------------------------------------------
# Deployment group: in-place, both ASGs, no load balancer info
# (deregistering the only target would drop HealthyHostCount to 0).
# ---------------------------------------------------------------------------
resource "aws_codedeploy_deployment_group" "this" {
  app_name               = aws_codedeploy_app.this.name
  deployment_group_name  = "${var.name_prefix}-dg"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = "CodeDeployDefault.AllAtOnce"
  autoscaling_groups     = var.asg_names

  # Instances launched during a deployment get the new revision afterwards.
  outdated_instances_strategy = "UPDATE"

  deployment_style {
    deployment_option = "WITHOUT_TRAFFIC_CONTROL"
    deployment_type   = "IN_PLACE"
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }

  # CodeDeploy validates the role when the group is created.
  depends_on = [
    aws_iam_role_policy_attachment.codedeploy,
    aws_iam_role_policy.codedeploy_launch_template,
  ]
}
