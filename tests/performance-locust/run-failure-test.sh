#!/usr/bin/env bash
# Resilience test (HU-32): injects a failure while the platform is under load and records
# how the error rate and latency change, and how long it takes to recover.
#
# Usage:
#   TARGET_HOST=<ip> LOAD_PASSWORD=<pwd> \
#   FAILURE_CMD='<command that breaks a component>' \
#   RECOVERY_CMD='<command that restores it>' \
#   ./run-failure-test.sh
#
# Examples:
#   Docker Compose host:
#     FAILURE_CMD='ssh ubuntu@<ip> docker stop circleguard-redis'
#     RECOVERY_CMD='ssh ubuntu@<ip> docker start circleguard-redis'
#   Kubernetes:
#     FAILURE_CMD='kubectl -n circleguard-dev scale deploy/promotion --replicas=0'
#     RECOVERY_CMD='kubectl -n circleguard-dev scale deploy/promotion --replicas=1'
#
# Timeline (defaults): 2 min of normal load, 2 min with the failure, 3 min after recovery.
set -euo pipefail

cd "$(dirname "$0")"

: "${TARGET_HOST:?Set TARGET_HOST to the environment host or IP}"
: "${LOAD_PASSWORD:?Set LOAD_PASSWORD to the test user password}"
: "${FAILURE_CMD:?Set FAILURE_CMD to the command that injects the failure}"
: "${RECOVERY_CMD:?Set RECOVERY_CMD to the command that restores the component}"

USERS="${USERS:-30}"
RATE="${RATE:-5}"
BEFORE="${BEFORE_SECONDS:-120}"
DURING="${DURING_SECONDS:-120}"
AFTER="${AFTER_SECONDS:-180}"
TOTAL=$((BEFORE + DURING + AFTER))

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="results/failure-${STAMP}"
mkdir -p "$OUT"
TIMELINE="$OUT/timeline.txt"

log() { echo "$(date -u +%H:%M:%S) $*" | tee -a "$TIMELINE"; }

log "start: ${USERS} users for ${TOTAL}s against ${TARGET_HOST}"
log "failure: ${FAILURE_CMD}"
log "recovery: ${RECOVERY_CMD}"

# --csv-full-history keeps one row per interval, so the effect of the failure is visible over time
locust -f locustfile.py --headless \
  --users "$USERS" --spawn-rate "$RATE" --run-time "${TOTAL}s" \
  --csv "$OUT/stats" --csv-full-history --html "$OUT/report.html" \
  --only-summary > "$OUT/console.log" 2>&1 &
LOCUST_PID=$!

sleep "$BEFORE"
log "injecting failure"
bash -c "$FAILURE_CMD" >> "$TIMELINE" 2>&1 || log "failure command returned an error"

sleep "$DURING"
log "recovering"
bash -c "$RECOVERY_CMD" >> "$TIMELINE" 2>&1 || log "recovery command returned an error"

set +e
wait "$LOCUST_PID"
STATUS=$?
set -e
log "end (locust exit code ${STATUS}, non-zero is expected because of the injected failure)"

echo
echo "Results in ${OUT}/ (stats_stats_history.csv shows the error rate and latency over time)"
