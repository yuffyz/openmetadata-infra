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

  # Recognizable NLB name in the console. Only applied when the controller
  # first provisions the load balancer -- an NLB that already exists keeps its
  # generated k8s-* name, so nothing may depend on this being the actual name
  # (nlb_tls.tf finds the NLB by tag for exactly that reason). 32 chars is the
  # AWS limit.
  app_nlb_name = substr("${var.eks_cluster_name}-omd", 0, 32)

  nlb_helm_values = var.app_expose_via_nlb ? {
    "service.type" = "LoadBalancer"

    "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"            = "external"
    "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-nlb-target-type" = "ip"
    "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"          = "internet-facing"
    "service.annotations.service\\.beta\\.kubernetes\\.io/load-balancer-source-ranges"       = join("\\,", var.app_lb_allowed_cidrs)
  } : {}

  # TLS terminates on the NLB listener for the chart's service port. Switching
  # this on does not replace the NLB: the controller adds a TLS listener to the
  # existing one, so the *.elb.amazonaws.com hostname survives.
  #
  # ssl-ports names the port ("http", the chart's 8585 UI port) instead of the
  # number. These values reach the chart through the upstream module's
  # `set = [for k, v in var.extra_helm_values : {name = k, value = v}]`, which
  # leaves the helm provider on its default "auto" typing -- and Helm's strvals
  # parser turns an all-digit value into an int64. A numeric annotation is
  # rejected by the API server, so the port number fails the upgrade with:
  #   json: cannot unmarshal number into Go struct field
  #   ObjectMeta.metadata.annotations of type string
  # The AWS Load Balancer Controller matches this annotation against either the
  # port name or the port number (model_build_listener.go: buildListenerProtocol
  # / validateTLSPortsSet), so the name is equivalent and stays a string.
  # Leaving it unset is NOT equivalent: with no ssl-ports, every port with a
  # certificate gets a TLS listener, which would include the chart's 8586
  # admin port.
  tls_helm_values = local.app_tls_enabled ? {
    "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-name"      = local.app_nlb_name
    "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-ssl-cert"  = aws_acm_certificate_validation.app[0].certificate_arn
    "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-ssl-ports" = "http"
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
