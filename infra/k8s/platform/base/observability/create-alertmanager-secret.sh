#!/usr/bin/env bash
# Creates or updates the alertmanager-discord Secret with the Discord webhook URL that
# Alertmanager uses to send the alerts (HU-27). The URL is a credential: it is never stored in
# the repository, in a file or on the command line.
#
# Usage:
#   kubectl config use-context <cluster of the environment>
#   ./create-alertmanager-secret.sh                 # asks for the URL (input not echoed)
#   DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/...' ./create-alertmanager-secret.sh
set -euo pipefail

NAMESPACE=circleguard-observability
SECRET=alertmanager-discord

command -v kubectl >/dev/null || { echo "kubectl is not installed"; exit 1; }

CONTEXT="$(kubectl config current-context)"
read -r -p "Create/update secret ${SECRET} in ${NAMESPACE} on context '${CONTEXT}'? [y/N] " answer
[ "$answer" = "y" ] || [ "$answer" = "Y" ] || { echo "Cancelled"; exit 1; }

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || {
  echo "Namespace ${NAMESPACE} does not exist. Apply the platform first: kubectl apply -k infra/k8s/platform/overlays/<env>"
  exit 1
}

if [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
  read -r -s -p "Discord webhook URL: " DISCORD_WEBHOOK_URL
  echo
fi
case "$DISCORD_WEBHOOK_URL" in
  https://discord.com/api/webhooks/*|https://discordapp.com/api/webhooks/*) ;;
  *) echo "That is not a Discord webhook URL"; exit 1 ;;
esac

# The value goes through a file descriptor, so it does not appear in the process list
kubectl create secret generic "$SECRET" -n "$NAMESPACE" \
  --from-file=webhook-url=<(printf '%s' "$DISCORD_WEBHOOK_URL") \
  --dry-run=client -o yaml \
  | kubectl label --local -f - app.kubernetes.io/name=alertmanager app.kubernetes.io/part-of=circleguard -o yaml \
  | kubectl apply -f -

# Alertmanager reads the file at start; restart it so a new URL is used
if kubectl get deployment alertmanager -n "$NAMESPACE" >/dev/null 2>&1; then
  kubectl rollout restart deployment/alertmanager -n "$NAMESPACE"
fi

echo "Secret ${SECRET} ready."
