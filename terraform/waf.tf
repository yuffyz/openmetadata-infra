# AWS WAF in front of the OpenMetadata ALB.
#
# Enabled by app_waf_enabled (requires app_expose_via_alb). The web ACL is
# created here; alb_ingress.tf hands its ARN to the AWS Load Balancer
# Controller through the wafv2-acl-arn annotation, and the controller does the
# association (its IRSA policy already carries wafv2:AssociateWebACL and
# friends).
#
# Order of evaluation, cheapest and least ambiguous first:
#
#   1 rate-limit           per source IP, COUNT by default (see below)
#   2 ip-reputation        AWS-managed list of known malicious sources: block
#   3 known-bad-inputs     exploit payloads such as Log4Shell (CVE-2021-44228)
#                          against a Java app: block
#   4 common-rule-set      AWS core rule set (OWASP-style): block, except the
#                          three rules below, which COUNT
#
# The security group allowlist (app_lb_allowed_cidrs) still runs first and is
# unchanged: WAF only ever sees traffic from addresses the allowlist admitted.
# So what this adds is not "who can connect" but "what an admitted client may
# send" -- which matters while ~66,000 addresses can reach a UI that still has
# a default admin account.
#
# --- Why three core rules only count ------------------------------------------
#
# OpenMetadata's API bodies legitimately trip them:
#
#   SizeRestrictions_BODY   blocks bodies over 8 KB. Saving a long description,
#                           a glossary or CSV import, a lineage edit or a stored
#                           query routinely exceeds that.
#   CrossSiteScripting_BODY descriptions are rich text / markdown and can carry
#                           tag-like content.
#   GenericLFI_BODY         ingestion and connection configs carry file paths
#                           ("../", "/etc/...") as ordinary values.
#
# Blocked, they surface as a 403 from the ALB with no OpenMetadata error behind
# it -- a save that silently fails. Counting records every match in the logs
# below; promote a rule to block once the logs show it only matches attacks.
# The SQL injection rule set is left out entirely for the same reason:
# OpenMetadata stores and displays SQL as data.
#
# --- Why the rate limit only counts by default --------------------------------
#
# The limit is per SOURCE IP, and behind a corporate proxy (Netskope here)
# whole offices share a handful of egress addresses. A limit that is generous
# per person can still lock out everyone behind one proxy address at once.
# Watch the rate-limit metric for a few weeks, then set
# app_waf_rate_limit_action = "block" with a limit above the observed peak.
#
# Cost: ~$5/month per web ACL + $1 per rule + $0.60 per million requests, plus
# CloudWatch Logs ingestion -- roughly $10/month per environment at this
# traffic.

locals {
  app_waf_enabled = var.app_expose_via_alb && var.app_waf_enabled

  # Core rule set rules that count instead of block; see above.
  app_waf_count_only_rules = [
    "SizeRestrictions_BODY",
    "CrossSiteScripting_BODY",
    "GenericLFI_BODY",
  ]

  # Metric names: alphanumeric plus hyphen/underscore, so derive them from the
  # cluster name rather than from free text.
  app_waf_name = "${var.eks_cluster_name}-omd"
}

resource "aws_wafv2_web_acl" "app" {
  count = local.app_waf_enabled ? 1 : 0

  name = local.app_waf_name
  # WAF descriptions allow only letters, digits, whitespace and + = : # @ / - , .
  # -- no parentheses; CreateWebACL rejects anything else with a 400.
  description = "OpenMetadata UI for cluster ${var.eks_cluster_name}"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit"
    priority = 1

    action {
      dynamic "count" {
        for_each = var.app_waf_rate_limit_action == "count" ? [1] : []
        content {}
      }
      dynamic "block" {
        for_each = var.app_waf_rate_limit_action == "block" ? [1] : []
        content {}
      }
    }

    statement {
      rate_based_statement {
        limit                 = var.app_waf_rate_limit
        aggregate_key_type    = "IP"
        evaluation_window_sec = 300
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.app_waf_name}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "ip-reputation"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.app_waf_name}-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "known-bad-inputs"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.app_waf_name}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "common-rule-set"
    priority = 4

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"

        dynamic "rule_action_override" {
          for_each = local.app_waf_count_only_rules
          content {
            name = rule_action_override.value
            action_to_use {
              count {}
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.app_waf_name}-common-rule-set"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.app_waf_name
    sampled_requests_enabled   = true
  }
}

# Full request logs, so count-only rules can be judged before they block.
# The aws-waf-logs- prefix is mandatory for a WAF log destination.
resource "aws_cloudwatch_log_group" "waf" {
  count = local.app_waf_enabled ? 1 : 0

  name              = "aws-waf-logs-${local.app_waf_name}"
  retention_in_days = var.app_waf_log_retention_days
}

resource "aws_wafv2_web_acl_logging_configuration" "app" {
  count = local.app_waf_enabled ? 1 : 0

  resource_arn            = aws_wafv2_web_acl.app[0].arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]

  # Session cookies and bearer tokens would otherwise be written to the log in
  # full, and anyone who can read the log group could replay them.
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
}
