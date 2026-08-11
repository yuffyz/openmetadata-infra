# openmetadata-infra

Deploys OpenMetadata on AWS via GitHub Actions from the Terraform project
committed in this repo at [`terraform/`](terraform/).

That project is a vendored copy of the upstream
`open-metadata/terraform-aws-openmetadata` `examples/complete` config, and it
consumes the `open-metadata/openmetadata/aws` registry module (pinned to
`1.12.13` in [`terraform/main.tf`](terraform/main.tf)). It is **maintained
here**: the workflow no longer checks out the upstream repo, and no config is
rewritten at run time. Only two files are injected — the remote-state backend
and the environment's `tfvars`.

Deployments are **environment-scoped**: pick `dev` or `production` at run time.
Each has its own tfvars, state file, and approval gate.

> 💸 This creates real, chargeable AWS infrastructure (EKS, RDS ×2, OpenSearch,
> NAT gateway, EFS). Run **destroy** when you no longer need it.

> 📖 **[README_full.md](README_full.md)** covers one-time setup (state bucket,
> GitHub OIDC role, repository variables, approval gates), the destroy runbook,
> configuration notes, and troubleshooting. Start there when setting this up in a
> new account.

## What gets created

A new **VPC** (public/private subnets, IGW, single NAT gateway) plus an EKS
cluster + node group, KMS key, IAM roles, two RDS Postgres instances
(OpenMetadata + Airflow), an OpenSearch domain, two EFS volumes, and the
OpenMetadata application deployed via Helm.

A `plan` from a clean state is **98 resources** for `dev` as configured: 91 for
the base stack, 3 core EKS addons (`vpc-cni`, `kube-proxy`, `coredns`), and 4 for
the AWS Load Balancer Controller and its IRSA role. Adding `app_tls_domain_name`
brings in about 5 more for the certificate and DNS record.

## Environments

| | **dev** | **production** |
|---|---|---|
| Config | `config/dev.auto.tfvars` | `config/production.auto.tfvars` |
| RDS | single-AZ, `deletion_protection=false`, `skip_final_snapshot=true`, no backups | multi-AZ, `deletion_protection=true`, final snapshot, 30-day backups |
| OpenSearch | 2 nodes / 2 AZs (the module's minimum) | 2 nodes / 2 AZs |
| Resource names | `-dev` suffixed (`open-metadata-dev`, `openmetadata-dev`, …) | defaults (`open-metadata`, `openmetadata`, …) |
| State key | `<prefix>/dev/terraform.tfstate` | `<prefix>/production/terraform.tfstate` |
| Approval | none (fast create/destroy) | required reviewers |
| Teardown | `terraform destroy` just works | intentionally hard (protected) |
| UI access | internet-facing NLB, IP-allowlisted; HTTPS via `app_tls_domain_name` | **not configured** — `ClusterIP` + port-forward only |

The `-dev` naming lets a dev stack coexist with production **in the same
account/region** without RDS/OpenSearch/EKS name collisions.

## Layout

```
openmetadata-infra/                     # repo root
├─ .github/
│  ├─ actions/prepare/action.yml     # composite: validate, inject cfg, OIDC, init
│  └─ workflows/
│     ├─ deploy.yml                  # manual: environment × (plan / apply / destroy)
│     ├─ state.yml                   # manual: state list / show / rm / force-unlock
│     └─ validate.yml                # PR fmt + validate (no cloud creds)
├─ terraform/                        # the Terraform root module that gets deployed
│  ├─ core_addons.tf                # vpc-cni / kube-proxy / coredns EKS addons
│  ├─ lb_controller.tf              # AWS Load Balancer Controller + IRSA (toggled)
│  └─ nlb_tls.tf                    # ACM cert + Route 53 alias for HTTPS (toggled)
├─ backend.tf                        # S3 backend block (values via -backend-config)
├─ bootstrap/                        # one-time: GitHub OIDC provider + deploy role
├─ config/
│  ├─ dev.auto.tfvars                # teardown-safe, cheaper, "-dev" names
│  └─ production.auto.tfvars         # production-safe defaults
├─ docs/architecture.drawio          # architecture diagram
└─ .terraform-version                # 1.15.8, matches TF_VERSION in the workflows
```

At deploy time the `prepare` action copies `backend.tf` → `terraform/backend.tf`
and `config/<env>.auto.tfvars` → `terraform/deploy.auto.tfvars`, then runs
`terraform init` in `terraform/`.

`backend.tf` is injected rather than committed inside `terraform/` so the same
directory stays usable locally with **local state** — a plain `terraform plan`
needs no bucket and no credentials beyond an AWS identity.

## Running it

Actions → **openmetadata-infra** → *Run workflow* → choose **environment**
(`dev` / `production`) and **action**:

- **plan** — init + validate + plan (a `destroy` selection plans `-destroy`), uploads the plan as an artifact.
- **apply** — applies the reviewed plan (waits for approval on `production`), then prints the UI URL in the run summary.
- **destroy** — tears the selected environment down (waits for approval on `production`).

**Typical dev loop:** `environment=dev, action=apply` to create, then
`environment=dev, action=destroy` to remove — no approvals, and the dev RDS
settings let destroy complete cleanly.

> With `app_expose_via_nlb = true`, delete the LoadBalancer Service **before**
> dispatching destroy. The NLB is owned by the load balancer controller, not
> Terraform, and an orphaned one blocks subnet and VPC deletion for 20 minutes.
> Full runbook in
> [README_full.md](README_full.md#destroying--clean-up-the-load-balancer-first).

Locally:

```bash
cd terraform
terraform init                                  # local state, no backend.tf present
terraform plan -var-file=../config/dev.auto.tfvars
```

## Accessing the UI

### 1. Get cluster access

```bash
aws --region us-east-1 eks update-kubeconfig --name open-metadata-dev
```

`eks.tf` sets `authentication_mode = "API"` with
`bootstrap_cluster_creator_admin_permissions = true`, so cluster-admin goes to
**the principal that created the cluster** — the GitHub Actions OIDC role, not
you. There is no `aws-auth` ConfigMap to edit, so expect
`error: You must be logged in to the server (Unauthorized)` until you grant
yourself an access entry:

```bash
CLUSTER=open-metadata-dev
ME=$(aws sts get-caller-identity --query Arn --output text)

aws eks create-access-entry --cluster-name $CLUSTER --principal-arn "$ME" --type STANDARD
aws eks associate-access-policy --cluster-name $CLUSTER --principal-arn "$ME" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

### 2. Open it

The apply job prints the URL in its run summary. To find it yourself:

```bash
# via the cluster
kubectl get svc -n openmetadata openmetadata \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# or straight from AWS, no cluster access needed
aws elbv2 describe-load-balancers --region us-east-1 \
  --query "LoadBalancers[?Type=='network'&&Scheme=='internet-facing'].DNSName" --output text
```

Then `http://<hostname>:8585` — port **8585**, and `http` not `https` unless TLS
is configured. Allow a couple of minutes after apply: the controller has to
provision the NLB and pass health checks.

Login is `admin@open-metadata.org` / `admin`. **Change it over `port-forward`,
not over the NLB** — until TLS is configured that password crosses the internet
in cleartext, starting with the well-known default.

Port-forward works in any environment and needs no load balancer:

```bash
kubectl port-forward -n openmetadata svc/openmetadata 8585:8585   # http://localhost:8585
```

### 3. HTTPS (optional)

Set both in `config/dev.auto.tfvars` and TLS terminates on the NLB with an ACM
certificate, plus a Route 53 alias record:

```hcl
app_tls_domain_name       = "openmetadata.example.com"
app_tls_route53_zone_name = "example.com"
```

Requires an existing **public** Route 53 hosted zone for a domain you control.
The URL becomes `https://openmetadata.example.com:8585`. Enabling it replaces the
NLB, so the raw `*.elb.amazonaws.com` hostname changes. Details and caveats in
[README_full.md](README_full.md#dev--https-on-the-nlb).

## Airflow and connecting data sources

### What's already deployed

Airflow comes from the `openmetadata-deps` Helm release (chart
`openmetadata-dependencies`) in the same namespace, and is what actually runs
metadata ingestion. Nothing extra needs installing:

| Piece | Where it lives |
|---|---|
| Airflow API server / UI | `svc/openmetadata-deps-api-server:8080` |
| Airflow metadata DB | its own RDS Postgres (`airflow-dev`, `db.t4g.micro`) |
| DAGs | EFS PVC `airflow-dags`, storage class `efs-dags` |
| Logs | EFS PVC `airflow-logs`, storage class `efs-logs` |
| Admin password | secret `airflow-auth`, key `password` |
| Fernet key | secret `openmetadata-deps-fernet-key` |

DAGs and logs are on **EFS**, not node storage, so ingestion pipelines survive
pod restarts and node replacement — and both Airflow and the OpenMetadata server
can see the same DAG files, which is what makes UI-deployed ingestion work.

OpenMetadata is wired to it through `pipelineServiceClientConfig` in the module's
Helm values: `type: airflow`, endpoint
`http://openmetadata-deps-api-server.openmetadata.svc:8080`, authenticating as
`admin` with the `airflow-auth` secret. You don't configure this yourself.

### Reaching the Airflow UI

Not exposed publicly — port-forward it:

```bash
kubectl port-forward -n openmetadata svc/openmetadata-deps-api-server 8080:8080
# then http://localhost:8080

# username is admin; get the generated password:
kubectl -n openmetadata get secret airflow-auth \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Confirm the service name first with `kubectl get svc -n openmetadata` — it
changed between chart versions, and the module's configured endpoint is the
authority.

You mostly don't need this UI: pipelines are created and monitored from
OpenMetadata. Reach for it when a pipeline fails and you want task-level logs.

### Adding a data source

Do this from the **OpenMetadata UI**, not Terraform — services and pipelines are
application state, not infrastructure.

1. **Settings → Services →** pick the category (Databases, Dashboards, Messaging,
   Pipelines, ML Models, Storage) **→ Add New Service**
2. Choose the connector, name the service, and fill in host, port, credentials
3. **Test Connection** — this runs from inside the cluster, so it is a real check
   of both credentials and network path
4. **Add Ingestion** → *Metadata* first, set a schedule, deploy

Deploying writes a DAG into the shared EFS `airflow-dags` volume; the Airflow
scheduler picks it up and runs it. Once metadata ingestion is green, layer on the
optional pipelines: **Usage** and **Lineage** (query-log based), **Profiler** and
**Data Quality** (row counts, distributions, tests), and **dbt** if you have
manifest artifacts.

### Network reachability — the usual blocker

Ingestion runs from **pods on nodes in the private subnets**, so "can I reach it
from my laptop" is the wrong test. What matters:

- **Internet sources** (Snowflake, BigQuery, SaaS APIs) — reachable via the
  single NAT gateway, with no extra setup **unless the source allowlists by IP**.
  What it sees is the NAT gateway's address, not your workstation:
  ```bash
  terraform output nat_egress_ip
  # or, without Terraform:
  aws ec2 describe-nat-gateways --region us-east-1 --filter Name=state,Values=available \
    --query 'NatGateways[].NatGatewayAddresses[].PublicIp' --output text
  ```
  By default that address is **reallocated on every destroy/apply**, so an
  allowlist entry goes stale on the next rebuild — a Snowflake network policy
  reports this as `250001: Could not connect to Snowflake backend`, which reads
  like a network fault rather than an allowlist miss. For a fixed address, apply
  `bootstrap/` with `create_nat_eips = true` and set `stable_nat_eip_name` in the
  environment's tfvars.
- **In-VPC sources** (RDS, Redshift, MSK, OpenSearch) — the source's security
  group must allow ingress **from the EKS cluster security group**. This is the
  same pattern the stack uses for its own RDS and OpenSearch, and the same thing
  to add for anything new:
  ```bash
  aws ec2 authorize-security-group-ingress --region us-east-1 \
    --group-id <data-source-sg> --protocol tcp --port 5432 \
    --source-group <eks-cluster-sg>
  ```
  Find the cluster SG with:
  ```bash
  aws eks describe-cluster --name open-metadata-dev --region us-east-1 \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text
  ```
- **Peered or on-prem sources** — need a route from the private subnets, plus DNS
  resolution. Neither is configured here.

If **Test Connection** times out, it is almost always a security group rather
than credentials. Credential errors come back fast and specific.

### When a pipeline fails

```bash
# is the ingestion DAG even there?
kubectl exec -n openmetadata deploy/openmetadata-deps-api-server -- \
  ls /opt/airflow/dags

# OpenMetadata server side — deployment failures show up here
kubectl logs -n openmetadata -l app.kubernetes.io/name=openmetadata --tail=100

# Airflow side — task-level detail
kubectl logs -n openmetadata -l component=scheduler --tail=100
```

A pipeline that never appears in Airflow points at the pipeline-service client
(endpoint or `airflow-auth` credentials); a pipeline that appears and fails is
usually connector configuration or network.

## Production exposure — what's still missing

Production deliberately has **no** UI exposure configured: its tfvars omit
`app_expose_via_nlb`, so the Service stays `ClusterIP` and the only access is
`kubectl port-forward`. Nothing stops you enabling the NLB + TLS variables there
— they are per-environment — and for an internal tool behind a tight allowlist
that may be enough. What it still doesn't give you:

1. **Standard ports.** The NLB listener mirrors the chart's Service port, so the
   URL carries `:8585`. An ALB Ingress serves 443 with an HTTP→HTTPS redirect and
   no port in the URL.
2. **Authentication.** The chart's default is a single `admin` account with a
   well-known password. This is the significant gap — TLS protects the transport,
   not the auth model. OpenMetadata supports OIDC/SAML via
   `openmetadata.config.authentication.*`; configure it and remove the default
   admin. An ALB can also carry a Cognito or OIDC authenticate action.
3. **WAF and managed rules.** Attachable to an ALB, not to an NLB. This is also
   where you stop maintaining `/32`s by hand — the dev allowlist is two dynamic
   ISP addresses and will keep drifting.
4. **Layer-7 anything** — path routing, header rules, request logging to S3,
   per-route timeouts. An NLB is TCP only.

Moving to an ALB Ingress reuses most of what's already here. The controller in
`lb_controller.tf` serves Ingresses as well as Services, and the ACM certificate
plus Route 53 alias in `nlb_tls.tf` transfer directly. The change is swapping the
Service annotations for chart Ingress values — `ingress.enabled`,
`ingress.className: alb`, the host rule, and `alb.ingress.kubernetes.io/*` for
`scheme`, `target-type: ip`, `certificate-arn`, `listen-ports` and the redirect
action — all of which fit through `app_extra_helm_values` with no module change.

Also worth revisiting for production, unrelated to exposure:
`enabled_cluster_log_types = []` disables EKS control-plane logging, and the node
group is the same 2 × `t3.xlarge` as dev.

## Divergence from the upstream example

The vendored config fixes inconsistencies that the upstream `examples/complete`
still carries. CI used to patch these with `awk`/`sed` before `init`; those steps
are gone, and the fixes are committed instead.

| Change | Why |
|---|---|
| `aws` provider `~> 6.0` (was `~> 5.0`) | The OpenMetadata module itself requires `aws ~> 6.0`, so the example's `~> 5.0` pin could not be satisfied alongside it. |
| `helm` provider `~> 3.0`, with `kubernetes = { … exec = { … } }` | The module's submodules use `set = [{ name, value }]`, which is helm v3 syntax. helm v3 also turned the provider's `kubernetes` block into a nested attribute. |
| `kubernetes` provider `~> 3.0` | Upstream leaves it unpinned; v3 is current. |
| `kubernetes_namespace_v1`, `kubernetes_storage_class_v1` | The unversioned resource names are deprecated in kubernetes provider v3. |
| `terraform-aws-modules/iam/aws` `~> 6.0`, submodule `iam-role-for-service-accounts` | Upstream references `iam-role-for-service-accounts-eks` with **no version**; v6 removed that submodule path (*"Unreadable module subdirectory"*), and v5 uses `data.aws_region.current.name`, deprecated under aws v6. In v6 the module renamed `role_name` → `name` and the `iam_role_arn` output → `arn`. |
| `use_name_prefix = false` on both IRSA modules | v6 defaults it to `true`, which would rename the roles to `ebs-csi-<suffix>` / `efs-csi-<suffix>`. |
| EKS `1.36` + `AL2023_x86_64_STANDARD` | Upstream pins 1.31, which is past standard support and refused by `CreateCluster`. AL2 AMIs stop at 1.32, so 1.33+ requires AL2023. |
| `vpc-cni` / `kube-proxy` / `coredns` as managed addons | Upstream relies on `bootstrap_self_managed_addons`, which pins whatever shipped at bootstrap. |

A `plan` from a clean state is clean — zero warnings, zero errors. If you
re-sync from a newer upstream release, expect to re-apply these.
