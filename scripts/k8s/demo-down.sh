#!/usr/bin/env bash
# HU-30 - Deletes the local k3d demo cluster created by scripts/k8s/demo-up.sh.
set -euo pipefail
k3d cluster delete "${CLUSTER:-circleguard-demo}"
