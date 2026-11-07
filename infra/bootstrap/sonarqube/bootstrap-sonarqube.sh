
#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Bootstrap SonarQube - CircleGuard
# Universidad Icesi - Ingeniería de Software V
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

log() {
    echo -e "\n[INFO] $1"
}

error() {
    echo -e "\n[ERROR] $1" >&2
    exit 1
}

# 1. Validar dependencias
log "Verificando dependencias..."

command -v docker >/dev/null 2>&1 \
    || error "Docker no está instalado."

docker compose version >/dev/null 2>&1 \
    || error "Docker Compose plugin no está instalado."

command -v curl >/dev/null 2>&1 \
    || error "curl no está instalado."

command -v grep >/dev/null 2>&1 \
    || error "grep no está instalado."

[[ -f "${COMPOSE_FILE}" ]] \
    || error "No se encontró docker-compose.yml."

docker info >/dev/null 2>&1 \
    || error "No se puede acceder al Docker Engine."

# 2. Configurar requisitos del kernel
log "Configurando requisitos de Elasticsearch..."

SYSCTL_FILE="/etc/sysctl.d/99-sonarqube.conf"

sudo tee "${SYSCTL_FILE}" >/dev/null <<EOF
vm.max_map_count=524288
fs.file-max=131072
EOF

sudo sysctl --system >/dev/null

# Verificar valores efectivos
MAP_COUNT="$(sysctl -n vm.max_map_count)"
FILE_MAX="$(sysctl -n fs.file-max)"

[[ "${MAP_COUNT}" -ge 524288 ]] \
    || error "vm.max_map_count no cumple el requisito."

[[ "${FILE_MAX}" -ge 131072 ]] \
    || error "fs.file-max no cumple el requisito."

log "Requisitos del kernel verificados."

# 3. Validar configuración Compose
log "Validando Docker Compose..."

docker compose -f "${COMPOSE_FILE}" config -q \
    || error "La configuración de Docker Compose no es válida."

# 4. Descargar imagen y desplegar SonarQube
log "Descargando imagen de SonarQube..."

docker compose -f "${COMPOSE_FILE}" pull \
    || error "No se pudo descargar la imagen."

log "Iniciando SonarQube..."

docker compose -f "${COMPOSE_FILE}" up -d \
    || error "No se pudo iniciar SonarQube."

# 5. Esperar disponibilidad
log "Esperando que SonarQube esté operativo..."

MAX_ATTEMPTS=150
ATTEMPT=0
SONAR_URL="http://127.0.0.1:9092/api/system/status"

while [[ "${ATTEMPT}" -lt "${MAX_ATTEMPTS}" ]]; do

    RESPONSE="$(curl -fsS "${SONAR_URL}" 2>/dev/null || true)"

    if echo "${RESPONSE}" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"UP"'; then
        log "SonarQube está operativo."
        break
    fi

    ATTEMPT=$((ATTEMPT + 1))
    sleep 2
done

# 6. Resultado
if [[ "${ATTEMPT}" -eq "${MAX_ATTEMPTS}" ]]; then
    echo "[ERROR] SonarQube no alcanzó el estado UP."
    echo "[INFO] Últimos registros del contenedor:"
    docker logs --tail 80 sonarqube
    exit 1
fi

echo
echo "============================================================"
echo " SonarQube desplegado correctamente"
echo "============================================================"
echo " URL local: http://localhost:9092"
echo " Puerto interno: 9000"
echo " Contenedor: sonarqube"
echo
echo " Para consultar los registros:"
echo " docker logs -f sonarqube"
echo
echo " Credenciales iniciales:"
echo " Usuario: admin"
echo " Contraseña: admin"
echo
echo " IMPORTANTE: cambia la contraseña en el primer ingreso."
echo "============================================================"
