# Deploying production

Step-by-step runbook for deploying OpenMetadata to the **production**
environment with this repo. For what each piece is and why, see
[README_full.md](README_full.md). This page is the order of operations.

Production uses the same code as dev. Only `config/production.auto.tfvars`
differs:

| | dev | production |
|---|---|---|
| UI | `https://dev.example-openmetadata.com` | `https://example-openmetadata.com` (zone apex) |
| EKS nodes | 2 × `t3.xlarge`, 20 GiB | 3 × `m7i.large` (one per AZ), 50 GiB |
| OpenSearch | 2 × `t3.medium.search` | 2 × `r6g.large.search`, 20 GiB, replicas kept |
| RDS | single-AZ, no backups, unprotected | multi-AZ, 30-day backups, deletion protection |
| Search auth | server's IAM role (SigV4) | same |
| WAF, HTTP→HTTPS redirect, IP allowlist | on | on, same allowlist |
| Approval | none | required reviewers |

> 💸 Production costs roughly **$221/month** for nodes, **$245/month** for
> OpenSearch, plus RDS (multi-AZ ×2), NAT, ALB, WAF (~$10) and EFS.

---

## 1. Before the first deploy (one time)

These are account- and repo-level, shared with dev. If dev already deploys
from the same repo and account, most are done. Check each anyway.

- [ ] **`bootstrap/` applied** in the production AWS account. It provides the
      GitHub OIDC deploy role, the OpenSearch service-linked role and,
      optionally, the state bucket. See
      [README_full.md → One-time setup](README_full.md#one-time-setup).
- [ ] **Repository variables and secret** set: `AWS_REGION`, `TF_STATE_BUCKET`,
      `TF_STATE_REGION`, optional `TF_STATE_PREFIX`, and secret `AWS_ROLE_ARN`.
      `AWS_REGION` must equal `region` in `config/production.auto.tfvars`
      (`us-east-1`).
- [ ] **GitHub Environment `production`** exists with **required reviewers**.
      Restrict *Deployment branches* to the branch production deploys from.
      The deploy role's trust policy must allow the `production` environment.
- [ ] **Hosted zone `example-openmetadata.com`** is in this account and
      delegated from the registrar. If dev's certificate validated, it is.
- [ ] **The zone apex is free.** Production publishes an alias A record at
      `example-openmetadata.com` itself and will not overwrite an existing one,
      so the apply fails instead. Check:
      ```bash
      aws route53 list-resource-record-sets --hosted-zone-id <zone-id> \
        --query "ResourceRecordSets[?Name=='example-openmetadata.com.' && Type=='A']"
      ```
      Must print `[]`.
- [ ] **Review the IP allowlist** in `config/production.auto.tfvars`
      (`app_lb_allowed_cidrs`). It copies dev's, including three individual
      home/ISP `/32`s that change over time. For production, keep only the
      corporate VPN/proxy ranges unless those people need direct access.

## 2. Get the code into the deploying repo

Deploys run from **`ffdb-enterprise/openmetadata-infra`**, not from a
personal fork.

- [ ] Bring the release's changes to the branch production deploys from. The
      run log's checkout step prints the commit it used. Confirm it is the one
      you expect before approving.
- [ ] The post-apply checks run as `bash scripts/<name>.sh`, so the scripts'
      executable bit does not matter. Both of these must be present:
      `scripts/opensearch-credentials.sh` and `scripts/opensearch-iam.sh`.

## 3. Plan

Actions → **openmetadata-infra** → *Run workflow* → environment **`production`**,
action **`plan`**.

Read the plan output in the **Plan (production)** job. What to expect:

**First deploy:** everything is created: VPC, EKS, node group, two RDS
instances, OpenSearch, EFS, the app, ALB, certificate, DNS, WAF and the
server's IAM role. Expect roughly 110 resources.

**Updating an existing production**, depending on what it last had:

| Change | Plan shows | Impact during apply |
|---|---|---|
| Node size → `m7i.large` / 50 GiB | node group **replaced** | **UI and Airflow down ~5–10 min** while new nodes join. The name is fixed, so old nodes go first |
| OpenSearch → `r6g.large.search` / 20 GiB | domain updated in place | Blue/green, no downtime, but **can take an hour or more**; the apply waits |
| UI exposure (ALB, cert, DNS, allowlist) | Ingress, certificate, Route 53 records created | none, it is new |
| WAF + HTTP→HTTPS redirect | web ACL, log group, logging config created; Ingress updated | none; the ALB is updated in place |
| Search over IAM | IAM role + policy created; Helm release updated | **server restarts; search returns 403 for a minute or two** until the post-apply step maps the role |

Stop and investigate if the plan **replaces or destroys** RDS, the OpenSearch
domain, or anything with `deletion_protection`. Nothing in this release should.

## 4. Apply

Run the workflow again: environment **`production`**, action **`apply`**. It
plans afresh, then pauses for a reviewer to approve the **Apply (production)**
job. Approve only after reading that run's plan.

Schedule it. The node-group replacement and the IAM switch each cause a short
outage, and the OpenSearch change can hold the apply open for an hour.

After `terraform apply`, the job runs two checks. **Both must be green:**

1. **Verify OpenSearch admin password (heal if drifted).** Expect:
   ```
   OpenSearch admin login with the secret's password: HTTP 200
   OK: the domain accepts the admin password in opensearch-credentials.
   ```
   On a `401` it bounces the domain's admin password back to Terraform's value
   and re-checks (`HEALED`). The server itself does not use this password, but
   the next step logs in with it.

2. **Verify search over IAM.** Expect on the first run:
   ```
   mapped (HTTP 200)                 <- "already mapped" on later runs
   1 ok    image supports IAM auth
   2 ok    server pod: SEARCH_AWS_IAM_AUTH_ENABLED=true, AWS_ROLE_ARN=...-openmetadata-search
   3 ok    server log: SigV4 transport created
   4 ok    signed request as the server's role: HTTP 200, roles=['all_access']
   ```
   Check 3 may say **SKIP** on a server that has been up long enough for its
   startup log to rotate. That is a warning, not a failure: check 4 is the one
   that proves the role works.

If either fails, the step names the failed check. See
[Troubleshooting](#troubleshooting).

## 5. Verify from outside

From an address on the allowlist:

- [ ] `curl -I http://example-openmetadata.com` → `301` with
      `Location: https://example-openmetadata.com/`
- [ ] `https://example-openmetadata.com` loads the OpenMetadata login page with
      a valid certificate.
- [ ] Actions → **openmetadata-ops** → `production` → **`show-exposure`**:
      listeners on 80 (redirect), 443 and 8585; the certificate attached; the
      WAF web ACL associated; the security group allowing only the allowlist.
- [ ] From an address **not** on the allowlist, the site does not connect.

## 6. Make it safe for users

- [ ] **Change the OpenMetadata `admin` password** in the UI immediately. The
      chart ships a single `admin` account with a well-known password, and the
      allowlist (~66,000 addresses) is the only other barrier. SSO is the
      proper fix and is still open; see
      [README_full.md → Production exposure](README_full.md#production-exposure--whats-still-missing).
- [ ] **Cut search shards before loading real metadata:**
  1. openmetadata-ops → `production` → **`set-shard-template`**. It sets 1 shard
     and 1 replica in OpenMetadata's own `om_*` index templates, leaving their
     mappings alone.
  2. In OpenMetadata: **Settings → Applications → Search Indexing →
     Configure**, *Recreate Index* = true, all entity types, **Run**. Wait for
     the cluster to be green first.
  3. Run `set-shard-template` again. Its table should show `pri` = 1.
     Afterwards production could drop from `r6g.large.search` to
     `m6g.large.search`. If `pri` is still 5, see README_full.md →
     *Shard defaults*.
- [ ] Ingest a first data source and confirm it appears in **Explore**.

## 7. In the weeks after

- [ ] **WAF tuning.** The rate limit and three core rules start in *count*
      mode. Review the log group `aws-waf-logs-open-metadata-omd` and the WAF
      metrics. Then set `app_waf_rate_limit_action = "block"` with a limit above
      the observed peak, and move core rules out of `app_waf_count_only_rules`
      in `terraform/waf.tf` once they only match attacks.
- [ ] **Allowlist drift.** If someone loses access, re-check their egress
      address with `curl ifconfig.me`.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Apply fails on `aws_route53_record.app`: record already exists | Something already holds the apex A record | Remove it, or choose another `app_tls_domain_name` |
| Apply sits on `aws_acm_certificate_validation` until timeout | Zone exists but is not delegated from the registrar | Fix NS delegation at the registrar |
| Post-apply step: `Permission denied` / exit 126 | Workflow calls a script directly and the file lost its executable bit | Use the current `deploy.yml`, which runs them with `bash` |
| Admin check: `HTTP 401` after heal, `UpdateVersion` moved | AWS API cannot set this domain's master password | Reset it in OpenSearch Dashboards: *Security → Internal users → admin* |
| IAM check 2 FAIL: no `AWS_ROLE_ARN` | Server pod predates the ServiceAccount annotation | openmetadata-ops → `restart-server`, then re-run apply |
| IAM check 4 FAIL: `403` | Role not mapped, or lacks `es:ESHttp*` | Re-run apply (it maps the role); check the role's policy names this domain |
| IAM check 4 FAIL: "authenticated but not mapped" | Mapping missing | Re-run apply, or `ROLE_ARN=... bash scripts/opensearch-iam.sh map` from a session with cluster access |
| Explore empty, everything else green | Index never built, or built against a broken cluster | Search Indexing → *Recreate Index* = true, once the cluster is green |
| Site times out from the office | Client's egress is not on the allowlist (often a proxy pool) | Add the proxy vendor's published ranges, not a `/32` |

## Rolling back

- **A bad application or config change:** revert the commit in the deploying
  repo, then plan and apply again.
- **Search over IAM:** set `opensearch_iam_auth = false` and apply. The server
  returns to the master password. There is no longer an automatic restart when
  that password changes, so run `restart-server` after any password change.
- **WAF:** set `app_waf_enabled = false` and apply. The controller detaches the
  web ACL.
- **Node size:** changing it back replaces the node group again (the same
  ~5–10 min outage).
- **Destroying production is intentionally hard.** RDS has deletion protection
  and final snapshots. First flip those in `config/production.auto.tfvars`,
  then follow [README_full.md → Destroying](README_full.md#destroying--clean-up-the-load-balancer-first),
  including deleting the Ingress before dispatching destroy.
