#!/usr/bin/env bash
# Checks, and optionally heals, OpenSearch password drift for one environment.
#
#   scripts/opensearch-credentials.sh check   # report only
#   scripts/opensearch-credentials.sh heal    # check, and fix what it finds
#
# Run by deploy.yml after every apply, and by openmetadata-ops for
# reset-opensearch-password. Needs kubectl pointed at the cluster, AWS
# credentials, and python3.
#
# Environment:
#   OS_DOMAIN   OpenSearch domain name (required for heal)
#   AWS_REGION  region of the domain
#   NAMESPACE   default openmetadata
#   RELEASE     default openmetadata (Deployment name)
#   RUN_ID      suffix for the probe pod name, default $$
#
# There are two ways the password drifts, and they need different fixes:
#
#   STALE POD  The secret changed but the server pod started before that, and
#              it embeds the password at container start. Fix: restart it.
#              (opensearch_password.tf now does this on apply; this is the
#              safety net.)
#
#   DOMAIN     The domain's master password differs from the secret. Terraform
#              cannot see this -- AWS never returns the password -- so a plan
#              stays clean while every search request gets 401. Fix: set the
#              domain to the secret's value.
#
# Why the domain fix is a "bounce": sending the secret's value straight to the
# domain is often accepted and silently not applied -- AWS returns success and
# AdvancedSecurityOptions.Status.UpdateVersion does not move (README_full.md,
# "Fixing password drift"). So this first sets a throwaway password, which AWS
# cannot treat as unchanged, then the secret's value, which now differs from
# the current one, and checks that UpdateVersion moved both times.
#
# The end state is the secret's value, which is Terraform's value. That is the
# difference from rotate-opensearch-password: rotation picks a NEW password, so
# the next apply puts the secret back to Terraform's and the domain is left
# behind again -- which this script then has to bounce.
#
# Exit codes: 0 healthy (or healed), 1 unhealthy and not fixed,
#             2 could not determine (no answer from OpenSearch).

set -uo pipefail

MODE="${1:-check}"
NAMESPACE="${NAMESPACE:-openmetadata}"
RELEASE="${RELEASE:-openmetadata}"
RUN_ID="${RUN_ID:-$$}"
SECRET=opensearch-credentials

log() { printf '%s\n' "$*"; }
err() { printf '::error::%s\n' "$*"; }

case "$MODE" in check|heal) ;; *) err "usage: $0 check|heal"; exit 1 ;; esac

secret_password() {
  kubectl get secret -n "$NAMESPACE" "$SECRET" -o jsonpath='{.data.password}' | base64 -d
}

sha() { python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])'; }

# Fallback when the server pod cannot be exec'd into -- crash-looping, or
# not yet scheduled. The literal env values from the Deployment spec; entries
# set by valueFrom (secrets) are skipped, and defaults fill the gaps.
spec_env() {
  kubectl get deploy "$RELEASE" -n "$NAMESPACE" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    c = json.load(sys.stdin)["spec"]["template"]["spec"]["containers"][0]
except Exception:
    sys.exit(0)
env = {e["name"]: e["value"] for e in c.get("env", []) if "value" in e}
for k, short, default in (("ELASTICSEARCH_HOST", "H", ""), ("ELASTICSEARCH_PORT", "P", "443"),
                          ("ELASTICSEARCH_SCHEME", "S", "https"), ("ELASTICSEARCH_USER", "U", "admin")):
    print(f"{short}={env.get(k, default)}")'
}

# Connection details as the server sees them, falling back to the Deployment
# spec. The chart wraps these values in literal double quotes; strip them (see
# the Probe step in openmetadata-ops).
server_env() {
  local out
  out=$(kubectl exec -n "$NAMESPACE" "deploy/$RELEASE" -- sh -c '
    echo "H=${ELASTICSEARCH_HOST:-}"
    echo "P=${ELASTICSEARCH_PORT:-443}"
    echo "S=${ELASTICSEARCH_SCHEME:-https}"
    echo "U=${ELASTICSEARCH_USER:-admin}"' 2>/dev/null)
  printf '%s\n' "$out" | grep -q '^H=..' || out=$(spec_env)
  printf '%s\n' "$out" | tr -d '\r' | sed -e 's/=\"\(.*\)\"$/=\1/'
}

# The password the RUNNING server holds, hashed. Compared against the secret's
# hash to spot a stale pod without either value leaving the cluster.
server_password_sha() {
  kubectl exec -n "$NAMESPACE" "deploy/$RELEASE" -- \
    sh -c 'printf %s "$ELASTICSEARCH_PASSWORD"' 2>/dev/null \
  | tr -d '\r' | sed -e 's/^"\(.*\)"$/\1/' | sha
}

# HTTP status from authenticating to OpenSearch with the SECRET's password,
# from a throwaway pod on the cluster's nodes (the domain is VPC-only). The
# password is injected by secretKeyRef, so it never appears in a pod spec or
# a log. 200 = accepted, 401 = rejected, 000 = no answer.
probe() {
  local env host port scheme user pod overrides
  env=$(server_env)
  host=$(printf '%s\n' "$env" | sed -n 's/^H=//p')
  port=$(printf '%s\n' "$env" | sed -n 's/^P=//p')
  scheme=$(printf '%s\n' "$env" | sed -n 's/^S=//p')
  user=$(printf '%s\n' "$env" | sed -n 's/^U=//p')
  [ -n "$host" ] || { echo "nohost"; return; }
  pod="om-os-cred-${RUN_ID}-$RANDOM"
  overrides=$(OS_HOST="$host" OS_PORT="$port" OS_SCHEME="$scheme" OS_USER="$user" POD="$pod" \
              SECRET="$SECRET" python3 - <<'PY'
import json, os
env = lambda k: {"name": k, "value": os.environ[k]}
script = ('curl -s -o /dev/null -w "%{http_code}" --max-time 30 '
          '-u "$OS_USER:$OS_PASS" "$OS_SCHEME://$OS_HOST:$OS_PORT/_plugins/_security/authinfo"')
print(json.dumps({"apiVersion": "v1", "spec": {"restartPolicy": "Never", "containers": [{
    "name": os.environ["POD"], "image": "curlimages/curl:8.11.1",
    "command": ["sh", "-c", script],
    "env": [env("OS_HOST"), env("OS_PORT"), env("OS_SCHEME"), env("OS_USER"),
            {"name": "OS_PASS", "valueFrom": {"secretKeyRef": {
                "name": os.environ["SECRET"], "key": "password"}}}]}]}}))
PY
  )
  kubectl run "$pod" -n "$NAMESPACE" --image=curlimages/curl:8.11.1 --restart=Never \
    --rm -i --quiet --pod-running-timeout=3m --overrides="$overrides" 2>/dev/null \
    | tr -dc '0-9' | tail -c 3
}

update_version() {
  aws opensearch describe-domain-config --domain-name "$OS_DOMAIN" --region "$AWS_REGION" \
    --query 'DomainConfig.AdvancedSecurityOptions.Status.UpdateVersion' --output text
}

wait_domain() {
  local p
  for _ in $(seq 1 60); do
    p=$(aws opensearch describe-domain --domain-name "$OS_DOMAIN" --region "$AWS_REGION" \
          --query 'DomainStatus.Processing' --output text)
    [ "$p" = "False" ] && return 0
    sleep 15
  done
  err "domain $OS_DOMAIN still processing after 15 minutes"
  return 1
}

# Sets the master password and proves AWS applied it. --cli-input-json rather
# than shorthand syntax, which splits on commas and equals signs.
set_domain_password() {
  local pw="$1" user="$2" before after cfg
  before=$(update_version)
  cfg=$(umask 077; mktemp)
  OS_DOMAIN="$OS_DOMAIN" OS_USER="$user" PW="$pw" python3 - > "$cfg" <<'PY'
import json, os
print(json.dumps({"DomainName": os.environ["OS_DOMAIN"], "AdvancedSecurityOptions": {
    "Enabled": True, "InternalUserDatabaseEnabled": True,
    "MasterUserOptions": {"MasterUserName": os.environ["OS_USER"],
                          "MasterUserPassword": os.environ["PW"]}}}))
PY
  aws opensearch update-domain-config --region "$AWS_REGION" --cli-input-json "file://$cfg" >/dev/null
  local rc=$?
  rm -f "$cfg"
  [ $rc -eq 0 ] || { err "update-domain-config failed"; return 1; }
  after=$(update_version)
  if [ "$before" = "$after" ]; then
    err "AWS accepted the password change but did not apply it (UpdateVersion still $before)"
    return 1
  fi
  log "  UpdateVersion $before -> $after"
  wait_domain
}

# --- check ---------------------------------------------------------------------
kubectl rollout status "deploy/$RELEASE" -n "$NAMESPACE" --timeout=10m >/dev/null 2>&1 \
  || log "warning: deploy/$RELEASE is not fully rolled out; checking anyway"

PW=$(secret_password)
[ -n "$PW" ] || { err "$SECRET is empty or missing in $NAMESPACE"; exit 1; }
[ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::$PW"

secret_sha=$(printf %s "$PW" | sha)
pod_sha=$(server_password_sha)
# sha of empty input: the server pod could not be exec'd (crash-looping or not
# running). Treated as stale, so heal restarts it -- which is also the cure.
[ "$pod_sha" = "$(printf '' | sha)" ] && log "server pod not reachable for exec -- treating it as stale"
stale=no
[ "$secret_sha" = "$pod_sha" ] || stale=yes
code=$(probe)

log "secret password sha256: $secret_sha"
log "server password sha256: $pod_sha  (stale pod: $stale)"
log "OpenSearch with the secret's password: HTTP $code"

if [ "$stale" = no ] && [ "$code" = 200 ]; then
  log "OK: server, secret and domain agree."
  exit 0
fi
if [ "$code" != 200 ] && [ "$code" != 401 ]; then
  err "OpenSearch did not give a usable answer (HTTP $code) -- not a credential verdict. Run openmetadata-ops diagnose."
  exit 2
fi

if [ "$MODE" = check ]; then
  [ "$stale" = yes ] && err "the server pod holds an old password: restart it (heal does this)"
  [ "$code" = 401 ] && err "the domain rejects the secret's password: domain drift (heal fixes this)"
  exit 1
fi

# --- heal ----------------------------------------------------------------------
if [ "$code" = 401 ]; then
  [ -n "${OS_DOMAIN:-}" ] || { err "OS_DOMAIN is not set; cannot fix the domain"; exit 1; }
  user=$(server_env | sed -n 's/^U=//p'); user=${user:-admin}
  log "Domain drift: bouncing the master password on $OS_DOMAIN back to the secret's value"
  TEMP=$(python3 -c "import secrets,string; print('T' + ''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(22)) + '_x9')")
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::$TEMP"
  log "step 1/2: throwaway password"
  set_domain_password "$TEMP" "$user" || exit 1
  log "step 2/2: the secret's (Terraform's) password"
  set_domain_password "$PW" "$user" || exit 1
fi

if [ "$stale" = yes ]; then
  log "Stale pod: restarting deploy/$RELEASE so it reloads the secret"
  kubectl rollout restart "deploy/$RELEASE" -n "$NAMESPACE"
  kubectl rollout status  "deploy/$RELEASE" -n "$NAMESPACE" --timeout=10m || exit 1
fi

# Re-check from scratch rather than trusting the steps above.
pod_sha=$(server_password_sha)
code=$(probe)
log "after: server password sha256 $pod_sha, OpenSearch HTTP $code"
if [ "$pod_sha" = "$secret_sha" ] && [ "$code" = 200 ]; then
  log "HEALED: server, secret and domain agree."
  log "If Explore is empty, re-run Search Indexing (Recreate Index = true)."
  exit 0
fi
err "still unhealthy after healing (server matches secret: $([ "$pod_sha" = "$secret_sha" ] && echo yes || echo no), HTTP $code)."
if [ "$pod_sha" = "$(printf '' | sha)" ]; then
  err "The server pod is not running (crash-looping?) -- check: kubectl logs -n $NAMESPACE deploy/$RELEASE --previous"
  err "With opensearch_iam_auth on, an unmapped IAM role is a likely cause; deploy.yml's next step maps it."
else
  err "If UpdateVersion moved but 401 persists, reset the password from OpenSearch Dashboards: Security -> Internal users."
fi
exit 1
