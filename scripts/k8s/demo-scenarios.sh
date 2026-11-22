#!/usr/bin/env bash
# =============================================================================
# HU-30 - Demonstrates the deployment patterns on the k3d demo cluster.
# Run scripts/k8s/demo-up.sh first. Starts from dashboard 1.0.0 as stable.
#
#   1. Canary 10 %     1.1.0 receives ~10 % of 200 real requests (per-pod metrics)
#   2. Canary 50 %     the share follows the weight
#   3. Abort           100 % back to stable, canary removed
#   4. Promote         canary again, then promoted with a rolling update under
#                      continuous traffic: no failed request
#   5. Auto rollback   a version that never becomes Ready is rolled back by
#                      scripts/k8s/rollout.sh, still without failed requests
# =============================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
URL=${URL:-http://localhost:8090/api/v1/analytics/summary}
NS=circleguard
STABLE_IMAGE=circleguard/dashboard-service:1.0.0
NEW_IMAGE=circleguard/dashboard-service:1.1.0
BROKEN_IMAGE=circleguard/dashboard-service:9.9.9-does-not-exist
LOAD_FILE=$(mktemp)
PASS=0; FAIL=0

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
check() { if eval "$2"; then PASS=$((PASS+1)); printf '  PASS %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; fi; }

# Requests to the summary endpoint served by one pod, read from its own metrics.
served_by() {
  kubectl -n "$NS" exec "$1" -- bash -c \
    'exec 3<>/dev/tcp/127.0.0.1/8084; printf "GET /actuator/prometheus HTTP/1.0\r\n\r\n" >&3; cat <&3' 2>/dev/null \
    | grep '^http_server_requests_seconds_count' | grep 'uri="/api/v1/analytics/summary"' \
    | awk '{s+=$NF} END {printf "%d", s}'
}
pod_of() { kubectl -n "$NS" get pods -l "app.kubernetes.io/instance=$1" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'; }
send() { for _ in $(seq 1 "$1"); do curl -s -o /dev/null "$URL"; done; }

# Continuous traffic (about 10 requests per second) recording every status code.
# The loop stops when STOP_FILE appears (killing a background subshell is not
# reliable in Git Bash). curl on Windows ends lines with \r\n, hence the tr.
STOP_FILE="$LOAD_FILE.stop"
load_start() {
  : > "$LOAD_FILE"; rm -f "$STOP_FILE"
  ( while [[ ! -e "$STOP_FILE" ]]; do
      curl -s -o /dev/null -m 5 -w '%{http_code}\n' "$URL" >> "$LOAD_FILE"; sleep 0.1
    done ) &
  LOAD_PID=$!
}
load_stop() { touch "$STOP_FILE"; wait "$LOAD_PID" 2>/dev/null; rm -f "$STOP_FILE"; }
load_total() { tr -d '\r' < "$LOAD_FILE" | grep -c .; }
load_errors() { tr -d '\r' < "$LOAD_FILE" | grep -cv '^200$'; }

split() {  # split <requests>: sends them and prints how many each pod served
  local stable canary s0 c0 s1 c1
  stable=$(pod_of dashboard); canary=$(pod_of dashboard-canary)
  s0=$(served_by "$stable"); c0=$(served_by "$canary")
  send "$1"
  s1=$(served_by "$stable"); c1=$(served_by "$canary")
  STABLE_N=$((s1 - s0)); CANARY_N=$((c1 - c0))
  log "  $1 requests -> stable $STABLE_N, canary $CANARY_N"
}

log "Initial state"
# Repeatable: leave no canary behind and start from the stable image.
"$HERE/canary.sh" abort >/dev/null
if [[ "$(kubectl -n "$NS" get deploy circleguard-dashboard-service -o jsonpath='{.spec.template.spec.containers[0].image}')" != "$STABLE_IMAGE" ]]; then
  "$HERE/rollout.sh" dashboard "$STABLE_IMAGE" >/dev/null
fi
"$HERE/canary.sh" status

log "Scenario 1 - canary with 10 % of the traffic"
"$HERE/canary.sh" start "$NEW_IMAGE" 10
split 200
check "the canary served between 5 % and 20 % (got $CANARY_N of 200)" '(( CANARY_N >= 10 && CANARY_N <= 40 ))'
check "stable and canary together served all requests" '(( STABLE_N + CANARY_N == 200 ))'

log "Scenario 2 - canary with 50 %"
"$HERE/canary.sh" weight 50
split 200
check "the canary served between 35 % and 65 % (got $CANARY_N of 200)" '(( CANARY_N >= 70 && CANARY_N <= 130 ))'

log "Scenario 3 - abort"
"$HERE/canary.sh" abort
sleep 3
check "the canary Deployment is gone" '! kubectl -n "$NS" get deploy circleguard-dashboard-service-canary >/dev/null 2>&1'
ok=$(for _ in $(seq 1 50); do curl -s -o /dev/null -w '%{http_code}\n' "$URL"; done | tr -d '\r' | grep -c '^200$')
check "stable answers all requests after the abort ($ok of 50 with HTTP 200)" '(( ok == 50 ))'

log "Scenario 4 - promote under continuous traffic"
"$HERE/canary.sh" start "$NEW_IMAGE" 10
load_start
"$HERE/canary.sh" promote
sleep 5; load_stop
image=$(kubectl -n "$NS" get deploy circleguard-dashboard-service -o jsonpath='{.spec.template.spec.containers[0].image}')
check "stable now runs $NEW_IMAGE (got $image)" '[[ "$image" == "$NEW_IMAGE" ]]'
check "no failed request during the promotion ($(load_errors) of $(load_total))" '(( $(load_errors) == 0 && $(load_total) > 0 ))'

log "Scenario 5 - automatic rollback of a version that never becomes Ready"
load_start
"$HERE/rollout.sh" dashboard "$BROKEN_IMAGE" 60s; rc=$?
sleep 3; load_stop
image=$(kubectl -n "$NS" get deploy circleguard-dashboard-service -o jsonpath='{.spec.template.spec.containers[0].image}')
check "rollout.sh reported the failure (exit $rc)" '(( rc == 1 ))'
check "the Deployment is back on $NEW_IMAGE (got $image)" '[[ "$image" == "$NEW_IMAGE" ]]'
check "no failed request during the failed rollout ($(load_errors) of $(load_total))" '(( $(load_errors) == 0 && $(load_total) > 0 ))'
echo "  rollout history:"; kubectl -n "$NS" rollout history deploy/circleguard-dashboard-service | sed 's/^/    /'

rm -f "$LOAD_FILE"
echo
log "Result: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
