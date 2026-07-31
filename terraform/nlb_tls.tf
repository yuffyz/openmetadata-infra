# HTTPS on the OpenMetadata NLB: ACM certificate + Route 53 alias record
#
# Enabled by setting app_tls_domain_name (and its hosted zone). TLS terminates
# on the NLB listener; traffic from the NLB to the pod stays plain TCP inside
# the VPC. The certificate ARN and the listener port are passed to the chart as
# Service annotations in main.tf.
#
# Why the NLB is looked up rather than created here: the load balancer is owned
# by the AWS Load Balancer Controller, not Terraform. The upstream module's
# helm_release sets wait = false, so it returns before the Service exists, let
# alone before the controller has provisioned the NLB. So we
#   1. pin the NLB to a deterministic name via annotation,
#   2. wait for the controller to catch up,
#   3. read it back with a data source and point Route 53 at it.
#
# If the controller is slower than the wait below, apply fails on the aws_lb
# lookup with "no matching LB found" -- everything else is already created, so
# re-running apply picks it up. Nothing is left half-built.

data "aws_route53_zone" "app" {
  count        = local.app_tls_enabled ? 1 : 0
  name         = var.app_tls_route53_zone_name
  private_zone = false
}

resource "aws_acm_certificate" "app" {
  count             = local.app_tls_enabled ? 1 : 0
  domain_name       = var.app_tls_domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# DNS validation records. allow_overwrite guards against a stale record from a
# previous certificate for the same name.
resource "aws_route53_record" "app_cert_validation" {
  for_each = local.app_tls_enabled ? {
    for dvo in aws_acm_certificate.app[0].domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  zone_id         = data.aws_route53_zone.app[0].zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# Blocks until ACM reports the certificate ISSUED. The chart's ssl-cert
# annotation references this rather than the certificate itself, so the Service
# is never created with an unvalidated ARN.
resource "aws_acm_certificate_validation" "app" {
  count                   = local.app_tls_enabled ? 1 : 0
  certificate_arn         = aws_acm_certificate.app[0].arn
  validation_record_fqdns = [for r in aws_route53_record.app_cert_validation : r.fqdn]
}

# Give the controller time to reconcile the Service into an NLB before the
# lookup below. Provisioning typically takes 2-3 minutes from a cold start.
resource "time_sleep" "wait_for_nlb" {
  count           = local.app_tls_enabled ? 1 : 0
  create_duration = "240s"

  depends_on = [module.app]
}

data "aws_lb" "app" {
  count = local.app_tls_enabled ? 1 : 0
  name  = local.app_nlb_name

  depends_on = [time_sleep.wait_for_nlb]
}

# Alias record rather than CNAME: no charge for queries, and it resolves at a
# zone apex if the domain is ever moved there.
resource "aws_route53_record" "app" {
  count   = local.app_tls_enabled ? 1 : 0
  zone_id = data.aws_route53_zone.app[0].zone_id
  name    = var.app_tls_domain_name
  type    = "A"

  alias {
    name                   = data.aws_lb.app[0].dns_name
    zone_id                = data.aws_lb.app[0].zone_id
    evaluate_target_health = true
  }
}
