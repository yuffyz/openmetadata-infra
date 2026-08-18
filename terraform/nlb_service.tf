# Public entry point for the OpenMetadata UI.
#
# A Service of type LoadBalancer that the AWS Load Balancer Controller turns
# into an internet-facing NLB. With TLS configured it listens on 443 and 8585;
# without it, on 8585 alone. Targets are always the pod's 8585.
#
# 443 is not cosmetic. Clients on a corporate network reach this through a
# forward proxy (Netskope here, which terminates TLS and re-signs with its own
# CA), and those proxies steer 443 and 80 -- a non-standard port is usually not
# proxied at all, so the connection hangs with no useful error. 8585 is kept
# alongside it so existing bookmarks and the raw *.elb.amazonaws.com hostname
# keep working.
#
# Why a Service of our own instead of flipping the chart's Service to
# LoadBalancer: an NLB listener port is always the Service port, so publishing
# on 443 would mean moving the chart's Service to 443 -- and that port is the
# cluster's internal address for OpenMetadata. The server advertises
# openmetadata.<namespace>.svc:8585 to Airflow as metadataApiEndpoint
# (hardcoded in the upstream module's helm_values.tftpl), and every ingestion
# pipeline already deployed carries that host:port in its DAG configuration.
# Moving it would break them until each was redeployed. A separate Service
# keeps the internal address at 8585 permanently and leaves the public listener
# free to be whatever we want.
#
# It also keeps these annotations out of Helm's `--set` handling, where a value
# that parses as a number or a bool stops being a string and is rejected by the
# API server.
locals {
  # Ports the NLB publishes. Named, because the ssl-ports annotation and the
  # controller both accept a port name, and a name cannot be mistyped as an
  # integer the way "443" can.
  app_public_ports = local.app_tls_enabled ? [
    { name = "https", port = 443 },
    { name = "http", port = 8585 },
    ] : [
    { name = "http", port = 8585 },
  ]
}

resource "kubernetes_service_v1" "app_public" {
  count = var.app_expose_via_nlb ? 1 : 0

  metadata {
    name      = "openmetadata-public"
    namespace = local.namespace

    annotations = merge(
      {
        "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
        "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
        "service.beta.kubernetes.io/aws-load-balancer-scheme"          = var.app_lb_scheme
        "service.beta.kubernetes.io/aws-load-balancer-name"            = local.app_nlb_name

        # Off by default on an NLB (defaultLoadBalancingCrossZoneEnabled =
        # false in the controller's model_builder.go). The load balancer gets a
        # node per subnet, but with cross-zone off each node only reaches
        # targets in its own AZ -- and OpenMetadata is a single replica in one
        # AZ. Every other node has nothing to forward to, so clients that
        # resolve to one hang with no SYN-ACK. Which clients those are changes
        # per DNS lookup and moves when the pod reschedules: "works for me, not
        # for them". Cross-AZ traffic is billed; at one replica it is cents.
        "service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled" = "true"
      },
      # TLS terminates on the listener; NLB-to-pod stays plain TCP inside the
      # VPC. Without ssl-ports every port would get a TLS listener, which is
      # what we want here, but naming them keeps it explicit and survives a
      # port being added later.
      local.app_tls_enabled ? {
        "service.beta.kubernetes.io/aws-load-balancer-ssl-cert"  = local.app_cert_arn
        "service.beta.kubernetes.io/aws-load-balancer-ssl-ports" = join(",", [for p in local.app_public_ports : p.name])
      } : {}
    )
  }

  spec {
    type = "LoadBalancer"

    # The native field rather than the source-ranges annotation: the controller
    # reads this first and turns it into the NLB's security group rules.
    #
    # Note what these have to contain for a proxied client: the address seen
    # here is the proxy's egress, not the user's workstation. Netskope and the
    # like egress from large, rotating pools, so allowlisting one address per
    # complaint will keep failing -- use the vendor's published ranges.
    load_balancer_source_ranges = var.app_lb_allowed_cidrs

    # The chart's selector labels (OpenMetadata.selectorLabels in
    # _helpers.tpl), so this targets the same pods as the chart's own Service.
    # The instance label is the Helm release name, set by the upstream module.
    selector = {
      "app.kubernetes.io/name"     = "openmetadata"
      "app.kubernetes.io/instance" = "openmetadata"
    }

    # Only the listeners differ. target_port is the pod's named "http" port, so
    # targets, health checks, and the backend security group rules the
    # controller manages all stay on 8585.
    dynamic "port" {
      for_each = local.app_public_ports
      content {
        name        = port.value.name
        port        = port.value.port
        target_port = "http"
        protocol    = "TCP"
      }
    }
  }

  # wait_for_load_balancer defaults to true, so this blocks until the
  # controller reports a hostname (10m timeout). That is what guarantees the
  # NLB exists before nlb_tls.tf reads it back, and on timeout the provider
  # prints the Service's warning events -- which is where controller errors
  # such as an unresolvable subnet or a rejected annotation surface.
  depends_on = [
    helm_release.aws_load_balancer_controller,
    module.app,
  ]
}
