#!/usr/bin/env bash
# Creates or updates the grafana-admin Secret used by Grafana (HU-27).
#
# The password is never written to the repository, to a file or to the command line:
#   - if GRAFANA_ADMIN_PASSWORD is set, that value is used;
#   - otherwise a random 32-character password is generated and shown once.
# Keep it in the team password manager (or as a Jenkins credential).
#
# Usage:
#   kubectl config use-context <cluster of the environment>
#   ./create-grafana-secret.sh                       # user "admin", random password
#   GRAFANA_ADMIN_USER=ops GRAFANA_ADMIN_PASSWORD='...' ./create-grafana-secret.sh
set -euo pipefail

NAMESPACE=circleguard-observability
SECRET=grafana-admin
ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"

command -v kubectl >/dev/null || { echo "kubectl is not installed"; exit 1; }

CONTEXT="$(kubectl config current-context)"
read -r -p "Create/update secret ${SECRET} in ${NAMESPACE} on context '${CONTEXT}'? [y/N] " answer
[ "$answer" = "y" ] || [ "$answer" = "Y" ] || { echo "Cancelled"; exit 1; }

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || {
  echo "Namespace ${NAMESPACE} does not exist. Apply the overlay first: kubectl apply -k infra/k8s/overlays/<env>"
  exit 1
}

GENERATED=false
if [ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
  GRAFANA_ADMIN_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
  GENERATED=true
fi
if [ "${#GRAFANA_ADMIN_PASSWORD}" -lt 12 ]; then
  echo "The password must have at least 12 characters"
  exit 1
fi

# The values go through a file descriptor, so they do not appear in the process list or in the
# shell history. "apply" makes the script safe to run again to rotate the password.
kubectl create secret generic "$SECRET" -n "$NAMESPACE" \
  --from-env-file=<(printf 'admin-user=%s\nadmin-password=%s\n' "$ADMIN_USER" "$GRAFANA_ADMIN_PASSWORD") \
  --dry-run=client -o yaml \
  | kubectl label --local -f - app.kubernetes.io/name=grafana app.kubernetes.io/part-of=circleguard -o yaml \
  | kubectl apply -f -

# Grafana reads the secret only when it starts
if kubectl get deployment grafana -n "$NAMESPACE" >/dev/null 2>&1; then
  kubectl rollout restart deployment/grafana -n "$NAMESPACE"
fi

echo "Secret ${SECRET} ready. User: ${ADMIN_USER}"
if [ "$GENERATED" = true ]; then
  echo "Generated password (shown only now, save it in the password manager):"
  echo "  ${GRAFANA_ADMIN_PASSWORD}"
fi
