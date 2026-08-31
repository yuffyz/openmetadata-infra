output "update_kubeconfig" {
  description = "Command to update kubeconfig with the new EKS cluster"
  value       = "aws --region ${var.region} eks update-kubeconfig --name ${local.eks_cluster_name}"
}

output "openmetadata_url" {
  description = "URL of the OpenMetadata UI. HTTPS on 443 via the domain when TLS is configured, otherwise the raw NLB hostname on plain HTTP 8585, otherwise a port-forward command. With a supplied certificate and no domain name, the NLB hostname must be resolved from AWS."
  value = (local.app_tls_enabled && var.app_tls_domain_name != ""
    ? "https://${var.app_tls_domain_name}"
    # TLS is on via app_tls_certificate_arn but no FQDN was declared, so the URL
    # is not knowable here -- the certificate's own domain is what browsers will
    # require, and only the operator knows it.
    : (local.app_tls_enabled
      ? "https://<nlb-hostname> -- kubectl get svc -n ${local.namespace} openmetadata-public -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' (set app_tls_domain_name to record the intended FQDN)"
      : (var.app_expose_via_nlb
        ? "http://<nlb-hostname>:8585 -- kubectl get svc -n ${local.namespace} openmetadata-public -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
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
# current load balancer on every apply, so the external record never has to
# change again:
#
#   openmetadata-dev.ffdb.com.  CNAME  <this value>.
output "app_dns_alias_fqdn" {
  description = "Stable hostname Terraform keeps pointed at the current NLB. CNAME an externally-managed domain at this name once and it never needs repointing, because it survives the load balancer being recreated. Empty when app_dns_alias_name is unset."
  value       = local.app_dns_alias_managed ? var.app_dns_alias_name : ""
}

output "app_lb_scheme" {
  description = "Scheme of the UI load balancer. internal means private addresses, reachable only from the VPC and networks routed to it."
  value       = var.app_expose_via_nlb ? var.app_lb_scheme : ""
}

# --- machine-readable outputs, consumed by deploy.yml ------------------------
# openmetadata_url above is written for humans; when the NLB is used but TLS is
# not, it carries a <nlb-hostname> placeholder because the load balancer is
# created by the AWS Load Balancer Controller AFTER Terraform returns (the
# upstream helm_release sets wait = false). The workflow resolves the real
# hostname from AWS, and needs these to do it.

output "app_url" {
  description = "Final UI URL when it is knowable at apply time (TLS configured and an FQDN declared). Empty when the NLB hostname must be resolved from AWS after the fact. Note this is the INTENDED URL: with app_tls_certificate_arn the DNS record is not created here, so it resolves only once you have published it."
  value       = local.app_tls_enabled && var.app_tls_domain_name != "" ? "https://${var.app_tls_domain_name}" : ""
}

output "app_expose_via_nlb" {
  description = "Whether the UI is published through an internet-facing NLB."
  value       = var.app_expose_via_nlb
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
