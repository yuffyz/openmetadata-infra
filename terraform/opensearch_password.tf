# Keeps the running OpenMetadata server on the same OpenSearch password as the
# opensearch-credentials secret.
#
# The upstream module generates the password (random_password in
# modules/opensearch) and writes it to two places: the domain's master user and
# the opensearch-credentials Kubernetes secret. The server embeds the value into
# openmetadata.yaml at CONTAINER START, so when the secret changes, the running
# pod keeps the old one and every search request is rejected with 401 -- the
# "stale pod" failure in README_full.md. Nothing in the chart restarts it.
#
# This puts a checksum of the secret on the Deployment's pod template. A change
# to the secret changes the checksum, which changes the template, which rolls
# the pods -- in the same apply, without anyone running restart-server.
#
# Why kubernetes_annotations rather than the chart's podAnnotations: the value
# only exists after the module has written the secret, and feeding it back into
# the module's own helm_release would be a dependency cycle. The data source
# below depends on module.app, so whenever the module has pending changes it is
# read during apply, after the secret is written, rather than at plan time.
# With no pending changes it reads at plan time, the checksum is unchanged, and
# nothing happens.
#
# Helm upgrades leave the annotation alone: Helm 3's three-way merge preserves
# fields it never set, and this resource re-asserts it on the next apply if
# anything ever removed it.
#
# The other half of the problem -- the DOMAIN disagreeing with the secret --
# cannot be fixed here: AWS never returns master_user_password, so Terraform
# cannot see that drift at all. scripts/opensearch-credentials.sh checks and
# heals it after every apply (deploy.yml, "Verify search credentials").
#
# > The first apply with this file restarts the server once, to add the
# > annotation. Every later apply restarts it only if the password changed.

locals {
  opensearch_on_aws = try(var.opensearch.provisioner, "helm") == "aws"

  opensearch_secret_name = try(var.opensearch.credentials.password.secret_ref, "opensearch-credentials")
  opensearch_secret_key  = try(var.opensearch.credentials.password.secret_key, "password")
}

data "kubernetes_secret_v1" "opensearch_credentials" {
  count = local.opensearch_on_aws ? 1 : 0

  metadata {
    name      = local.opensearch_secret_name
    namespace = local.namespace
  }

  depends_on = [module.app]
}

resource "kubernetes_annotations" "openmetadata_opensearch_checksum" {
  count = local.opensearch_on_aws ? 1 : 0

  api_version = "apps/v1"
  kind        = "Deployment"

  metadata {
    # The chart's Deployment, named after the Helm release (see openmetadata-ops).
    name      = "openmetadata"
    namespace = local.namespace
  }

  # A SHA-256 of a 24-character random password does not expose it, so the
  # value is shown in plans: a changed checksum in a plan is how you see that a
  # restart is coming.
  template_annotations = {
    "openmetadata-infra/opensearch-password-sha256" = nonsensitive(sha256(
      data.kubernetes_secret_v1.opensearch_credentials[0].data[local.opensearch_secret_key]
    ))
  }

  depends_on = [module.app]
}
