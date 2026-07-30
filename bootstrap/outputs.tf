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
