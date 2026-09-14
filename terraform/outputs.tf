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
#   openmetadata-dev.corp.example.com.  CNAME  <this value>.
output "app_dns_alias_fqdn" {
  description = "Stable hostname Terraform keeps pointed at the current front door (the accelerator when enabled, otherwise the ALB). CNAME an externally-managed domain at this name once and it never needs repointing, because it survives the load balancer being recreated. Empty when app_dns_alias_name is unset."
  value       = local.app_dns_alias_managed ? var.app_dns_alias_name : ""
}

output "app_lb_scheme" {
  description = "Scheme of the UI load balancer. internal means private addresses, reachable only from the VPC and networks routed to it."
  value       = var.app_expose_via_alb ? var.app_lb_scheme : ""
}

# --- Global Accelerator ------------------------------------------------------

# The pair to put in the corp.example.com ticket, and the pair to give the network team
# for a proxy steering bypass.
#
# These survive `terraform destroy` of this environment: the accelerator is
# owned by bootstrap/, and only its listener and endpoint group live here. A
# teardown leaves the addresses reserved with nothing behind them, and the next
# apply reattaches them -- so the external DNS record is written once and never
# re-ticketed. Same arrangement, and same reason, as the NAT EIP.
output "app_static_ips" {
  description = "The accelerator's two static anycast IPv4 addresses. Publish an A record with both. Empty when app_accelerator_arn is empty. Owned by bootstrap/, so they survive this environment being destroyed and rebuilt."
  value       = try(one(data.aws_globalaccelerator_accelerator.app[*].ip_sets[0].ip_addresses), [])
}

output "app_accelerator_dns_name" {
  description = "The accelerator's own hostname, an alternative CNAME target to app_static_ips for a zone that would rather not pin addresses. Empty when app_accelerator_arn is empty."
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
    ? "CNAME ${var.app_tls_domain_name} -> ${var.app_dns_alias_name}  (TTL 300). Written once: Terraform repoints the second hop on every apply. Full record in `terraform output app_dns_record`."
    : local.app_ga_enabled
    ? "CNAME ${var.app_tls_domain_name} -> ${one(data.aws_globalaccelerator_accelerator.app[*].dns_name)}  (TTL 300). Written once: the accelerator is owned by bootstrap/ and outlives this environment. An A record to app_static_ips works too. Full record in `terraform output app_dns_record`."
    : "CNAME ${var.app_tls_domain_name} -> the hostname from: kubectl get ingress -n ${local.namespace} openmetadata-public -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' (changes whenever the ALB is replaced)"
  )
}

# The record to hand to whoever runs the external zone, as fields rather than
# prose -- because what gets pasted into a ticket should not need interpreting,
# and because a DNS team that does not know this system will otherwise ask three
# follow-up questions.
#
# `stable_target = true` is the claim that matters to them: this value will not
# change again, so they are being asked for a one-off, not a standing
# commitment. It is false only in the degenerate case where app_dns_alias_name
# was left unset and the record would have to point straight at a load balancer
# hostname that moves -- which is worth refusing to hand over at all.
output "app_dns_record" {
  description = "The exact DNS record the externally-managed zone must publish for app_tls_domain_name: name, type, value, TTL. Empty when nothing needs handing over -- either the UI is not exposed, or Terraform owns the record itself."
  value = (!var.app_expose_via_alb || local.app_cert_managed
    ? {}
    : local.app_dns_alias_managed
    ? {
      name          = var.app_tls_domain_name
      type          = "CNAME"
      value         = var.app_dns_alias_name
      ttl           = 300
      stable_target = true
      note          = "Terraform repoints ${var.app_dns_alias_name} at the current front door on every apply, so this record is written once and never revisited."
    }

    # The accelerator's own hostname, in preference to its two addresses: one
    # value to transcribe instead of two, and it keeps working if AWS ever
    # changes how an accelerator's addresses are presented. The addresses are in
    # app_static_ips for a zone that would rather pin an A record, and for the
    # network team's proxy bypass, which needs literal addresses either way.
    : local.app_ga_enabled
    ? {
      name          = var.app_tls_domain_name
      type          = "CNAME"
      value         = one(data.aws_globalaccelerator_accelerator.app[*].dns_name)
      ttl           = 300
      stable_target = true
      note          = "Fixed for the life of the accelerator, which is owned by bootstrap/ and therefore survives this environment being destroyed and rebuilt -- so this record is written once. Alternative if an A record is preferred: ${join(", ", try(one(data.aws_globalaccelerator_accelerator.app[*].ip_sets[0].ip_addresses), []))}. Both break only if the accelerator itself is released."
    }

    : {
      name          = var.app_tls_domain_name
      type          = "CNAME"
      value         = one(data.aws_lb.app[*].dns_name)
      ttl           = 300
      stable_target = false
      note          = "UNSTABLE -- do not hand this over. It points straight at the load balancer, whose hostname carries a per-load-balancer hash that AWS reassigns whenever it is recreated, so the record goes dead on the next rebuild. Give the external zone something that does not move first: set app_accelerator_arn (the accelerator's hostname, no Route 53 needed) or app_dns_alias_name (a Terraform-managed Route 53 name)."
    }
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
