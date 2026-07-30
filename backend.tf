# Remote state backend for the OpenMetadata deployment.
# This file is copied into terraform/ by the GitHub Actions workflow.
#
# Account-specific values (bucket, key, region) are supplied at `terraform init`
# time via -backend-config, so nothing environment-specific is committed here.
#
# State locking uses S3 natively (`use_lockfile`): Terraform writes a
# `<key>.tflock` object alongside the state and holds the lock with S3
# conditional writes. No DynamoDB table is involved. Requires Terraform >= 1.10.
terraform {
  backend "s3" {
    use_lockfile = true
  }
}
