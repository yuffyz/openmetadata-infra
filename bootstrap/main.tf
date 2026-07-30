# One-time bootstrap: GitHub OIDC provider + IAM role this repo's workflow assumes.
# Run once with admin/elevated credentials. Uses local state (it's a bootstrap).

terraform {
  required_version = "~> 1.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

provider "aws" {
  region = var.region
}

# ---------------------------------------------------------------------------
# OIDC identity provider for GitHub Actions
# (Only one per account for this URL. If it already exists, set
#  create_oidc_provider = false to reference the existing one instead.)
# ---------------------------------------------------------------------------
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count           = var.create_oidc_provider ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

data "aws_iam_openid_connect_provider" "existing" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  oidc_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.existing[0].arn

  # Which GitHub identities may assume the role. Defaults cover the contexts
  # the deploy workflow actually runs in:
  #   - plan          -> workflow_dispatch on the main branch (ref:refs/heads/<main>)
  #   - apply/destroy -> each GitHub Environment              (environment:<env>)
  subs = length(var.subject_claims) > 0 ? var.subject_claims : concat(
    ["repo:${var.github_org}/${var.github_repo}:ref:refs/heads/${var.main_branch}"],
    [for e in var.environment_names : "repo:${var.github_org}/${var.github_repo}:environment:${e}"],
  )
}

# ---------------------------------------------------------------------------
# Remote state backend (optional)
#
# The deploy workflow's S3 backend needs this bucket to already exist. Locking
# is S3-native (`use_lockfile = true`): Terraform holds the lock with a
# "<key>.tflock" object in the same bucket, so there is no DynamoDB table and
# nothing else to provision.
#
# Defaults to false so re-applying this bootstrap can never collide with a
# bucket you created by hand -- Terraform cannot adopt a bucket it didn't create.
#
# One bucket serves every environment: each already has its own key
# (<prefix>/<environment>/terraform.tfstate), and therefore its own lock object.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  count  = var.create_state_bucket ? 1 : 0
  bucket = var.state_bucket

  lifecycle {
    precondition {
      condition     = var.state_bucket != ""
      error_message = "state_bucket must be set when create_state_bucket is true."
    }
  }
}

resource "aws_s3_bucket_versioning" "state" {
  count  = var.create_state_bucket ? 1 : 0
  bucket = aws_s3_bucket.state[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  count  = var.create_state_bucket ? 1 : 0
  bucket = aws_s3_bucket.state[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  count                   = var.create_state_bucket ? 1 : 0
  bucket                  = aws_s3_bucket.state[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# IAM role with a trust policy scoped to this repo
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }

    # Audience must be sts.amazonaws.com (set by aws-actions/configure-aws-credentials)
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scope to this repo's specific subjects (branch + environment)
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.subs
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = var.role_name
  description          = "Assumed via GitHub OIDC by ${var.github_org}/${var.github_repo} to deploy OpenMetadata"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}

# Broad permissions to build the whole stack. PowerUserAccess + IAMFullAccess
# is the pragmatic default (the stack creates IAM roles/KMS). Tighten by
# overriding permissions_policy_arns with your own least-privilege policy.
resource "aws_iam_role_policy_attachment" "managed" {
  for_each   = toset(var.permissions_policy_arns)
  role       = aws_iam_role.deploy.name
  policy_arn = each.value
}

# Explicit remote-state access, so the role still works if you swap in a
# tighter permissions policy that doesn't already grant S3.
#
# These same actions cover S3 native locking: the lock is a "<key>.tflock"
# object under the state prefix, so PutObject/GetObject/DeleteObject on
# "<bucket>/*" is all it needs. No DynamoDB permissions are required.
data "aws_iam_policy_document" "state" {
  count = var.state_bucket == "" ? 0 : 1

  statement {
    sid       = "S3State"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.state_bucket}", "arn:aws:s3:::${var.state_bucket}/*"]
  }
}

resource "aws_iam_role_policy" "state" {
  count  = var.state_bucket == "" ? 0 : 1
  name   = "tfstate-access"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.state[0].json
}
