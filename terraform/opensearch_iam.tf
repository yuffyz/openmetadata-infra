# OpenMetadata -> OpenSearch over IAM (SigV4) instead of the master password.
#
# Enabled by opensearch_iam_auth. The point is to take the drifting password
# out of the application's path entirely: with this on, the server signs every
# search request with its pod's IAM role and never sends the password, so the
# domain and the secret can disagree without search breaking.
#
# What OpenMetadata 1.12 does (openmetadata.yaml `elasticsearch.aws`, and
# OpenSearchClient / AwsCredentialsUtil in the server source):
#   SEARCH_AWS_IAM_AUTH_ENABLED=true plus a region, with no static keys, makes
#   the server use the AWS SDK DefaultCredentialsProvider -- which includes the
#   web identity token IRSA injects -- over a separate AwsSdk2Transport. The
#   username/password are attached only on the non-IAM transport.
#
# Three pieces, all here except the last:
#   1. An IAM role the chart's ServiceAccount ("openmetadata": the release name
#      contains the chart name, so the chart's fullname helper uses it as is)
#      can assume through the cluster's OIDC provider, allowed es:ESHttp* on
#      this domain only.
#   2. The ServiceAccount annotated with that role, and the two env vars that
#      switch the server's search client to IAM.
#   3. Fine-grained access control must know the role: the domain's internal
#      user database only knows `admin`, so a signed request from an unmapped
#      role is authenticated but authorised for nothing (403). The mapping
#      lives inside OpenSearch's security index, which Terraform cannot reach
#      from a GitHub runner (the domain is VPC-only), so
#      scripts/opensearch-iam.sh maps it from inside the cluster after every
#      apply (deploy.yml).
#
# What does NOT change: the module still generates the master password and the
# opensearch-credentials secret, and the domain's `admin` user keeps it. The
# ops tooling still uses it for administration (including the mapping above).
# It just stops being something the application depends on.
#
# > ⚠️ The apply that turns this on restarts the server onto IAM before the
# > mapping exists, so search returns 403 for the minute or two until the
# > post-apply step maps the role. Dev only until that has been watched.

locals {
  opensearch_iam_enabled = var.opensearch_iam_auth && local.opensearch_on_aws

  openmetadata_service_account = "openmetadata"
  opensearch_domain_name       = try(var.opensearch.aws.domain_name, "openmetadata")

  # The issuer without its scheme, as IAM condition keys expect it.
  eks_oidc_issuer = replace(aws_eks_cluster.openmetadata.identity[0].oidc[0].issuer, "https://", "")

  # Switch the server's search client to SigV4. Passed through the module's
  # extra_envs, which the chart renders as quoted env vars.
  opensearch_iam_envs = local.opensearch_iam_enabled ? {
    "SEARCH_AWS_IAM_AUTH_ENABLED" = "true"
    "AWS_DEFAULT_REGION"          = var.region
    "SEARCH_AWS_SERVICE_NAME"     = "es"
  } : {}

  # The IRSA annotation on the chart's ServiceAccount. Dots inside a key must
  # be escaped for helm --set, hence the doubled backslashes.
  opensearch_iam_helm_values = local.opensearch_iam_enabled ? {
    "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn" = aws_iam_role.openmetadata_search[0].arn
  } : {}
}

data "aws_iam_policy_document" "openmetadata_search_trust" {
  count = local.opensearch_iam_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    # Exactly this ServiceAccount: nothing else in the cluster can borrow it.
    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_issuer}:sub"
      values   = ["system:serviceaccount:${local.namespace}:${local.openmetadata_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "openmetadata_search" {
  count = local.opensearch_iam_enabled ? 1 : 0

  name               = "${var.eks_cluster_name}-openmetadata-search"
  description        = "OpenMetadata server -> OpenSearch domain ${local.opensearch_domain_name} over SigV4"
  assume_role_policy = data.aws_iam_policy_document.openmetadata_search_trust[0].json
}

data "aws_iam_policy_document" "openmetadata_search" {
  count = local.opensearch_iam_enabled ? 1 : 0

  statement {
    actions = ["es:ESHttp*"]
    resources = [
      "arn:aws:es:${var.region}:${data.aws_caller_identity.current.account_id}:domain/${local.opensearch_domain_name}",
      "arn:aws:es:${var.region}:${data.aws_caller_identity.current.account_id}:domain/${local.opensearch_domain_name}/*",
    ]
  }
}

resource "aws_iam_role_policy" "openmetadata_search" {
  count = local.opensearch_iam_enabled ? 1 : 0

  name   = "opensearch-http"
  role   = aws_iam_role.openmetadata_search[0].id
  policy = data.aws_iam_policy_document.openmetadata_search[0].json
}
