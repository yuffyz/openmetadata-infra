# openmetadata-infra

Deploys OpenMetadata on AWS via GitHub Actions from the Terraform project
committed in this repo at [`terraform/`](terraform/).

That project is a vendored copy of the upstream
`open-metadata/terraform-aws-openmetadata` `examples/complete` config, and it
consumes the `open-metadata/openmetadata/aws` registry module (pinned to
`1.12.13` in [`terraform/main.tf`](terraform/main.tf)). It is now **maintained
here**: the workflow no longer checks out the upstream repo, and no config is
rewritten at run time. Only two files are injected — the remote-state backend
and the environment's `tfvars`.

Deployments are **environment-scoped**: pick `dev` or `production` at run time.
Each environment has its own tfvars, its own state file, and its own approval
gate — so a throwaway **dev** stack is easy to spin up and tear down without
touching production.

> 💸 This creates real, chargeable AWS infrastructure (EKS, RDS ×2, OpenSearch,
> NAT gateway, EFS). Run **destroy** when you no longer need it.

## What gets created

A new **VPC** (public/private subnets, IGW, single NAT gateway) plus an EKS
cluster + node group, KMS key, IAM roles, two RDS Postgres instances
(OpenMetadata + Airflow), an OpenSearch domain, two EFS volumes, and the
OpenMetadata application deployed via Helm.

A `plan` from a clean state is **95 resources** for `dev` — 91 for the base
stack plus 4 for the AWS Load Balancer Controller and its IRSA role, which
`dev.auto.tfvars` enables (see [Accessing the UI](#accessing-the-ui)). With the
variable defaults and no NLB it's **99**, because `azs_to_use` defaults to 3
rather than dev's 2, adding a subnet and route table association per extra AZ.

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
| UI access | internet-facing NLB, IP-allowlisted, plain HTTP | **not configured** — `ClusterIP` + port-forward only |

The `-dev` naming lets a dev stack coexist with production **in the same
account/region** without RDS/OpenSearch/EKS name collisions.

## Layout

```
openmetadata-infra/                     # repo root
├─ .github/
│  ├─ actions/prepare/action.yml     # composite: inject cfg, OIDC, pre-flight, init
│  └─ workflows/
│     ├─ deploy.yml                  # manual: environment × (plan / apply / destroy)
│     └─ validate.yml                # PR fmt + validate (no cloud creds)
├─ terraform/                        # the Terraform root module that gets deployed
│  └─ lb_controller.tf              # AWS Load Balancer Controller + IRSA (toggled)
├─ backend.tf                        # S3 backend block (values via -backend-config)
├─ bootstrap/                        # one-time: GitHub OIDC provider + deploy role
├─ config/
│  ├─ dev.auto.tfvars                # teardown-safe, cheaper, "-dev" names
│  └─ production.auto.tfvars         # production-safe defaults
└─ .terraform-version                # 1.15.8, matches TF_VERSION in the workflows
```

At deploy time the `prepare` action copies `backend.tf` → `terraform/backend.tf`
and `config/<env>.auto.tfvars` → `terraform/deploy.auto.tfvars`, then runs
`terraform init` in `terraform/`.

`backend.tf` is injected rather than committed inside `terraform/` so the same
directory stays usable locally with **local state** — a plain `terraform plan`
needs no bucket and no credentials beyond an AWS identity. To relocate or rename
the project, update `TF_DIR` in both workflows.

## One-time setup

### 1. State storage (in the target AWS account)
- An **S3 bucket** for Terraform state (versioning on). That's it.

Locking is **S3-native** (`use_lockfile = true` in [`backend.tf`](backend.tf)):
Terraform takes the lock by writing a `<key>.tflock` object next to the state
using S3 conditional writes. There is **no DynamoDB table** — no table to
create, no `dynamodb:*` permissions, and no second resource to keep in sync.

State is separated per environment automatically via the key
`<prefix>/<environment>/terraform.tfstate`, so one bucket serves both, and each
environment gets its own independent lock object.

Either create the bucket by hand, or let [`bootstrap/`](bootstrap/) own it with
`create_state_bucket = true`.

> ⚠️ The bucket must exist before the workflow runs, and S3 native locking
> requires **Terraform >= 1.10** (this repo pins `1.15.8` in
> `.terraform-version` and both workflows). `terraform/versions.tf` declares
> `required_version = ">= 1.10"`, so an older CLI fails fast with a clear
> message rather than a confusing backend error.

### 2. GitHub OIDC → AWS IAM role
Create an IAM OIDC identity provider for `token.actions.githubusercontent.com`
and an IAM role this repo can assume, with a trust policy scoped to this repo
(branch `main` for `plan`; environments `dev` and `production` for
`apply`/`destroy`). Grant it permissions to manage the resources above (EKS,
EC2/VPC, RDS, OpenSearch, EFS, IAM, KMS) and to read/write the state bucket +
lock table. No long-lived keys are stored.

Ready-made Terraform for this lives in [`bootstrap/`](bootstrap/) — `terraform
apply` it once, then `gh secret set AWS_ROLE_ARN --body "$(terraform output -raw
role_arn)"`. See [bootstrap/README.md](bootstrap/README.md).

### 3. Repository configuration

**Variables** (Settings → Secrets and variables → Actions → *Variables*):

| Name | Example | Purpose |
|------|---------|---------|
| `AWS_REGION` | `us-east-1` | Region for the AWS CLI/provider — **must match `region` in the env tfvars** |
| `TF_STATE_BUCKET` | `dkc-tfstate` | State bucket |
| `TF_STATE_REGION` | `us-east-1` | Region of the state bucket |
| `TF_STATE_PREFIX` | `openmetadata` | *(optional)* state key prefix; the environment + `terraform.tfstate` are appended. Defaults to `openmetadata` |

> The state **key** is derived (`<prefix>/<environment>/terraform.tfstate`) —
> there is no `TF_STATE_KEY` variable, and no `TF_STATE_LOCK_TABLE` variable
> (locking is S3-native). There is no `MODULE_REF` variable either:
> the deployed config lives in `terraform/`, and the registry module it consumes
> is pinned in `terraform/main.tf`.

**Secrets:**

| Name | Purpose |
|------|---------|
| `AWS_ROLE_ARN` | ARN of the IAM role assumed via OIDC (repository-level, so `plan` can read it) |

### 4. OpenSearch service-linked role
A VPC OpenSearch domain can't be created until the account has
`AWSServiceRoleForAmazonOpenSearchService`. Miss it and `apply` fails partway in
with *"you must enable a service-linked role to give Amazon OpenSearch Service
permissions to access your VPC"* — after the VPC, EKS and RDS are already built.

[`bootstrap/`](bootstrap/) creates it by default
(`create_opensearch_service_linked_role`). It's account-wide and one-time, so
it's deliberately not in the per-environment stack — a `dev` destroy must not
delete a role `production` still needs. The equivalent one-off:

```bash
aws iam create-service-linked-role --aws-service-name opensearchservice.amazonaws.com
```

Verify with `aws iam get-role --role-name AWSServiceRoleForAmazonOpenSearchService`.

### 5. Approval gates (GitHub Environments)
Under Settings → Environments:
- **`production`** — add **required reviewers**. `apply`/`destroy` pause for approval.
- **`dev`** — create it with **no** protection rules (or don't create it; it's
  used unprotected). `apply`/`destroy` run immediately.

`plan` runs under no environment, so it's never gated.

## Running it

Actions → **openmetadata-infra** → *Run workflow* → choose **environment**
(`dev` / `production`) and **action**:

- **plan** — init + validate + plan (a `destroy` selection plans `-destroy`), uploads the plan as an artifact.
- **apply** — applies the reviewed plan (waits for approval on `production`).
- **destroy** — tears the selected environment down (waits for approval on `production`).

After a successful apply, the `update_kubeconfig` output prints the
`aws eks update-kubeconfig …` command to connect to the cluster.

**Typical dev loop:** run with `environment=dev, action=apply` to create, then
`environment=dev, action=destroy` to remove — no approvals, and the dev RDS
settings let destroy complete cleanly.

### Locally

```bash
cd terraform
terraform init                                  # local state, no backend.tf present
terraform plan -var-file=../config/dev.auto.tfvars
```

Without a `-var-file` the variable defaults apply, including
`region = "us-east-1"`.

## Accessing the UI

### Get cluster access first

```bash
aws --region us-east-1 eks update-kubeconfig --name open-metadata-dev
```

`eks.tf` sets `authentication_mode = "API"` with
`bootstrap_cluster_creator_admin_permissions = true`, so cluster-admin goes to
**the principal that created the cluster** — the GitHub Actions OIDC role, not
you. There is no `aws-auth` ConfigMap to edit. Expect
`error: You must be logged in to the server (Unauthorized)` until you add an
access entry for your own identity:

```bash
CLUSTER=open-metadata-dev
ME=$(aws sts get-caller-identity --query Arn --output text)

aws eks create-access-entry --cluster-name $CLUSTER --principal-arn "$ME" --type STANDARD
aws eks associate-access-policy --cluster-name $CLUSTER --principal-arn "$ME" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

The API endpoint is public (`public_access_cidrs = ["0.0.0.0/0"]`), so this
works from anywhere.

### dev — internet-facing NLB

`dev.auto.tfvars` sets `app_expose_via_nlb = true`, which installs the AWS Load
Balancer Controller and turns the chart's Service into a `LoadBalancer`:

```bash
kubectl get svc -n openmetadata openmetadata \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Then `http://<hostname>:8585`. Allow a couple of minutes after apply — Terraform
returns when the Helm release succeeds, but the controller still has to
provision the NLB and pass health checks, so the hostname is briefly empty and
then briefly unresolvable.

Initial login is `admin@open-metadata.org` / `admin`, from the module's
`initial_admins = "[admin]"` and `principal_domain = "open-metadata.org"`.
**Change it immediately** — see the warning below.

### Any environment — port-forward

Works with no load balancer and no public exposure:

```bash
kubectl port-forward -n openmetadata svc/openmetadata 8585:8585   # UI on :8585
```

Airflow (ingestion) is a separate release in the same namespace; confirm the
service name with `kubectl get svc -n openmetadata`, as it varies by chart
version.

### Exposure variables

| Variable | Default | Purpose |
|---|---|---|
| `app_expose_via_nlb` | `false` | Install the LB Controller and switch the Service to `LoadBalancer` |
| `app_lb_allowed_cidrs` | `[]` | CIDRs allowed to reach the NLB. **Required** when the toggle is on |
| `lb_controller_chart_version` | `null` | Controller chart version; `null` tracks latest |
| `app_extra_helm_values` | `{}` | Arbitrary Helm `set` overrides, merged over the NLB values |

Two validation rules fail the plan rather than let an unsafe config through:
an empty `app_lb_allowed_cidrs` while the toggle is on, and `0.0.0.0/0`
anywhere in the list.

`module "app"` is **shared by both environments**, so exposure has to be a
variable — hardcoding `service.type` would publish production on its next apply.
That's why the toggle defaults to `false` and only dev opts in.

Source ranges are applied as the controller annotation
`service.beta.kubernetes.io/load-balancer-source-ranges`, not
`service.loadBalancerSourceRanges`. The chart templates `service.annotations`
verbatim, so the annotation is guaranteed to reach the Service; relying on a
dedicated chart field that may not exist would silently leave the NLB open.
Enforcement needs a controller that manages NLB security groups (v2.6+).

> ⚠️ **The dev NLB serves plain HTTP.** Credentials — including that default
> admin password — cross the internet in the clear. It is IP-allowlisted, which
> limits exposure but does not encrypt anything. Acceptable for a throwaway dev
> stack; not acceptable for real data. See below.

### Known gaps

- **Allowlisted IPs drift.** The dev entries are dynamic ISP addresses. When
  access starts hanging with no useful error, re-check with `curl ifconfig.me`
  from the affected network and update the `/32`.
- **The controller chart version is unpinned.** Everything else in the repo is
  pinned; this one floats to latest on every fresh `init`. Pin it after the
  first successful apply:
  ```bash
  terraform state show 'helm_release.aws_load_balancer_controller[0]' | grep '^ *version'
  ```
- **No TLS, no DNS, no SSO** anywhere in the stack yet.

## Production exposure — what's still missing

Production deliberately has **no** UI exposure configured: its tfvars omit
`app_expose_via_nlb`, so the Service stays `ClusterIP` and the only access is
`kubectl port-forward`. Copying dev's NLB setup would put an unencrypted login
page on the internet, so production needs an ALB Ingress with TLS instead.

The AWS Load Balancer Controller installed by `lb_controller.tf` already serves
both NLB Services and ALB Ingresses, so it is reusable as-is. What's missing:

1. **A domain and a hosted zone.** A Route 53 public hosted zone for the name
   you'll serve (e.g. `openmetadata.example.com`). Not created by this repo.
2. **An ACM certificate** in the cluster's region, DNS-validated against that
   zone. `aws_acm_certificate` + `aws_acm_certificate_validation` +
   `aws_route53_record` for the validation CNAME. Terraform must wait on
   validation before the Ingress references the ARN.
3. **Ingress values on the chart**, replacing dev's Service annotations —
   `ingress.enabled`, `ingress.className: alb`, the host rule, and
   `alb.ingress.kubernetes.io/*` annotations for `scheme: internet-facing`,
   `target-type: ip`, `certificate-arn`, `listen-ports` (443), and an
   HTTP→HTTPS redirect action. These go through `app_extra_helm_values`, so no
   module change is required.
4. **A DNS record** — an `aws_route53_record` alias to the ALB, or
   `external-dns` in-cluster (the vendored iam v6 module has
   `attach_external_dns_policy`, so its IRSA role is a few lines).
5. **Authentication.** The chart's basic auth with a default admin is not
   adequate for production. OpenMetadata supports OIDC/SAML SSO; configure it
   through `openmetadata.config.authentication.*` and remove the default admin.
   Alternatively front the ALB with Cognito or an OIDC authenticate action.
6. **A tighter allowlist decision.** An ALB can use a security group or WAF
   rather than IP ranges, which is the point at which you stop maintaining
   `/32`s by hand.

Also worth revisiting for production, unrelated to exposure:
`enabled_cluster_log_types = []` disables EKS control-plane logging, and the
node group is the same 2 × `t3.xlarge` as dev.

## Configuration notes

- **Region** is set in three places that must agree: the `AWS_REGION` repository
  variable, `region` in the selected env tfvars, and the `region` default in
  `terraform/variables.tf`. All three are `us-east-1`. The tfvars value wins for
  CI; the default only applies to local runs with no var-file.
- **Pinning:** the OpenMetadata registry module is pinned to `1.12.13` in
  `terraform/main.tf`, and `app_version` in each env's tfvars pins the deployed
  application. Bump both together and `plan` first to review the diff.
- **Provider versions are not locked.** `.terraform.lock.hcl` is gitignored, so
  every CI run resolves the newest release matching the constraints in
  `terraform/versions.tf` (`aws ~> 6.0`, `helm ~> 3.0`, `kubernetes ~> 3.0`,
  `tls ~> 4.0`). To make runs reproducible, un-ignore the lock file and generate
  it for both platforms — `linux_amd64` is required or CI init fails checksum
  verification:
  ```bash
  terraform -chdir=terraform providers lock \
    -platform=linux_amd64 -platform=darwin_arm64
  ```
- **Production destroy is intentionally hard.** `production.auto.tfvars` keeps the
  module's protective RDS defaults (`deletion_protection=true`,
  `skip_final_snapshot=false`), which block `terraform destroy`. Use the **dev**
  environment for disposable stacks; to tear down production you must first flip
  those flags and apply, then destroy.
- **Not variable-controlled, but editable here.** The EKS node group
  (2–3 × `t3.xlarge`, `eks.tf`) and the VPC CIDR (`172.72.0.0/16`, `vpc.tf`) are
  hard-coded locals rather than variables, so dev and production share them.
  Because the config is vendored, you can now change them directly instead of
  patching upstream — but the value is shared across both environments.
- **EKS version and AMI move together.** `eks_version` must be under STANDARD
  support (`upgrade_policy { support_type = "STANDARD" }`) or `CreateCluster`
  fails outright; check with `aws eks describe-cluster-versions` before bumping.
  AL2 EKS-optimized AMIs stop at 1.32, so 1.33+ requires
  `ami_type = "AL2023_x86_64_STANDARD"`. Currently 1.36 / AL2023.
- **Subnets carry ELB discovery tags** (`kubernetes.io/role/elb` on public,
  `kubernetes.io/role/internal-elb` on private, plus the cluster tag). Applied
  unconditionally — they're inert until something requests a load balancer, and
  without them an internet-facing LB either fails to provision or lands in the
  private subnets and is unreachable. Note the cluster and node group run in
  **private subnets only**.

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

A `plan` from a clean state is clean — zero warnings, zero errors. If you
re-sync from a newer upstream release, expect to re-apply these.
