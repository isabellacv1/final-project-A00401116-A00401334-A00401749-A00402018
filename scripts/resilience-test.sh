#!/usr/bin/env bash
# =============================================================================
# HU-28 - Fault injection tests against a running CircleGuard stack.
#
# Prerequisite: the stack is up and healthy, e.g. locally
#   docker compose -f docker-compose.dev.yml -f docker-compose.app.yml up -d --build --wait
# or on an environment host after the pipeline deploy.
#
# Scenarios (each one injects a fault, observes, and repairs it):
#   1. Detection   - every container reports `healthy`; readiness answers 200.
#   2. Crash       - the auth process exits; the restart policy brings it back.
#   3. Dependency  - Redis stops; gateway turns `unhealthy` (detected) and returns
#                    to `healthy` on its own when Redis comes back, without restart.
#   4. Downstream  - promotion stops; dashboard keeps answering 200 with its fallback,
#                    the circuit breaker opens, and dashboard recovers afterwards.
#
# Usage: scripts/resilience-test.sh [host]      (default host: localhost)
# Exit code 0 only if every check passes. Needs bash, curl and docker.
# =============================================================================
set -uo pipefail

HOST="${1:-localhost}"
PASS=0
FAIL=0

AUTH=circleguard-auth-service
GATEWAY=circleguard-gateway-service
DASHBOARD=circleguard-dashboard-service
PROMOTION=circleguard-promotion-service
REDIS=circleguard-redis

APP_CONTAINERS=(circleguard-auth-service circleguard-identity-service circleguard-promotion-service
  circleguard-form-service circleguard-gateway-service circleguard-notification-service
  circleguard-file-service circleguard-dashboard-service circleguard-web)

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
ko()   { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
check() { if eval "$2"; then ok "$1"; else ko "$1"; fi; }

health()   { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null; }
restarts() { docker inspect -f '{{.RestartCount}}' "$1" 2>/dev/null; }
http_code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$1"; }

# wait_for <container> <status> <timeout-seconds>; prints the seconds it took
wait_for() {
  local c=$1 want=$2 timeout=$3 start=$SECONDS
  while (( SECONDS - start < timeout )); do
    [[ "$(health "$c")" == "$want" ]] && { echo $((SECONDS - start)); return 0; }
    sleep 2
  done
  echo $((SECONDS - start)); return 1
}

# ---------------------------------------------------------------------------
log "Scenario 1 - detection: every container is healthy"
for c in "${APP_CONTAINERS[@]}"; do
  check "$c is healthy" '[[ "$(health "$c")" == healthy ]]'
done
for port in 8180 8083 8088 8086 8087 8082 8085 8084; do
  code=$(http_code "http://$HOST:$port/actuator/health/readiness")
  check "readiness on :$port answers 200 (got $code)" '[[ "$code" == 200 ]]'
done
code=$(http_code "http://$HOST:8083/actuator/env")
check "only health is exposed (/actuator/env -> $code, not 200)" '[[ "$code" != 200 ]]'

# ---------------------------------------------------------------------------
log "Scenario 2 - crash: the auth process exits"
before=$(restarts $AUTH)
docker exec $AUTH sh -c 'kill -TERM 1' >/dev/null 2>&1
log "  auth killed (restarts before: $before); waiting for the restart policy"
t=$(wait_for $AUTH healthy 180); rc=$?
after=$(restarts $AUTH)
check "Docker restarted auth by itself (RestartCount $before -> $after)" '(( after > before ))'
check "auth is healthy again after ${t}s" '(( rc == 0 ))'

# ---------------------------------------------------------------------------
log "Scenario 3 - dependency failure: Redis stops (gateway depends on it)"
before=$(restarts $GATEWAY)
docker stop $REDIS >/dev/null
code=$(http_code "http://$HOST:8087/actuator/health/readiness")
log "  redis stopped; gateway readiness now answers $code"
check "gateway readiness reports the failure (503, got $code)" '[[ "$code" == 503 ]]'
code=$(http_code "http://$HOST:8087/actuator/health/liveness")
check "gateway liveness stays 200: the process is fine (got $code)" '[[ "$code" == 200 ]]'
t=$(wait_for $GATEWAY unhealthy 120); rc=$?
check "Docker marks gateway unhealthy after ${t}s" '(( rc == 0 ))'
docker start $REDIS >/dev/null
log "  redis started again"
t=$(wait_for $GATEWAY healthy 120); rc=$?
check "gateway is healthy again after ${t}s, on its own" '(( rc == 0 ))'
after=$(restarts $GATEWAY)
check "gateway recovered without a restart (RestartCount $before -> $after)" '(( after == before ))'

# ---------------------------------------------------------------------------
log "Scenario 4 - downstream failure: promotion stops (dashboard calls it)"
docker stop $PROMOTION >/dev/null
all200=true; slow=0
for i in $(seq 1 8); do
  start=$(date +%s%N)
  body=$(curl -s -m 15 -w '\n%{http_code}' "http://$HOST:8084/api/v1/analytics/summary")
  ms=$(( ($(date +%s%N) - start) / 1000000 ))
  code=${body##*$'\n'}
  [[ "$code" == 200 && "$body" == *"Service unavailable"* ]] || all200=false
  log "  call $i -> HTTP $code in ${ms} ms"
  last_ms=$ms
done
check "dashboard keeps answering 200 with the fallback" '$all200'
check "once the circuit is open the answer is immediate (${last_ms} ms < 500 ms)" '(( last_ms < 500 ))'
# Logs are captured first: with pipefail, `docker logs | grep -q` fails when grep exits
# early and docker logs receives SIGPIPE.
open_logs=$(docker logs --since 5m $DASHBOARD 2>&1 | grep -c "Circuit breaker 'promotion' is OPEN")
check "dashboard logs the open circuit ($open_logs answers served without calling promotion)" \
  '(( open_logs > 0 ))'
docker start $PROMOTION >/dev/null
log "  promotion started again; waiting until it is healthy"
t=$(wait_for $PROMOTION healthy 240); rc=$?
check "promotion is healthy again after ${t}s" '(( rc == 0 ))'
log "  waiting for the circuit to leave the open state (30 s)"
sleep 35
body=$(curl -s -m 15 "http://$HOST:8084/api/v1/analytics/summary")
check "dashboard serves real data again (no fallback)" '[[ -n "$body" && "$body" != *"Service unavailable"* ]]'

# ---------------------------------------------------------------------------
echo
log "Result: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
