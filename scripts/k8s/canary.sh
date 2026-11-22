#!/usr/bin/env bash
# =============================================================================
# HU-30 - Canary release of the dashboard service with Traefik weights.
#
#   scripts/k8s/canary.sh start <image> [weight]   canary with <weight>% (default 10)
#   scripts/k8s/canary.sh weight <weight>          change the canary share
#   scripts/k8s/canary.sh promote                  roll the stable Deployment to the
#                                                  canary image and remove the canary
#   scripts/k8s/canary.sh abort                    send 100% back to stable, remove it
#   scripts/k8s/canary.sh status                   weights, images and pods
#
# start   copies the live stable Deployment (same config, probes and resources) as
#         circleguard-dashboard-service-canary with the new image, waits until it is
#         Ready and only then gives it traffic. If it never becomes Ready, it is
#         deleted and the stable version keeps 100% of the traffic.
# promote uses scripts/k8s/rollout.sh, so the stable pods are replaced without
#         downtime and rolled back automatically if the new version fails.
#
# Requires the component infra/k8s/components/canary-dashboard. Environment:
# NAMESPACE (default circleguard). Only kubectl and bash are needed.
# =============================================================================
set -euo pipefail

NS=${NAMESPACE:-circleguard}
STABLE_DEPLOY=circleguard-dashboard-service
CANARY_DEPLOY=circleguard-dashboard-service-canary
CANARY_INSTANCE=dashboard-canary
CONTAINER=dashboard-service
STABLE_SVC=dashboard
CANARY_SVC=dashboard-canary
PORT=8084
WEIGHTED=dashboard-weighted
TIMEOUT=${TIMEOUT:-180s}
HERE=$(cd "$(dirname "$0")" && pwd)

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }
k() { kubectl -n "$NS" "$@"; }
canary_exists() { k get deploy "$CANARY_DEPLOY" >/dev/null 2>&1; }
image_of() { k get deploy "$1" -o jsonpath="{.spec.template.spec.containers[?(@.name=='$CONTAINER')].image}"; }

set_weights() {
  local canary=$1 stable=$((100 - $1)) services
  if (( canary == 0 )); then
    services="[{\"name\":\"$STABLE_SVC\",\"port\":$PORT,\"weight\":100}]"
  else
    services="[{\"name\":\"$STABLE_SVC\",\"port\":$PORT,\"weight\":$stable},{\"name\":\"$CANARY_SVC\",\"port\":$PORT,\"weight\":$canary}]"
  fi
  k patch traefikservice "$WEIGHTED" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/weighted/services\",\"value\":$services}]" >/dev/null
  log "traffic: stable ${stable}% / canary ${canary}%"
}

# Traefik applies a new weight a moment after the patch; deleting the canary
# right away could send it a request while it shuts down.
remove_canary() {
  if canary_exists; then
    sleep "${DRAIN_SECONDS:-5}"
    k delete deploy "$CANARY_DEPLOY" >/dev/null
  fi
}

valid_weight() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 99 )) || die "weight must be 1-99, got '$1'"; }

start() {
  local image=$1 weight=${2:-10}
  valid_weight "$weight"
  canary_exists && die "a canary is already running; promote or abort it first"

  log "creating $CANARY_DEPLOY from the live $STABLE_DEPLOY with image $image"
  # Copy of the stable Deployment: new name, its own instance label (so the stable
  # Service does not select it), one replica and the new image. Server-generated
  # fields are dropped so it is created as a new object.
  k get deploy "$STABLE_DEPLOY" -o json \
    | kubectl patch --local -f - --type=json -o json -p "[
        {\"op\":\"replace\",\"path\":\"/metadata/name\",\"value\":\"$CANARY_DEPLOY\"},
        {\"op\":\"remove\",\"path\":\"/metadata/uid\"},
        {\"op\":\"remove\",\"path\":\"/metadata/resourceVersion\"},
        {\"op\":\"remove\",\"path\":\"/metadata/creationTimestamp\"},
        {\"op\":\"remove\",\"path\":\"/metadata/generation\"},
        {\"op\":\"remove\",\"path\":\"/status\"},
        {\"op\":\"add\",\"path\":\"/metadata/annotations\",\"value\":{\"kubernetes.io/change-cause\":\"canary.sh start $image\"}},
        {\"op\":\"add\",\"path\":\"/metadata/labels\",\"value\":{\"circleguard.io/track\":\"canary\"}},
        {\"op\":\"replace\",\"path\":\"/spec/replicas\",\"value\":1},
        {\"op\":\"add\",\"path\":\"/spec/selector/matchLabels/app.kubernetes.io~1instance\",\"value\":\"$CANARY_INSTANCE\"},
        {\"op\":\"add\",\"path\":\"/spec/template/metadata/labels/app.kubernetes.io~1instance\",\"value\":\"$CANARY_INSTANCE\"},
        {\"op\":\"add\",\"path\":\"/spec/template/metadata/labels/circleguard.io~1track\",\"value\":\"canary\"},
        {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"$image\"}
      ]" \
    | kubectl apply -f - >/dev/null

  if ! k rollout status deploy "$CANARY_DEPLOY" --timeout="$TIMEOUT"; then
    k delete deploy "$CANARY_DEPLOY" --wait=false >/dev/null
    die "the canary never became Ready; it was removed and stable keeps 100% of the traffic"
  fi
  set_weights "$weight"
  log "canary running: watch its errors and latency, then 'promote' or 'abort'"
}

weight() {
  valid_weight "$1"
  canary_exists || die "no canary is running"
  set_weights "$1"
}

promote() {
  canary_exists || die "no canary is running"
  local image
  image=$(image_of "$CANARY_DEPLOY")
  log "promoting $image: rolling update of the stable pods"
  if ! "$HERE/rollout.sh" dashboard "$image" "$TIMEOUT"; then
    abort
    die "the stable rollout failed and was rolled back; canary aborted"
  fi
  set_weights 0
  remove_canary
  log "promoted: stable runs $image with 100% of the traffic"
}

abort() {
  set_weights 0
  remove_canary
  log "aborted: stable keeps 100% of the traffic with $(image_of "$STABLE_DEPLOY")"
}

status() {
  echo "weights:"
  k get traefikservice "$WEIGHTED" \
    -o jsonpath='{range .spec.weighted.services[*]}  {.name}: {.weight}{"\n"}{end}'
  echo "stable: $(image_of "$STABLE_DEPLOY")"
  if canary_exists; then echo "canary: $(image_of "$CANARY_DEPLOY")"; else echo "canary: none"; fi
  k get pods -l app.kubernetes.io/name=circleguard-dashboard-service \
    -o custom-columns='POD:.metadata.name,TRACK:.metadata.labels.circleguard\.io/track,READY:.status.containerStatuses[0].ready,IMAGE:.spec.containers[0].image'
}

case "${1:-}" in
  start)   [[ $# -ge 2 ]] || die "usage: $0 start <image> [weight]"; start "$2" "${3:-10}" ;;
  weight)  [[ $# -ge 2 ]] || die "usage: $0 weight <weight>"; weight "$2" ;;
  promote) promote ;;
  abort)   abort ;;
  status)  status ;;
  *) echo "usage: $0 {start <image> [weight]|weight <n>|promote|abort|status}" >&2; exit 2 ;;
esac
