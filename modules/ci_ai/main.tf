# Role for the CI "ai-analyze" job: may ONLY call bedrock:InvokeModel on one model.
# It lives in envs/dev (bootstrap stays untouched), so the analyzer works while the
# dev stack exists; otherwise the job fails quietly (continue-on-error).
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  owner = split("/", var.github_repository)[0]
  repo  = split("/", var.github_repository)[1]
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repository}:pull_request",
        "repo:${local.owner}@${var.github_owner_id}/${local.repo}@${var.github_repo_id}:pull_request",
      ]
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = "${var.name_prefix}-ci-ai-analyze"
  description          = "GitHub Actions ai-analyze job: Bedrock InvokeModel only"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "bedrock" {
  statement {
    actions   = ["bedrock:InvokeModel"]
    resources = var.bedrock_resource_arns
  }
}

resource "aws_iam_role_policy" "bedrock" {
  name   = "bedrock-invoke"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.bedrock.json
}
