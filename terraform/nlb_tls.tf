# HTTPS on the OpenMetadata NLB: ACM certificate + Route 53 alias record
#
# Enabled by setting app_tls_domain_name (and its hosted zone). TLS terminates
# on the NLB listener; traffic from the NLB to the pod stays plain TCP inside
# the VPC. The certificate ARN and the listener port are passed to the chart as
# Service annotations in main.tf.
#
# Why the NLB is looked up rather than created here: the load balancer is owned
# by the AWS Load Balancer Controller, not Terraform. The Service in
# nlb_service.tf blocks until the controller reports a hostname, so by the time
# the lookup below runs the NLB exists; we find it by the tags the controller
# stamps on everything it provisions, and point Route 53 at it.

data "aws_route53_zone" "app" {
  count        = local.app_cert_managed ? 1 : 0
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

# Blocks until ACM reports the certificate ISSUED. The chart's ssl-cert
# annotation references this rather than the certificate itself, so the Service
# is never created with an unvalidated ARN.
resource "aws_acm_certificate_validation" "app" {
  count                   = local.app_cert_managed ? 1 : 0
  certificate_arn         = aws_acm_certificate.app[0].arn
  validation_record_fqdns = [for r in aws_route53_record.app_cert_validation : r.fqdn]
}

# Found by tag, not by name. The aws-load-balancer-name annotation only takes
# effect when the controller first provisions the load balancer: ELBv2 has no
# rename API, and the controller replaces an existing LB only when its type or
# scheme changes (isSDKLoadBalancerRequiresReplacement in
# pkg/deploy/elbv2/load_balancer_synthesizer.go), never for a name change. A
# name lookup would therefore silently fail forever against any NLB that
# predates the annotation.
#
# These three tags are what the controller stamps on every AWS resource it
# provisions for a Service (pkg/deploy/tracking/provider.go); the stack ID is
# "<namespace>/<service name>". Matching on the cluster tag as well keeps this
# from picking up an identically-named stack in another cluster in the same
# account. Referencing the Service resource also orders this read after the
# provider has waited for the load balancer to come up.
data "aws_lb" "app" {
  count = local.app_cert_managed ? 1 : 0

  tags = {
    "elbv2.k8s.aws/cluster"    = local.eks_cluster_name
    "service.k8s.aws/stack"    = "${local.namespace}/${kubernetes_service_v1.app_public[0].metadata[0].name}"
    "service.k8s.aws/resource" = "LoadBalancer"
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
