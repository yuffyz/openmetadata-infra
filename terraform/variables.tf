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

variable "app_expose_via_nlb" {
  description = "Expose the OpenMetadata UI through an internet-facing NLB provisioned by the AWS Load Balancer Controller. Installs the controller as a side effect. Requires app_lb_allowed_cidrs."
  type        = bool
  default     = false
}

variable "app_lb_allowed_cidrs" {
  description = "CIDRs permitted to reach the NLB. Required when app_expose_via_nlb is true."
  type        = list(string)
  default     = []

  validation {
    condition     = !var.app_expose_via_nlb || length(var.app_lb_allowed_cidrs) > 0
    error_message = "app_lb_allowed_cidrs must list at least one CIDR when app_expose_via_nlb is true. The UI is served over plain HTTP with a default admin account, so it must not be reachable from anywhere."
  }

  validation {
    condition     = !contains(var.app_lb_allowed_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not accepted. OpenMetadata is served over plain HTTP here; put an ALB with an ACM certificate in front before exposing it to the internet at large."
  }

  # These become spec.loadBalancerSourceRanges, which Kubernetes requires in
  # CIDR notation and only validates when the Service is written -- i.e.
  # part-way through `apply`, after other resources have already changed:
  #   Service "openmetadata-public" is invalid:
  #   spec.loadBalancerSourceRanges: Invalid value: "13.223.252.86":
  #   must be a valid CIDR value
  # A bare address is the easy mistake; append /32 for a single host.
  #
  # For a client behind a forward proxy the address that arrives here is the
  # proxy's egress, not their workstation -- see the note in nlb_service.tf.
  validation {
    condition     = alltrue([for c in var.app_lb_allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "Every entry in app_lb_allowed_cidrs must be CIDR notation, not a bare address: use \"203.0.113.4/32\" for a single host, \"203.0.113.0/24\" for a range."
  }
}

variable "app_tls_domain_name" {
  description = "FQDN to serve the OpenMetadata UI over HTTPS on 443, e.g. openmetadata.example.com. Empty leaves the NLB on plain HTTP on 8585. Requires app_expose_via_nlb."
  type        = string
  default     = ""

  validation {
    condition     = var.app_tls_domain_name == "" || var.app_expose_via_nlb
    error_message = "app_tls_domain_name requires app_expose_via_nlb = true -- TLS terminates on the NLB, so there must be one."
  }
}

variable "app_tls_route53_zone_name" {
  description = "Public Route 53 hosted zone that owns app_tls_domain_name, e.g. example.com. Used for both ACM DNS validation and the alias record. Leave empty when supplying app_tls_certificate_arn -- DNS is then yours to manage."
  type        = string
  default     = ""

  # Required only when Terraform has to issue the certificate. With
  # app_tls_certificate_arn set there is nothing to validate and no record to
  # create, so a Route 53 zone is neither needed nor consulted.
  validation {
    condition     = var.app_tls_domain_name == "" || var.app_tls_certificate_arn != "" || var.app_tls_route53_zone_name != ""
    error_message = "app_tls_route53_zone_name must be set when app_tls_domain_name is set and no app_tls_certificate_arn is supplied -- the certificate is DNS-validated and the alias record is created in that zone."
  }
}

# Bring-your-own certificate, for a domain that does not live in Route 53.
#
# An internal-only zone cannot be served by an ACM-issued public certificate at
# all: ACM validates by resolving a record from the public internet, so a name
# that resolves nowhere public can never be issued. The supported route is to
# import a certificate from your own PKI and point this at it.
#
#   aws acm import-certificate --region <same region as the NLB> \
#     --certificate fileb://cert.pem \
#     --private-key  fileb://key.pem \
#     --certificate-chain fileb://chain.pem
#
# Two operational notes. The certificate must live in the SAME region as the
# load balancer, and imported certificates do NOT auto-renew -- re-import before
# expiry with `--certificate-arn <existing arn>` so the ARN is stable and the
# listener keeps working without a Terraform change.
#
# Setting this skips certificate issuance, DNS validation and the Route 53 alias
# record entirely. Creating the DNS record is then yours: a CNAME from your
# FQDN to the load balancer's *.elb.amazonaws.com name. Prefer a CNAME over an
# A record -- an NLB's addresses are stable but change if it is ever replaced,
# and an internal NLB's AWS hostname resolves through public DNS to its private
# addresses, so a CNAME works from inside the VPC.
variable "app_tls_certificate_arn" {
  description = "ARN of an existing ACM certificate to terminate TLS with, in the same region as the NLB. Use for domains outside Route 53 (e.g. an internal-only zone) with a certificate imported from your own PKI. When set, Terraform issues no certificate and creates no DNS record."
  type        = string
  default     = ""

  validation {
    condition     = var.app_tls_certificate_arn == "" || var.app_expose_via_nlb
    error_message = "app_tls_certificate_arn requires app_expose_via_nlb = true -- TLS terminates on the NLB, so there must be one."
  }

  validation {
    condition     = var.app_tls_certificate_arn == "" || can(regex("^arn:aws[a-z-]*:acm:", var.app_tls_certificate_arn))
    error_message = "app_tls_certificate_arn must be an ACM certificate ARN, e.g. arn:aws:acm:us-east-1:123456789012:certificate/<id>."
  }
}

# internet-facing (default) publishes the NLB on public addresses; internal
# gives it private addresses in the private subnets, reachable only from inside
# the VPC and whatever is routed to it (VPN, Direct Connect, Transit Gateway).
# The private subnets already carry kubernetes.io/role/internal-elb, so the
# controller can place an internal load balancer without further tagging.
#
# > ⚠️ Changing this REPLACES the load balancer. Scheme is one of the two
# > changes the controller treats as requiring replacement
# > (isSDKLoadBalancerRequiresReplacement), so the *.elb.amazonaws.com hostname
# > changes and the UI is unreachable until DNS is repointed.
variable "app_lb_scheme" {
  description = "NLB scheme: internet-facing or internal. Changing it replaces the load balancer and changes its hostname."
  type        = string
  default     = "internet-facing"

  validation {
    condition     = contains(["internet-facing", "internal"], var.app_lb_scheme)
    error_message = "app_lb_scheme must be \"internet-facing\" or \"internal\"."
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
