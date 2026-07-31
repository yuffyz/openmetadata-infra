# Core EKS addons: CNI, kube-proxy, CoreDNS
#
# The cluster sets bootstrap_self_managed_addons = true, which installs these as
# static self-managed manifests pinned to whatever EKS shipped at bootstrap. On a
# large version jump that CNI can lag the control plane, and a CNI that never
# goes Ready means nodes never register:
#
#   NodeCreationFailure: Instances failed to join the kubernetes cluster
#
# Declaring them as EKS addons lets EKS resolve a version compatible with the
# cluster, and OVERWRITE lets the addon adopt the self-managed objects that
# bootstrap already created.
#
# bootstrap_self_managed_addons is deliberately left alone: it can only be set at
# create time, so flipping it forces replacement of the cluster and everything
# built on it. These addons fix the version skew without that.
#
# Ordering matters:
#   vpc-cni + kube-proxy  -> DaemonSets, install fine with zero nodes, and must
#                            exist BEFORE the node group so nodes can go Ready.
#   coredns               -> a Deployment, so it cannot reach ACTIVE until there
#                            are nodes to schedule on; it follows the node group.

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.openmetadata.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.openmetadata.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.openmetadata.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.nodes]
}
