# Keyless CI: GitHub Actions exchanges its OIDC token for short-lived AWS
# credentials. No AWS access keys are stored in GitHub.

locals {
  repo = "${var.github_org}/${var.github_repo}"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS validates GitHub's certificate chain itself; thumbprints kept for older provider versions
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
  tags = var.tags
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

data "aws_iam_policy_document" "trust" {
  for_each = {
    ecr_push       = ["repo:${local.repo}:ref:refs/heads/main"]
    terraform_plan = ["repo:${local.repo}:pull_request", "repo:${local.repo}:ref:refs/heads/main"]
    terraform_apply = [
      for env in var.apply_environments : "repo:${local.repo}:environment:${env}"
    ]
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value
    }
  }
}

# --- Image publishing (main branch only) ---------------------------------
resource "aws_iam_role" "ecr_push" {
  name                 = "gha-${var.github_repo}-ecr-push"
  assume_role_policy   = data.aws_iam_policy_document.trust["ecr_push"].json
  max_session_duration = 3600
  tags                 = var.tags
}

data "aws_iam_policy_document" "ecr_push" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = var.ecr_repository_arns
  }
}

resource "aws_iam_role_policy" "ecr_push" {
  role   = aws_iam_role.ecr_push.id
  policy = data.aws_iam_policy_document.ecr_push.json
}

# --- Terraform plan on pull requests (read-only + state lock) -----------
resource "aws_iam_role" "terraform_plan" {
  name               = "gha-${var.github_repo}-tf-plan"
  assume_role_policy = data.aws_iam_policy_document.trust["terraform_plan"].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.terraform_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "state_access" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.state_bucket}"]
  }
  statement {
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.state_bucket}/*"]
  }
  # S3-native state locking writes a <key>.tflock object
  statement {
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.state_bucket}/*.tflock"]
  }
}

resource "aws_iam_role_policy" "plan_state" {
  role   = aws_iam_role.terraform_plan.id
  policy = data.aws_iam_policy_document.state_access.json
}

# --- Terraform apply, only from protected GitHub environments ------------
resource "aws_iam_role" "terraform_apply" {
  count = length(var.apply_environments) > 0 ? 1 : 0

  name               = "gha-${var.github_repo}-tf-apply"
  assume_role_policy = data.aws_iam_policy_document.trust["terraform_apply"].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "apply" {
  #checkov:skip=CKV_AWS_274:Lab default, overridable via apply_policy_arn; assumable only from reviewed GitHub environments
  count = length(var.apply_environments) > 0 ? 1 : 0

  role       = aws_iam_role.terraform_apply[0].name
  policy_arn = var.apply_policy_arn
}
