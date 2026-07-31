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

Run it once, with credentials that can create IAM resources. It uses **local
state** — that's fine for a bootstrap; commit nothing sensitive.

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
state_bucket        = "dkc-tfstate"
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
