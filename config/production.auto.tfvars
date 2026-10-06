# PRODUCTION deployment config for the OpenMetadata "complete" example.
#
# Leaves db / airflow at the module's production-safe defaults: RDS
# multi_az = true, deletion_protection = true, skip_final_snapshot = false,
# backup_retention_period = 30. These intentionally make `terraform destroy`
# hard — use the dev environment for disposable stacks. OpenSearch is sized
# explicitly below.
#
# `region` MUST match the AWS_REGION repository variable.

region           = "us-east-1"
eks_cluster_name = "open-metadata"
azs_to_use       = 3
app_version      = "1.12.13"

# --- EKS nodes: right-sized for production ----------------------------------
# 3 x m7i.large (2 vCPU / 8 GiB each, 24 GiB total), one per AZ, replacing the
# 2 x t3.xlarge (4 vCPU / 16 GiB, 32 GiB total) that dev runs.
#
# What runs on these nodes: the OpenMetadata server (requests 500m / 256Mi,
# limited to 1 CPU / 2 GiB by the module), Airflow's scheduler and webserver,
# the ingestion pods Airflow launches per pipeline run, the load balancer
# controller, metrics-server, the EBS/EFS CSI drivers and the core addons.
# Steady state is around 6 GiB; ingestion runs add 1-2 GiB per concurrent
# pipeline. RDS and OpenSearch are managed services and use none of it.
#
# Why this shape:
#   - Three nodes across the three AZs production uses (azs_to_use = 3), so
#     losing a node or a zone leaves two. With two nodes, one failure halves
#     capacity and can leave the server with nowhere to reschedule.
#   - m7i rather than t3. T-family CPU is burstable: sustained ingestion either
#     exhausts credits and throttles, or (EKS's default "unlimited" mode) bills
#     surplus credits on top. m7i gives fixed, full CPU at a known price.
#   - 24 GiB is ~4x steady state, enough for several concurrent ingestion runs
#     and for a full node to drain onto the other two during an upgrade.
#   - Roughly $221/month on demand vs ~$243 for 2 x t3.xlarge: more resilient
#     for slightly less.
#
# max_size 5 is headroom for a manual scale-up (nothing here autoscales).
#
# Disk goes 20 -> 50 GiB. The OpenMetadata ingestion images are several GB
# each and accumulate in the image cache; at 20 GiB a node hits disk pressure
# and the kubelet starts evicting pods. EBS gp3 is ~$0.08/GiB-month, so this
# is ~$7/month across all three nodes.
#
# > ⚠️ If production already exists, the first apply with these values
# > REPLACES the node group (instance type and disk size are immutable), and
# > the UI and Airflow are down until the new nodes join, typically 5-10
# > minutes. Schedule it. See the note above the variables in variables.tf.
eks_node_instance_types = ["m7i.large"]
eks_node_disk_size      = 50
eks_node_min_size       = 3
eks_node_desired_size   = 3
eks_node_max_size       = 5

# --- OpenMetadata UI exposure: same setup as dev -----------------------------
# An internet-facing ALB in front of the chart's ClusterIP Service, reachable
# only from the CIDRs below, with HTTPS on a Route 53 name and an ACM
# certificate that Terraform issues, DNS-validates and renews. dev.auto.tfvars
# explains each piece and its history at length; the short version is here.
#
# Production and dev share the account and the hosted zone without colliding:
# the ALB is named after the cluster (open-metadata-omd-alb vs
# open-metadata-dev-omd-alb), alb_tls.tf finds it by the cluster's tags, and the
# two FQDNs are distinct records with their own certificates.
#
# > ⚠️ Authentication is still the chart default -- one `admin` account with a
# > well-known password -- and this allowlist is the ONLY thing limiting who can
# > reach it. It admits ~66,000 addresses. Before real users or real metadata
# > land here: change the admin password, and plan the SSO cutover described in
# > README_full.md ("Production exposure -- what's still missing").
app_expose_via_alb = true

# Kept identical to dev on purpose: the same people use both. When one changes,
# change the other. The individual /32s are dynamic ISP addresses and drift --
# see "Known gaps" in README_full.md.
app_lb_allowed_cidrs = [
  # Corporate VPN / proxy egress pools.
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

# --- WAF ---------------------------------------------------------------------
# AWS WAF in front of the ALB: IP reputation, known bad inputs (e.g. Log4Shell
# against this Java app) and the AWS core rule set block; three core rules that
# misfire on OpenMetadata's own request bodies, and the per-IP rate limit, only
# count for now. waf.tf explains each choice. Requests are logged, with cookies
# and auth headers redacted, to CloudWatch log group aws-waf-logs-<cluster>-omd.
#
# This does not replace app_lb_allowed_cidrs: the allowlist still decides who
# can connect, and WAF inspects what they send.
app_waf_enabled = true

# HTTPS on 443 at the zone apex, https://example-openmetadata.com -- dev
# stays at dev.example-openmetadata.com in the same zone. Terraform issues the
# certificate, validates it through this zone, and keeps the alias record
# pointed at the current ALB on every apply. An alias A record is valid at the
# apex, where a CNAME would not be.
#
# The zone must exist in this account and be delegated from the registrar --
# the same requirement as dev, already met if dev's certificate validated.
#
# > ⚠️ The apex must not already carry an A record (a website, a parking page).
# > The record here is created without allow_overwrite, so an existing one fails
# > the apply rather than being replaced -- check first:
# >   aws route53 list-resource-record-sets --hosted-zone-id <zone id> \
# >     --query "ResourceRecordSets[?Name=='example-openmetadata.com.']"
app_tls_domain_name       = "example-openmetadata.com"
app_tls_route53_zone_name = "example-openmetadata.com"

# Not carried over from dev, deliberately:
#   app_display_name    -- tab-title branding proxy; cosmetic, and an extra hop
#                          in front of the UI. Add it once production is stable.
#   app_accelerator_arn -- off in dev too.
#   stable_nat_eip_name -- off in dev too. Turn it on before anything external
#                          (e.g. Snowflake) allowlists production's egress IP.

# --- OpenSearch: right-sized for production ----------------------------------
# 2 x r6g.large.search (2 vCPU / 16 GiB, ~8 GiB JVM heap each), up from the
# module default of 2 x t3.small.search (~1 GiB heap each).
#
# The load here is shard count, not data. OpenMetadata 1.12 creates ~45 indices
# at 5 primaries + 1 replica each, ~757 shards, while the data itself is tens of
# MB. Every shard costs heap whatever it holds, so heap is what to buy; see
# "When the cluster is overwhelmed" in README_full.md for what t3.small does
# under this load (a data node knocked out, half the shards unassigned).
#
#   t3.small.search  x2   ~2 GiB heap total   ~380 shards/GiB  -- falls over
#   t3.medium.search x2   ~4 GiB heap total   ~190 shards/GiB  -- dev, and dev
#                                                                 also drops replicas
#   r6g.large.search x2  ~16 GiB heap total    ~47 shards/GiB  -- production
#
# r6g (memory optimised) rather than m6g: the same 16 GiB from m6g needs the
# xlarge, at about 1.5x the price, for CPU this workload does not use. Not t3:
# AWS does not recommend T instances for production domains, and their CPU
# credits run out during a full reindex. Production keeps its replicas
# (reduce-replicas refuses to run outside dev), so this is sized to hold all
# ~757 shards with headroom, not half of them.
#
# Why not more: ~47 shards/GiB is still above the conservative 20-25/GiB rule
# of thumb, but that rule assumes shards holding real data. Fixing the shard
# count (1 primary per index would cut it ~5x) is the better lever and is in
# README_full.md's "Worth fixing properly"; once that lands this can come down
# to m6g.large.search.
#
# Fixed by the module, not choosable here: 2 AZs (it always takes the first
# two subnets), instance_count a multiple of 2, no dedicated master nodes.
#
# Cost: ~$245/month on demand, vs ~$53 for 2 x t3.small.search.
#
# Every field is spelled out on purpose. Setting `opensearch` here replaces the
# root default object wholesale, and the module fills gaps from ITS defaults --
# where provisioner is "helm". Leaving provisioner out would move search off
# AWS and into the cluster. domain_name must stay "openmetadata": renaming a
# domain replaces it.
#
# > ⚠️ On an existing domain, changing instance_type or volume_size is a
# > blue/green deployment: no downtime, but it can take an hour or more, and the
# > apply waits for it.
opensearch = {
  provisioner = "aws"
  aws = {
    availability_zone_count = 2
    domain_name             = "openmetadata"
    engine_version          = "OpenSearch_3.3"
    instance_count          = 2
    instance_type           = "r6g.large.search"
    tls_security_policy     = "Policy-Min-TLS-1-2-2019-07"
  }
  credentials = {
    username = "admin"
    password = { secret_ref = "opensearch-credentials", secret_key = "password" }
  }
  volume_size = 20
}
