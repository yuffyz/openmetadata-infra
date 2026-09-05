output "update_kubeconfig" {
  description = "Command to update kubeconfig with the new EKS cluster"
  value       = "aws --region ${var.region} eks update-kubeconfig --name ${local.eks_cluster_name}"
}

output "openmetadata_url" {
  description = "URL of the OpenMetadata UI. HTTPS on 443 via the domain when TLS is configured, otherwise the raw ALB hostname on plain HTTP 8585, otherwise a port-forward command. With a supplied certificate and no domain name, the ALB hostname must be resolved from AWS."
  value = (local.app_tls_enabled && var.app_tls_domain_name != ""
    ? "https://${var.app_tls_domain_name}"
    # TLS is on via app_tls_certificate_arn but no FQDN was declared, so the URL
    # is not knowable here -- the certificate's own domain is what browsers will
    # require, and only the operator knows it.
    : (local.app_tls_enabled
      ? "https://<alb-hostname> -- kubectl get ingress -n ${local.namespace} openmetadata-public -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' (set app_tls_domain_name to record the intended FQDN)"
      : (var.app_expose_via_alb
        ? "http://<alb-hostname>:8585 -- kubectl get ingress -n ${local.namespace} openmetadata-public -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
    : "kubectl port-forward -n ${local.namespace} svc/openmetadata 8585:8585 -- then http://localhost:8585"))
  )
}

# Whether Terraform owns the DNS record for app_tls_domain_name.
#
# False with app_tls_certificate_arn set: that name is in a zone this account
# does not own, so publishing it is yours. Surfaced as an output so it is
# visible in `terraform output` rather than only in the code.
#
# It does NOT mean Terraform publishes no DNS at all -- see
# app_dns_alias_fqdn, which is created on either certificate route.
output "app_dns_managed" {
  description = "True when Terraform creates the Route 53 alias record for app_tls_domain_name. False when a certificate ARN was supplied and that name is managed outside Terraform -- app_dns_alias_fqdn may still be published."
  value       = local.app_cert_managed
}

# The stable target for a domain managed outside this repo.
#
# Point the external record here once. Terraform repoints this name at the
# current front door on every apply, so the external record never has to
# change again:
#
#   openmetadata-dev.ffdb.com.  CNAME  <this value>.
output "app_dns_alias_fqdn" {
  description = "Stable hostname Terraform keeps pointed at the current front door (the accelerator when enabled, otherwise the ALB). CNAME an externally-managed domain at this name once and it never needs repointing, because it survives the load balancer being recreated. Empty when app_dns_alias_name is unset."
  value       = local.app_dns_alias_managed ? var.app_dns_alias_name : ""
}

output "app_lb_scheme" {
  description = "Scheme of the UI load balancer. internal means private addresses, reachable only from the VPC and networks routed to it."
  value       = var.app_expose_via_alb ? var.app_lb_scheme : ""
}

# --- Global Accelerator ------------------------------------------------------

# The pair to put in the ffdb.com ticket, and the pair to give the network team
# for a proxy steering bypass.
#
# These survive `terraform destroy` of this environment: the accelerator is
# owned by bootstrap/, and only its listener and endpoint group live here. A
# teardown leaves the addresses reserved with nothing behind them, and the next
# apply reattaches them -- so the external DNS record is written once and never
# re-ticketed. Same arrangement, and same reason, as the NAT EIP.
output "app_static_ips" {
  description = "The accelerator's two static anycast IPv4 addresses. Publish an A record with both. Empty when app_accelerator_name is empty. Owned by bootstrap/, so they survive this environment being destroyed and rebuilt."
  value       = try(one(data.aws_globalaccelerator_accelerator.app[*].ip_sets[0].ip_addresses), [])
}

output "app_accelerator_dns_name" {
  description = "The accelerator's own hostname, an alternative CNAME target to app_static_ips for a zone that would rather not pin addresses. Empty when app_accelerator_name is empty."
  value       = try(one(data.aws_globalaccelerator_accelerator.app[*].dns_name), "")
}

# What to actually publish, resolved down to one answer.
#
# Exists because "which of these four outputs do I give the DNS team" was a
# real question every time, and getting it wrong is a silent failure: pointing
# the record at the ALB while an accelerator is enabled resolves past the
# accelerator, and nothing anywhere reports that.
output "app_dns_publish_instruction" {
  description = "Human-readable statement of the DNS record to publish for app_tls_domain_name in the externally-managed zone. Accounts for whether an accelerator is in front and whether Terraform already owns the record."
  value = (!var.app_expose_via_alb
    ? "Nothing to publish -- the UI is not exposed. Reach it with: kubectl port-forward -n ${local.namespace} svc/openmetadata 8585:8585"
    : local.app_cert_managed
    ? "Nothing to do -- Terraform owns ${var.app_tls_domain_name} in Route 53."
    : local.app_dns_alias_managed
    ? "CNAME ${var.app_tls_domain_name} -> ${var.app_dns_alias_name} (written once; Terraform repoints the second hop)"
    : local.app_ga_enabled
    ? "A record ${var.app_tls_domain_name} -> the two addresses in app_static_ips (owned by bootstrap/, so this is written once)"
    : "CNAME ${var.app_tls_domain_name} -> the hostname from: kubectl get ingress -n ${local.namespace} openmetadata-public -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' (changes whenever the ALB is replaced)"
  )
}

# --- machine-readable outputs, consumed by deploy.yml ------------------------
# openmetadata_url above is written for humans; when the ALB is used but TLS is
# not, it carries an <alb-hostname> placeholder because the load balancer is
# created by the AWS Load Balancer Controller AFTER Terraform returns (the
# upstream helm_release sets wait = false). The workflow resolves the real
# hostname from AWS, and needs these to do it.

output "app_url" {
  description = "Final UI URL when it is knowable at apply time (TLS configured and an FQDN declared). Empty when the ALB hostname must be resolved from AWS after the fact. Note this is the INTENDED URL: with app_tls_certificate_arn the DNS record is not created here, so it resolves only once you have published it."
  value       = local.app_tls_enabled && var.app_tls_domain_name != "" ? "https://${var.app_tls_domain_name}" : ""
}

output "app_expose_via_alb" {
  description = "Whether the UI is published through an internet-facing ALB."
  value       = var.app_expose_via_alb
}

output "app_namespace" {
  description = "Namespace the OpenMetadata release is deployed into."
  value       = local.namespace
}

output "nat_egress_ip" {
  description = "Outbound address every pod egresses from. This is what external systems see and must allowlist (Snowflake network policies, partner firewalls). Stable across rebuilds only when stable_nat_eip_name is set."
  value       = try(one(module.vpc.nat_public_ips), null)
}

output "eks_cluster_name" {
  description = "EKS cluster name. Used to find the controller-created load balancer by its elbv2.k8s.aws/cluster tag."
  value       = local.eks_cluster_name
}
