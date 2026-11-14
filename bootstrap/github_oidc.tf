# GitHub Actions -> AWS without stored keys.
# GitHub issues a short-lived OIDC token per job; AWS STS trades it for role credentials
# only if the token's claims match the trust policy conditions below.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  github_oidc_host = "token.actions.githubusercontent.com"
  # GitHub can send the subject in two formats. Newer repos use "immutable" subjects that
  # embed the numeric owner/repo IDs, so a deleted or renamed repo re-created by someone else
  # does not match. Accept both forms for this exact repo.
  github_repo_subs = [
    "repo:${var.github_owner}/${var.github_repo}",
    "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}",
  ]
  iam_arn_prefix = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}"
  aws_policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy"
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.github_oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

# ---------------------------------------------------------------------------
# Plan role: read-only, only for pull requests in this repo.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "gha_plan_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Jobs triggered by pull_request (without an `environment:`) get this subject.
    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:sub"
      values   = [for s in local.github_repo_subs : "${s}:pull_request"]
    }
  }
}

resource "aws_iam_role" "gha_plan" {
  name                 = "${var.name_prefix}-gha-plan"
  description          = "GitHub Actions: terraform plan on pull requests (read-only)"
  assume_role_policy   = data.aws_iam_policy_document.gha_plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "gha_plan_readonly" {
  role       = aws_iam_role.gha_plan.name
  policy_arn = "${local.aws_policy_arn}/ReadOnlyAccess"
}

data "aws_iam_policy_document" "gha_plan_state" {
  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "ReadDevState"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.state.arn}/envs/dev/terraform.tfstate"]
  }

  # `terraform plan` takes the S3 native lock (a .tflock object).
  statement {
    sid       = "DevStateLock"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/envs/dev/terraform.tfstate.tflock"]
  }
}

resource "aws_iam_role_policy" "gha_plan_state" {
  name   = "terraform-state"
  role   = aws_iam_role.gha_plan.id
  policy = data.aws_iam_policy_document.gha_plan_state.json
}

# ---------------------------------------------------------------------------
# Deploy role: only for jobs running in the GitHub Environment "dev"
# (which has a required reviewer).
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "gha_deploy_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:sub"
      values   = [for s in local.github_repo_subs : "${s}:environment:dev"]
    }
  }
}

resource "aws_iam_role" "gha_deploy" {
  name                 = "${var.name_prefix}-gha-deploy"
  description          = "GitHub Actions: apply/deploy/destroy envs/dev (environment dev only)"
  assume_role_policy   = data.aws_iam_policy_document.gha_deploy_trust.json
  max_session_duration = 3600
}

# PowerUserAccess = everything except IAM / Organizations / Account management.
resource "aws_iam_role_policy_attachment" "gha_deploy_poweruser" {
  role       = aws_iam_role.gha_deploy.name
  policy_arn = "${local.aws_policy_arn}/PowerUserAccess"
}

data "aws_iam_policy_document" "gha_deploy_iam" {
  statement {
    sid = "IamReadOnly"
    actions = [
      "iam:Get*",
      "iam:List*",
    ]
    resources = ["*"]
  }

  # The project creates its own roles/policies/instance profiles, always named <prefix>-*.
  statement {
    sid = "ManageProjectIam"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PassRole",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = [
      "${local.iam_arn_prefix}:role/${var.name_prefix}-*",
      "${local.iam_arn_prefix}:instance-profile/${var.name_prefix}-*",
      "${local.iam_arn_prefix}:policy/${var.name_prefix}-*",
    ]
  }

  # The CI roles must never be able to change themselves (privilege escalation).
  statement {
    sid         = "DenyChangingCiRoles"
    effect      = "Deny"
    not_actions = ["iam:Get*", "iam:List*"]
    resources   = ["${local.iam_arn_prefix}:role/${var.name_prefix}-gha-*"]
  }

  # Guardrail: envs/dev deploys must not touch the bootstrap buckets' configuration
  # or the bootstrap state file.
  statement {
    sid    = "DenyBootstrapBucketChanges"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:PutBucketVersioning",
      "s3:PutLifecycleConfiguration",
      "s3:PutEncryptionConfiguration",
      "s3:PutBucketPublicAccessBlock",
    ]
    resources = [
      aws_s3_bucket.state.arn,
      aws_s3_bucket.artifacts.arn,
    ]
  }

  statement {
    sid       = "DenyBootstrapStateWrites"
    effect    = "Deny"
    actions   = ["s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion"]
    resources = ["${aws_s3_bucket.state.arn}/bootstrap/*"]
  }
}

resource "aws_iam_role_policy" "gha_deploy_iam" {
  name   = "project-iam-and-guardrails"
  role   = aws_iam_role.gha_deploy.id
  policy = data.aws_iam_policy_document.gha_deploy_iam.json
}
