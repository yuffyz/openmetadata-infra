# HTTPS on the OpenMetadata ALB: ACM certificate + Route 53 records
#
# Enabled by setting app_tls_domain_name (and its hosted zone). TLS terminates
# on the ALB listener; traffic from the ALB to the pod stays plain HTTP inside
# the VPC. The certificate ARN reaches the listener as an Ingress annotation in
# alb_ingress.tf.
#
# Two independent DNS concerns live here, gated separately:
#
#   app_cert_managed      Terraform issues the certificate, so it also owns the
#                         validation records and the alias for
#                         app_tls_domain_name.
#   app_dns_alias_managed Terraform publishes app_dns_alias_name and keeps it
#                         pointed at the current front door. Works with an
#                         imported certificate, and exists so that a domain
#                         managed outside this repo has a target that does not
#                         change when the load balancer is recreated.
#
# Why the ALB is looked up rather than created here: the load balancer is owned
# by the AWS Load Balancer Controller, not Terraform. The Ingress in
# alb_ingress.tf blocks until the controller reports an address, so by the time
# the lookup below runs the ALB exists; we find it by the tags the controller
# stamps on everything it provisions, and point Route 53 at it.

# Needed by both DNS paths, so it is gated on app_zone_needed rather than on
# certificate issuance.
data "aws_route53_zone" "app" {
  count        = local.app_zone_needed ? 1 : 0
  name         = var.app_tls_route53_zone_name
  private_zone = false
}

resource "aws_acm_certificate" "app" {
  count             = local.app_cert_managed ? 1 : 0
  domain_name       = var.app_tls_domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# DNS validation records. allow_overwrite guards against a stale record from a
# previous certificate for the same name.
resource "aws_route53_record" "app_cert_validation" {
  for_each = local.app_cert_managed ? {
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

# Blocks until ACM reports the certificate ISSUED. The Ingress's
# certificate-arn annotation references this rather than the certificate
# itself, so the listener is never created with an unvalidated ARN.
resource "aws_acm_certificate_validation" "app" {
  count                   = local.app_cert_managed ? 1 : 0
  certificate_arn         = aws_acm_certificate.app[0].arn
  validation_record_fqdns = [for r in aws_route53_record.app_cert_validation : r.fqdn]
}

# Found by tag, not by name. The load-balancer-name annotation only takes
# effect when the controller first provisions the load balancer: ELBv2 has no
# rename API, and the controller does not rebuild an existing load balancer for
# a name change. A name lookup would therefore silently fail forever against
# any ALB that predates the annotation.
#
# These three tags are what the controller stamps on every AWS resource it
# provisions for an INGRESS (pkg/deploy/tracking/provider.go). Note the prefix:
# an Ingress-provisioned ALB carries ingress.k8s.aws/*, where the Service-
# provisioned NLB this replaced carried service.k8s.aws/* -- the stack ID is
# "<namespace>/<ingress name>" either way. Leaving the old keys here would have
# matched nothing, and `data.aws_lb` fails with "no matching LB found" rather
# than returning empty, so it would at least have been loud.
#
# Matching on the cluster tag as well keeps this from picking up an
# identically-named stack in another cluster in the same account. Referencing
# the Ingress resource also orders this read after the provider has waited for
# the load balancer to come up.
#
data "aws_lb" "app" {
  count = local.app_zone_needed ? 1 : 0

  tags = {
    "elbv2.k8s.aws/cluster"    = local.eks_cluster_name
    "ingress.k8s.aws/stack"    = "${local.namespace}/${kubernetes_ingress_v1.app_public[0].metadata[0].name}"
    "ingress.k8s.aws/resource" = "LoadBalancer"
  }
}

# Alias record rather than CNAME: no charge for queries, and it resolves at a
# zone apex if the domain is ever moved there.
resource "aws_route53_record" "app" {
  count   = local.app_cert_managed ? 1 : 0
  zone_id = data.aws_route53_zone.app[0].zone_id
  name    = var.app_tls_domain_name
  type    = "A"

  alias {
    name                   = data.aws_lb.app[0].dns_name
    zone_id                = data.aws_lb.app[0].zone_id
    evaluate_target_health = true
  }
}

# The stable name external DNS points at.
#
# Same alias mechanics as the record above, but created on either certificate
# route and carrying a different job: this one exists purely so that a record
# published outside this repo -- openmetadata-dev.corp.example.com, in an internal zone
# this account does not own -- has something to CNAME to that Terraform keeps
# current.
#
#   <external name>.       CNAME  <app_dns_alias_name>.
#   <app_dns_alias_name>.  ALIAS  <current ALB>.
#
# The second hop is rewritten by every apply; the first is written once. That
# is the whole point -- the load balancer is owned by the AWS Load Balancer
# Controller and its hostname carries a hash AWS assigns per load balancer, so
# it cannot be held stable directly.
#
# Unused in dev as of 2026-09-09: the UI moved to a name in a PUBLIC Route 53
# zone this account owns, so Terraform publishes the user-facing record itself
# (aws_route53_record.app above) and there is no external zone left needing a
# stable target. Kept for a domain that genuinely cannot move.
#
# TLS is unaffected either way. The client resolves through the chain but still
# sends the external name in SNI, and the ALB still answers with the
# certificate for that name, so the indirection is invisible to the handshake.
resource "aws_route53_record" "app_stable" {
  count   = local.app_dns_alias_managed ? 1 : 0
  zone_id = data.aws_route53_zone.app[0].zone_id
  name    = var.app_dns_alias_name
  type    = "A"

  alias {
    name                   = data.aws_lb.app[0].dns_name
    zone_id                = data.aws_lb.app[0].zone_id
    evaluate_target_health = true
  }
}
