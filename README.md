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
OpenMetadata application deployed via Helm. A `plan` from a clean state is
**91 resources** for `dev` (`azs_to_use = 2`) and **99** with the variable
defaults (`azs_to_use = 3`) — the difference is two subnets and their route
table associations per extra AZ.

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

### 4. Approval gates (GitHub Environments)
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
