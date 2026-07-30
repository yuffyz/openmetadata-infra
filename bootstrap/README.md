# bootstrap — GitHub OIDC + deploy role

One-time setup that creates the two things the deploy workflow needs to
authenticate to AWS without stored keys:

1. An **IAM OIDC identity provider** for `token.actions.githubusercontent.com`.
2. An **IAM role** (`openmetadata-infra-deploy`) whose trust policy is scoped to
   this repo: branch `main` for `plan`, and the `dev` + `production` environments
   for `apply`/`destroy`.

It can also create the **remote state backend** (S3 bucket + DynamoDB lock
table) — off by default, see below.

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

## State backend (optional)

The deploy workflow's S3 backend needs the state bucket **and** the DynamoDB
lock table to already exist. A missing lock table is easy to miss because
`terraform init` doesn't touch DynamoDB — it only reads state from S3. The
failure appears later, on the first command that takes a lock:

```
Error: Error acquiring the state lock
ResourceNotFoundException: Requested resource not found
```

Set either toggle to have this bootstrap own them instead of creating them by
hand:

```hcl
state_bucket        = "dkc-tfstate"
lock_table          = "terraform-locks"
create_state_bucket = true    # bucket: versioned, SSE, public access blocked
create_lock_table   = true    # table: PAY_PER_REQUEST, hash key LockID (S)
```

Both default to **false**, so re-applying this bootstrap never collides with
resources you already made — Terraform cannot adopt a bucket or table it didn't
create. Turn on only the one that's missing.

**One table serves every environment.** The S3 backend's `LockID` is
`<bucket>/<key>`, and each environment already gets its own key
(`<prefix>/<environment>/terraform.tfstate`). A per-environment lock table (e.g.
a `-dev` suffixed one) buys nothing and is easy to get half-configured.

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
