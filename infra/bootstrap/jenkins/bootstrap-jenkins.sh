#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"

log() {
    echo "[JENKINS] $*"
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

# 1. Validar dependencias
command -v docker >/dev/null 2>&1 || error "Docker no está instalado."
docker compose version >/dev/null 2>&1 || error "Docker Compose no está disponible."
command -v curl >/dev/null 2>&1 || error "curl no está instalado."

# 2. Validar archivos
[[ -f "${COMPOSE_FILE}" ]] || error "No existe docker-compose.yml."
[[ -f "${ENV_EXAMPLE}" ]] || error "No existe .env.example."
[[ -f "${SCRIPT_DIR}/Dockerfile" ]] || error "No existe Dockerfile."
[[ -f "${SCRIPT_DIR}/plugins.txt" ]] || error "No existe plugins.txt."
[[ -f "${SCRIPT_DIR}/smee/Dockerfile" ]] || error "No existe smee/Dockerfile."

# 3. Preparar variables
if [[ ! -f "${ENV_FILE}" ]]; then
    log "Creando .env desde .env.example."
    cp "${ENV_EXAMPLE}" "${ENV_FILE}"
fi

set -a
source "${ENV_FILE}"
set +a

[[ -n "${SMEE_URL:-}" ]] || error "SMEE_URL no está configurada."
[[ "${SMEE_URL}" != *"REEMPLAZAR"* ]] || error "Configura tu canal de Smee en .env (SMEE_URL)."

DOCKER_SOCK="/var/run/docker.sock"

if [[ -S "${DOCKER_SOCK}" ]]; then
    DOCKER_GID="$(stat -c '%g' "${DOCKER_SOCK}")"
    [[ -n "${DOCKER_GID}" ]] || error "No se pudo determinar el GID de ${DOCKER_SOCK}."
else
    log "No existe ${DOCKER_SOCK}; se usará DOCKER_GID=${DOCKER_GID:-<vacío>} del .env."
    [[ -n "${DOCKER_GID:-}" ]] || error "DOCKER_GID no está definido en .env y no hay docker.sock."
fi

export DOCKER_GID

# 4. Validar Compose
log "Validando configuración."

docker compose \
    --project-directory "${SCRIPT_DIR}" \
    --env-file "${ENV_FILE}" \
    config -q

# 5. Construir imágenes
log "Construyendo imágenes de Jenkins y Smee."

docker compose \
    --project-directory "${SCRIPT_DIR}" \
    --env-file "${ENV_FILE}" \
    build

# 6. Desplegar
log "Iniciando Jenkins y Smee Client."

docker compose \
    --project-directory "${SCRIPT_DIR}" \
    --env-file "${ENV_FILE}" \
    up -d

# 7. Esperar disponibilidad de Jenkins
log "Esperando disponibilidad de Jenkins."

MAX_ATTEMPTS=60
ATTEMPT=0

until curl -fsS http://127.0.0.1:${JENKINS_PORT:-8080}/login >/dev/null 2>&1; do
    ATTEMPT=$((ATTEMPT + 1))

    echo "[JENKINS] Esperando... ${ATTEMPT}/${MAX_ATTEMPTS}"

    if [[ "${ATTEMPT}" -ge "${MAX_ATTEMPTS}" ]]; then
        error "Jenkins no respondió. Revisa docker compose logs jenkins."
    fi

    sleep 5
done

log "Jenkins está disponible."

# 8. Mostrar contraseña inicial
if docker exec jenkins test -f /var/jenkins_home/secrets/initialAdminPassword; then
    echo
    echo "============================================"
    echo " JENKINS DESPLEGADO CORRECTAMENTE"
    echo "============================================"
    echo "Usuario inicial: admin"
    echo "Contraseña inicial:"
    docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
else
    log "Jenkins posiblemente ya fue configurado."
fi

echo
log "Interfaz: http://<IP-PRIVADA-CG-DEVOPS>:${JENKINS_PORT:-8080}"
log "Logs Jenkins: docker logs -f jenkins"
log "Logs Smee: docker logs -f smee-client"
