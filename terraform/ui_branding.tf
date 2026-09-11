# Renaming the OpenMetadata UI in the browser tab.
#
# Set app_display_name and every page title becomes "<route> | <that name>"
# instead of "<route> | OpenMetadata".
#
# --- Why this is a proxy and not a setting ----------------------------------
#
# OpenMetadata has no configuration for it. Settings -> Preferences ->
# Appearance customises the logo, the monogram, the favicon and the theme
# colours, and stops there. The document title is assembled client-side by the
# SPA and rewritten on every navigation, so there is no server-side string to
# change and no value in the chart, the database or the API that reaches it.
#
# The options that remain are: fork and rebuild the UI image; patch the built
# assets inside the running container; or rewrite the HTML on the way out. This
# is the third. It touches no OpenMetadata image, chart value or database row,
# so an upgrade cannot undo it and a rollback is one variable.
#
# What it does is add ONE script tag to the served HTML. Everything else is
# passed through byte for byte.
#
# > ⚠️ This puts another hop in front of the UI. The Ingress targets this proxy
# > instead of the chart's Service, so the ALB health-checks nginx, and nginx
# > health-checks nothing -- a failure here presents as the UI being down. Given
# > how much of this stack's history has been spent on the request path, weigh
# > that against a cosmetic change. Setting app_display_name back to "" removes
# > the proxy and repoints the Ingress at the app on the next apply.
#
# Airflow is unaffected either way: it talks to openmetadata.<ns>.svc:8585
# directly and never traverses this.

locals {
  app_branding_enabled = var.app_expose_via_alb && var.app_display_name != ""

  # The chart's own Service, which this proxies to and which stays exactly as
  # it was. Fully qualified because nginx resolves it once at startup.
  app_branding_upstream = "openmetadata.${local.namespace}.svc.cluster.local:8585"

  # What the Ingress points at. The proxy when it exists, the app otherwise --
  # so turning branding off restores the direct path with no other edit.
  app_ingress_service = (local.app_branding_enabled
    ? "openmetadata-branded"
    : "openmetadata"
  )
}

resource "kubernetes_config_map_v1" "app_branding" {
  count = local.app_branding_enabled ? 1 : 0

  metadata {
    name      = "openmetadata-branding"
    namespace = local.namespace
  }

  data = {
    # Two files rather than one inlined blob: nginx string literals and
    # JavaScript quoting do not mix well, and keeping the script separate means
    # it can be linted and unit-tested as JavaScript.
    "default.conf" = templatefile("${path.module}/files/branding-nginx.conf.tftpl", {
      upstream = local.app_branding_upstream
    })

    "brand-title.js" = templatefile("${path.module}/files/brand-title.js.tftpl", {
      display_name = var.app_display_name
    })
  }
}

resource "kubernetes_deployment_v1" "app_branding" {
  count = local.app_branding_enabled ? 1 : 0

  metadata {
    name      = "openmetadata-branding"
    namespace = local.namespace
    labels    = { "app.kubernetes.io/name" = "openmetadata-branding" }
  }

  spec {
    # Two, because this is now in the path of every UI request and a single
    # replica makes a routine node roll an outage. It is a stateless proxy, so
    # there is nothing to coordinate.
    replicas = 2

    selector {
      match_labels = { "app.kubernetes.io/name" = "openmetadata-branding" }
    }

    template {
      metadata {
        labels = { "app.kubernetes.io/name" = "openmetadata-branding" }

        # Restarts the pods when either file changes. Without it a title change
        # would apply only on the next unrelated rollout, because Kubernetes
        # does not restart pods when a mounted ConfigMap's contents change and
        # nginx does not reload on its own.
        annotations = {
          "checksum/config" = sha256(jsonencode(kubernetes_config_map_v1.app_branding[0].data))
        }
      }

      spec {
        container {
          name  = "nginx"
          image = "nginx:1.27-alpine"

          port {
            name           = "http"
            container_port = 8080
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/nginx/conf.d/default.conf"
            sub_path   = "default.conf"
            read_only  = true
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/nginx/brand/brand-title.js"
            sub_path   = "brand-title.js"
            read_only  = true
          }

          # Probes the locally served script, not the app. This pod is healthy
          # when nginx can serve; whether OpenMetadata is up is the ALB target
          # group's question, and conflating the two would take the proxy out
          # of rotation during an app restart and turn a slow start into a
          # 503 with no targets.
          readiness_probe {
            http_get {
              path = "/_brand/title.js"
              port = "http"
            }
            period_seconds        = 10
            failure_threshold     = 3
            initial_delay_seconds = 3
          }

          liveness_probe {
            http_get {
              path = "/_brand/title.js"
              port = "http"
            }
            period_seconds    = 20
            failure_threshold = 3
          }

          resources {
            requests = {
              cpu    = "25m"
              memory = "32Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.app_branding[0].metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [module.app]
}

# Deliberately named differently from the chart's Service rather than replacing
# it. The chart's "openmetadata" Service on 8585 is the cluster-internal address
# baked into every deployed ingestion pipeline's metadataApiEndpoint, and
# nothing here may disturb it.
#
# Published on 8585 so the Ingress backend port is the same whichever Service it
# points at, and switching branding on or off is a one-line diff.
resource "kubernetes_service_v1" "app_branding" {
  count = local.app_branding_enabled ? 1 : 0

  metadata {
    name      = "openmetadata-branded"
    namespace = local.namespace
  }

  spec {
    type     = "ClusterIP"
    selector = { "app.kubernetes.io/name" = "openmetadata-branding" }

    port {
      name        = "http"
      port        = 8585
      target_port = "http"
      protocol    = "TCP"
    }
  }
}
