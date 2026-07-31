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

# Helm set-overrides for the OpenMetadata chart.
#
# The NLB block is emitted only when app_expose_via_nlb is true, so production
# stays on ClusterIP unless its own tfvars opt in -- this module block is shared
# by every environment.
#
# Source ranges are applied as a controller *annotation* rather than
# service.loadBalancerSourceRanges: the chart templates service.annotations
# verbatim, so this does not depend on the chart exposing a dedicated field.
# Enforced by the security group the controller attaches to the NLB.
locals {
  app_tls_enabled = var.app_expose_via_nlb && var.app_tls_domain_name != ""

  # Deterministic NLB name so Terraform can read the load balancer back and
  # point Route 53 at it (see nlb_tls.tf). 32 chars is the AWS limit.
  app_nlb_name = substr("${var.eks_cluster_name}-omd", 0, 32)

  nlb_helm_values = var.app_expose_via_nlb ? {
    "service.type" = "LoadBalancer"

    "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"            = "external"
    "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-nlb-target-type" = "ip"
    "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"          = "internet-facing"
    "service.annotations.service\\.beta\\.kubernetes\\.io/load-balancer-source-ranges"       = join("\\,", var.app_lb_allowed_cidrs)
  } : {}

  # TLS terminates on the NLB listener for the chart's service port. The name
  # annotation is only set here because renaming an existing NLB forces the
  # controller to replace it -- enabling TLS therefore changes the hostname,
  # which is fine since DNS is what's used from then on.
  tls_helm_values = local.app_tls_enabled ? {
    "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-name"      = local.app_nlb_name
    "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-ssl-cert"  = aws_acm_certificate_validation.app[0].certificate_arn
    "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-ssl-ports" = "8585"
  } : {}

  app_helm_values = merge(local.nlb_helm_values, local.tls_helm_values, var.app_extra_helm_values)
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
