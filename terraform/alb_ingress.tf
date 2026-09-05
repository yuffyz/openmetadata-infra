# Public entry point for the OpenMetadata UI.
#
# An Ingress that the AWS Load Balancer Controller turns into an
# internet-facing ALB. With TLS configured it listens HTTPS on 443 and 8585;
# without it, HTTP on 8585 alone. Targets are always the pod's 8585.
#
# 443 is not cosmetic. Clients on a corporate network reach this through a
# forward proxy (Netskope here, which terminates TLS and re-signs with its own
# CA), and those proxies steer 443 and 80 -- a non-standard port is usually not
# proxied at all, so the connection hangs with no useful error. 8585 is kept
# alongside it so existing bookmarks and the raw AWS hostname keep working.
#
# --- Why an Ingress, and not a Service of type LoadBalancer -----------------
#
# The controller provisions NLBs from Services and ALBs from Ingresses; there
# is no annotation that turns a Service into an ALB. That difference is what
# removes the awkwardness this file used to carry.
#
# An NLB listener port is ALWAYS the Service port, so publishing on 443 meant
# owning a second Service just to hold the listener -- the chart's own Service
# had to stay on 8585 because the server advertises
# openmetadata.<namespace>.svc:8585 to Airflow as metadataApiEndpoint
# (hardcoded in the upstream module's helm_values.tftpl), and every ingestion
# pipeline already deployed carries that host:port in its DAG configuration.
#
# An ALB has no such coupling: the listener ports come from the listen-ports
# annotation and the backend port comes from the rule. So this Ingress points
# straight at the chart's own ClusterIP Service, the second Service is gone,
# and metadataApiEndpoint is untouched.
#
# --- What changed by moving off the NLB -------------------------------------
#
#   Health checks are HTTP, not TCP. An NLB target group with a TCP check
#   reports healthy as soon as something holds the socket open, so a wedged
#   JVM that accepts connections and answers nothing still passes. That is
#   indistinguishable from a network fault at the client, and it cost us a
#   debugging session. An HTTP check fails.
#
#   Stickiness is cookie-based, not source-IP. OpenMetadata stores sessions
#   IN-MEMORY, so OIDC logins break across replicas with "Missing state
#   parameter" and the documented workaround is sticky sessions. An NLB can
#   only do source-IP affinity, and behind a corporate proxy every user shares
#   a handful of egress addresses -- that would pin the whole company onto one
#   pod. See the target-group-attributes annotation below.
#
#   Layer 7 is now available. WAF and listener-level OIDC
#   (alb.ingress.kubernetes.io/auth-type) are annotations away, which they
#   were not on an NLB. Neither is enabled here -- see the note at the bottom.

locals {
  # Ports the ALB publishes, and the ports Global Accelerator forwards. Named
  # because listen-ports is JSON keyed by protocol and the name keeps the two
  # lists from drifting apart.
  app_public_ports = local.app_tls_enabled ? [
    { name = "https", port = 443 },
    { name = "http", port = 8585 },
    ] : [
    { name = "http", port = 8585 },
  ]

  # listen-ports takes a JSON array of single-key objects, protocol -> port.
  # jsonencode rather than a hand-built string: a literal is easy to get
  # subtly wrong and the controller's parse error names the annotation, not
  # the offending character.
  app_listen_ports = jsonencode([
    for p in local.app_public_ports : { (local.app_tls_enabled ? "HTTPS" : "HTTP") = p.port }
  ])
}

resource "kubernetes_ingress_v1" "app_public" {
  count = var.app_expose_via_alb ? 1 : 0

  metadata {
    name      = "openmetadata-public"
    namespace = local.namespace

    annotations = merge(
      {
        "alb.ingress.kubernetes.io/load-balancer-name" = local.app_alb_name
        "alb.ingress.kubernetes.io/scheme"             = var.app_lb_scheme
        "alb.ingress.kubernetes.io/listen-ports"       = local.app_listen_ports

        # Targets are pod IPs, so the ALB bypasses kube-proxy and the pod's
        # own 8585 is the target port. "instance" mode would need the Service
        # to be NodePort, which it is not.
        "alb.ingress.kubernetes.io/target-type" = "ip"

        # The pod speaks plain HTTP. TLS terminates on the listener and the
        # hop to the pod stays cleartext inside the VPC, as it did on the NLB.
        "alb.ingress.kubernetes.io/backend-protocol" = "HTTP"

        # An Ingress has no equivalent of spec.loadBalancerSourceRanges, so
        # the allowlist arrives as an annotation. The controller turns it into
        # the managed security group's ingress rules, same as before.
        #
        # Note what this has to contain for a proxied client: the address seen
        # here is the proxy's egress, not the user's workstation. Netskope and
        # the like egress from large, rotating pools, so allowlisting one
        # address per complaint will keep failing -- use the vendor's
        # published ranges.
        "alb.ingress.kubernetes.io/inbound-cidrs" = join(",", var.app_lb_allowed_cidrs)

        # Health check on the traffic port over HTTP. Path is "/" and not
        # "/healthcheck": OpenMetadata is a Dropwizard service and
        # /healthcheck lives on the ADMIN port 8586, which would mean a second
        # target-group port and another security group rule for no benefit.
        # "/" is served by the app itself, so it still catches a JVM that is
        # listening but not answering -- which is the failure the TCP check
        # missed.
        #
        # 200-399 rather than 200: the root path redirects in some versions,
        # and a health check that fails on a redirect takes the whole service
        # down for a cosmetic reason.
        "alb.ingress.kubernetes.io/healthcheck-protocol" = "HTTP"
        "alb.ingress.kubernetes.io/healthcheck-path"     = "/"
        "alb.ingress.kubernetes.io/success-codes"        = "200-399"

        # Cookie stickiness, for the in-memory session store described above.
        # Inert at one replica and correct the moment there are two, which is
        # the point -- the failure it prevents ("Missing state parameter" on
        # login) looks like an IdP misconfiguration, not a routing problem.
        "alb.ingress.kubernetes.io/target-group-attributes" = "stickiness.enabled=true,stickiness.type=lb_cookie"

        # 60s is the ALB default and it severs OpenMetadata's activity-feed
        # stream, which looks like the UI quietly going stale rather than an
        # error.
        "alb.ingress.kubernetes.io/load-balancer-attributes" = "idle_timeout.timeout_seconds=300"
      },

      # TLS on the listener. ssl-policy is pinned rather than left at the
      # controller default so a policy change is a visible diff here.
      local.app_tls_enabled ? {
        "alb.ingress.kubernetes.io/certificate-arn" = local.app_cert_arn
        "alb.ingress.kubernetes.io/ssl-policy"      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
      } : {},

      # Global Accelerator's published address ranges, added to the same
      # managed security group as inbound-cidrs.
      #
      # Whether this is strictly required depends on the client IP
      # preservation mode of the endpoint group (global_accelerator.tf sets it
      # true, so client addresses arrive intact and inbound-cidrs is what
      # admits them). It is here because it is additive and safe -- an
      # accelerator can only target endpoints in its own account, so
      # permitting these ranges does not widen access to anyone else -- and
      # because getting it wrong presents as the same silent SYN black-hole we
      # already spent a day on.
      #
      # > Verify with a real connection through the accelerator after the
      # > first apply. If it works, consider dropping this to keep the group
      # > tight.
      local.app_ga_enabled ? {
        "alb.ingress.kubernetes.io/security-group-prefix-lists" = one(data.aws_ec2_managed_prefix_list.global_accelerator[*].id)
      } : {}
    )
  }

  spec {
    # The class the controller watches. Set as a field rather than the
    # deprecated kubernetes.io/ingress.class annotation, which newer
    # controller versions ignore.
    ingress_class_name = "alb"

    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"

          # The chart's own Service -- ClusterIP, named after the Helm release,
          # still on 8585. Nothing about it changes; this only reads it.
          backend {
            service {
              name = "openmetadata"
              port {
                number = 8585
              }
            }
          }
        }
      }
    }
  }

  # Defaults to true, so this blocks until the controller reports an address
  # (10m). That is what guarantees the ALB exists before alb_tls.tf and
  # global_accelerator.tf read it back, and on timeout the provider prints the
  # Ingress's warning events -- which is where controller errors such as an
  # unresolvable subnet, a rejected annotation, or a duplicate load balancer
  # name surface.
  wait_for_load_balancer = true

  depends_on = [
    helm_release.aws_load_balancer_controller,
    module.app,
  ]
}

# --- Not enabled here: listener OIDC ----------------------------------------
#
# An ALB can authenticate at the listener with
# alb.ingress.kubernetes.io/auth-type = "oidc" plus auth-idp-oidc referencing a
# Secret holding the client ID and secret. It is deliberately left off.
#
# It gates the door, not the application: everyone who passes the IdP still
# shares OpenMetadata's single admin account, so there is no per-user identity,
# no ownership and no RBAC -- which is most of what a catalog is for. It also
# 302-redirects any non-browser client, and OpenMetadata's own bots
# authenticate with JWTs, so anything hitting /api from outside the cluster
# breaks. (Airflow is unaffected: it talks to openmetadata.<ns>.svc:8585
# internally and never traverses this load balancer.)
#
# Upstream's recommendation is OIDC in the chart -- authentication.clientType =
# confidential with an oidcConfiguration block -- which yields real per-user
# identity, and which upstream says cannot be combined with basic auth. The
# module templates only authorizer.initialAdmins and authorizer.principalDomain,
# so that config has to arrive through the module's helm_values, NOT through
# app_extra_helm_values: those reach Helm as --set, where an all-digit or
# true/false value stops being a string.
#
# Enable one or the other, never both -- two redirect flows with two session
# lifetimes produce login loops that look like an IdP fault.
