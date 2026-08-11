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
Balancer Controller and turns the chart's Service into a `LoadBalancer`:

```bash
kubectl get svc -n openmetadata openmetadata \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Then `http://<hostname>:8585`. Allow a couple of minutes after apply — Terraform
returns when the Helm release succeeds (the module sets `wait = false`), but the
controller still has to provision the NLB and pass health checks, so the
hostname is briefly empty and then briefly unresolvable.

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

The URL becomes `https://openmetadata.example.com:8585`. What Terraform creates
(`terraform/nlb_tls.tf`), all conditional on those variables:

| Resource | Purpose |
|---|---|
| `aws_acm_certificate` | DNS-validated cert for the FQDN |
| `aws_route53_record.app_cert_validation` | Validation CNAMEs, `allow_overwrite` for cert rotation |
| `aws_acm_certificate_validation` | Blocks until ACM reports ISSUED |
| `time_sleep.wait_for_nlb` | 240s for the controller to provision the NLB |
| `data.aws_lb` | Reads the NLB back by the controller's resource tags |
| `aws_route53_record.app` | Alias A record → NLB |

The certificate reaches the chart as the
`service.beta.kubernetes.io/aws-load-balancer-ssl-cert` annotation, paired with
`ssl-ports: "http"`. It references the **validation** resource, not the
certificate, so the Service is never created with an unissued ARN.

`ssl-ports` names the Service port rather than numbering it (`http` is the
chart's name for 8585). The controller accepts either, but these annotations
reach the chart through the upstream module's `set = [...]` with the helm
provider's default `auto` typing, and Helm parses an all-digit value into an
integer — which the API server rejects, since annotation values must be
strings (`cannot unmarshal number into Go struct field
ObjectMeta.metadata.annotations of type string`). Leaving `ssl-ports` off
entirely is not the same thing: with a certificate and no port list, *every*
Service port gets a TLS listener, including the chart's 8586 admin port.

Three things to know before enabling it:

- **The NLB is kept, not replaced.** The controller adds a TLS listener to the
  existing load balancer, so the `*.elb.amazonaws.com` hostname keeps working
  and there is no outage. The `aws-load-balancer-name` annotation
  (`<cluster>-omd`) applies only when the NLB is first provisioned — ELBv2 has
  no rename API and the controller replaces an LB only on a type or scheme
  change — so an NLB created before TLS was switched on keeps its generated
  `k8s-*` name. That is why `data.aws_lb` matches on the controller's tags
  (`service.k8s.aws/stack`, `service.k8s.aws/resource`, `elbv2.k8s.aws/cluster`)
  instead of the name.
- **The port stays 8585**, so the URL is `https://<domain>:8585`, not 443. The
  NLB listener mirrors the chart's Service port. Moving to 443 means setting
  `app_extra_helm_values = { "service.port" = "443" }` — verify afterwards that
  `kubectl get svc -n openmetadata openmetadata -o yaml` still shows
  `targetPort: 8585`, since how this chart templates `targetPort` isn't
  guaranteed.
- **The first apply may need a re-run.** Because `wait = false`, Terraform can
  reach the `data.aws_lb` lookup before the controller has finished. The 240s
  sleep usually covers it; if not, apply fails with *reading ELBv2 Load
  Balancers: couldn't find resource* and re-running completes it. Nothing is
  left half-built.

The hosted zone must already exist and be **public** — this repo does not create
it, and DNS validation needs it to be authoritative for the domain.

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
| `app_tls_route53_zone_name` | `""` | Public hosted zone owning that FQDN. **Required** with the above |
| `lb_controller_chart_version` | `null` | Controller chart version; `null` tracks latest |
| `app_extra_helm_values` | `{}` | Arbitrary Helm `set` overrides, merged last |

Four validation rules fail the plan rather than let a broken or unsafe config
through: an empty `app_lb_allowed_cidrs` while the NLB toggle is on, `0.0.0.0/0`
anywhere in that list, a TLS domain without `app_expose_via_nlb`, and a TLS
domain without a hosted zone.

`module "app"` is **shared by both environments**, so exposure has to be a
variable — hardcoding `service.type` would publish production on its next apply.
That's why the toggle defaults to `false` and only dev opts in.

Source ranges are applied as the controller annotation
`service.beta.kubernetes.io/load-balancer-source-ranges`, not
`service.loadBalancerSourceRanges`. The chart templates `service.annotations`
verbatim, so the annotation is guaranteed to reach the Service; relying on a
dedicated chart field that may not exist would silently leave the NLB open.
Enforcement needs a controller that manages NLB security groups (v2.6+).

> ⚠️ **Without `app_tls_domain_name`, the NLB serves plain HTTP.** Credentials —
> including that default admin password — cross the internet in the clear.
> IP-allowlisting limits *who can connect*; it encrypts nothing, and browsers
> correctly flag the login page as "Not secure". Configure TLS above, or use
> `port-forward`, before typing a password you care about.

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

1. **Standard ports.** The NLB listener mirrors the chart's Service port, so the
   URL carries `:8585`. An ALB Ingress serves 443 with an HTTP→HTTPS redirect and
   no port in the URL.
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
