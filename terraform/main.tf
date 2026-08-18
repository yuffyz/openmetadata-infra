# OpenMetadata AWS module

module "app" {
  source  = "open-metadata/openmetadata/aws"
  version = "1.12.13"

  airflow  = var.airflow
  env_from = local.env_from
  extra_envs = {
    "ELASTICSEARCH_BATCH_SIZE" = 250
  }
  app_namespace    = local.namespace
  app_version      = var.app_version
  db               = var.db
  eks_nodes_sg_ids = [local.eks_nodes_sg_id]
  kms_key_id       = local.kms_key_id
  opensearch       = var.opensearch
  subnet_ids       = local.subnet_ids
  vpc_id           = local.vpc_id

  openmetadata_helm_values = local.app_helm_values

  depends_on = [
    aws_eks_cluster.openmetadata,
    aws_kms_alias.this,
    kubernetes_namespace_v1.app,
    kubernetes_secret_v1.env_from_secret,
    module.vpc,
    helm_release.aws_load_balancer_controller
  ]
}

# The chart's own Service is left alone -- ClusterIP on 8585, whatever the
# environment. Publishing the UI is done by a second Service we own
# (nlb_service.tf), because an NLB listener port is always the Service port and
# 8585 is the address the cluster itself depends on. See the comment there.
locals {
  # TLS terminates on the NLB when there is a certificate to terminate it with,
  # from either route: Terraform issues one via ACM + Route 53, or the operator
  # supplies an existing ARN (app_tls_certificate_arn) for a domain that is not
  # in Route 53.
  app_tls_enabled = var.app_expose_via_nlb && (var.app_tls_domain_name != "" || var.app_tls_certificate_arn != "")

  # True only for the Route 53 route, and therefore the switch for every
  # resource in nlb_tls.tf: the certificate, its DNS validation records, the
  # load balancer lookup and the alias record. With a supplied ARN none of that
  # exists and DNS belongs to whoever owns the zone.
  app_cert_managed = var.app_expose_via_nlb && var.app_tls_domain_name != "" && var.app_tls_certificate_arn == ""

  # The ARN that reaches the Service's ssl-cert annotation. On the managed route
  # it references the VALIDATION resource, not the certificate, so the Service
  # never carries an unissued ARN.
  # one() rather than [0]: it yields null for a zero-count resource, where an
  # index would risk an "Invalid index" error on the branch that is not taken.
  app_cert_arn = (var.app_tls_certificate_arn != ""
    ? var.app_tls_certificate_arn
    : one(aws_acm_certificate_validation.app[*].certificate_arn)
  )

  # Recognizable NLB name in the console, applied when the controller first
  # provisions the load balancer. Nothing depends on it being the actual name
  # -- ELBv2 has no rename API, so a load balancer that already exists keeps
  # whatever it was created with, which is why nlb_tls.tf looks it up by tag.
  # 32 chars is the AWS limit.
  app_nlb_name = substr("${var.eks_cluster_name}-omd", 0, 32)

  app_helm_values = var.app_extra_helm_values
}

# Extra environment variables from Kubernets secret

locals {
  env_from = [
    kubernetes_secret_v1.env_from_secret.metadata.0.name
  ]
}

resource "kubernetes_secret_v1" "env_from_secret" {
  metadata {
    name      = "env-from"
    namespace = local.namespace
  }
  data = {
    "PIPELINE_SERVICE_IP_INFO_ENABLED" = true
  }
}
