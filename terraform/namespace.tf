# K8s namespace for OpenMetadata

locals {
  namespace = kubernetes_namespace_v1.app.metadata[0].name
}

resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = "openmetadata"
  }
}
