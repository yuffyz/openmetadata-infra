output "role_arn" {
  description = "Set this as the AWS_ROLE_ARN repository secret."
  value       = aws_iam_role.deploy.arn
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC identity provider in use."
  value       = local.oidc_arn
}

output "allowed_subjects" {
  description = "GitHub token 'sub' claims permitted to assume the role."
  value       = local.subs
}

output "nat_egress_ips" {
  description = "Stable outbound address per environment. These are what external systems see and must allowlist (Snowflake network policies, partner firewalls). Empty unless create_nat_eips is true."
  value       = { for env, eip in aws_eip.nat : env => eip.public_ip }
}

output "accelerator_static_ips" {
  description = "Static anycast addresses per environment. These are what externally-managed DNS should point at, and what a forward-proxy steering bypass is written against. Stable across environment destroy/apply because the accelerator is owned here. Empty unless create_global_accelerator is true."
  value       = { for env, a in aws_globalaccelerator_accelerator.app : env => a.ip_sets[0].ip_addresses }
}

output "accelerator_names" {
  description = "Accelerator name per environment, for recognising it in the console. The environment stack consumes accelerator_arns below, not this."
  value       = { for env, a in aws_globalaccelerator_accelerator.app : env => a.name }
}

# The value each environment's app_accelerator_arn takes.
#
# The ARN and not the name: the environment stack looks the accelerator up by
# ARN, because the provider leaves `arn` null when the same data source is
# looked up by name and the listener then fails with "accelerator_arn is
# required, but no definition was found".
output "accelerator_arns" {
  description = "Accelerator ARN per environment. Set the matching one as app_accelerator_arn in that environment's tfvars. Empty unless create_global_accelerator is true."
  value       = { for env, a in aws_globalaccelerator_accelerator.app : env => a.arn }
}
