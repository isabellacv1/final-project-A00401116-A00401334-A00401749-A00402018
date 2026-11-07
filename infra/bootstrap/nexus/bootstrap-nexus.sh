
#!/usr/bin/env bash

# Despliega Nexus Repository mediante Docker Compose.
# Uso: ./bootstrap-nexus.sh

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"

log() {
    echo "[NEXUS] $*"
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

# 1. Validar dependencias
command -v docker >/dev/null 2>&1 || error "Docker no está instalado."
docker compose version >/dev/null 2>&1 || error "Docker Compose no está disponible."

# 2. Validar archivos
[[ -f "${COMPOSE_FILE}" ]] || error "No existe docker-compose.yml."
[[ -f "${ENV_EXAMPLE}" ]] || error "No existe .env.example."

# 3. Preparar configuración
if [[ ! -f "${ENV_FILE}" ]]; then
    log "Creando .env desde .env.example."
    cp "${ENV_EXAMPLE}" "${ENV_FILE}"
fi

# 4. Validar Compose
log "Validando configuración."

docker compose \
    --project-directory "${SCRIPT_DIR}" \
    --env-file "${ENV_FILE}" \
    -f "${COMPOSE_FILE}" \
    config -q || error "Configuración de Docker Compose inválida."

# 5. Descargar imagen
log "Descargando imagen de Nexus."

docker compose \
    --project-directory "${SCRIPT_DIR}" \
    --env-file "${ENV_FILE}" \
    -f "${COMPOSE_FILE}" \
    pull

# 6. Desplegar
log "Iniciando Nexus Repository."

docker compose \
    --project-directory "${SCRIPT_DIR}" \
    --env-file "${ENV_FILE}" \
    -f "${COMPOSE_FILE}" \
    up -d

# 7. Verificar contenedor
CONTAINER_ID="$(
    docker compose \
        --project-directory "${SCRIPT_DIR}" \
        --env-file "${ENV_FILE}" \
        -f "${COMPOSE_FILE}" \
        ps -q nexus
)"

[[ -n "${CONTAINER_ID}" ]] || error "No se encontró el contenedor."

log "Nexus fue desplegado. Esperando disponibilidad..."

# 8. Esperar a que Nexus responda
MAX_ATTEMPTS=60
ATTEMPT=0

until curl -fsS http://127.0.0.1:8081/ >/dev/null 2>&1; do

    ATTEMPT=$((ATTEMPT + 1))

    if [[ "${ATTEMPT}" -ge "${MAX_ATTEMPTS}" ]]; then
        error "Nexus no respondió después de esperar 5 minutos. Revisa: docker logs nexus"
    fi

    sleep 5
done

log "Nexus Repository está disponible."

# 9. Mostrar contraseña inicial si todavía existe
if docker exec nexus test -f /nexus-data/admin.password; then
    echo
    echo "============================================"
    echo " NEXUS DESPLEGADO CORRECTAMENTE"
    echo "============================================"
    echo "Usuario inicial: admin"
    echo "Contraseña inicial:"

    docker exec nexus cat /nexus-data/admin.password

    echo
    echo "IMPORTANTE: cambia esta contraseña y guárdala"
    echo "en un gestor de secretos."
else
    log "No existe contraseña inicial. Nexus posiblemente ya fue configurado."
fi

echo
log "Interfaz: http://<IP-PUBLICA-CG-DEVOPS>:8081"
log "Logs: docker logs -f nexus"
