# Global Accelerator in front of the OpenMetadata ALB.
#
# Two static anycast IPv4 addresses, advertised from AWS edge locations, that
# forward TCP to the ALB. Enabled by setting app_accelerator_name to the name of
# an accelerator that bootstrap/ owns.
#
# --- What lives where, and why ----------------------------------------------
#
# The ACCELERATOR is created in bootstrap/, not here. It holds the addresses,
# and the whole point of those addresses is that they outlive this stack: this
# environment is built for cheap teardown (see the header of
# config/dev.auto.tfvars), and openmetadata-dev.ffdb.com is published in an
# internal zone this account does not own, so repointing it is a ticket rather
# than a command. An accelerator created here would be destroyed with the
# environment and the rebuild would get a new pair -- moving the staleness from
# the ALB's hostname to the accelerator's addresses rather than removing it.
# Same reasoning as the NAT EIP (stable_nat_eip_name), which is in bootstrap/
# for exactly the same reason.
#
# The LISTENER and ENDPOINT GROUP are created here, because both are properties
# of this environment: the listener's ports follow this environment's TLS
# configuration, and the endpoint group points at an ALB that only exists once
# this stack is applied. Destroying the environment removes both and leaves the
# accelerator holding its addresses with nothing behind it. That is the intended
# resting state -- the addresses stay reserved, and the next apply reattaches
# them.
#
# What it buys:
#
#   Addresses that do not move, so the ffdb.com record is written once, and a
#   fixed pair the network team can write a forward-proxy steering bypass
#   against -- which is not possible against a rotating set of
#   *.elb.amazonaws.com addresses.
#
# What it does NOT buy, so that nobody rediscovers it later:
#
#   It is not a fix for anything that was wrong with the NLB. The outage that
#   started this was Netskope terminating TLS on the client side and failing to
#   reach AWS at all. An accelerator changes where traffic ENTERS the AWS
#   network; it has no say in what a proxy on the endpoint does with port 443.
#
#   It is not multi-region failover. There is one endpoint group, in one
#   region, holding one ALB. The health-aware routing GA is sold on has
#   nothing to fail over TO.
#
# Cost: roughly $18/month for the accelerator (billed in bootstrap/, and billed
# even while this environment is torn down) plus a per-GB data transfer premium.

locals {
  app_ga_enabled = var.app_expose_via_alb && var.app_accelerator_name != ""
}

# The bootstrap-owned accelerator this environment attaches to.
#
# Fails the plan with "no matching Global Accelerator Accelerator found" if
# app_accelerator_name is set but bootstrap/ has not been applied with
# create_global_accelerator = true -- the same failure mode, deliberately, as an
# unbootstrapped NAT EIP.
data "aws_globalaccelerator_accelerator" "app" {
  count    = local.app_ga_enabled ? 1 : 0
  provider = aws.global_accelerator

  name = var.app_accelerator_name
}

# AWS's published address ranges for Global Accelerator, referenced by the
# Ingress so they land in the ALB's managed security group. See the annotation
# in alb_ingress.tf for why it is there.
#
# Looked up by name rather than hardcoded: the ranges change. If this ever
# fails with "no managed prefix list found", the name has been changed by AWS
# -- find the current one with:
#
#   aws ec2 describe-managed-prefix-lists --region us-east-1 \
#     --filters Name=owner-id,Values=AWS \
#     --query "PrefixLists[?contains(PrefixListName,'globalaccelerator')]"
data "aws_ec2_managed_prefix_list" "global_accelerator" {
  count = local.app_ga_enabled ? 1 : 0
  name  = "com.amazonaws.global.globalaccelerator"
}

# Both of these carry the aliased provider for the same reason the data source
# above does: Global Accelerator's control plane is reachable only through the
# us-west-2 endpoint, whatever region the endpoints live in.
resource "aws_globalaccelerator_listener" "app" {
  count    = local.app_ga_enabled ? 1 : 0
  provider = aws.global_accelerator

  accelerator_arn = data.aws_globalaccelerator_accelerator.app[0].arn
  protocol        = "TCP"

  # NONE, not SOURCE_IP. Client affinity picks which ENDPOINT a client reaches,
  # and there is exactly one, so it has nothing to decide. Session stickiness
  # is a different problem, solved a layer down by the ALB's cookie stickiness
  # (see alb_ingress.tf) -- and source-IP affinity would be the wrong tool for
  # it anyway, because behind a corporate proxy the whole company shares a
  # handful of source addresses.
  client_affinity = "NONE"

  # The same ports the ALB listens on. A port that is not listed here is not
  # forwarded, and presents to the client as a connection that hangs -- so
  # this deriving from app_public_ports rather than being written out is what
  # keeps 8585 working when TLS is toggled.
  dynamic "port_range" {
    for_each = local.app_public_ports
    content {
      from_port = port_range.value.port
      to_port   = port_range.value.port
    }
  }
}

resource "aws_globalaccelerator_endpoint_group" "app" {
  count    = local.app_ga_enabled ? 1 : 0
  provider = aws.global_accelerator

  listener_arn          = aws_globalaccelerator_listener.app[0].id
  endpoint_group_region = var.region

  # No health_check_* arguments on purpose. For an ALB endpoint, Global
  # Accelerator takes endpoint health from the load balancer's own target
  # group rather than probing it separately, so setting them here would either
  # be rejected or silently ignored -- and would imply a second, competing
  # health definition that does not exist. The check that matters is the
  # healthcheck-path annotation in alb_ingress.tf.
  endpoint_configuration {
    # The ALB's ARN, from the tag-based lookup in alb_tls.tf. That data source
    # reads after the Ingress has settled, so the load balancer exists by the
    # time this runs.
    endpoint_id = data.aws_lb.app[0].arn
    weight      = 100

    # Without this the ALB sees the accelerator's addresses instead of the
    # client's, and app_lb_allowed_cidrs -- which is the ONLY thing limiting
    # who can reach a UI with a default admin account -- silently stops
    # matching anything and admits every client the accelerator forwards.
    #
    # Confirm it took effect after the first apply rather than trusting it:
    #
    #   aws globalaccelerator describe-endpoint-group --region us-west-2 \
    #     --endpoint-group-arn <arn> \
    #     --query 'EndpointGroup.EndpointDescriptions[].ClientIPPreservationEnabled'
    client_ip_preservation_enabled = true
  }
}
