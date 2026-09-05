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
# environment. The Ingress in alb_ingress.tf points straight at it, so nothing
# here has to move: the server advertises openmetadata.<namespace>.svc:8585 to
# Airflow as metadataApiEndpoint and every deployed pipeline carries that
# host:port. (Under the NLB this needed a second Service of our own, because an
# NLB listener port is always the Service port. An ALB decouples them.)
locals {
  # TLS terminates on the ALB when there is a certificate to terminate it with,
  # from either route: Terraform issues one via ACM + Route 53, or the operator
  # supplies an existing ARN (app_tls_certificate_arn) for a domain that is not
  # in Route 53.
  app_tls_enabled = var.app_expose_via_alb && (var.app_tls_domain_name != "" || var.app_tls_certificate_arn != "")

  # True only for the Route 53 route: Terraform issues the certificate, so it
  # also owns the validation records and the alias record for
  # app_tls_domain_name. With a supplied ARN none of that exists and that name
  # belongs to whoever owns its zone.
  #
  # Scoped to certificate issuance ONLY. It used to gate every resource in
  # alb_tls.tf, which meant supplying app_tls_certificate_arn switched off DNS
  # altogether -- including the one record that has nothing to do with the
  # certificate. See app_dns_alias_managed.
  app_cert_managed = var.app_expose_via_alb && var.app_tls_domain_name != "" && var.app_tls_certificate_arn == ""

  # Terraform publishes a stable name that tracks whatever the current load
  # balancer is, and repoints it on every apply.
  #
  # Independent of app_cert_managed on purpose. The imported-certificate route
  # leaves app_tls_domain_name to be published by whoever owns that zone --
  # an internal ffdb.com here -- and the only target available to them was the
  # *.elb.amazonaws.com hostname, which changes whenever the load balancer is
  # recreated. This gives them a name in a zone we control to point at instead,
  # so their record is written once and never again.
  app_dns_alias_managed = var.app_expose_via_alb && var.app_dns_alias_name != "" && var.app_tls_route53_zone_name != ""

  # Either DNS path needs the hosted zone looked up, so the Route 53 data
  # source in alb_tls.tf is gated on this rather than on one route.
  app_zone_needed = local.app_cert_managed || local.app_dns_alias_managed

  # The load balancer lookup is separate from, and wider than, app_zone_needed.
  # Global Accelerator needs the ALB's ARN for its endpoint group even when
  # Terraform publishes no DNS at all -- which is exactly the dev case, where
  # the record lives in an internal zone this account does not own. Gating the
  # lookup on DNS alone left the endpoint group with nothing to point at.
  app_lb_lookup_needed = local.app_zone_needed || local.app_ga_enabled

  # The ARN that reaches the Ingress's certificate-arn annotation. On the
  # managed route it references the VALIDATION resource, not the certificate,
  # so the Ingress never carries an unissued ARN.
  # one() rather than [0]: it yields null for a zero-count resource, where an
  # index would risk an "Invalid index" error on the branch that is not taken.
  app_cert_arn = (var.app_tls_certificate_arn != ""
    ? var.app_tls_certificate_arn
    : one(aws_acm_certificate_validation.app[*].certificate_arn)
  )

  # Recognizable ALB name in the console, applied when the controller first
  # provisions the load balancer. Nothing depends on it being the actual name
  # -- ELBv2 has no rename API, so a load balancer that already exists keeps
  # whatever it was created with, which is why alb_tls.tf looks it up by tag.
  # 32 chars is the AWS limit.
  #
  # The "-alb" suffix is load-bearing during the migration off the NLB.
  # ELBv2 load balancer names are unique per account and region ACROSS TYPES,
  # and the NLB this replaces is named "<cluster>-omd". Terraform deletes the
  # old Service and creates the Ingress in the same apply, but the controller
  # tears the NLB down asynchronously -- so reusing the name races the
  # deletion and the apply fails with a duplicate-name error from the
  # controller, surfaced only as an Ingress warning event. A distinct name
  # lets both exist for the minute it takes.
  app_alb_name = substr("${var.eks_cluster_name}-omd-alb", 0, 32)

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
