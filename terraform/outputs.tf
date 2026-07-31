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
