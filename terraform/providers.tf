provider "aws" {
  region = var.region

  default_tags {
    tags = {
      "provisioner" = "terraform"
      "project"     = "openmetadata"
    }
  }
}

# Global Accelerator only. Its control plane is reachable through the us-west-2
# endpoint alone, regardless of where the endpoints it forwards to live -- so
# the resources in global_accelerator.tf take this provider explicitly while
# everything else uses the default one above. Nothing regional is created here;
# the accelerator is a global resource and its endpoint group still names
# var.region.
provider "aws" {
  alias  = "global_accelerator"
  region = "us-west-2"

  default_tags {
    tags = {
      "provisioner" = "terraform"
      "project"     = "openmetadata"
    }
  }
}

provider "kubernetes" {
  host                   = aws_eks_cluster.openmetadata.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.openmetadata.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", var.eks_cluster_name, "--region", var.region]
    command     = "aws"
  }
}

provider "helm" {
  kubernetes = {
    host                   = aws_eks_cluster.openmetadata.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.openmetadata.certificate_authority[0].data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", var.eks_cluster_name, "--region", var.region]
      command     = "aws"
    }
  }
}
