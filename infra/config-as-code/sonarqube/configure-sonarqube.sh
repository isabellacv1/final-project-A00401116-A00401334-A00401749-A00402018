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
: "${SONARQUBE_PROJECT_KEY:=CircleGuard}"
: "${SONARQUBE_WEBHOOK_NAME:=Jenkins-Webhook}"
: "${SONARQUBE_WEBHOOK_URL:=http://10.20.1.230:8080/sonarqube-webhook/}"

CREATED=0
UNCHANGED=0

log()  { echo "[sonarqube] $*"; }
ok()   { echo "  [OK]      $*"; }
skip() { echo "  [EXISTS]  $*"; UNCHANGED=$((UNCHANGED + 1)); }
make() { echo "  [CREATE]  $*"; CREATED=$((CREATED + 1)); }
warn() { echo "  [WARN]    $*"; UNCHANGED=$((UNCHANGED + 1)); }

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

# SonarQube tarda varios minutos en la primera puesta en marcha (indexa
# Elasticsearch): se espera el estado UP antes de tocar cualquier cosa.
WAIT_UP="${SONARQUBE_WAIT_SECONDS:-180}"
log "Esperando estado UP (máximo ${WAIT_UP}s)"
STATUS=""
for ((i = 1; i <= WAIT_UP; i += 5)); do
    STATUS=$(api "system/status" || true)
    if echo "${STATUS}" | grep -q '"status":"UP"'; then
        log "SonarQube está UP (esperado ${i}s)"
        break
    fi
    if (( i % 30 == 0 )); then
        echo "    ...estado actual: $(echo "${STATUS}" | grep -o '"status":"[A-Z]*"' || echo 'sin respuesta')"
    fi
    sleep 5
done

if ! echo "${STATUS}" | grep -q '"status":"UP"'; then
    echo "[ERROR] SonarQube no llegó a UP en ${WAIT_UP}s. Última respuesta: ${STATUS}" >&2
    echo "        Nada fue modificado. Revise los logs y vuelva a ejecutar este script." >&2
    exit 1
fi

# 1. Quality gate -------------------------------------------------------------
log "Quality gate: ${SONARQUBE_QUALITY_GATE}"
if api "qualitygates/list" | grep -q "\"name\":\"${SONARQUBE_QUALITY_GATE}\""; then
    skip "quality gate '${SONARQUBE_QUALITY_GATE}'"
else
    make "quality gate '${SONARQUBE_QUALITY_GATE}'"
    run "post 'qualitygates/create?name=${SONARQUBE_QUALITY_GATE}'"
fi

# 2. Condiciones (solo si la gate quedó sin condiciones) ----------------------
CONDITIONS=$(api "qualitygates/show?name=${SONARQUBE_QUALITY_GATE}" 2>/dev/null || echo '{}')
COND_COUNT=$(python3 -c "
import json,sys
try: print(len(json.load(sys.stdin).get('conditions',[])))
except Exception: print(0)
" <<< "${CONDITIONS}" 2>/dev/null || echo 0)

if [[ "${COND_COUNT}" -gt 0 ]]; then
    skip "condiciones ya definidas (${COND_COUNT})"
else
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
fi

# 3. Proyecto asociado a la gate ---------------------------------------------
# En una instancia nueva todavía no existe el proyecto: se crea con el primer
# análisis, así que esto no debe abortar el script.
PROJ_TOTAL=$(api "projects/search?projects=${SONARQUBE_PROJECT_KEY}" 2>/dev/null | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('paging',{}).get('total',0))
except Exception: print(0)
" 2>/dev/null || echo 0)

if [[ "${PROJ_TOTAL}" == "0" ]]; then
    warn "el proyecto '${SONARQUBE_PROJECT_KEY}' no existe aún (se asociará tras el primer análisis)"
else
    ASSOC=$(api "qualitygates/get_by_project?project=${SONARQUBE_PROJECT_KEY}" 2>/dev/null || echo '{}')
    if echo "${ASSOC}" | grep -q "\"name\":\"${SONARQUBE_QUALITY_GATE}\""; then
        skip "proyecto '${SONARQUBE_PROJECT_KEY}' asociado a '${SONARQUBE_QUALITY_GATE}'"
    else
        make "asociar '${SONARQUBE_PROJECT_KEY}' a '${SONARQUBE_QUALITY_GATE}'"
        run "post 'qualitygates/select?gateName=${SONARQUBE_QUALITY_GATE}&projectKey=${SONARQUBE_PROJECT_KEY}'"
    fi
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
