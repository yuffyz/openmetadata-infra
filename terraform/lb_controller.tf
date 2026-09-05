# AWS Load Balancer Controller
#
# Provisions the ALB that fronts the OpenMetadata UI. Only installed when
# var.app_expose_via_alb is true -- a cluster with no Ingress has nothing for
# it to do.
#
# EKS no longer ships in-tree load balancer provisioning as the supported path,
# so this controller is what turns the Ingress in alb_ingress.tf into a real
# ALB with IP targets. It relies on the kubernetes.io/role/elb subnet tags set
# in vpc.tf for subnet discovery.
#
# The IRSA policy below covers both ALBs and NLBs, so nothing about the
# permissions changed when this stack moved off the NLB.

module "lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~>6.0"

  count = var.app_expose_via_alb ? 1 : 0

  name            = "aws-load-balancer-controller"
  use_name_prefix = false

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = aws_iam_openid_connect_provider.this.arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  count = var.app_expose_via_alb ? 1 : 0

  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.lb_controller_chart_version
  namespace  = "kube-system"

  set = [
    { name = "clusterName", value = local.eks_cluster_name },
    { name = "region", value = var.region },
    { name = "vpcId", value = local.vpc_id },
    { name = "serviceAccount.create", value = "true" },
    { name = "serviceAccount.name", value = "aws-load-balancer-controller" },
    {
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = module.lb_controller_irsa[0].arn
    },
  ]

  # The controller's pods need somewhere to run, and its webhook must be
  # serving before any LoadBalancer Service is created.
  depends_on = [aws_eks_node_group.nodes]
}
