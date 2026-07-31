terraform {
  # >= 1.10 for S3 native state locking (`use_lockfile` in backend.tf).
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    # Used to let the AWS Load Balancer Controller finish provisioning the NLB
    # before Terraform reads it back for the Route 53 alias (see nlb_tls.tf).
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }
}
