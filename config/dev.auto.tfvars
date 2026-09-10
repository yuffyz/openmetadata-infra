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
# Published on an internet-facing ALB, reachable only from the CIDRs below.
# This creates an Ingress, openmetadata-public, which the AWS Load Balancer
# Controller turns into the ALB; it points straight at the chart's own
# ClusterIP Service on 8585, which is unchanged.
#
# Was an NLB until 2026-09-04. The ALB brings an HTTP health check (a TCP one
# passes against a JVM that accepts connections and answers nothing -- that
# cost a day of debugging), cookie session stickiness for OpenMetadata's
# in-memory session store, and the option of WAF or listener OIDC later.
# alb_ingress.tf has the details.
#
# The address that arrives at the NLB is whatever the client egresses from. A
# coworker behind a corporate proxy (Netskope, Zscaler) arrives as the proxy,
# from a large rotating pool -- allowlist the vendor's published ranges rather
# than one /32 per complaint.
#
# Without TLS the UI is plain HTTP on 8585 with a default admin account, so
# Terraform refuses both 0.0.0.0/0 and an empty list -- keep this list tight.
#
# Adds roughly $0.55-0.70/day for the ALB, plus LCUs.
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
app_expose_via_alb = true
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

# > ⚠️ With an internet-facing ALB, this list is the ONLY thing limiting who can
# > reach the UI, and it currently admits ~66k addresses. TLS encrypts the
# > transport; it does nothing for the auth model, and the chart still ships a
# > single `admin` account with a well-known password. Change that password and
# > configure OIDC/SAML (`openmetadata.config.authentication.*`) before treating
# > this as safe.
# >
# > This matters more now, not less: the UI is on a public Route 53 name, so the
# > hostname is discoverable rather than buried in an internal zone.
# >
# > Upstream's own position is that basic auth is the no-security posture:
# > "Enabling Security is only required for your Production installation", and
# > it cannot be combined with SSO -- so this is a cutover, not a migration.
# > The module templates only authorizer.initialAdmins and
# > authorizer.principalDomain, so the authentication block has to arrive
# > through the module's helm_values, not app_extra_helm_values (which reaches
# > Helm as --set and retypes strings).

# --- Global Accelerator: ENABLED --------------------------------------------
# Two static anycast IPs in front of the ALB. The accelerator itself is owned by
# bootstrap/ so the addresses outlive this environment's teardown loop; only the
# listener and endpoint group are created here.
#
# Enabled 2026-09-10, after the ALB was verified on its own. That order was
# deliberate: stacking a new load balancer and a new network hop in one change
# makes them indistinguishable when something times out, which is exactly the
# failure that cost a day here -- a completed TLS handshake with nothing behind
# it looks the same whichever hop is at fault.
#
# The ARN must match an accelerator bootstrap/ has already created, or the plan
# fails with "no matching Global Accelerator Accelerator found" -- the same
# failure mode as an unbootstrapped NAT EIP. The runbook for the whole sequence
# is in README.md, "Enabling Global Accelerator".
#
# The ARN and not the name. Looking the accelerator up by name leaves the data
# source's `arn` attribute null -- it doubles as an optional input, and the
# provider does not populate it on that path -- and the listener then fails with
# "accelerator_arn is required, but no definition was found". See the comment in
# global_accelerator.tf.
#
# Fill this in from bootstrap/ (it is not derivable from the name or the
# accelerator's DNS name):
#
#   terraform output accelerator_arns
#
# or, without a bootstrap checkout:
#
#   aws globalaccelerator list-accelerators --region us-west-2 \
#     --query "Accelerators[?Name=='openmetadata-dev'].AcceleratorArn" \
#     --output text
#
# app_accelerator_arn = "arn:aws:globalaccelerator::123456789012:accelerator/<uuid>"

# > ⚠️ Verify client IP preservation after the first apply, and do not assume
# > it. With it off, the ALB sees the accelerator's addresses instead of the
# > client's, app_lb_allowed_cidrs matches nothing, and it stops limiting access
# > at all -- on a UI that still has a default admin account, and with no error
# > anywhere to say so.
# >
# >   openmetadata-ops -> show-exposure     # reads Preserve back per endpoint
#
# What this does and does not buy, now that DNS is in a zone we own:
#
#   The original justification is GONE. Static IPs were worth $18/month because
#   the openmetadata-dev.corp.example.com record could only be written once; Route 53
#   repoints itself, so that problem no longer exists.
#
#   What remains is a fixed pair of addresses to hand the network team for a
#   Netskope steering bypass, which cannot be written against a rotating set of
#   *.elb.amazonaws.com addresses. That is the thing to actually test while this
#   is on -- if the bypass is not granted, or is granted on FQDN instead, turn
#   this back off and keep the $18.
#
#   It is NOT a fix for the September 2026 outage. That was Netskope terminating
#   TLS on the client side and never reaching AWS; an accelerator changes where
#   traffic ENTERS the AWS network and has no say over what a proxy on the
#   endpoint does with port 443.
#
#   It is NOT multi-region failover: one endpoint group, one region, one ALB.
#
# Cost: ~$18/month plus a per-GB data transfer premium, billed by bootstrap/
# whether or not this environment is currently deployed.

# --- HTTPS and DNS: a public Route 53 zone this account owns -----------------
# The UI is https://dev.example-openmetadata.com. Terraform owns the whole chain:
# ACM issues and DNS-validates the certificate, and an A-alias record points at
# the current front door -- the accelerator, since the section above is on --
# repointed on every apply.
#
# This replaced openmetadata-dev.corp.example.com, which lived in an internal zone this
# account does not own. Terraform could publish nothing there, so every load
# balancer replacement meant a ticket rather than a command, and the name was
# served by a *.corp.example.com certificate imported from our own PKI -- which does NOT
# auto-renew, and which nothing in this stack warned about before expiry.
#
# Moving the name into a zone we control fixes both: ACM issues and renews on
# its own, and the alias record follows the load balancer with no ticket. The
# hosted zone costs about $0.50/month.
#
#
# > ⚠️ openmetadata-dev.corp.example.com NO LONGER WORKS. The ALB serves only the
# > certificate for the name below, so that hostname now fails the TLS handshake
# > rather than returning a readable error. Withdraw the internal record, and
# > repoint anyone holding the bookmark.
#
# The zone must already exist as a PUBLIC hosted zone in this account --
# Terraform looks it up with a data source and does not create it. ACM proves
# ownership by publishing a validation record into it, so a private zone, or one
# held in another account, can never validate.
app_tls_domain_name       = "dev.example-openmetadata.com"
app_tls_route53_zone_name = "example-openmetadata.com"

# Both left unset, deliberately.
#
# app_tls_certificate_arn imports a certificate for a name that is NOT in Route
# 53. Setting it switches OFF issuance, validation and the record above, handing
# DNS back to whoever owns that zone -- the arrangement this environment just
# moved away from. The import command is on the variable in variables.tf if a
# future name genuinely cannot move.
#
# app_dns_alias_name publishes a second, stable name for an external zone to
# CNAME at. Redundant here: app_tls_domain_name is already in a zone we own, so
# Terraform publishes the user-facing record directly.
#
# app_tls_certificate_arn = ""
# app_dns_alias_name      = ""

# --- Scheme: internet-facing, deliberately ----------------------------------
# Left at the default (internet-facing) after trying `internal` and reverting.
#
# `internal` gives the load balancer private addresses only, so it is reachable
# just from inside the VPC and networks routed to it. It is also incompatible
# with the accelerator named above, which cannot forward to a private load
# balancer -- Terraform rejects the combination at plan time. A corporate VPN
# (GlobalProtect here) puts the client on the CORPORATE network, which is not
# this VPC: with no Site-to-Site VPN, Direct Connect, Transit Gateway or peering
# carrying 172.72.0.0/16, packets never arrive. Every connection times out, and
# no app_lb_allowed_cidrs entry can help -- allowlisting a PUBLIC address on an
# internal load balancer is a no-op, because there is no path for the packet to
# take in the first place.
#
# So the UI stays internet-facing and the allowlist above is what limits access.
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
