# openmetadata-infra

Wraps the upstream `open-metadata/openmetadata/aws` Terraform module (the same
module the "complete" example uses) and deploys it via GitHub Actions.

The workflow checks out that module at a pinned ref, injects a remote-state
backend and deployment `tfvars`, and runs Terraform. The example config is left
authoritative, this repo only adds CI/CD, state, and configuration.

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
OpenMetadata application deployed via Helm. Full list in the
[example README](https://github.com/open-metadata/terraform-aws-openmetadata/tree/main/examples/complete).

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
<repo root>/                            # e.g. kiban/
├─ .github/
│  ├─ actions/prepare/action.yml     # composite: checkout module, inject cfg, OIDC, init
│  └─ workflows/
│     ├─ deploy.yml                  # manual: environment × (plan / apply / destroy)
│     └─ validate.yml                # PR fmt + validate (no cloud creds)
└─ openmetadata-infra/               # this Terraform project (PROJECT_DIR)
   ├─ backend.tf                     # S3 backend block (values via -backend-config)
   ├─ bootstrap/                     # one-time: GitHub OIDC provider + deploy role
   └─ config/
      ├─ dev.auto.tfvars             # teardown-safe, cheaper, "-dev" names
      └─ production.auto.tfvars      # production-safe defaults
```

> The workflows live at the **repo root** `.github/` and reference this project
> via `PROJECT_DIR: openmetadata-infra`. To relocate/rename the project, update
> that one value (and `BACKEND_FILE`/`TFVARS_FILE`) in the workflows.

## One-time setup

### 1. State storage (in the target AWS account)
- An **S3 bucket** for Terraform state (versioning on).
- A **DynamoDB table** with primary key `LockID` (string) for state locking.

State is separated per environment automatically via the key
`<prefix>/<environment>/terraform.tfstate`, so one bucket + table serves both —
**including the lock table**, whose `LockID` is `<bucket>/<key>`. Don't create
one table per environment.

Either create them by hand, or let [`bootstrap/`](bootstrap/) own them with
`create_state_bucket = true` / `create_lock_table = true`.

> ⚠️ Both must exist before the workflow runs. `terraform init` only reads state
> from S3, so a **missing lock table isn't caught at init** — it fails later, on
> the first command that takes a lock, with `Error acquiring the state lock …
> ResourceNotFoundException`.

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
| `TF_STATE_REGION` | `us-east-1` | Region of the bucket/lock table |
| `TF_STATE_LOCK_TABLE` | `terraform-locks` | DynamoDB lock table |
| `TF_STATE_PREFIX` | `openmetadata` | *(optional)* state key prefix; the environment + `terraform.tfstate` are appended. Defaults to `openmetadata` |
| `MODULE_REF` | `1.12.13` | *(optional)* module tag/branch/sha to deploy; defaults to `1.12.13` |

> The state **key** is derived (`<prefix>/<environment>/terraform.tfstate`) —
> there is no `TF_STATE_KEY` variable anymore.

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

## Configuration notes

- **Region** is set in two places that must agree: the `AWS_REGION` variable and
  `region` in the selected env tfvars.
- **Pinning:** the module ref defaults to `1.12.13`. Bump `MODULE_REF` to upgrade
  (e.g. `1.13.1`); `plan` first to review the diff.
- **Production destroy is intentionally hard.** `production.auto.tfvars` keeps the
  module's protective RDS defaults (`deletion_protection=true`,
  `skip_final_snapshot=false`), which block `terraform destroy`. Use the **dev**
  environment for disposable stacks; to tear down production you must first flip
  those flags and apply, then destroy.
- **Not variable-controlled:** the EKS node group (2 × `t3.xlarge`) and the VPC
  CIDR are hard-coded in the upstream example, so dev and production use the same
  node size. Adjust the upstream example if you need smaller dev nodes.
- **Upstream example patches (workaround).** Before `init`, the `prepare` action
  (and `validate.yml`) patch two inconsistencies in the pinned `examples/complete`
  — both present through at least `1.13.1`:
  1. `ebs_csi_irsa` / `efs_csi_irsa` reference
     `terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks`
     with **no version**, so `init` resolves iam **v6**, where that submodule was
     removed → *"Unreadable module subdirectory."* We inject `version = "~> 5.0"`
     (its submodule only needs aws `>= 4.0`, so it stays v6-compatible).
  2. The example's `versions.tf` pins **aws `~> 5.0`**, but the OpenMetadata
     module itself requires **aws `~> 6.0`** (its root and `rds` `versions.tf`),
     so provider resolution fails with *"no available releases match … ~> 5.0 …
     ~> 6.0."* We bump the example provider to `~> 6.0`.
  3. `helm` / `kubernetes` providers are **unpinned**, and the example and the
     module target *different helm majors*:
     - The module's `openmetadata-deployment` / `openmetadata-dependencies`
       submodules write `set = [{ name, value }]` — **helm v3** syntax. Under
       helm v2, where `set` is a repeatable block, validate fails with
       *"An argument named 'set' is not expected here."*
     - The example's `provider "helm"` uses a `kubernetes {}` **block** — helm
       v2 syntax. Under helm v3, where it became a nested attribute, it fails
       with *"Blocks of type 'kubernetes' are not expected here."*

     The submodules come from the registry and can't be edited pre-`init`, so we
     pin **helm `~> 3.0`** (matching the module) and rewrite the example's
     provider config to the v3 form (`kubernetes = { … exec = { … } }`).
     `kubernetes` stays `~> 2.0` — its own provider block is v2 syntax.
     The pins are injected into the example's existing `required_providers`
     block in `versions.tf` (a module may have only one such block, so a
     separate file would fail with *"Duplicate required providers
     configuration."*).

  Remove these patch steps once `MODULE_REF` points at an upstream release whose
  example is self-consistent (pins the CSI modules, targets aws v6, and pins the
  helm/kubernetes providers).
