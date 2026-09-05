variable "airflow" {
  description = "Airflow configuration"
  type        = any
  default = {
    credentials = {
      username = "admin"
      password = {
        secret_ref = "airflow-auth"
        secret_key = "password"
      }
    }
    storage = {
      logs = 5
      dags = 5
    }
    pvc = {
      logs = "airflow-logs"
      dags = "airflow-dags"
    }
    subpath = {
      logs = "airflow-logs"
      dags = "airflow-dags"
    }
    db = {
      provisioner  = "aws"
      storage_size = 20
      port         = 5432
      db_name      = "airflow"
      aws = {
        identifier              = "airflow"
        instance_class          = "db.t4g.micro"
        maintenance_window      = "Sat:02:00-Sat:03:00"
        backup_window           = "03:00-04:00"
        backup_retention_period = 30
        multi_az                = true
        skip_final_snapshot     = false
        deletion_protection     = true
      }
      credentials = {
        username = "dbadmin"
        password = {
          secret_ref = "airflow-db-secrets"
          secret_key = "password"
        }
      }
      engine = {
        name    = "postgres"
        version = "16"
      }
    }
  }
}

variable "app_env_from" {
  type        = list(string)
  description = "List of Kubernetes secrets. Will be converted to environment variables for the OpenMetadata application."
  default     = []
}

variable "app_extra_envs" {
  type        = map(string)
  description = "Extra environment variables for the OpenMetadata application."
  default     = {}
}

variable "app_version" {
  type        = string
  description = "OpenMetadata version to deploy"
  default     = "1.12.13"
}

variable "stable_nat_eip_name" {
  description = "Name tag of a pre-allocated Elastic IP to use for the NAT gateway, e.g. \"openmetadata-dev-nat\", created by bootstrap/ with create_nat_eips = true. Gives the environment a fixed outbound address that survives destroy/apply, so it can be allowlisted in external systems such as a Snowflake network policy. Empty lets the VPC module allocate a fresh EIP on every apply."
  type        = string
  default     = ""
}

variable "azs_to_use" {
  description = "Availability zones to use in selected region"
  type        = number
  default     = 3
}

variable "db" {
  description = "OpenMetadata database configuration"
  type        = any
  default = {
    provisioner = "aws"
    aws = {
      identifier              = "openmetadata"
      instance_class          = "db.t4g.medium"
      maintenance_window      = "Sat:02:00-Sat:03:00"
      backup_window           = "03:00-04:00"
      backup_retention_period = 30
      multi_az                = true
      skip_final_snapshot     = false
      deletion_protection     = true
    }
    engine = {
      name    = "postgres"
      version = "16"
    }
    port         = 5432
    db_name      = "openmetadata_db"
    storage_size = 20
    credentials = {
      username = "dbadmin"
      password = {
        secret_ref = "db-secrets"
        secret_key = "password"
      }
    }
  }
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "open-metadata"
}

variable "opensearch" {
  description = "OpenSearch configuration"
  type        = any
  default = {
    provisioner = "aws"
    aws = {
      availability_zone_count = 2
      domain_name             = "openmetadata"
      engine_version          = "OpenSearch_3.3"
      instance_count          = 2
      instance_type           = "t3.small.search"
      tls_security_policy     = "Policy-Min-TLS-1-2-2019-07"
    }
    credentials = {
      username = "admin"
      password = {
        secret_ref = "opensearch-credentials"
        secret_key = "password"
      }
    }
    volume_size = 10
  }
}

variable "region" {
  description = "AWS region in which the resources will be deployed"
  type        = string
  default     = "us-east-1"
}

# --- OpenMetadata UI exposure -----------------------------------------------
# Off by default: with this false the UI is reachable only via
# `kubectl port-forward`, which is the safe default for an app served over
# plain HTTP with a well-known initial admin account.

variable "app_expose_via_alb" {
  description = "Expose the OpenMetadata UI through an internet-facing ALB provisioned by the AWS Load Balancer Controller from an Ingress. Installs the controller as a side effect. Requires app_lb_allowed_cidrs."
  type        = bool
  default     = false
}

variable "app_lb_allowed_cidrs" {
  description = "CIDRs permitted to reach the ALB. Required when app_expose_via_alb is true."
  type        = list(string)
  default     = []

  validation {
    condition     = !var.app_expose_via_alb || length(var.app_lb_allowed_cidrs) > 0
    error_message = "app_lb_allowed_cidrs must list at least one CIDR when app_expose_via_alb is true. The UI is served over plain HTTP with a default admin account, so it must not be reachable from anywhere."
  }

  validation {
    condition     = !contains(var.app_lb_allowed_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not accepted. This allowlist is the only thing limiting who can reach a UI whose chart still ships a default admin account -- configure authentication before widening it."
  }

  # These are joined into the alb.ingress.kubernetes.io/inbound-cidrs
  # annotation. An Ingress has no equivalent of the Service's
  # spec.loadBalancerSourceRanges, so unlike that field nothing validates the
  # syntax at admission: a malformed entry is accepted by Kubernetes and
  # rejected later by the CONTROLLER, which reports it only as a warning event
  # on the Ingress while the apply sits waiting for an address. Hence the
  # check below, which fails at plan time instead.
  #
  # A bare address is the easy mistake; append /32 for a single host.
  #
  # For a client behind a forward proxy the address that arrives here is the
  # proxy's egress, not their workstation -- see the note in alb_ingress.tf.
  validation {
    condition     = alltrue([for c in var.app_lb_allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "Every entry in app_lb_allowed_cidrs must be CIDR notation, not a bare address: use \"203.0.113.4/32\" for a single host, \"203.0.113.0/24\" for a range."
  }
}

variable "app_tls_domain_name" {
  description = "FQDN to serve the OpenMetadata UI over HTTPS on 443, e.g. openmetadata.example.com. Empty leaves the ALB on plain HTTP on 8585. Requires app_expose_via_alb."
  type        = string
  default     = ""

  validation {
    condition     = var.app_tls_domain_name == "" || var.app_expose_via_alb
    error_message = "app_tls_domain_name requires app_expose_via_alb = true -- TLS terminates on the ALB, so there must be one."
  }
}

variable "app_tls_route53_zone_name" {
  description = "Public Route 53 hosted zone in this account, e.g. example.com. Used for ACM DNS validation, for the alias record when Terraform issues the certificate, and for app_dns_alias_name. Required when Terraform must issue the certificate; optional -- but needed for a stable hostname -- when supplying app_tls_certificate_arn."
  type        = string
  default     = ""

  # Required only when Terraform has to issue the certificate: that path is
  # DNS-validated, so there must be a zone to publish the validation record in.
  #
  # With app_tls_certificate_arn set the zone is optional, but it is NOT
  # ignored the way it once was -- app_dns_alias_name uses it to publish the
  # stable hostname that external DNS points at. See that variable.
  validation {
    condition     = var.app_tls_domain_name == "" || var.app_tls_certificate_arn != "" || var.app_tls_route53_zone_name != ""
    error_message = "app_tls_route53_zone_name must be set when app_tls_domain_name is set and no app_tls_certificate_arn is supplied -- the certificate is DNS-validated and the alias record is created in that zone."
  }
}

# Stable hostname, for a domain published outside this repo.
#
# The ALB is created by the AWS Load Balancer Controller, and its
# *.elb.amazonaws.com hostname carries a per-load-balancer hash that AWS
# assigns at creation time. Anything that recreates the load balancer -- a
# destroy/apply cycle, a scheme change, the Ingress being replaced -- yields a
# new hostname, and every external record pointing at the old one breaks. The
# load-balancer-name annotation does not help: it fixes the NAME, while the
# hash is per load balancer.
#
# app_accelerator_name addresses the same problem differently, and more
# expensively. If both are on, this record points at the accelerator
# rather than the ALB -- see the target locals in alb_tls.tf.
#
# Setting this creates a record in app_tls_route53_zone_name that Terraform
# repoints at the current load balancer on every apply. Point the external
# domain at THIS name, once, and it never needs repointing again:
#
#   openmetadata-dev.ffdb.com.  CNAME  openmetadata-dev.example.com.
#
# Deliberately independent of who issues the certificate -- it works with an
# imported app_tls_certificate_arn, which is the case it exists for. TLS is
# unaffected: the client still sends the external name in SNI and the ALB still
# serves the certificate for that name, so the extra hop is invisible to it.
variable "app_dns_alias_name" {
  description = "FQDN inside app_tls_route53_zone_name that Terraform keeps pointed at the current front door -- the accelerator when app_accelerator_name is set, otherwise the ALB -- giving external DNS a target that survives load balancer replacement. Empty disables it."
  type        = string
  default     = ""

  validation {
    condition     = var.app_dns_alias_name == "" || var.app_expose_via_alb
    error_message = "app_dns_alias_name requires app_expose_via_alb = true -- there is no load balancer to point it at otherwise."
  }

  validation {
    condition     = var.app_dns_alias_name == "" || var.app_tls_route53_zone_name != ""
    error_message = "app_dns_alias_name requires app_tls_route53_zone_name -- the record has to be created in a hosted zone this account owns."
  }

  # A record can only be created inside its own zone. Caught here because the
  # AWS error for the alternative ("InvalidChangeBatch: RRSet with DNS name
  # ... is not permitted in zone ...") arrives several minutes into an apply.
  validation {
    condition     = var.app_dns_alias_name == "" || var.app_tls_route53_zone_name == "" || endswith(var.app_dns_alias_name, ".${var.app_tls_route53_zone_name}")
    error_message = "app_dns_alias_name must be a name inside app_tls_route53_zone_name, e.g. openmetadata-dev.example.com in zone example.com."
  }
}

# Bring-your-own certificate, for a domain that does not live in Route 53.
#
# An internal-only zone cannot be served by an ACM-issued public certificate at
# all: ACM validates by resolving a record from the public internet, so a name
# that resolves nowhere public can never be issued. The supported route is to
# import a certificate from your own PKI and point this at it.
#
#   aws acm import-certificate --region <same region as the ALB> \
#     --certificate fileb://cert.pem \
#     --private-key  fileb://key.pem \
#     --certificate-chain fileb://chain.pem
#
# Two operational notes. The certificate must live in the SAME region as the
# load balancer, and imported certificates do NOT auto-renew -- re-import before
# expiry with `--certificate-arn <existing arn>` so the ARN is stable and the
# listener keeps working without a Terraform change. Nothing in this stack
# warns you before it expires.
#
# Setting this skips certificate issuance, DNS validation and the Route 53 alias
# record entirely. Creating the DNS record is then yours: a CNAME from your FQDN
# to the load balancer's *.elb.amazonaws.com name, or -- with
# app_accelerator_name set -- an A record to the accelerator's two
# static addresses, which is the pair `terraform output app_static_ips`
# reports. Prefer a CNAME for the bare-ALB case: an ALB's addresses are not
# stable at all, so an A record to one of them breaks without warning.
variable "app_tls_certificate_arn" {
  description = "ARN of an existing ACM certificate to terminate TLS with, in the same region as the ALB. Use for domains outside Route 53 (e.g. an internal-only zone) with a certificate imported from your own PKI. When set, Terraform issues no certificate and creates no record for app_tls_domain_name -- that name is yours to publish. It does still create app_dns_alias_name, if set, to give that record a stable target."
  type        = string
  default     = ""

  validation {
    condition     = var.app_tls_certificate_arn == "" || var.app_expose_via_alb
    error_message = "app_tls_certificate_arn requires app_expose_via_alb = true -- TLS terminates on the ALB, so there must be one."
  }

  validation {
    condition     = var.app_tls_certificate_arn == "" || can(regex("^arn:aws[a-z-]*:acm:", var.app_tls_certificate_arn))
    error_message = "app_tls_certificate_arn must be an ACM certificate ARN, e.g. arn:aws:acm:us-east-1:123456789012:certificate/<id>."
  }
}

# internet-facing (default) publishes the ALB on public addresses; internal
# gives it private addresses in the private subnets, reachable only from inside
# the VPC and whatever is routed to it (VPN, Direct Connect, Transit Gateway).
# The private subnets already carry kubernetes.io/role/internal-elb, so the
# controller can place an internal load balancer without further tagging.
#
# internal is incompatible with app_accelerator_name, which names an
# internet-facing service that cannot front a private load balancer -- see the
# validation on that variable.
#
# > ⚠️ Changing this REPLACES the load balancer. Scheme is one of the two
# > changes the controller treats as requiring replacement
# > (isSDKLoadBalancerRequiresReplacement), so the *.elb.amazonaws.com hostname
# > changes and the UI is unreachable until DNS is repointed.
variable "app_lb_scheme" {
  description = "ALB scheme: internet-facing or internal. Changing it replaces the load balancer and changes its hostname."
  type        = string
  default     = "internet-facing"

  validation {
    condition     = contains(["internet-facing", "internal"], var.app_lb_scheme)
    error_message = "app_lb_scheme must be \"internet-facing\" or \"internal\"."
  }
}

# --- Global Accelerator -----------------------------------------------------
#
# Two static anycast addresses in front of the ALB, so the record in the
# externally-managed ffdb.com zone can be written once instead of re-ticketed
# every time the load balancer is replaced. The listener and endpoint group,
# and the full rationale -- including what this does NOT solve -- are in
# global_accelerator.tf.
#
# The accelerator ITSELF is not created here. It belongs to bootstrap/, because
# the addresses have to outlive `terraform destroy` in an environment built for
# cheap teardown; created here, a rebuild would hand out a new pair and the
# external DNS record would be stale again. This variable names the
# bootstrap-owned accelerator to attach to, exactly as stable_nat_eip_name names
# the bootstrap-owned NAT address.
#
# > ⚠️ Roughly $18/month for the accelerator plus a per-GB data transfer
# > premium. The accelerator is billed by bootstrap/ whether or not this
# > environment is currently deployed.
variable "app_accelerator_name" {
  description = "Name of a bootstrap-owned AWS Global Accelerator to put in front of the ALB, giving two static anycast IPs that survive this environment being destroyed. Apply bootstrap/ with create_global_accelerator = true first; the name is \"<global_accelerator_name_prefix>-<environment>\". Empty disables it. Requires app_expose_via_alb and an internet-facing scheme."
  type        = string
  default     = ""

  validation {
    condition     = var.app_accelerator_name == "" || var.app_expose_via_alb
    error_message = "app_accelerator_name requires app_expose_via_alb = true -- there is no load balancer for the accelerator to forward to otherwise."
  }

  # Global Accelerator is an internet-facing service: its endpoints must be
  # publicly addressable, and it rejects an internal load balancer. Caught here
  # because the alternative is an AccessDeniedException several minutes into an
  # apply, naming the endpoint group rather than the scheme that caused it.
  validation {
    condition     = var.app_accelerator_name == "" || var.app_lb_scheme == "internet-facing"
    error_message = "app_accelerator_name requires app_lb_scheme = \"internet-facing\" -- an accelerator cannot forward to an internal load balancer."
  }
}

variable "lb_controller_chart_version" {
  description = "aws-load-balancer-controller Helm chart version. null tracks the latest release; pin it after the first successful apply (terraform state show 'helm_release.aws_load_balancer_controller[0]' | grep version)."
  type        = string
  default     = null
}

variable "app_extra_helm_values" {
  description = "Additional Helm set-overrides for the OpenMetadata chart. Values reach Helm as --set, which types an all-digit or true/false value as a number or bool; anything that must stay a string needs a non-numeric form."
  type        = map(string)
  default     = {}
}
