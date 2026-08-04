output "update_kubeconfig" {
  description = "Command to update kubeconfig with the new EKS cluster"
  value       = "aws --region ${var.region} eks update-kubeconfig --name ${local.eks_cluster_name}"
}

output "openmetadata_url" {
  description = "URL of the OpenMetadata UI. HTTPS via the domain when TLS is configured, otherwise the raw NLB hostname over plain HTTP, otherwise a port-forward command."
  value = (local.app_tls_enabled
    ? "https://${var.app_tls_domain_name}:8585"
    : (var.app_expose_via_nlb
      ? "http://<nlb-hostname>:8585 -- kubectl get svc -n ${local.namespace} openmetadata -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
    : "kubectl port-forward -n ${local.namespace} svc/openmetadata 8585:8585 -- then http://localhost:8585")
  )
}

# --- machine-readable outputs, consumed by deploy.yml ------------------------
# openmetadata_url above is written for humans; when the NLB is used but TLS is
# not, it carries a <nlb-hostname> placeholder because the load balancer is
# created by the AWS Load Balancer Controller AFTER Terraform returns (the
# upstream helm_release sets wait = false). The workflow resolves the real
# hostname from AWS, and needs these to do it.

output "app_url" {
  description = "Final UI URL when it is knowable at apply time (TLS configured). Empty when the NLB hostname must be resolved from AWS after the fact."
  value       = local.app_tls_enabled ? "https://${var.app_tls_domain_name}:8585" : ""
}

output "app_expose_via_nlb" {
  description = "Whether the UI is published through an internet-facing NLB."
  value       = var.app_expose_via_nlb
}

output "app_namespace" {
  description = "Namespace the OpenMetadata release is deployed into."
  value       = local.namespace
}

output "eks_cluster_name" {
  description = "EKS cluster name. Used to find the controller-created load balancer by its elbv2.k8s.aws/cluster tag."
  value       = local.eks_cluster_name
}
