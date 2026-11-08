#!/usr/bin/env bash
# ==============================================================================
# SonarQube como código: crea SOLO lo que falta (patrón check-then-create).
# Idempotente: puede ejecutarse N veces; si algo ya existe, lo reporta y no toca.
#
# Uso:
#   ./configure-sonarqube.sh            # aplica (solo lectura + creación faltante)
#   ./configure-sonarqube.sh --dry-run  # qué haría, sin modificar nada
#
# Requiere: infra/config-as-code/.env (ver .env.example) y curl + python3.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

[[ -f "${ENV_FILE}" ]] || { echo "[ERROR] Falta ${ENV_FILE}. Copie .env.example y complete las credenciales."; exit 1; }
set -a; source "${ENV_FILE}"; set +a

: "${SONARQUBE_URL:?SONARQUBE_URL no definida}"
: "${SONARQUBE_USER:?SONARQUBE_USER no definida}"
: "${SONARQUBE_PASSWORD:?SONARQUBE_PASSWORD no definida}"
: "${SONARQUBE_QUALITY_GATE:=circle-guard}"
: "${SONARQUBE_PROJECT_KEY:=circleGuard}"
: "${SONARQUBE_WEBHOOK_NAME:=Jenkins-Webhook}"
: "${SONARQUBE_WEBHOOK_URL:=http://10.20.1.22:8080/sonarqube-webhook/}"

CREATED=0
UNCHANGED=0

log()  { echo "[sonarqube] $*"; }
ok()   { echo "  [OK]      $*"; }
skip() { echo "  [EXISTS]  $*"; UNCHANGED=$((UNCHANGED + 1)); }
make() { echo "  [CREATE]  $*"; CREATED=$((CREATED + 1)); }

# api <ruta>  -> imprime el body (tolerante a 4xx: sirve para consultar)
api() {
    curl -sS --max-time 30 -u "${SONARQUBE_USER}:${SONARQUBE_PASSWORD}" "${SONARQUBE_URL}/api/$1"
}

# post <ruta> [args...]  -> POST estricto: falla si el servidor no responde 2xx
post() {
    local path="$1"; shift
    local out code
    out="$(mktemp)"
    code="$(curl -sS --max-time 30 -o "${out}" -w "%{http_code}" \
        -u "${SONARQUBE_USER}:${SONARQUBE_PASSWORD}" \
        -X POST "${SONARQUBE_URL}/api/${path}" "$@" 2>/dev/null || echo 000)"
    if [[ ! "${code}" =~ ^2 ]]; then
        echo "  [FAIL]    HTTP ${code} en POST /api/${path}: $(head -c 200 "${out}")" >&2
        rm -f "${out}"
        return 1
    fi
    rm -f "${out}"
}

run() {
    if [[ "${DRY_RUN}" == "true" ]]; then echo "  [DRY]     $*"; else eval "$@"; fi
}

# ------------------------------------------------------------------------------
log "Autenticando contra ${SONARQUBE_URL}"
STATUS=$(api "system/status" || true)
echo "${STATUS}" | grep -q '"status":"UP"' || { echo "[ERROR] SonarQube no responde UP: ${STATUS}"; exit 1; }

# 1. Quality gate -------------------------------------------------------------
log "Quality gate: ${SONARQUBE_QUALITY_GATE}"
if api "qualitygates/list" | grep -q "\"name\":\"${SONARQUBE_QUALITY_GATE}\""; then
    skip "quality gate '${SONARQUBE_QUALITY_GATE}'"
else
    make "quality gate '${SONARQUBE_QUALITY_GATE}'"
    run "post 'qualitygates/create?name=${SONARQUBE_QUALITY_GATE}'"
fi

# 2. Condiciones (solo si la gate está vacía) ---------------------------------
CONDITIONS=$(api "qualitygates/show?name=${SONARQUBE_QUALITY_GATE}" 2>/dev/null || echo '{}')
if echo "${CONDITIONS}" | grep -q '"conditions":\[.\]'; then
    make "condiciones de la quality gate"
    for cond in \
        "new_coverage|LT|60" \
        "new_duplicated_lines_density|GT|3" \
        "new_security_hotspots_reviewed|LT|100" \
        "new_violations|GT|0"; do
        IFS='|' read -r metric op error <<< "${cond}"
        run "post 'qualitygates/create_condition?gateName=${SONARQUBE_QUALITY_GATE}&metric=${metric}&op=${op}&error=${error}'"
        echo "            - ${metric} ${op} ${error}"
    done
else
    skip "condiciones ya definidas ($(echo "${CONDITIONS}" | python3 -c 'import json,sys;print(len(json.load(sys.stdin).get("conditions",[])))' 2>/dev/null || echo '?'))"
fi

# 3. Proyecto asociado a la gate ---------------------------------------------
ASSOC=$(api "qualitygates/get_by_project?project=${SONARQUBE_PROJECT_KEY}" 2>/dev/null || echo '{}')
if echo "${ASSOC}" | grep -q "\"name\":\"${SONARQUBE_QUALITY_GATE}\""; then
    skip "proyecto '${SONARQUBE_PROJECT_KEY}' asociado a '${SONARQUBE_QUALITY_GATE}'"
else
    make "asociar '${SONARQUBE_PROJECT_KEY}' a '${SONARQUBE_QUALITY_GATE}'"
    run "post 'qualitygates/select?gateName=${SONARQUBE_QUALITY_GATE}&projectKey=${SONARQUBE_PROJECT_KEY}'"
fi

# 4. Webhook hacia Jenkins ----------------------------------------------------
if api "webhooks/list" | grep -q "\"name\":\"${SONARQUBE_WEBHOOK_NAME}\""; then
    skip "webhook '${SONARQUBE_WEBHOOK_NAME}'"
else
    make "webhook '${SONARQUBE_WEBHOOK_NAME}' -> ${SONARQUBE_WEBHOOK_URL}"
    run "post \"webhooks/create?name=${SONARQUBE_WEBHOOK_NAME}&url=${SONARQUBE_WEBHOOK_URL}\""
fi

# 5. Seguridad: exigir autenticación ------------------------------------------
if api "settings/values?keys=sonar.forceAuthentication" | grep -q '"value":"true"'; then
    skip "sonar.forceAuthentication=true"
else
    make "sonar.forceAuthentication=true"
    run "post 'settings/set?key=sonar.forceAuthentication&value=true'"
fi

# ------------------------------------------------------------------------------
echo
if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY-RUN: no se modificó nada."
else
    log "Listo: ${CREATED} creación(es), ${UNCHANGED} ya existente(s)."
    log "Verificación:"
    echo "  curl -u \$SONARQUBE_USER:\$SONARQUBE_PASSWORD \$SONARQUBE_URL/api/qualitygates/show?name=${SONARQUBE_QUALITY_GATE}"
fi
