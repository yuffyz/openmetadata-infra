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

# Global Accelerator only. Its control plane is reachable through the us-west-2
# endpoint alone, whatever region the endpoints it forwards to live in. The
# accelerator itself is a global resource; only the API call is regional.
provider "aws" {
  alias  = "global_accelerator"
  region = "us-west-2"
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

  # Repo paths that may appear in the token's `sub` claim.
  #
  # Normally "<org>/<repo>". But an org or enterprise with immutable OIDC
  # identifiers enabled emits numeric IDs instead:
  #   repo:my-org@180184251/my-repo@1317047516:ref:refs/heads/main
  # The IDs survive renames, so the claim can't be spoofed by re-creating a repo
  # under a reused name. A policy written against the plain form silently fails
  # with "Not authorized to perform sts:AssumeRoleWithWebIdentity".
  #
  # Set github_org_id / github_repo_id to cover that form. Both forms are then
  # allowed, so the role keeps working whether or not the policy is active, and
  # through the transition. Find the IDs with:
  #   gh api orgs/<org> --jq .id
  #   gh api repos/<org>/<repo> --jq .id
  repo_paths = compact([
    "${var.github_org}/${var.github_repo}",
    (var.github_org_id != "" && var.github_repo_id != "")
    ? "${var.github_org}@${var.github_org_id}/${var.github_repo}@${var.github_repo_id}"
    : "",
  ])

  # Which GitHub identities may assume the role. Defaults cover the contexts
  # the deploy workflow actually runs in:
  #   - plan          -> workflow_dispatch on the main branch (ref:refs/heads/<main>)
  #   - apply/destroy -> each GitHub Environment              (environment:<env>)
  generated_subs = flatten([
    for p in local.repo_paths : concat(
      ["repo:${p}:ref:refs/heads/${var.main_branch}"],
      [for e in var.environment_names : "repo:${p}:environment:${e}"],
    )
  ])

  subs = length(var.subject_claims) > 0 ? var.subject_claims : local.generated_subs
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
# Service-linked role for OpenSearch
#
# A VPC OpenSearch domain needs AWSServiceRoleForAmazonOpenSearchService to
# create ENIs in the VPC. Without it CreateDomain fails with:
#   ValidationException: Before you can proceed, you must enable a
#   service-linked role to give Amazon OpenSearch Service permissions to
#   access your VPC.
#
# It is account-wide and shared by every domain, which is why it lives here and
# not in the per-environment stack: destroying dev must not delete a role that
# production's domain still depends on.
#
# Set create_opensearch_service_linked_role = false if the account already has
# it (created by hand, by another stack, or by a pre-existing domain) --
# Terraform cannot adopt it, and creating a duplicate fails with
# "InvalidInput: Service role name ... has been taken in this account".
# ---------------------------------------------------------------------------
resource "aws_iam_service_linked_role" "opensearch" {
  count            = var.create_opensearch_service_linked_role ? 1 : 0
  aws_service_name = "opensearchservice.amazonaws.com"
  description      = "Lets Amazon OpenSearch Service manage VPC ENIs for OpenMetadata domains"
}

# ---------------------------------------------------------------------------
# Stable NAT egress addresses (optional)
#
# Everything in the cluster runs in private subnets, so all outbound traffic --
# including metadata ingestion -- is source-NAT'd through the environment's NAT
# gateway. External systems that allowlist by IP (Snowflake network policies,
# partner firewalls, on-prem ACLs) see that NAT gateway's Elastic IP.
#
# By default the VPC module allocates that EIP itself, which means it is
# destroyed along with the environment and a NEW address appears on the next
# apply. Anything that allowlisted the old one then fails, typically with an
# unhelpful connection timeout.
#
# Allocating the EIPs here instead keeps them stable across teardown cycles:
# bootstrap is applied once and is not part of the dev destroy loop. The
# environment stack finds its EIP by Name tag (see terraform/vpc.tf) and hands
# it to the VPC module via reuse_nat_ips.
#
# They are deliberately NOT in the environment stack with prevent_destroy --
# that would make `terraform destroy` fail outright and break the dev loop.
#
# Cost: AWS bills every public IPv4 address (~$0.12/day each), whether attached
# or not, so a held EIP costs that much while the environment is torn down.
# Off by default for that reason.
# ---------------------------------------------------------------------------
resource "aws_eip" "nat" {
  for_each = var.create_nat_eips ? toset(var.environment_names) : toset([])

  domain = "vpc"

  tags = {
    Name        = "${var.nat_eip_name_prefix}-${each.key}-nat"
    Environment = each.key
    ManagedBy   = "openmetadata-infra/bootstrap"
  }
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

# ---------------------------------------------------------------------------
# Global Accelerator, one per environment (optional)
#
# Two static anycast IPv4 addresses that stay in front of that environment's
# ALB. Here rather than in the environment stack for the same reason as the NAT
# EIPs above: the addresses have to outlive `terraform destroy`.
#
# The environment's UI is published in an internal zone this account does not
# own (openmetadata-dev.ffdb.com), so repointing it is a ticket rather than a
# command -- and the ALB's hostname carries a per-load-balancer hash that AWS
# reassigns whenever the load balancer is recreated. Held here, the addresses
# survive the dev teardown loop, so that record is written once and the fixed
# pair is also something a forward-proxy steering bypass can be written against.
#
# Only the ACCELERATOR lives here. Its listener and endpoint group stay in the
# environment stack (terraform/global_accelerator.tf): the listener's ports
# follow that environment's TLS configuration, and the endpoint group points at
# an ALB that does not exist yet. Destroying an environment removes both and
# leaves the accelerator holding its addresses with nothing behind it, which is
# exactly the intended resting state.
#
# The environment stack finds this by name -- "<prefix>-<environment>" -- via
# app_accelerator_name. Setting that name without applying this first fails the
# plan with "no matching Global Accelerator Accelerator found", which is the
# same failure mode as an unbootstrapped NAT EIP.
#
# Cost: ~$18/month per accelerator, charged whether or not an environment is
# currently deployed, plus a per-GB data transfer premium when it is. Off by
# default for that reason.
# ---------------------------------------------------------------------------
resource "aws_globalaccelerator_accelerator" "app" {
  provider = aws.global_accelerator

  for_each = var.create_global_accelerator ? toset(var.environment_names) : toset([])

  name            = "${var.global_accelerator_name_prefix}-${each.key}"
  ip_address_type = "IPV4"
  enabled         = true

  tags = {
    Environment = each.key
    ManagedBy   = "openmetadata-infra/bootstrap"
  }
}
