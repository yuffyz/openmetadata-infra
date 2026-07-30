# bootstrap — GitHub OIDC + deploy role

One-time setup that creates the two things the deploy workflow needs to
authenticate to AWS without stored keys:

1. An **IAM OIDC identity provider** for `token.actions.githubusercontent.com`.
2. An **IAM role** (`openmetadata-infra-deploy`) whose trust policy is scoped to
   this repo: branch `main` for `plan`, and the `dev` + `production` environments
   for `apply`/`destroy`.

It can also create the **remote state bucket** — off by default, see below.
There is no lock table: the deploy workflow uses S3 native locking.

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
