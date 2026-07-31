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
}

variable "app_tls_domain_name" {
  description = "FQDN to serve the OpenMetadata UI over HTTPS, e.g. openmetadata.example.com. Empty leaves the NLB on plain HTTP. Requires app_expose_via_nlb."
  type        = string
  default     = ""

  validation {
    condition     = var.app_tls_domain_name == "" || var.app_expose_via_nlb
    error_message = "app_tls_domain_name requires app_expose_via_nlb = true -- TLS terminates on the NLB, so there must be one."
  }
}

variable "app_tls_route53_zone_name" {
  description = "Public Route 53 hosted zone that owns app_tls_domain_name, e.g. example.com. Used for both ACM DNS validation and the alias record."
  type        = string
  default     = ""

  validation {
    condition     = var.app_tls_domain_name == "" || var.app_tls_route53_zone_name != ""
    error_message = "app_tls_route53_zone_name must be set when app_tls_domain_name is set -- the certificate is DNS-validated and the record is created in that zone."
  }
}

variable "lb_controller_chart_version" {
  description = "aws-load-balancer-controller Helm chart version. null tracks the latest release; pin it after the first successful apply (terraform state show 'helm_release.aws_load_balancer_controller[0]' | grep version)."
  type        = string
  default     = null
}

variable "app_extra_helm_values" {
  description = "Additional Helm set-overrides for the OpenMetadata chart, merged on top of the NLB values."
  type        = map(string)
  default     = {}
}
