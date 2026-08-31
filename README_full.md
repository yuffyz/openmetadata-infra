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

A `plan` from a clean state is **98 resources** for `dev` as configured: 91 for
the base stack, 3 core EKS addons (`vpc-cni`, `kube-proxy`, `coredns`), and 4 for
the AWS Load Balancer Controller and its IRSA role, which `dev.auto.tfvars`
enables (see [Accessing the UI](#accessing-the-ui)). Adding
`app_tls_domain_name` brings in about 5 more — certificate, validation, the
alias record and the provisioning wait.

With the variable defaults and no NLB it's higher again on subnets, because
`azs_to_use` defaults to 3 rather than dev's 2 — a subnet and route table
association per extra AZ.

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
| UI access | internet-facing NLB, IP-allowlisted; HTTPS available via `app_tls_domain_name` | **not configured** — `ClusterIP` + port-forward only |

The `-dev` naming lets a dev stack coexist with production **in the same
account/region** without RDS/OpenSearch/EKS name collisions.

## Layout

```
openmetadata-infra/                     # repo root
├─ .github/
│  ├─ actions/prepare/action.yml     # composite: inject cfg, OIDC, pre-flight, init
│  └─ workflows/
│     ├─ deploy.yml                  # manual: environment × (plan / apply / destroy)
│     ├─ openmetadata-ops.yml        # manual: diagnose / restart / search-index repair
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

> With `app_expose_via_nlb = true`, delete the LoadBalancer Service **before**
> dispatching destroy — see [Destroying](#destroying--clean-up-the-load-balancer-first).
> Skipping it costs a 20-minute timeout and a manual cleanup.

### Locally

```bash
cd terraform
terraform init                                  # local state, no backend.tf present
terraform plan -var-file=../config/dev.auto.tfvars
```

Without a `-var-file` the variable defaults apply, including
`region = "us-east-1"`.

## Destroying — clean up the load balancer first

**The NLB is not a Terraform resource.** The AWS Load Balancer Controller creates
it by reconciling the Service annotations, so Terraform can neither delete it nor
wait for it. Delete the Service *while the controller is still running* and it
tidies up after itself. Destroy a broken cluster and the load balancer is
stranded — and because its ENIs hold public IPs in the public subnets, the
subnets and internet gateway then refuse to delete:

```
Error: deleting EC2 Internet Gateway (igw-…): DependencyViolation:
  Network vpc-… has some mapped public address(es). Please unmap those
  public address(es) before detaching the gateway.
Error: deleting EC2 Subnet (subnet-…): DependencyViolation:
  The subnet 'subnet-…' has dependencies and cannot be deleted.
Error: context deadline exceeded
```

Those appear only after the provider's **20-minute** delete timeout expires, so
the run wastes 20 minutes before telling you. Note the private subnets delete
fine — only the public ones are held, which is the signature of an
internet-facing load balancer.

This only bites when `app_expose_via_nlb = true`. With the default `false` there
is no load balancer and destroy is unremarkable.

### The graceful path (cluster still healthy)

Run this before dispatching `destroy`:

```bash
aws --region us-east-1 eks update-kubeconfig --name open-metadata-dev

kubectl delete svc -n openmetadata openmetadata      # controller deletes the NLB
kubectl get svc -A --field-selector spec.type=LoadBalancer   # expect none

# confirm it is really gone before proceeding
aws elbv2 describe-load-balancers --region us-east-1 \
  --query "LoadBalancers[?VpcId=='<vpc-id>'].LoadBalancerName" --output text
```

Give the controller 30–60 seconds; the ENIs disappear a little after the load
balancer does.

### The recovery path (cluster unhealthy or already gone)

If the node group never became `ACTIVE`, no controller pod ever ran, so nothing
reconciled the deletion and the graceful path is unavailable. Clean up in AWS
directly, then re-run `destroy` — it is idempotent and picks up where it stopped.

```bash
VPC=<vpc-id>              # from the DependencyViolation error
R="--region us-east-1"

# what is holding the subnets
aws elbv2 describe-load-balancers $R \
  --query "LoadBalancers[?VpcId=='$VPC'].[LoadBalancerName,Scheme,LoadBalancerArn]" --output table
aws elb describe-load-balancers $R \
  --query "LoadBalancerDescriptions[?VPCId=='$VPC'].LoadBalancerName" --output text
aws ec2 describe-network-interfaces $R --filters Name=vpc-id,Values=$VPC \
  --query 'NetworkInterfaces[].[NetworkInterfaceId,Status,SubnetId,Description,Association.PublicIp]' \
  --output table

# remove it
aws elbv2 delete-load-balancer $R --load-balancer-arn <arn>
aws ec2 release-address $R --allocation-id <id>              # orphaned EIPs
aws ec2 delete-network-interface $R --network-interface-id <eni>   # only if Status=available

# controller-created security groups also block VPC deletion
aws ec2 describe-security-groups $R --filters Name=vpc-id,Values=$VPC \
  --query 'SecurityGroups[?GroupName!=`default`].[GroupId,GroupName]' --output table
```

### Other things that strand a destroy

- **Kubernetes/Helm resources in state after the cluster is gone.** The
  `kubernetes` and `helm` providers are configured from the cluster endpoint, so
  once it is destroyed they fail with `dial tcp 127.0.0.1:80: connect: connection
  refused` or `Unauthorized`. Those objects died with the cluster — drop them
  from state:
  ```bash
  terraform state list | grep -E '^kubernetes_|helm_release' | xargs -n1 terraform state rm
  ```
- **A namespace stuck `Terminating`.** Two ways this shows up: a later apply
  fails with `unable to create new content in namespace openmetadata because it
  is being terminated`, or the destroy itself hangs on
  `kubernetes_namespace_v1.app: Still destroying...` and gives up with
  `Error: context deadline exceeded`.

  The usual cause during teardown is that **the node group is already gone while
  the cluster remains**. Namespace termination needs controllers to release
  finalizers on the objects inside it — with no nodes there is no CSI controller
  to clear `kubernetes.io/pvc-protection` on the Airflow PVCs, and no pod behind
  any admission webhook the deletion must pass through. It can never complete.

  The namespace is inside the cluster you are deleting anyway, so the quickest
  correct move is to stop tracking it and let the cluster removal take it:
  ```bash
  terraform state rm kubernetes_namespace_v1.app
  ```
  To unstick it properly instead, inspect
  `kubectl get ns openmetadata -o jsonpath='{.status}'`, clear PVC finalizers,
  or force-finalize via `/api/v1/namespaces/openmetadata/finalize`.

  Either way, check afterwards for volumes and EFS access points that
  Kubernetes provisioned and Terraform never knew about:
  ```bash
  aws ec2 describe-volumes --region us-east-1 --filters Name=status,Values=available \
    --query 'Volumes[].[VolumeId,Size,Tags[?Key==`kubernetes.io/created-for/pvc/name`].Value|[0]]' --output table
  ```
- **A Helm release live in the cluster but absent from state** fails apply with
  `cannot re-use a name that is still in use`. Either
  `helm -n kube-system uninstall <name>` or `terraform import` it.
- **EFS mount targets** occasionally linger and produce the same
  `DependencyViolation` on a private subnet.

### Stale state lock

A killed or cancelled run can leave the S3 lock object behind, and the next run
fails with `Error acquiring the state lock … PreconditionFailed`. The error
prints the lock ID and the operation that took it. With no run in flight:

```bash
terraform force-unlock <lock-id>
```

Check whether the holder is actually still running first — `Operation` and
`Created` in the error tell you.

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
Balancer Controller and creates a second Service, `openmetadata-public`, of type
`LoadBalancer` (`terraform/nlb_service.tf`):

```bash
kubectl get svc -n openmetadata openmetadata-public \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Then `http://<hostname>:8585` without TLS, or `https://<domain>` with it. Either
way the pods are reached on 8585.

The chart's own Service is left as `ClusterIP` on 8585 and is not touched. An
NLB listener port always equals the Service port, so serving 443 by moving the
chart's Service would also move the cluster-internal address — and that address
is baked into things that outlive an apply: the module hardcodes
`metadataApiEndpoint: http://openmetadata.<ns>.svc:8585/api`, and every
ingestion pipeline already deployed carries the host:port it was created with,
inside its Airflow DAG configuration. Owning a separate Service decouples the
public listener from all of that.

Allow a couple of minutes after apply — Terraform returns when the Helm release
succeeds (the module sets `wait = false`), and the Service resource then blocks
until the controller reports a hostname, which is briefly unresolvable
afterwards.

Cross-zone load balancing is switched on explicitly
(`load_balancing.cross_zone.enabled=true`). An NLB has it **off** by default and
gets one node per subnet, so with a single OpenMetadata replica every node
outside the pod's AZ has nothing to forward to. Clients that resolve to one of
those nodes hang with no SYN-ACK, and which clients those are changes with each
DNS lookup and each time the pod reschedules — the failure reads as "the UI
works for some people and not others". Cross-AZ traffic is billed, which at one
replica is cents.

The hostname is also readable without cluster access, which is often quicker:

```bash
aws elbv2 describe-load-balancers --region us-east-1 \
  --query "LoadBalancers[?Type=='network'&&Scheme=='internet-facing'].DNSName" --output text
```

`terraform output openmetadata_url` prints the right URL — or the right command
to find it — for whichever exposure mode is configured.

Initial login is `admin@open-metadata.org` / `admin`, from the module's
`initial_admins = "[admin]"` and `principal_domain = "open-metadata.org"`.
**Change it over `port-forward`, not over the NLB** — until TLS is configured
that password would otherwise cross the internet in cleartext, starting with
the well-known default.

### dev — HTTPS on the NLB

Set both variables in `config/dev.auto.tfvars` and TLS terminates on the NLB
listener with an ACM certificate:

```hcl
app_tls_domain_name       = "openmetadata.example.com"
app_tls_route53_zone_name = "example.com"
```

The URL becomes `https://openmetadata.example.com` — with a certificate
attached, `openmetadata-public` listens on 443 as well as 8585. What Terraform
creates (`terraform/nlb_tls.tf`), all conditional on those variables:

| Resource | Purpose |
|---|---|
| `aws_acm_certificate` | DNS-validated cert for the FQDN |
| `aws_route53_record.app_cert_validation` | Validation CNAMEs, `allow_overwrite` for cert rotation |
| `aws_acm_certificate_validation` | Blocks until ACM reports ISSUED |
| `data.aws_lb` | Reads the NLB back by the controller's resource tags |
| `aws_route53_record.app` | Alias A record → NLB |

The certificate reaches the NLB as the
`service.beta.kubernetes.io/aws-load-balancer-ssl-cert` annotation on
`openmetadata-public`, paired with `ssl-ports` listing the Service's port names
(the controller matches either a name or a number). It references the
**validation** resource, not the certificate, so the Service never carries an
unissued ARN.

Three things to know before enabling it:

- **443 is what makes this usable from a corporate network.** Clients behind a
  forward proxy — Netskope, Zscaler — reach the origin through the proxy, and
  those proxies steer 443 and 80 only. A non-standard port is typically not
  proxied at all, so the request hangs with no error rather than failing fast.
  Such a client also arrives from the *proxy's* egress address, so
  `app_lb_allowed_cidrs` has to hold the vendor's published ranges, and the
  certificate the user's browser validates is the proxy's, not this one.
- **Only the listeners differ.** `targetPort` stays the pod's `http` port, so
  targets, health checks, and the backend security group rules the controller
  manages are all still on 8585 — as is the chart's own ClusterIP Service,
  which is what the cluster talks to.
- **Failures surface on the Service, not the lookup.** `kubernetes_service_v1`
  waits up to 10 minutes for the controller to report a hostname and prints the
  Service's warning events if it doesn't, so a controller problem reads as a
  controller problem instead of a missing load balancer later on.

The hosted zone must already exist and be **public** — this repo does not create
it, and DNS validation needs it to be authoritative for the domain.

### A domain outside Route 53 — internal-only zones

`app_tls_domain_name` + `app_tls_route53_zone_name` only work for a **public
Route 53 hosted zone in this account**: `nlb_tls.tf` looks the zone up with a
data source and ACM proves ownership by publishing a validation record into it.
For a zone held elsewhere — an internal `ffdb.com`, say — that path cannot be
used at all.

The blocker is not Route 53, it is ACM. **A public certificate can never be
issued for an internal-only name**, because ACM validates by resolving a record
from the public internet, and a name that resolves nowhere public never
validates. Email validation does not help either.

So bring your own certificate. Import one from your corporate PKI — which
clients on the internal network already trust — and point
`app_tls_certificate_arn` at it:

```bash
aws acm import-certificate --region us-east-1 \
  --certificate       fileb://cert.pem \
  --private-key       fileb://key.pem \
  --certificate-chain fileb://chain.pem
```

```hcl
app_tls_domain_name     = "openmetadata.ffdb.com"   # served FQDN, for the URL output
app_tls_certificate_arn = "arn:aws:acm:us-east-1:<acct>:certificate/<id>"
app_lb_scheme           = "internal"
app_lb_allowed_cidrs    = ["10.0.0.0/8"]            # internal ranges, not workstation /32s

# Stable target for the record you publish in the internal zone. Without these
# the only thing to point at is the NLB hostname, which changes on rebuild.
app_tls_route53_zone_name = "example.com"
app_dns_alias_name        = "openmetadata.example.com"
```

Setting a certificate ARN switches off certificate issuance, DNS validation and
the alias record for `app_tls_domain_name` — that name lives in a zone this
account does not own, so publishing it is yours. `local.app_cert_managed` is the
flag that gates those, and `terraform output app_dns_managed` reports `false` so
the split is visible without reading the code.

It does **not** switch off DNS entirely. `app_tls_route53_zone_name` stays
useful here: combined with `app_dns_alias_name` it publishes a stable record, in
a zone you do own, that Terraform keeps pointed at the current load balancer.
That is gated separately by `local.app_dns_alias_managed`, precisely because it
has nothing to do with which certificate is in use. Leave the zone empty only if
you have no Route 53 zone at all.

Then publish the record yourself — but **point it at `app_dns_alias_name`, not
at the load balancer**:

```hcl
app_tls_route53_zone_name = "example.com"                    # a zone this account owns
app_dns_alias_name        = "openmetadata.example.com"       # stable, Terraform-managed
```

```
openmetadata.ffdb.com.   CNAME  openmetadata.example.com.    # written once, by you
openmetadata.example.com. ALIAS <current NLB>.elb.amazonaws.com.   # rewritten every apply
```

The reason for the extra hop is that the load balancer's hostname is **not
stable**. It is `<name>-<hash>.elb.<region>.amazonaws.com`, and AWS assigns that
hash per load balancer at creation — so anything that recreates it produces a
new hostname and breaks every record pointing at the old one. The
`aws-load-balancer-name` annotation does not help: it fixes the *name*, not the
hash. Pointing your zone straight at the ELB hostname means repointing it by
hand after every rebuild, with the UI down until someone notices.

`app_dns_alias_name` gives you a name in a zone this account controls that
Terraform repoints on every apply. Your record targets that instead, and is
written once. `terraform output app_dns_alias_fqdn` prints it.

This is independent of who issues the certificate — it works with an imported
`app_tls_certificate_arn`, which is the case it exists for. TLS is unaffected:
the client sends the external name in SNI no matter how many CNAMEs it follows,
so the NLB still answers with the certificate for that name.

If you have no Route 53 zone at all, point your record at the ELB hostname as
before — a **CNAME, not an A record**, since an NLB's addresses change if it is
replaced, and an internal NLB's AWS hostname resolves through *public* DNS to
its *private* addresses. Accept that it needs repointing after any replacement.

Three things to plan for:

- **`app_lb_scheme = "internal"` REPLACES the load balancer.** Scheme is one of
  the two changes the controller treats as requiring replacement
  (`isSDKLoadBalancerRequiresReplacement`), so the hostname changes and the UI
  is unreachable until DNS is repointed. Budget a short outage.
- **Clients need a route into the VPC** — VPN, Direct Connect or Transit
  Gateway. An internal NLB has no public address, so allowlisting alone is not
  enough to make it reachable.
- **Imported certificates do not auto-renew.** Re-import before expiry with
  `--certificate-arn <existing arn>`; the ARN stays stable, the listener keeps
  working, and no Terraform change is needed. Nothing here will warn you, so
  put the expiry in a calendar.

Migrating an existing environment onto this path moves the old certificate and
alias record from managed to unmanaged, so **`plan` will show
`aws_route53_record.app` and `aws_acm_certificate.app` being destroyed.** That is
correct when migrating — but read it, rather than approving past it.

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
| `app_tls_domain_name` | `""` | FQDN to serve over HTTPS. Empty leaves the NLB on plain HTTP |
| `app_tls_route53_zone_name` | `""` | Public Route 53 zone owning that FQDN. Required with the above **unless** `app_tls_certificate_arn` is set |
| `app_tls_certificate_arn` | `""` | Existing ACM certificate to terminate with, for a domain outside Route 53. Skips issuance, validation and the record for `app_tls_domain_name` |
| `app_dns_alias_name` | `""` | FQDN in `app_tls_route53_zone_name` that Terraform repoints at the current NLB every apply. Give externally-managed DNS this as a target so it survives the load balancer being recreated |
| `app_lb_scheme` | `"internet-facing"` | `internal` gives the NLB private addresses. **Changing it replaces the load balancer** |
| `lb_controller_chart_version` | `null` | Controller chart version; `null` tracks latest |
| `app_extra_helm_values` | `{}` | Arbitrary Helm `set` overrides, merged last |

Validation rules fail the plan rather than let a broken or unsafe config
through: an empty `app_lb_allowed_cidrs` while the NLB toggle is on, `0.0.0.0/0`
anywhere in that list, an entry that is not CIDR notation, a TLS domain or
certificate ARN without `app_expose_via_nlb`, a TLS domain with neither a hosted
zone nor a certificate ARN, a certificate ARN that is not an ACM ARN, and a
scheme that is neither `internet-facing` nor `internal`.

`module "app"` is **shared by both environments**, so exposure has to be a
variable — hardcoding `service.type` would publish production on its next apply.
That's why the toggle defaults to `false` and only dev opts in.

Source ranges are applied as `spec.loadBalancerSourceRanges` on the Service in
`nlb_service.tf` — the native field, which the controller reads first and turns
into the NLB's security group rules. (An earlier revision used the
`service.beta.kubernetes.io/load-balancer-source-ranges` annotation because the
values went through the chart; owning the Service outright removed that
constraint.) Enforcement needs a controller that manages NLB security groups
(v2.6+).

> ⚠️ **Without `app_tls_domain_name`, the NLB serves plain HTTP.** Credentials —
> including that default admin password — cross the internet in the clear.
> IP-allowlisting limits *who can connect*; it encrypts nothing, and browsers
> correctly flag the login page as "Not secure". Configure TLS above, or use
> `port-forward`, before typing a password you care about.

### If the NLB hostname changes on every apply

Fixed, but worth recognising if it ever returns. The symptom is a new
`*.elb.amazonaws.com` hostname after an apply that changed nothing relevant,
plus a few minutes of downtime while the replacement's targets pass health
checks. In a plan it looks like this, on `kubernetes_service_v1.app_public`:

```
- load_balancer_class = "service.k8s.aws/nlb" -> null # forces replacement
```

The `aws-load-balancer-type: external` annotation makes the controller's
mutating webhook stamp `spec.loadBalancerClass` onto the Service at admission.
If the Terraform config does not also declare it, every plan sees a field in
state that is absent from config and moves to remove it — and `loadBalancerClass`
is immutable, so removing it means replacing the Service. The controller then
deletes the load balancer along with it, and AWS hashes a new hostname for the
replacement.

`nlb_service.tf` declares `load_balancer_class` explicitly so config matches
what the webhook writes. Any controller-set immutable field left out of the
config produces the same loop.

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
- **Authentication is still the chart default** — a single `admin` account with a
  well-known password. TLS protects the transport, not the auth model. SSO is the
  remaining gap for any real use.
- **No TLS on internal hops.** NLB→pod traffic is plain TCP inside the VPC, and
  the OpenSearch/RDS connections use the module's defaults.

## Production exposure — what's still missing

Production deliberately has **no** UI exposure configured: its tfvars omit
`app_expose_via_nlb`, so the Service stays `ClusterIP` and the only access is
`kubectl port-forward`. Nothing stops you enabling the NLB + TLS variables there
— they are per-environment — and for an internal tool behind a tight allowlist
that may be enough. What it still doesn't give you:

1. **HTTP→HTTPS redirect.** The NLB serves 443, but it cannot redirect plain
   HTTP to HTTPS — port 80 is not served at all, so a user who types the bare
   hostname gets a connection refused. An ALB Ingress does the redirect in a
   listener rule.
2. **Authentication.** The chart's default is a single `admin` account with a
   well-known password. This is the significant gap — TLS protects the transport,
   not the auth model. OpenMetadata supports OIDC/SAML via
   `openmetadata.config.authentication.*`; configure it and remove the default
   admin. An ALB can also carry a Cognito or OIDC authenticate action, putting
   login in front of the app entirely.
3. **WAF and managed rules.** Attachable to an ALB, not to an NLB. This is also
   where you stop maintaining `/32`s by hand — the dev allowlist is two dynamic
   ISP addresses and will keep drifting.
4. **Layer-7 anything** — path routing, header rules, request logging to S3,
   per-route timeouts. An NLB is TCP only.

Moving to an ALB Ingress reuses most of what's already here. The AWS Load
Balancer Controller in `lb_controller.tf` serves Ingresses as well as Services,
and the ACM certificate plus Route 53 alias in `nlb_tls.tf` transfer directly.
The change is swapping the Service annotations for chart Ingress values —
`ingress.enabled`, `ingress.className: alb`, the host rule, and
`alb.ingress.kubernetes.io/*` for `scheme`, `target-type: ip`,
`certificate-arn`, `listen-ports` and the redirect action — all of which fit
through `app_extra_helm_values` with no module change. The alias record would
then point at the ALB instead of the NLB.

Two further considerations for production specifically:

- **Certificate scope.** One cert per FQDN today. A wildcard (`*.example.com`)
  or SANs would cover Airflow and any future subdomain in one certificate.
- **DNS ownership.** The alias record is created by reading the load balancer
  back after the fact, which needs the 240s wait described above. `external-dns`
  in-cluster removes that race and self-heals if the LB is replaced; the vendored
  iam v6 module has `attach_external_dns_policy`, so its IRSA role is a few
  lines.

Also worth revisiting for production, unrelated to exposure:
`enabled_cluster_log_types = []` disables EKS control-plane logging, and the
node group is the same 2 × `t3.xlarge` as dev.

## Search index — when Explore is empty

The **Explore** page reads exclusively from the OpenSearch index, never from the
application database. Nothing else in OpenMetadata does. So when the search sink
cannot write, ingestion still reports success, the entities are genuinely
present and reachable by API and by direct URL, and Explore is blank. The failure
is silent in every place you would naturally look:

- The ingestion pipeline is green — it writes to the database, and indexing is a
  separate, asynchronous path.
- The **Airflow task log shows nothing.** Sink errors live in the OpenMetadata
  **server** log, which that log never touches.
- `terraform plan` is clean, for the reason in the next section.

The symptom to recognise: **Search Indexing fails for every entity type at once**
— `table`, `tag`, `classification`, `domain`, `ingestionPipeline`,
`webAnalyticUserActivityReportData` — all with the same error. A fault affecting
every entity kind equally is never about the entities; it is the transport.

```
os.org.opensearch.client.transport.TransportException: Unauthorized access
```

### The recurring cause: OpenSearch master password drift

`modules/opensearch/main.tf` generates the domain's FGAC master password with
`random_password` and writes it to **two** places: the domain's
`master_user_options`, and the `opensearch-credentials` Kubernetes secret that
the server reads.

AWS never returns `master_user_password` from any API. Terraform therefore
**cannot detect drift on it** — if the domain's copy stops matching the secret,
a `plan` stays clean forever while every single search request is rejected with
`401`. The server and the secret agree with each other; only the domain
disagrees, and nothing reports it.

Anything that regenerates `random_password` — state rebuilt, resource replaced,
`terraform state rm` — updates the secret and the state, but leaves the live
domain on the old password unless the domain update also lands.

### Diagnosing it

Use the `openmetadata-ops` workflow rather than local `kubectl`: cluster-admin
belongs to the GitHub OIDC role that created the cluster (see *Get cluster access
first*), so CI needs no EKS access entry, and no individual has to win the
access-entry fight to run any of this.

| Action | Mutates | What it answers |
|---|---|---|
| `diagnose` | no | Pod password vs secret (by hash), stored password *shape*, domain health, node/AZ availability, `MasterUserName`, `UpdateVersion`, recent server-side search errors |
| `test-search-write` | throwaway index | Can the credentials read **and write**? Cluster health, node list, index list with `docs.count`, FGAC roles in effect |
| `restart-server` | rollout | For the stale-pod case: secret rolled, running pod still holds the old value |
| `reset-opensearch-password` | domain | Sets the domain master password to the secret's value. **Often a no-op — see below** |
| `rotate-opensearch-password` | domain + secret + rollout | Sets a *new* password on both sides and verifies the change actually landed. This is the one that works |
| `reduce-replicas` | index settings, dev only | Drops `number_of_replicas` to 0 on non-system indices |

Read `test-search-write` by **which kind of failure** you get. The distinction
that matters is *rejected* versus *overwhelmed*:

| Result | Meaning |
|---|---|
| `401` on everything | Credentials rejected. Password drift → `rotate-opensearch-password` |
| `403` on writes, `200` on reads | Authenticated, not authorised. Check `_plugins/_security/api/account`; the master user should show `all_access` |
| `HTTP 000` / `504`, mixed with successes | **Timeouts, not refusals.** The cluster is overwhelmed — see *When the cluster is overwhelmed* |
| `HTTP 000` on everything, instantly | Never connected. Malformed endpoint (the quoting trap below) or a security group |
| `cluster_block_exception` / `read_only_allow_delete` | Flood-stage disk watermark, not auth. Raise `volume_size` |
| `200`s, indices present, `docs.count` 0 | Connection fine, index never populated. Re-run Search Indexing |
| `404` on a `DELETE` of a nonexistent index | **Success.** A 404 is an authenticated answer |

A distinct failure with the same outward symptom: the chart embeds the password
into `openmetadata.yaml` **at container start**, so an apply that rolls the
password updates the secret while the running pod keeps the old one in memory.
`diagnose` catches this by comparing hashes and warns; the fix is
`restart-server`, not a password change.

### Runbook

1. `diagnose` — read-only. May end it immediately: a stale pod needs only
   `restart-server`.
2. `test-search-write` — classify the failure with the table above.
3. Repair: `rotate-opensearch-password` for `401`; `reduce-replicas` plus
   right-sizing for timeouts.
4. `test-search-write` again — confirm `200`s and check `table_search_index`
   has a non-zero `docs.count`.
5. Only once the cluster is **green**: **Settings → Applications → Search
   Indexing → Configure**, *Recreate Index* = true, all entity types, **Run**.

Re-ingestion is never part of this. The entities are already in the application
database; only the index was missing.

### Fixing password drift — and why `reset` is not enough

`reset-opensearch-password` sends the secret's existing value to the domain.
**AWS frequently accepts that call and applies nothing**, returning what looks
exactly like success:

```json
{ "State": "Active", "UpdateDate": "2026-08-04T03:56:20", "UpdateVersion": 10 }
```

`State` never becomes `Processing` and `UpdateDate` is whenever the domain was
last genuinely changed. There is no error, and the CLI exit code is 0. The only
way to tell is to compare `AdvancedSecurityOptions.Status.UpdateVersion` before
and after.

`rotate-opensearch-password` exists because of this. It generates a **new**
password — which AWS cannot treat as unchanged — asserts that `UpdateVersion`
incremented, waits for `Processing=False`, patches the secret only after the
domain has taken the value, and then restarts the server so it reloads. If
`UpdateVersion` still does not move, the AWS API cannot set this domain's master
password and the step tells you to reset it from OpenSearch Dashboards
(*Security → Internal users → admin*).

Its generated password satisfies AWS complexity **and** the module's YAML-safety
constraints: uppercase first character, specials limited to `_ - .` so it
survives being embedded in `openmetadata.yaml`.

Two things that look wrong in the output but are not:

- `MasterUserName: None` from `describe-domain-config` — AWS redacts it. It does
  not mean the master user is unset.
- Rotation **diverges from Terraform state**, which still holds the old
  `random_password`. The next `apply` pushes the state value back to both the
  domain and the secret, which reconverges them — but if a state operation is
  what broke them originally, watch that apply.

### When the cluster is overwhelmed instead

Once authentication is fixed, the next wall is capacity, and it presents very
differently: **timeouts rather than refusals** — `HTTP 000` and `504` mixed with
successes, and slow endpoints (`_cluster/health`, `_cat/indices`) failing while
trivial ones answer instantly.

OpenMetadata 1.12 creates roughly **45 indices at 5 primaries + 1 replica each**,
around **757 shards**. A `t3.small.search` node has ~2 GiB RAM, so ~1 GiB heap,
and the working guideline is **20–25 shards per GiB** — about 25 shards. That is
some thirty times oversubscribed, and it is enough to knock a data node out:

```
AvailabilityZoneName: us-east-1b
ZoneStatus:           NotAvailable
AvailableDataNodeCount: 0
```

```
status yellow  node.total 1  shards 391  unassign 366  active_shards_percent 51.7%
```

With one node gone, every replica is unassignable. Note what is *not* the
problem: `disk.used` was 32.7 MB of 9.6 GB. This is heap and shard overhead, not
storage — raising `volume_size` does nothing for it.

Two fixes, and dev wants both:

1. **`reduce-replicas`** — sets `number_of_replicas: 0` on non-system indices.
   Clears every unassigned shard at once and halves the shard load. Safe in dev
   because these indices are *derived*: Search Indexing rebuilds them from the
   database. The action refuses to run outside dev for that reason, and excludes
   dot-prefixed system indices (`.opendistro_security`, `.plugins-ml-*`), which
   OpenSearch manages itself.
2. **Right-size the domain.** `instance_type` in the env tfvars —
   `t3.small.search` is below what this index set needs. `t3.medium.search` is a
   floor; `m6g.large.search` gives real headroom.

Reindexing against a saturated or yellow cluster is how you get another round of
partial failures. Get it green first.

Caveat: a Search Indexing run with *Recreate Index* may recreate indices at the
chart's default replica count and undo `reduce-replicas`. Re-run it afterwards,
or fix the shard defaults once the domain is right-sized.

### Traps that waste time

- **`ELASTICSEARCH_HOST`, `_PORT`, `_SCHEME` and `_USER` reach the container
  wrapped in literal double-quote characters.** `helm_values.tftpl` writes them
  unquoted, so the quoting is added downstream by the chart.
  `ELASTICSEARCH_PASSWORD` is unaffected because it arrives via `secretRef`
  rather than string templating. This does not stop the server, but anything
  else reading those variables must strip the quotes or it will not resolve the
  host — `curl` reports `HTTP 000`. Verify with a byte dump, not by eye:
  ```bash
  kubectl exec -n openmetadata deploy/openmetadata -- \
    sh -c 'printf %s "$ELASTICSEARCH_HOST"' | od -c | head
  ```
- **The server image ships no `curl` or `wget`.** Probing OpenSearch from inside
  it is impossible, and a naive `command -v curl` guard exits 0 — which reads as
  a pass. `openmetadata-ops` probes from a throwaway `curlimages/curl` pod
  instead: same nodes, so the same node security group faces the VPC-only
  domain, with the password injected by `secretKeyRef` so it never lands in a pod
  spec or a log.
- **A matching password hash proves agreement, not correctness.** Comparing the
  secret against the pod shows they agree with *each other*. If the stored value
  itself were malformed — wrapping quotes, a trailing newline — both sides would
  send the malformed value and both would be rejected, with hashes matching
  throughout. `diagnose` therefore also reports the stored password's *shape*:
  length, leading/trailing quote, whitespace, first/last byte class.
- **Truncated output hides the answer.** `docs.count` for `table_search_index`
  is the number that settles whether Explore should work, and it sits far down an
  alphabetical `_cat/indices` listing. Print enough of the body, and sort by
  `docs.count`.
- **`$( )` strips trailing newlines**, so a `_bulk` body built with
  `$(printf '...\n')` loses its terminator and OpenSearch answers
  `400 The bulk request must be terminated by a newline` — a self-inflicted
  failure that reads as a cluster fault.

### Worth fixing properly

- **Password drift recurs** on any apply that rolls it. Either add a checksum
  annotation to the deployment's pod template so a secret change forces a
  rollout, or give `random_password` `keepers` so it stops regenerating. The
  first is better but lives in the upstream module's deployment template, so it
  needs `app_extra_helm_values` or an upstream change.
- **Shard defaults.** 5 primaries per index is wrong for a single-node dev
  domain. Until that is configurable here, `reduce-replicas` plus a larger
  instance type is the workaround.
- **The quoting bug** belongs upstream — the module writes those values
  unquoted, so the chart is adding them.

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
- **Core addons are managed, not bootstrapped.** The cluster keeps
  `bootstrap_self_managed_addons = true`, but `vpc-cni`, `kube-proxy` and
  `coredns` are also declared as `aws_eks_addon` with `OVERWRITE`, so EKS
  resolves versions matching the cluster instead of leaving whatever bootstrap
  installed. Without this, a large version jump can leave a CNI that never goes
  Ready, and the node group fails with `NodeCreationFailure: Instances failed to
  join the kubernetes cluster`. The node group depends on the CNI and kube-proxy;
  CoreDNS depends on the node group, since a Deployment cannot become healthy
  with no nodes. `bootstrap_self_managed_addons` is left alone deliberately — it
  is create-time only, so changing it forces cluster replacement.
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
