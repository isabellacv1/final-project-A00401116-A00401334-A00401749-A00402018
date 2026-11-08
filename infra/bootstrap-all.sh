#!/usr/bin/env bash
# ==============================================================================
# UN SOLO COMANDO para levantar y configurar toda la infraestructura de CI/CD.
#
#   ./infra/bootstrap-all.sh                 # levanta todo + aplica config SonarQube
#   ./infra/bootstrap-all.sh --dry-run       # muestra qué haría, sin tocar nada
#   ./infra/bootstrap-all.sh --sync          # copia los compose del repo a las instancias
#   ./infra/bootstrap-all.sh --rebuild       # reconstruye las imágenes (lento)
#   ./infra/bootstrap-all.sh --apply-jenkins # además aplica el jenkins.yaml (JCasC)
#
# Qué hace:
#   1. cg-devops     : Docker + Jenkins (8080) + Smee  + Nexus (8081)
#   2. cg-sonarqube  : SonarQube (9092)
#   3. Espera cada healthcheck / status UP
#   4. Aplica la configuración de SonarQube (idempotente, check-then-create)
#   5. (opcional) Aplica el jenkins.yaml de infra/config-as-code/jenkins
#
# Requiere: infra/config-as-code/.env (hosts, credenciales y llave SSH).
# Es idempotente: correrlo dos veces no cambia nada la segunda vez.
# ==============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_DIR}/infra/config-as-code/.env"

DRY_RUN=false; SYNC=false; REBUILD=false; APPLY_JENKINS=false
for arg in "$@"; do
    case "${arg}" in
        --dry-run)        DRY_RUN=true ;;
        --sync)           SYNC=true ;;
        --rebuild)        REBUILD=true ;;
        --apply-jenkins)  APPLY_JENKINS=true ;;
        -h|--help)        sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "[ERROR] Opción desconocida: ${arg} (use --help)"; exit 1 ;;
    esac
done

[[ -f "${ENV_FILE}" ]] || { echo "[ERROR] Falta ${ENV_FILE}. Copie .env.example y complete las credenciales."; exit 1; }
set -a; source "${ENV_FILE}"; set +a

: "${JENKINS_URL:?JENKINS_URL no definida en ${ENV_FILE}}"
: "${SONARQUBE_URL:?SONARQUBE_URL no definida en ${ENV_FILE}}"

# Hosts derivados de las URLs (se pueden pisar con CI_DEVOPS_HOST / CI_SONARQUBE_HOST)
host_of() { local u="${1#*://}"; u="${u%%/*}"; printf '%s' "${u%%:*}"; }
: "${CI_DEVOPS_HOST:=$(host_of "${JENKINS_URL}")}"
: "${CI_SONARQUBE_HOST:=$(host_of "${SONARQUBE_URL}")}"
: "${CI_SSH_USER:=ubuntu}"
: "${CI_SSH_KEY:=~/.ssh/cg-devops-key.pem}"
CI_SSH_KEY="${CI_SSH_KEY/#\~/${HOME}}"

log()  { echo; echo "==> $*"; }
info() { echo "    $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

run_remote() { # run_remote <host> <comando>
    local host="$1"; shift
    if [[ "${DRY_RUN}" == "true" ]]; then echo "    [DRY] ${host}: $*"; return 0; fi
    ssh -i "${CI_SSH_KEY}" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
        "${CI_SSH_USER}@${host}" "$@"
}

# Ejecuta un comando en la instancia solo si hace falta (evita recrear contenedores)
compose_up() { # compose_up <host> <directorio>
    local host="$1" dir="$2" build="${3:-}"
    run_remote "${host}" "cd ${dir} && docker compose up -d ${build} && docker compose ps --format '{{.Name}}\t{{.Status}}'"
}

wait_http() { # wait_http <host> <url> <intentos> <etiqueta>
    local host="$1" url="$2" tries="${3:-40}" label="${4:-servicio}"
    [[ "${DRY_RUN}" == "true" ]] && { echo "    [DRY] esperaría ${label} en ${url}"; return 0; }
    for ((i = 1; i <= tries; i++)); do
        if run_remote "${host}" "curl -fsS -o /dev/null --max-time 8 '${url}'" >/dev/null 2>&1; then
            echo "    [OK] ${label} responde (${i}/${tries})"; return 0
        fi
        sleep 5
    done
    die "${label} no respondió en ${tries} intentos: ${url}"
}

# ------------------------------------------------------------------------------
log "Validando acceso SSH"
[[ -f "${CI_SSH_KEY}" ]] || die "No existe la llave SSH: ${CI_SSH_KEY}"
run_remote "${CI_DEVOPS_HOST}" "echo 'devops OK: '\$(hostname)" >/dev/null
run_remote "${CI_SONARQUBE_HOST}" "echo 'sonarqube OK: '\$(hostname)" >/dev/null
info "cg-devops=${CI_DEVOPS_HOST}  cg-sonarqube=${CI_SONARQUBE_HOST}"

# 1. Docker en cg-devops -------------------------------------------------------
log "1/5 Docker en cg-devops"
if run_remote "${CI_DEVOPS_HOST}" "command -v docker >/dev/null && docker compose version >/dev/null"; then
    info "Docker ya instalado (idempotente)"
else
    info "Instalando Docker con scripts/install-docker.sh"
    if [[ "${DRY_RUN}" == "true" ]]; then echo "    [DRY] instalaría docker"; else
        ssh -i "${CI_SSH_KEY}" "${CI_SSH_USER}@${CI_DEVOPS_HOST}" 'bash -s' < "${REPO_DIR}/scripts/install-docker.sh"
    fi
fi

# 2. Sincronizar archivos (opcional) -------------------------------------------
if [[ "${SYNC}" == "true" ]]; then
    log "2/5 Sincronizando compose del repositorio"
    for svc in jenkins nexus sonarqube; do
        target_host="${CI_DEVOPS_HOST}"; [[ "${svc}" == "sonarqube" ]] && target_host="${CI_SONARQUBE_HOST}"
        if [[ "${DRY_RUN}" == "true" ]]; then echo "    [DRY] scp infra/bootstrap/${svc} -> ${target_host}:~/${svc}"; else
            ssh -i "${CI_SSH_KEY}" "${CI_SSH_USER}@${target_host}" "mkdir -p ~/${svc}"
            scp -q -i "${CI_SSH_KEY}" -r "${REPO_DIR}/infra/bootstrap/${svc}/." "${CI_SSH_USER}@${target_host}:~/${svc}/"
            info "${svc} sincronizado en ${target_host}"
        fi
    done
else
    log "2/5 Sincronización omitida (use --sync para copiar los compose del repo)"
fi

# 3. Levantar servicios --------------------------------------------------------
log "3/5 Levantando Jenkins + Nexus en cg-devops"
build_flag=""; [[ "${REBUILD}" == "true" ]] && build_flag="--build"
compose_up "${CI_DEVOPS_HOST}" "~/jenkins" "${build_flag}"
compose_up "${CI_DEVOPS_HOST}" "~/nexus"   ""

log "4/5 Levantando SonarQube en cg-sonarqube"
compose_up "${CI_SONARQUBE_HOST}" "~/sonarqube" ""

# 4. Esperar salud -------------------------------------------------------------
log "5/5 Esperando servicios"
wait_http "${CI_DEVOPS_HOST}" "http://localhost:8080/login" 40 "Jenkins"
wait_http "${CI_DEVOPS_HOST}" "http://localhost:8081/"      60 "Nexus"
wait_http "${CI_SONARQUBE_HOST}" "http://localhost:9092/api/system/status" 60 "SonarQube"

# 5. Aplicar configuración como código ----------------------------------------
log "Aplicando configuración de SonarQube (idempotente)"
if [[ "${DRY_RUN}" == "true" ]]; then
    "${REPO_DIR}/infra/config-as-code/sonarqube/configure-sonarqube.sh" --dry-run
else
    "${REPO_DIR}/infra/config-as-code/sonarqube/configure-sonarqube.sh"
fi

if [[ "${APPLY_JENKINS}" == "true" ]]; then
    log "Aplicando jenkins.yaml (JCasC)"
    die "Aplicar JCasC requiere montar jenkins.yaml + variables de entorno en infra/bootstrap/jenkins/docker-compose.yml (ver README). No lo hago automáticamente para no arriesgar la instancia."
fi

# ------------------------------------------------------------------------------
log "RESUMEN"
echo "    Jenkins    : http://${CI_DEVOPS_HOST}:8080"
echo "    Nexus      : http://${CI_DEVOPS_HOST}:8081"
echo "    SonarQube  : http://${CI_SONARQUBE_HOST}:9092"
echo "    Webhook    : http://${CI_DEVOPS_HOST}:8080/github-webhook/  (y /sonarqube-webhook/)"
echo
echo "    Evidencia  : ${REPO_DIR}/scripts/check-infrastructure.sh"
echo "    Listo. Este mismo comando puede correrse de nuevo sin efectos secundarios."
