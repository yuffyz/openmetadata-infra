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
# Reconciled against the live security group, which had drifted to 15 CIDRs
# while this file still listed 2. Applying the old list would have removed
# 162.10.0.0/17 -- the range corporate VPN clients egress from -- and locked
# everyone out. The set below is the exact equivalent of what was live, with
# seven entries dropped because a broader entry already covered them
# (162.10.127.41/32 sits inside 162.10.0.0/17; five 163.116.x addresses and
# 163.116.128.0/32 sit inside 163.116.128.0/17).
#
# The dynamic-ISP /32s still need re-checking with `curl ifconfig.me` from the
# affected network when access starts hanging.
#
# Without this, the UI is still reachable via:
#   kubectl port-forward -n openmetadata svc/openmetadata 8585:8585
app_expose_via_nlb = true
app_lb_allowed_cidrs = [
  # Corporate VPN / proxy egress pools. Broad on purpose: clients egress from a
  # rotating pool, so a /32 per complaint never converges. Together these permit
  # ~66,000 addresses -- see the warning below about the default admin account.
  "162.10.0.0/17",
  "163.116.128.0/17",
  "8.39.144.0/24",
  "8.36.116.0/24",
  "31.186.239.0/24",
  # Individual clients.
  "73.141.150.76/32", # workstation egress (seen in CloudTrail)
  "153.66.173.67/32",
  "24.63.41.112/32",
]

# > ⚠️ With an internet-facing NLB, this list is the ONLY thing limiting who can
# > reach the UI, and it currently admits ~66k addresses. TLS encrypts the
# > transport; it does nothing for the auth model, and the chart still ships a
# > single `admin` account with a well-known password. Change that password and
# > configure OIDC/SAML (`openmetadata.config.authentication.*`) before treating
# > this as safe.

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

# --- Internal-only domain (a zone that is NOT in Route 53) -------------------
# An internal-only name cannot be served by an ACM-issued certificate: ACM
# validates by resolving a record from the public internet, so a name that
# resolves nowhere public can never be issued. Import a certificate from your
# own PKI instead -- clients on the corporate network already trust that CA:
#
#   aws acm import-certificate --region us-east-1 \
#     --certificate fileb://cert.pem --private-key fileb://key.pem \
#     --certificate-chain fileb://chain.pem
#
# Then set the ARN below and LEAVE app_tls_route53_zone_name empty. Terraform
# issues no certificate and creates no DNS record; publish a CNAME from the
# FQDN to the load balancer's *.elb.amazonaws.com name in your own zone.
# `terraform output app_dns_managed` reports false to make that explicit.
#
# Imported certificates do NOT auto-renew. Re-import before expiry with
# `--certificate-arn <existing arn>` so the ARN stays stable and the listener
# keeps working without a Terraform change.
app_tls_domain_name     = "openmetadata-dev.ffdb.com"
app_tls_certificate_arn = "arn:aws:acm:us-east-1:146445314234:certificate/a443aeb2-67db-4105-8c05-b9ca0020e654"

# --- Stable hostname for the internal domain --------------------------------
# openmetadata-dev.ffdb.com is published in an internal zone this account does
# not own, and it used to CNAME straight to the NLB's *.elb.amazonaws.com
# hostname. That hostname carries a hash AWS assigns per load balancer, so it
# changed whenever the load balancer was recreated -- and the internal record
# had to be repointed by hand each time, with the UI unreachable until someone
# noticed. The aws-load-balancer-name annotation does not help: it fixes the
# name, not the hash.
#
# Terraform now publishes a name in a zone we DO own and repoints it at the
# current load balancer on every apply. The internal record points there
# instead, and is written once:
#
#   openmetadata-dev.ffdb.com.  CNAME  dev.fuji-openmetadata.com.
#
# `terraform output app_dns_alias_fqdn` prints the name to point at.
#
# Setting the zone here does NOT switch on ACM issuance -- app_cert_managed
# also requires app_tls_certificate_arn to be empty, and it is not. No
# certificate is issued and nothing tries to DNS-validate ffdb.com, which could
# never validate anyway (see the note above about internal-only names).
#
# The certificate is unchanged and still covers openmetadata-dev.ffdb.com:
# browsers send that name in SNI no matter how many CNAMEs they follow, so the
# extra hop is invisible to the TLS handshake.
app_tls_route53_zone_name = "fuji-openmetadata.com"
app_dns_alias_name        = "dev.fuji-openmetadata.com"

# --- Scheme: internet-facing, deliberately ----------------------------------
# Left at the default (internet-facing) after trying `internal` and reverting.
#
# `internal` gives the load balancer private addresses only, so it is reachable
# just from inside the VPC and networks routed to it. A corporate VPN
# (GlobalProtect here) puts the client on the CORPORATE network, which is not
# this VPC: with no Site-to-Site VPN, Direct Connect, Transit Gateway or peering
# carrying 172.72.0.0/16, packets never arrive. Every connection times out, and
# no app_lb_allowed_cidrs entry can help -- allowlisting a PUBLIC address on an
# internal load balancer is a no-op, because there is no path for the packet to
# take in the first place.
#
# So the UI stays internet-facing and the allowlist below is what limits access.
# TLS still terminates on the listener with the imported certificate above, so
# credentials are encrypted in transit either way.
#
# To revisit `internal`, the prerequisite is routing, not configuration: confirm
# it first with the "Is anything routed into this VPC?" section of the
# openmetadata-ops `show-exposure` action. Private subnets showing only
# 0.0.0.0/0 -> NAT gateway are egress-only, and internal cannot work.
#
# > ⚠️ Changing the scheme REPLACES the load balancer: new hostname, and the UI
# > is unreachable until DNS is repointed.
#
# app_lb_scheme = "internal"

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
    instance_type           = "t3.medium.search"
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
