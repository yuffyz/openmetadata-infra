#!/usr/bin/env bash
# OpenMetadata -> OpenSearch over IAM: the parts Terraform cannot do.
#
#   scripts/opensearch-iam.sh map     # map the server's IAM role in OpenSearch
#   scripts/opensearch-iam.sh check   # prove the server is signing with it
#
# Run by deploy.yml after every apply when opensearch_iam_auth is on
# (terraform output opensearch_iam_role_arn is non-empty). Idempotent.
#
# Environment:
#   ROLE_ARN    the server's IAM role (terraform output opensearch_iam_role_arn)
#   AWS_REGION  region of the domain
#   NAMESPACE   default openmetadata
#   RELEASE     default openmetadata (Deployment and ServiceAccount name)
#   RUN_ID      suffix for probe pod names, default $$
#
# map: OpenSearch fine-grained access control only knows the internal `admin`
#   user, so a signed request from the server's role is authenticated but
#   authorised for nothing. This adds the role ARN as a backend role on the
#   all_access role mapping -- the same privilege the server had as `admin`.
#   It reads the current mapping and adds to it rather than replacing it, so
#   the master user and anything else mapped there are kept. Done as the
#   master user, which is why the password still has to work.
#
# check: four independent proofs, because "search works" alone would also be
#   true if the server had quietly fallen back to the password:
#   1. the image supports it  (SEARCH_AWS_IAM_AUTH_ENABLED in openmetadata.yaml)
#   2. the server pod has it  (the env var, and AWS_ROLE_ARN injected by IRSA
#                              equal to ROLE_ARN)
#   3. the server chose it    (its startup log line for the SigV4 transport)
#   4. the role is authorised (a request signed with the role's credentials,
#                              from a pod running AS the server's
#                              ServiceAccount, returns 200 with all_access)
#
# Exit: 0 ok, 1 failed.

set -uo pipefail

MODE="${1:-check}"
NAMESPACE="${NAMESPACE:-openmetadata}"
RELEASE="${RELEASE:-openmetadata}"
RUN_ID="${RUN_ID:-$$}"
: "${ROLE_ARN:?ROLE_ARN is required}"
: "${AWS_REGION:?AWS_REGION is required}"

log() { printf '%s\n' "$*"; }
err() { printf '::error::%s\n' "$*"; }
case "$MODE" in map|check) ;; *) err "usage: $0 map|check"; exit 1 ;; esac

# The newest Ready server pod that is NOT terminating, or empty.
#
# check must not address the server as deploy/$RELEASE. kubectl resolves that
# to ONE pod of the Deployment's selector, preferring the pod that has been
# Ready longest -- and it does not look at deletionTimestamp. Right after a
# rollout the old pod is still in its grace period, still Running and Ready,
# and older than its replacement, so exec and logs land on the pod that is
# going away. That is how run 37552351108 (2026-10-07) failed check 3: it read
# the outgoing pod, three seconds after `rollout status` returned.
server_pod() {
  local sel
  sel=$(kubectl get deploy "$RELEASE" -n "$NAMESPACE" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    m = json.load(sys.stdin)["spec"]["selector"]["matchLabels"]
except Exception:
    sys.exit(0)
print(",".join(f"{k}={v}" for k, v in sorted(m.items())))')
  [ -n "$sel" ] || return 0
  kubectl get pods -n "$NAMESPACE" -l "$sel" -o json 2>/dev/null | python3 -c '
import json, sys
def ready(p):
    return any(c["type"] == "Ready" and c["status"] == "True" for c in p["status"].get("conditions", []))
pods = [p for p in json.load(sys.stdin)["items"]
        if not p["metadata"].get("deletionTimestamp") and p["status"].get("phase") == "Running" and ready(p)]
pods.sort(key=lambda p: p["metadata"]["creationTimestamp"])
print(pods[-1]["metadata"]["name"] if pods else "")'
}

# map keeps deploy/: it only needs connection details any server pod has, and
# it must still work when the server is crash-looping (see spec_env below).
TARGET="deploy/$RELEASE"
if [ "$MODE" = check ]; then
  pod=""
  for _ in $(seq 1 36); do                        # up to ~3 minutes
    pod=$(server_pod)
    [ -n "$pod" ] && break
    sleep 5
  done
  [ -n "$pod" ] || { err "no Ready, non-terminating $RELEASE pod in $NAMESPACE"; exit 1; }
  TARGET="pod/$pod"
  log "checking server pod $pod"
fi

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

# Connection details as the server sees them, the chart's quotes stripped.
# map only needs host/port/user, so it falls back to the Deployment spec when
# the pod cannot be exec'd -- the case where a crash-looping server is waiting
# for exactly this mapping. check needs the live pod, and fails if it is gone.
env_dump=$(kubectl exec -n "$NAMESPACE" "$TARGET" -- sh -c '
  echo "H=${ELASTICSEARCH_HOST:-}"
  echo "P=${ELASTICSEARCH_PORT:-443}"
  echo "U=${ELASTICSEARCH_USER:-admin}"
  echo "IAM=${SEARCH_AWS_IAM_AUTH_ENABLED:-}"
  echo "ROLE=${AWS_ROLE_ARN:-}"
  echo "TOKEN=${AWS_WEB_IDENTITY_TOKEN_FILE:-}"' 2>/dev/null \
  | tr -d '\r' | sed -e 's/=\"\(.*\)\"$/=\1/')
printf '%s\n' "$env_dump" | grep -q '^H=..' \
  || env_dump=$(spec_env | tr -d '\r' | sed -e 's/=\"\(.*\)\"$/=\1/')
field() { printf '%s\n' "$env_dump" | sed -n "s/^$1=//p"; }
OS_HOST=$(field H); OS_PORT=$(field P); OS_USER=$(field U)
[ -n "$OS_HOST" ] || { err "ELASTICSEARCH_HOST is empty in the server pod"; exit 1; }
export OS_HOST OS_PORT OS_USER

# Runs a one-shot pod to completion and prints its output on stdout.
#
# Deliberately NOT `kubectl run --rm -i`: that attaches to the container while
# it runs, and a request that finishes in under a second can exit before the
# attach lands -- the output is lost, and with kubectl's stderr discarded the
# caller just sees nothing ("unexpected HTTP : "). Instead: create the pod,
# poll until it has finished, read its logs, delete it. Each step reports its
# own failure on stderr (so it reaches the job log without polluting the
# captured output), including why a pod never started (image pull, etc.).
#   $1 pod name, $2 image, $3 overrides JSON
pod_output() {
  local name="$1" image="$2" overrides="$3" err phase="" state
  if ! err=$(kubectl run "$name" -n "$NAMESPACE" --image="$image" --restart=Never \
               --overrides="$overrides" 2>&1 >/dev/null); then
    printf '::error::could not create pod %s: %s\n' "$name" "$err" >&2
    return 1
  fi
  for _ in $(seq 1 90); do                       # up to ~3 minutes
    phase=$(kubectl get pod "$name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
    case "$phase" in Succeeded|Failed) break ;; esac
    sleep 2
  done
  kubectl logs "$name" -n "$NAMESPACE" 2>/dev/null
  if [ "$phase" != Succeeded ]; then
    state=$(kubectl get pod "$name" -n "$NAMESPACE" \
              -o jsonpath='{.status.containerStatuses[0].state}' 2>/dev/null)
    printf '::error::pod %s ended in phase %s; container state: %s\n' \
      "$name" "${phase:-unknown}" "${state:-none}" >&2
  fi
  kubectl delete pod "$name" -n "$NAMESPACE" --wait=false >/dev/null 2>&1
  [ "$phase" = Succeeded ]
}

# Runs a script in a throwaway pod and prints its output.
#   $1 pod name, $2 image, $3 script, $4 "master" to inject the master
#   password by secretKeyRef, or "server-sa" to run as the server's
#   ServiceAccount (so IRSA gives it the server's role), $5 extra env names.
run_pod() {
  local name="$1" image="$2" script="$3" mode="$4" extra="${5:-}" overrides
  overrides=$(POD="$name" IMAGE="$image" SCRIPT="$script" MODE="$mode" EXTRA="$extra" \
              SA="$RELEASE" python3 - <<'PY'
import json, os
env = lambda k: {"name": k, "value": os.environ[k]}
names = ["OS_HOST", "OS_PORT", "OS_USER"] + os.environ["EXTRA"].split()
c = {"name": os.environ["POD"], "image": os.environ["IMAGE"],
     "command": ["sh", "-c", os.environ["SCRIPT"]], "env": [env(k) for k in names]}
spec = {"restartPolicy": "Never", "containers": [c]}
if os.environ["MODE"] == "master":
    c["env"].append({"name": "OS_PASS", "valueFrom": {"secretKeyRef": {
        "name": "opensearch-credentials", "key": "password"}}})
else:
    spec["serviceAccountName"] = os.environ["SA"]
print(json.dumps({"apiVersion": "v1", "spec": spec}))
PY
  )
  pod_output "$name" "$image" "$overrides"
}

# ------------------------------------------------------------------- map ---
if [ "$MODE" = map ]; then
  log "mapping $ROLE_ARN to all_access on $OS_HOST"
  read -r -d '' GET <<'SH' || true
curl -s --max-time 60 -u "$OS_USER:$OS_PASS" -w '\n@@HTTP:%{http_code}' \
  "https://$OS_HOST:$OS_PORT/_plugins/_security/api/rolesmapping/all_access"
SH
  current=$(run_pod "om-os-iam-get-$RUN_ID-$RANDOM" curlimages/curl:8.11.1 "$GET" master)
  body=$(BODY="$current" ROLE_ARN="$ROLE_ARN" python3 - <<'PY'
import json, os, sys
raw = os.environ["BODY"]
code = raw.rsplit("@@HTTP:", 1)[-1].strip()
text = raw.rsplit("@@HTTP:", 1)[0]
if code == "401":
    print("401: the master password is rejected -- run scripts/opensearch-credentials.sh heal first", file=sys.stderr); sys.exit(1)
if code == "404":
    m = {}
elif code == "200":
    m = json.loads(text).get("all_access", {})
else:
    print(f"unexpected HTTP {code}: {text[:500]}", file=sys.stderr); sys.exit(1)
roles = m.get("backend_roles", [])
if os.environ["ROLE_ARN"] in roles:
    print("ALREADY"); sys.exit(0)
print(json.dumps({"backend_roles": roles + [os.environ["ROLE_ARN"]],
                  "hosts": m.get("hosts", []), "users": m.get("users", []),
                  "and_backend_roles": m.get("and_backend_roles", [])}))
PY
  ) || { err "could not read the all_access mapping"; exit 1; }
  if [ "$body" = ALREADY ]; then log "already mapped"; exit 0; fi

  export MAPPING="$body"
  read -r -d '' PUT <<'SH' || true
curl -s --max-time 60 -u "$OS_USER:$OS_PASS" -X PUT -H 'Content-Type: application/json' \
  --data-binary "$MAPPING" -w '\n@@HTTP:%{http_code}' \
  "https://$OS_HOST:$OS_PORT/_plugins/_security/api/rolesmapping/all_access"
SH
  out=$(run_pod "om-os-iam-put-$RUN_ID-$RANDOM" curlimages/curl:8.11.1 "$PUT" master MAPPING)
  code=$(printf %s "$out" | sed -n 's/^@@HTTP://p')
  if [ "$code" = 200 ] || [ "$code" = 201 ]; then
    log "mapped (HTTP $code)"; exit 0
  fi
  err "mapping failed (HTTP $code): $(printf %s "$out" | head -c 400)"
  exit 1
fi

# ----------------------------------------------------------------- check ---
fail=0

# 1. The image knows the setting. Looked up rather than assumed, both the key
#    and the file, so an image without it says so plainly.
supported=$(kubectl exec -n "$NAMESPACE" "$TARGET" -- sh -c \
  'grep -rl SEARCH_AWS_IAM_AUTH_ENABLED /opt/openmetadata/conf 2>/dev/null | head -1' 2>/dev/null | tr -d '\r')
if [ -n "$supported" ]; then log "1 ok    image supports IAM auth ($supported)"
else err "1 FAIL  this OpenMetadata image has no SEARCH_AWS_IAM_AUTH_ENABLED setting"; fail=1; fi

# 2. The pod got the switch and the role.
pod_role=$(field ROLE)
if [ "$(field IAM)" = true ] && [ "$pod_role" = "$ROLE_ARN" ] && [ -n "$(field TOKEN)" ]; then
  log "2 ok    server pod: SEARCH_AWS_IAM_AUTH_ENABLED=true, AWS_ROLE_ARN=$pod_role"
else
  err "2 FAIL  server pod: SEARCH_AWS_IAM_AUTH_ENABLED='$(field IAM)', AWS_ROLE_ARN='$pod_role' (want $ROLE_ARN), token file='$(field TOKEN)'"
  err "        a pod started before the ServiceAccount annotation gets no IRSA env: restart it"
  fail=1
fi

# 3. The server actually took the IAM path (logged once, at client creation,
#    at INFO by OpenSearchClient.createAwsSdk2Transport in 1.12.x).
#
#    That line is written once, at startup, so its absence only proves
#    something if the log still reaches back to startup. The kubelet rotates
#    container logs (10 MiB by default) and `kubectl logs` returns only the
#    current file, so on a server that has been up for a while the line is
#    simply gone. Compare the first surviving timestamp with the container's
#    start: if the beginning is missing, say so instead of claiming the server
#    is on the password.
logs=$(kubectl logs -n "$NAMESPACE" "$TARGET" --tail=-1 --timestamps 2>/dev/null)
started=$(kubectl get -n "$NAMESPACE" "$TARGET" \
  -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}' 2>/dev/null)
log_start_missing=$(FIRST="$(printf '%s\n' "$logs" | head -1 | cut -d' ' -f1)" STARTED="$started" python3 -c '
import os
from datetime import datetime
def ts(s):
    s = s.strip().rstrip("Z")
    if "." in s:
        head, frac = s.split(".", 1)
        s = head + "." + frac[:6]
    return datetime.fromisoformat(s)
try:
    gap = (ts(os.environ["FIRST"]) - ts(os.environ["STARTED"])).total_seconds()
except Exception:
    gap = 0
print("yes" if gap > 120 else "no")')

if printf '%s' "$logs" | grep -q 'Failed to create AwsSdk2Transport'; then
  err "3 FAIL  the server failed to create its SigV4 transport -- see 'Failed to create AwsSdk2Transport' in its log"; fail=1
elif printf '%s' "$logs" | grep -q 'Creating AwsSdk2Transport for AWS OpenSearch IAM auth'; then
  log "3 ok    server log: SigV4 transport created"
elif [ "$log_start_missing" = yes ]; then
  printf '::warning::%s\n' "3 SKIP  ${TARGET#pod/} started at $started but its log now begins later (rotated), so the startup line cannot be checked. Restart the server (openmetadata-ops -> restart-server) and re-run to verify."
else
  err "3 FAIL  no SigV4 transport line in ${TARGET#pod/}'s log since it started at $started -- it is still on the password"; fail=1
fi

# 4. A request signed with the server's role is accepted and authorised.
#    The aws-cli image, run as the server's ServiceAccount, gets the same
#    web identity token; export-credentials turns it into keys for curl.
read -r -d '' SIGNED <<'SH' || true
eval "$(aws configure export-credentials --format env 2>/dev/null)" || true
[ -n "${AWS_ACCESS_KEY_ID:-}" ] || { echo "@@NOCREDS"; exit 0; }
curl -s --max-time 60 --aws-sigv4 "aws:amz:$REGION:es" \
  --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" \
  -H "x-amz-security-token: $AWS_SESSION_TOKEN" -w '\n@@HTTP:%{http_code}' \
  "https://$OS_HOST:$OS_PORT/_plugins/_security/authinfo"
SH
export REGION="$AWS_REGION"
out=$(run_pod "om-os-iam-chk-$RUN_ID-$RANDOM" amazon/aws-cli:latest "$SIGNED" server-sa REGION)
verdict=$(OUT="$out" ROLE_ARN="$ROLE_ARN" python3 - <<'PY'
import json, os
raw = os.environ["OUT"]
if "@@NOCREDS" in raw:
    print("FAIL the probe pod got no IAM credentials from the ServiceAccount (IRSA)"); raise SystemExit
code = raw.rsplit("@@HTTP:", 1)[-1].strip()
try:
    info = json.loads(raw.rsplit("@@HTTP:", 1)[0])
except Exception:
    info = {}
roles, backend = info.get("roles", []), info.get("backend_roles", [])
if code == "200" and "all_access" in roles:
    print(f"ok    signed request as the server's role: HTTP 200, roles={roles}")
elif code == "200":
    print(f"FAIL  signed request authenticated but not mapped (roles={roles}, backend_roles={backend}) -- run map")
elif code == "403":
    print("FAIL  signed request rejected 403 -- the role is not allowed es:ESHttp* or not mapped")
else:
    print(f"FAIL  signed request: HTTP {code or 'none'} {raw[:300]}")
PY
)
case "$verdict" in ok*) log "4 $verdict" ;; *) err "4 $verdict"; fail=1 ;; esac

[ $fail -eq 0 ] && log "OK: OpenMetadata reaches OpenSearch over IAM; the master password is no longer in its path."
exit $fail
