#!/usr/bin/env bash
# Runs the CircleGuard load test (HU-32) without the web UI and saves the results.
#
# Usage:
#   TARGET_HOST=<ip> LOAD_PASSWORD=<pwd> ./run-load-test.sh [profile]
#
# Profiles (users / spawn rate per second / duration):
#   smoke    5 users,  1/s,  1 min   quick check that the scenarios work
#   load    50 users,  5/s,  5 min   expected campus peak (default)
#   stress 200 users, 10/s,  5 min   beyond the expected peak, to find the limit
set -euo pipefail

cd "$(dirname "$0")"

PROFILE="${1:-load}"
case "$PROFILE" in
  smoke)  USERS=5;   RATE=1;  DURATION=1m ;;
  load)   USERS=50;  RATE=5;  DURATION=5m ;;
  stress) USERS=200; RATE=10; DURATION=5m ;;
  *) echo "Unknown profile: $PROFILE (smoke | load | stress)"; exit 2 ;;
esac

: "${TARGET_HOST:?Set TARGET_HOST to the environment host or IP}"
: "${LOAD_PASSWORD:?Set LOAD_PASSWORD to the test user password}"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="results/${PROFILE}-${STAMP}"
mkdir -p "$OUT"

echo "Profile ${PROFILE}: ${USERS} users, ${RATE}/s, ${DURATION} against ${TARGET_HOST}"
echo "Results in ${OUT}/"

set +e
locust -f locustfile.py --headless \
  --users "$USERS" --spawn-rate "$RATE" --run-time "$DURATION" \
  --csv "$OUT/stats" --html "$OUT/report.html" \
  --only-summary 2>&1 | tee "$OUT/console.log"
STATUS=${PIPESTATUS[0]}
set -e

echo
if [ "$STATUS" -eq 0 ]; then
  echo "All objectives met."
else
  echo "Some objectives were not met (see the Objectives section above)."
fi
exit "$STATUS"
