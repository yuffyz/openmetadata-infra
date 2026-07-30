# PRODUCTION deployment config for the OpenMetadata "complete" example.
#
# Leaves db / opensearch / airflow at the module's production-safe defaults:
# RDS multi_az = true, deletion_protection = true, skip_final_snapshot = false,
# backup_retention_period = 30, OpenSearch 2 nodes / 2 AZs. These intentionally
# make `terraform destroy` hard — use the dev environment for disposable stacks.
#
# `region` MUST match the AWS_REGION repository variable.

region           = "us-east-1"
eks_cluster_name = "open-metadata"
azs_to_use       = 3
app_version      = "1.12.13"
