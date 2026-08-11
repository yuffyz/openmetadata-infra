# DEV deployment config for the OpenMetadata "complete" example.
# Optimized for cheap, fast, no-friction teardown.
#
# Key differences from production:
#   - RDS: deletion_protection = false, skip_final_snapshot = true,
#     multi_az = false, backup_retention_period = 0   -> `terraform destroy` just works
#   - OpenSearch: smallest the module allows (2 nodes / 2 AZs — see below)
#   - All stateful resources use "-dev" identifiers so a dev stack can coexist
#     with production in the same account/region without name collisions.
#
# `region` MUST match the AWS_REGION repository variable.

region           = "us-east-1"
eks_cluster_name = "open-metadata-dev"
azs_to_use       = 2
app_version      = "1.12.13"

# --- OpenMetadata UI exposure ----------------------------------------------
# Published on an internet-facing NLB, reachable only from the CIDRs below.
# This creates a second Service, openmetadata-public, which owns the NLB; the
# chart's own Service stays ClusterIP on 8585 for in-cluster traffic.
#
# The address that arrives at the NLB is whatever the client egresses from. A
# coworker behind a corporate proxy (Netskope, Zscaler) arrives as the proxy,
# from a large rotating pool -- allowlist the vendor's published ranges rather
# than one /32 per complaint.
#
# Without TLS the UI is plain HTTP on 8585 with a default admin account, so
# Terraform refuses both 0.0.0.0/0 and an empty list -- keep this list tight.
#
# Adds roughly $0.55-0.70/day for the NLB, plus LCUs.
#
# Both entries are dynamic ISP addresses: if access starts hanging, re-check
# with `curl ifconfig.me` from the affected network and update the /32.
#
# Without this, the UI is still reachable via:
#   kubectl port-forward -n openmetadata svc/openmetadata 8585:8585
app_expose_via_nlb = true
app_lb_allowed_cidrs = [
  "73.141.150.76/32",  # workstation egress (seen in CloudTrail)
  "163.116.255.50/32", # additional allowed client
]

# HTTPS on the NLB. Set both to terminate TLS with an ACM certificate and get a
# Route 53 alias record; leave them empty and the NLB stays plain HTTP (browsers
# will flag the login page as "Not secure", correctly -- credentials would cross
# the internet in the clear).
#
# The zone must be an existing PUBLIC Route 53 hosted zone, in this account, for
# a domain you control -- ACM proves ownership by publishing a validation record
# into it, so a zone for a domain you don't own can never validate.
#
# Enabling this adds a 443 listener, so the URL is https://<domain> with no
# port. 8585 keeps working alongside it. 443 matters for anyone behind a
# corporate proxy: those forward 443 and 80, and typically will not proxy a
# non-standard port at all -- the connection just hangs.
# app_tls_domain_name       = "openmetadata.example.com"
# app_tls_route53_zone_name = "example.com"

# Stable outbound address. Everything runs in private subnets, so external
# systems see the NAT gateway's IP -- and by default that IP is reallocated on
# every destroy/apply, silently breaking anything that allowlisted the old one
# (a Snowflake network policy shows this as a connection timeout, not an auth
# error).
#
# Apply bootstrap/ with create_nat_eips = true first, then uncomment. Switching
# this on or off REPLACES the NAT gateway, so egress drops for a minute and the
# address changes once, at the point of the switch.
#
# stable_nat_eip_name = "openmetadata-dev-nat"

# --- OpenMetadata database (teardown-safe) ---------------------------------
db = {
  provisioner = "aws"
  aws = {
    identifier              = "openmetadata-dev"
    instance_class          = "db.t4g.small"
    maintenance_window      = "Sat:02:00-Sat:03:00"
    backup_window           = "03:00-04:00"
    backup_retention_period = 0
    multi_az                = false
    skip_final_snapshot     = true
    deletion_protection     = false
  }
  engine       = { name = "postgres", version = "16" }
  port         = 5432
  db_name      = "openmetadata_db"
  storage_size = 20
  credentials = {
    username = "dbadmin"
    password = { secret_ref = "db-secrets", secret_key = "password" }
  }
}

# --- OpenSearch (smallest supported: 2 nodes / 2 AZs) ----------------------
# NOT single-node. The module hardcodes `zone_awareness_enabled = true` with an
# unconditional zone_awareness_config block (modules/opensearch/main.tf), and
# AWS only accepts availability_zone_count 2 or 3 when zone awareness is on:
#   Error: expected cluster_config.0.zone_awareness_config.0
#          .availability_zone_count to be one of [2 3], got 1
# instance_count must also be a multiple of availability_zone_count, so 2 nodes
# is the floor here. A 1-node dev domain needs an upstream change to make zone
# awareness optional -- it can't be reached from tfvars.
opensearch = {
  provisioner = "aws"
  aws = {
    availability_zone_count = 2
    domain_name             = "openmetadata-dev"
    engine_version          = "OpenSearch_3.3"
    instance_count          = 2
    instance_type           = "t3.small.search"
    tls_security_policy     = "Policy-Min-TLS-1-2-2019-07"
  }
  credentials = {
    username = "admin"
    password = { secret_ref = "opensearch-credentials", secret_key = "password" }
  }
  volume_size = 10
}

# --- Airflow (full object; only db.aws differs from the default) -----------
airflow = {
  credentials = {
    username = "admin"
    password = { secret_ref = "airflow-auth", secret_key = "password" }
  }
  storage = { logs = 5, dags = 5 }
  pvc     = { logs = "airflow-logs", dags = "airflow-dags" }
  subpath = { logs = "airflow-logs", dags = "airflow-dags" }
  db = {
    provisioner  = "aws"
    storage_size = 20
    port         = 5432
    db_name      = "airflow"
    aws = {
      identifier              = "airflow-dev"
      instance_class          = "db.t4g.micro"
      maintenance_window      = "Sat:02:00-Sat:03:00"
      backup_window           = "03:00-04:00"
      backup_retention_period = 0
      multi_az                = false
      skip_final_snapshot     = true
      deletion_protection     = false
    }
    credentials = {
      username = "dbadmin"
      password = { secret_ref = "airflow-db-secrets", secret_key = "password" }
    }
    engine = { name = "postgres", version = "16" }
  }
}
