# bootstrap — GitHub OIDC + deploy role

One-time setup that creates the two things the deploy workflow needs to
authenticate to AWS without stored keys:

1. An **IAM OIDC identity provider** for `token.actions.githubusercontent.com`.
2. An **IAM role** (`openmetadata-infra-deploy`) whose trust policy is scoped to
   this repo: branch `main` for `plan`, and the `dev` + `production` environments
   for `apply`/`destroy`.

It also creates the **OpenSearch service-linked role** (on by default — the
deploy fails without it, see below), and can create the **remote state bucket**
(off by default). There is no lock table: the deploy workflow uses S3 native
locking.

Run it once, with credentials that can create IAM resources. Run locally it uses
**local state** — fine for a bootstrap; commit nothing sensitive. The
`openmetadata-bootstrap` workflow keeps state in S3 instead, so read
[Running it from Actions](#running-it-from-actions) before mixing the two.

```bash
cd openmetadata-infra/bootstrap
cp terraform.tfvars.example terraform.tfvars   # edit github_org, region, state_*
terraform init
terraform apply
```

Then wire the output into the repo:

```bash
gh secret set AWS_ROLE_ARN --body "$(terraform output -raw role_arn)"
```

## State bucket (optional)

The deploy workflow's S3 backend needs the state bucket to already exist — and
that's the only prerequisite. Locking is **S3-native** (`use_lockfile = true` in
`backend.tf`): Terraform takes the lock by writing a `<key>.tflock` object next
to the state using S3 conditional writes. No DynamoDB table, nothing extra to
create, and no separate IAM permissions.

Set the toggle to have this bootstrap own the bucket instead of creating it by
hand:

```hcl
state_bucket        = "your-org-tfstate"
create_state_bucket = true    # bucket: versioned, SSE, public access blocked
```

It defaults to **false**, so re-applying this bootstrap never collides with a
bucket you already made — Terraform cannot adopt a bucket it didn't create.

**One bucket serves every environment.** Each gets its own state key
(`<prefix>/<environment>/terraform.tfstate`), and therefore its own independent
lock object.

## OpenSearch service-linked role

A VPC OpenSearch domain cannot be created until the account has
`AWSServiceRoleForAmazonOpenSearchService`, which lets OpenSearch manage ENIs in
your VPC. Without it, `apply` fails partway through with:

```
Error: creating OpenSearch Domain (openmetadata-dev): ValidationException:
Before you can proceed, you must enable a service-linked role to give Amazon
OpenSearch Service permissions to access your VPC.
```

This bootstrap creates it by default. It's account-wide and shared by every
domain, which is why it belongs here rather than in the per-environment stack —
a `dev` destroy must not delete a role `production`'s domain still needs.

If the account already has it, set `create_opensearch_service_linked_role =
false`. Terraform cannot adopt an existing service-linked role, and creating a
duplicate fails with `InvalidInput: Service role name ... has been taken in this
account`. Check with:

```bash
aws iam get-role --role-name AWSServiceRoleForAmazonOpenSearchService
```

The equivalent one-off, if you'd rather not run this bootstrap:

```bash
aws iam create-service-linked-role \
  --aws-service-name opensearchservice.amazonaws.com
```

## Notes

- **Provider already exists?** Only one OIDC provider per account may use this
  URL. If GitHub Actions OIDC is already set up, run with
  `create_oidc_provider = false` to reference the existing one.
- **Thumbprint** is derived automatically from GitHub's live certificate (via the
  `tls_certificate` data source), so nothing is hardcoded.
- **Trust scope** defaults to `ref:refs/heads/main` plus one
  `environment:<name>` subject per entry in `environment_names`
  (`["dev","production"]`). Widen with `subject_claims = ["repo:ORG/REPO:*"]` if
  you dispatch `plan` from other branches; tighten by listing exact subjects.
- **Permissions** default to `PowerUserAccess` + `IAMFullAccess` (the stack
  creates IAM roles and KMS keys). Override `permissions_policy_arns` with a
  least-privilege policy for production use.

## Global Accelerator (optional)

`create_global_accelerator = true` allocates one AWS Global Accelerator per
entry in `environment_names`, named `<global_accelerator_name_prefix>-<env>`.
Each holds two static anycast IPv4 addresses that sit in front of that
environment's ALB.

It is here, rather than in the environment stack, for the same reason as the NAT
EIPs: the addresses have to outlive `terraform destroy`. The environment's UI is
published in an internal zone this account does not own, so repointing it is a
ticket rather than a command — and the ALB's hostname carries a hash AWS
reassigns whenever the load balancer is recreated. Held here, the addresses
survive the dev teardown loop and the external DNS record is written once.

Only the accelerator lives here. Its listener and endpoint group belong to the
environment stack (`terraform/global_accelerator.tf`), which finds this by name
through `app_accelerator_name`. Destroying an environment removes those two and
leaves the accelerator holding its addresses with nothing behind it — the
intended resting state.

```bash
terraform apply -var create_global_accelerator=true
terraform output accelerator_names        # -> set as app_accelerator_name
terraform output accelerator_static_ips   # -> the pair to publish in DNS
```

Then in the environment's tfvars:

```hcl
app_accelerator_name = "openmetadata-dev"
```

> ⚠️ ~$18/month per accelerator, billed whether or not that environment is
> currently deployed — that is the cost of holding the addresses. Setting this
> back to false, or destroying this bootstrap, releases them permanently; AWS
> does not hand the same pair back.

## Running it from Actions

`openmetadata-bootstrap` (Actions → *openmetadata-bootstrap*) runs this
directory with a checkbox per service, so adding one resource later does not
mean finding the machine that first applied it.

| Input | Provisions |
|---|---|
| `oidc_provider` | The GitHub OIDC identity provider |
| `state_bucket` | The Terraform state bucket |
| `opensearch_service_linked_role` | `AWSServiceRoleForAmazonOpenSearchService` |
| `nat_eips` | Stable NAT egress EIPs, one per environment |
| `global_accelerator` | One accelerator per environment, holding the static IPs |

`plan` is ungated. `apply` runs in the **bootstrap** GitHub Environment — it is
created automatically with no protection rules, so add reviewers under
Settings → Environments if account-wide changes should need approval.

### The selection is the whole desired state

Anything left unticked is passed as `create_* = false`, so a resource already in
state that is not ticked **plans as a delete**. Tick everything you want to
keep, not just the thing you are adding.

That is Terraform working correctly rather than a quirk — using `-target` to
paper over it would hide genuine drift — but the failure mode is expensive
enough that the plan job refuses to produce an appliable plan containing
deletions unless you set `allow_destroy` to the literal string `destroy`. It
catches replacements too, because a `delete+create` on an Elastic IP or an
accelerator loses those addresses just as permanently as a delete, and every
external DNS record and firewall allowlist pointing at them goes stale.

### One-time state migration

The workflow cannot use local state: a runner starts with an empty state file
and would try to **create resources that already exist**. Worse, an empty state
with `global_accelerator` ticked would quietly provision a *second* accelerator
with different addresses at ~$18/month.

So bootstrap state moves to the same bucket as the environments, under
`<TF_STATE_PREFIX>/bootstrap/terraform.tfstate`. If you have already applied
this directory by hand, migrate that state **once**, from the machine holding
it:

```bash
cd openmetadata-infra/bootstrap
cp ../backend.tf .                 # the same generic S3 backend block
terraform init -migrate-state \
  -backend-config="bucket=<TF_STATE_BUCKET>" \
  -backend-config="key=<TF_STATE_PREFIX>/bootstrap/terraform.tfstate" \
  -backend-config="region=<TF_STATE_REGION>" \
  -backend-config="encrypt=true"
rm backend.tf                      # not committed; the workflow injects it
```

You do not have to guess whether this is needed. The plan job fails with an
explicit message if the remote state is empty while the deploy role already
exists in the account — the only thing that combination can mean.

### Why the deploy role has no checkbox

`aws_iam_role.deploy` and its policy attachments are unconditional: the role is
what the workflow authenticates *as*, so it cannot be toggled off from a run
that depends on it. Creating it for the first time therefore stays a local
operation with elevated credentials. Everything else in the table above is
within the deploy role's own permissions (PowerUser + IAMFullAccess), which is
why those got checkboxes and this did not.
