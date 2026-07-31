variable "region" {
  description = "AWS region for the bootstrap provider (IAM is global; this sets where the state bucket is created)."
  type        = string
  default     = "us-east-1"
}

variable "github_org" {
  description = "GitHub organization or user that owns the repo."
  type        = string
}

variable "github_repo" {
  description = "Repository name (the repo hosting the workflows — NOT the project subfolder)."
  type        = string
  default     = "kiban"
}

variable "main_branch" {
  description = "Branch that plan runs from (workflow_dispatch)."
  type        = string
  default     = "main"
}

variable "environment_names" {
  description = "GitHub Environments that apply/destroy run under (one deploy per env)."
  type        = list(string)
  default     = ["dev", "production"]
}

variable "role_name" {
  description = "Name of the IAM role the workflow assumes."
  type        = string
  default     = "openmetadata-infra-deploy"
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false if one already exists in this account."
  type        = bool
  default     = true
}

variable "subject_claims" {
  description = "Override the allowed token 'sub' claims. Empty = use the branch + environment defaults. Use [\"repo:ORG/REPO:*\"] to allow the whole repo."
  type        = list(string)
  default     = []
}

variable "permissions_policy_arns" {
  description = "Managed policy ARNs granting the role permission to build the stack."
  type        = list(string)
  default = [
    "arn:aws:iam::aws:policy/PowerUserAccess",
    "arn:aws:iam::aws:policy/IAMFullAccess",
  ]
}

variable "state_bucket" {
  description = "Terraform state S3 bucket (for the explicit state-access policy, and the name used if create_state_bucket is true). Empty to skip."
  type        = string
  default     = ""
}

variable "create_opensearch_service_linked_role" {
  description = "Create AWSServiceRoleForAmazonOpenSearchService, required for VPC OpenSearch domains. Set false if the account already has it -- Terraform cannot adopt an existing service-linked role."
  type        = bool
  default     = true
}

variable "create_state_bucket" {
  description = "Create the state S3 bucket named by state_bucket. Leave false if it already exists (Terraform would fail on a bucket it doesn't own)."
  type        = bool
  default     = false
}

