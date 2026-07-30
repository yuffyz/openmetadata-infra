# Remote state backend for the OpenMetadata "complete" deployment.
# This file is copied into examples/complete by the GitHub Actions workflow.
# All values are supplied at `terraform init` time via -backend-config, so no
# account-specific data is committed here.
terraform {
  backend "s3" {}
}
