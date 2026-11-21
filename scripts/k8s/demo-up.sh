#!/usr/bin/env bash
# =============================================================================
# HU-30 - Local k3d cluster to demonstrate the deployment patterns.
#
#   scripts/k8s/demo-up.sh      create the cluster and deploy the demo
#   scripts/k8s/demo-down.sh    delete it
#
# - k3s v1.37.2+k3s1, the version of the environments (infra/terraform/shared),
#   with its bundled Traefik; the HTTP entrypoint is published on localhost:8090.
# - Deploys infra/k8s/demo/deployment-patterns (base + rolling-update + canary).
# - Imports the local images circleguard/dashboard-service:1.0.0 and :1.1.0
#   (build them first with docker compose; 1.1.0 is a retag used as "new version").
# - Database passwords are generated here and stored only in the cluster.
# Requires: docker, k3d, kubectl.
# =============================================================================
set -euo pipefail

CLUSTER=${CLUSTER:-circleguard-demo}
K3S_IMAGE=rancher/k3s:v1.37.2-k3s1
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

for tool in docker k3d kubectl; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
docker image inspect circleguard/dashboard-service:1.0.0 >/dev/null \
  || { echo "build the image first: docker compose -f docker-compose.dev.yml -f docker-compose.app.yml build dashboard" >&2; exit 1; }
docker tag circleguard/dashboard-service:1.0.0 circleguard/dashboard-service:1.1.0

if ! k3d cluster list "$CLUSTER" >/dev/null 2>&1; then
  log "creating k3d cluster $CLUSTER ($K3S_IMAGE)"
  # The API is bound to 127.0.0.1 so kubectl does not depend on other network
  # adapters of the host (a VPN or virtual adapter dropping kills the watches).
  k3d cluster create "$CLUSTER" --image "$K3S_IMAGE" --agents 0 \
    --api-port 127.0.0.1:6550 -p "8090:80@loadbalancer" --wait --timeout 180s
fi
kubectl config use-context "k3d-$CLUSTER" >/dev/null

log "importing images"
k3d image import -c "$CLUSTER" circleguard/dashboard-service:1.0.0 circleguard/dashboard-service:1.1.0

log "waiting for the Traefik CRDs of k3s"
until kubectl get crd ingressroutes.traefik.io traefikservices.traefik.io >/dev/null 2>&1; do sleep 3; done

log "applying infra/k8s/demo/deployment-patterns"
kubectl apply -k "$ROOT/infra/k8s/demo/deployment-patterns" >/dev/null

log "creating demo credentials (random, only inside the cluster)"
DB_PASSWORD=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
kubectl -n circleguard-data create secret generic postgres-credentials \
  --from-literal=POSTGRES_USER=admin --from-literal=POSTGRES_PASSWORD="$DB_PASSWORD" \
  --from-literal=POSTGRES_DB=circleguard --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n circleguard create secret generic circleguard-dashboard-secret \
  --from-literal=SPRING_DATASOURCE_PASSWORD="$DB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "waiting for PostgreSQL and the dashboard"
kubectl -n circleguard-data rollout status statefulset/postgres --timeout=300s
kubectl -n circleguard rollout restart deploy/circleguard-dashboard-service >/dev/null
kubectl -n circleguard rollout status deploy/circleguard-dashboard-service --timeout=300s

code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8090/api/v1/analytics/summary)
log "ready: GET http://localhost:8090/api/v1/analytics/summary -> HTTP $code"
