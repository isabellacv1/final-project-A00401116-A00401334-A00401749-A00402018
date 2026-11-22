#!/usr/bin/env bash
# =============================================================================
# HU-30 - Rolling Update with automatic rollback for a CircleGuard service.
#
#   scripts/k8s/rollout.sh <service> <image> [timeout]
#   scripts/k8s/rollout.sh dashboard 10.20.1.230:8082/circleguard/dashboard-service:1.2.0
#
# 1. Updates the image of Deployment circleguard-<service>-service. Kubernetes
#    replaces the pods one at a time (strategy from infra/k8s/components/rolling-update):
#    a new pod must be Ready before an old one is removed, so there is no downtime.
# 2. Waits until the rollout finishes (`kubectl rollout status`).
# 3. If the new version does not become Ready in time, runs `kubectl rollout undo`:
#    the previous ReplicaSet, which was never scaled down, serves traffic again.
#
# Exit code: 0 when the new version is live, 1 when it was rolled back.
# Environment: NAMESPACE (default circleguard), KUBECONFIG/context as usual.
# =============================================================================
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <service> <image> [timeout, default 180s]" >&2
  exit 2
fi

SERVICE=$1
IMAGE=$2
TIMEOUT=${3:-180s}
NS=${NAMESPACE:-circleguard}
DEPLOY="circleguard-${SERVICE}-service"
CONTAINER="${SERVICE}-service"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
image_of() {
  kubectl -n "$NS" get deploy "$DEPLOY" \
    -o jsonpath="{.spec.template.spec.containers[?(@.name=='$CONTAINER')].image}"
}

previous=$(image_of)
log "$DEPLOY: $previous -> $IMAGE"

# The change cause is copied to the new ReplicaSet, so `kubectl rollout history`
# shows which image each revision deployed.
kubectl -n "$NS" annotate deploy "$DEPLOY" --overwrite \
  kubernetes.io/change-cause="rollout.sh $IMAGE" >/dev/null
kubectl -n "$NS" set image deploy "$DEPLOY" "$CONTAINER=$IMAGE" >/dev/null

if kubectl -n "$NS" rollout status deploy "$DEPLOY" --timeout="$TIMEOUT"; then
  log "OK: $DEPLOY runs $(image_of)"
  exit 0
fi

log "FAILED: $IMAGE did not become Ready within $TIMEOUT; rolling back"
kubectl -n "$NS" rollout undo deploy "$DEPLOY" >/dev/null
# Without this the restored revision keeps the change cause of the failed image.
kubectl -n "$NS" annotate deploy "$DEPLOY" --overwrite \
  kubernetes.io/change-cause="rollout.sh rollback from $IMAGE" >/dev/null
kubectl -n "$NS" rollout status deploy "$DEPLOY" --timeout="$TIMEOUT"
log "ROLLED BACK: $DEPLOY runs $(image_of) again"
exit 1
