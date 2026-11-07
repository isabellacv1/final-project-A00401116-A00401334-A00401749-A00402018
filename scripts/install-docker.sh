#!/usr/bin/env bash
# Instala Docker Engine + Compose plugin en Ubuntu 24.04 y crea un swapfile.
# Uso (en la instancia EC2):  bash install-docker.sh [GB_de_swap]
set -euo pipefail
SWAP_GB="${1:-2}"

sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release git

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"

# Swap: red de seguridad para instancias con poca RAM (Nexus / JVM)
if ! grep -q "^/swapfile" /proc/swaps; then
  sudo fallocate -l "${SWAP_GB}G" /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi

sudo docker --version && sudo docker compose version
echo ">> Cierre la sesion SSH y vuelva a conectarse para usar 'docker' sin sudo."
