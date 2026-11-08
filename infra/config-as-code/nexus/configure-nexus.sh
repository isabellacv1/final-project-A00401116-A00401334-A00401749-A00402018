#!/usr/bin/env bash
# ==============================================================================
# Nexus como código: crea SOLO lo que falta (patrón check-then-create).
# Idempotente: puede ejecutarse N veces; si algo ya existe, lo reporta y no toca.
#
# Configuración declarada (la que se hizo a mano en la UI):
#   - Repositorio : docker-hosted (docker/hosted)
#   - Rol         : role-ci-publisher   (maven releases/snapshots/public-read,
#                                        raw-releases y docker-hosted)
#   - Rol         : role-deploy-reader  (read + browse sobre maven-releases y
#                                        raw-releases; nunca escritura)
#   - Usuarios    : ci-publisher  -> role-ci-publisher
#                   deploy-reader -> role-deploy-reader
#
# Uso:
#   ./configure-nexus.sh            # aplica
#   ./configure-nexus.sh --dry-run  # qué haría, sin modificar nada
#
# Requiere: infra/config-as-code/.env (ver .env.example), curl y python3.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

[[ -f "${ENV_FILE}" ]] || { echo "[ERROR] Falta ${ENV_FILE}. Copie .env.example y complete las credenciales."; exit 1; }
set -a; source "${ENV_FILE}"; set +a

: "${NEXUS_URL:?NEXUS_URL no definida}"
: "${NEXUS_USER:?NEXUS_USER no definida}"
: "${NEXUS_PASSWORD:?NEXUS_PASSWORD no definida}"

CREATED=0; EXISTED=0; WARNED=0
log()  { echo "[nexus] $*"; }
ok()   { echo "  [OK]      $*"; EXISTED=$((EXISTED + 1)); }
make() { echo "  [CREATE]  $*"; CREATED=$((CREATED + 1)); }
warn() { echo "  [WARN]    $*"; WARNED=$((WARNED + 1)); }

BASE="${NEXUS_URL%/}/service/rest/v1"
AUTH=(-u "${NEXUS_USER}:${NEXUS_PASSWORD}")

# json_get <ruta> <expr-python sobre 'd'>  -> imprime el resultado (sin comas:
# se usa para tests de pertenencia con grep, por eso se une con espacios)
json_get() {
    curl -sS --max-time 30 "${AUTH[@]}" "$1" 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: d=None
try: print(eval(sys.argv[1]))
except Exception: print('')
" "$2"
}

# request <GET|POST|PUT> <ruta> [curl args...] -> código HTTP en stdout
request() {
    local method="$1" path="$2"; shift 2
    curl -sS --max-time 30 "${AUTH[@]}" -X "${method}" "${BASE}/${path}" "$@" 2>/dev/null -o /tmp/nexus-api-body -w "%{http_code}" || true
}

post_json() { # post_json <ruta> <json>
    local code
    code=$(request POST "$1" -H 'Content-Type: application/json' -d "$2")
    if [[ "${code}" =~ ^2 ]]; then return 0; fi
    echo "  [FAIL]    HTTP ${code} en POST /$1: $(head -c 200 /tmp/nexus-api-body)" >&2
    return 1
}

run() { if [[ "${DRY_RUN}" == "true" ]]; then echo "  [DRY]     $*"; else eval "$@"; fi; }

# ------------------------------------------------------------------------------
log "Autenticando contra ${NEXUS_URL}"
CODE=$(request GET "status")
[[ "${CODE}" =~ ^2 ]] || { echo "[ERROR] Nexus no responde (HTTP ${CODE}). ¿Está levantado?"; exit 1; }

# 1. Repositorios -------------------------------------------------------------
log "Repositorios"
REPOS=$(json_get "${BASE}/repositories" "' '.join(r['name'] for r in d)")

ensure_repo() { # ensure_repo <nombre> <formato> <tipo> <json-cuerpo>
    local name="$1" fmt="$2" type="$3" body="$4"
    if echo " ${REPOS} " | grep -q " ${name} "; then
        ok "repositorio '${name}' (${fmt}/${type})"
    else
        make "repositorio '${name}' (${fmt}/${type})"
        run "post_json 'repositories/${fmt}/${type}' '${body}'"
    fi
}

ensure_repo "docker-hosted" "docker" "hosted" \
    '{"name":"docker-hosted","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":true,"writePolicy":"ALLOW"},"docker":{"v1Enabled":false,"forceBasicAuth":false,"forceCreation":false}}'

ensure_repo "raw-releases" "raw" "hosted" \
    '{"name":"raw-releases","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":true,"writePolicy":"ALLOW"}}'

# Se reconsulta para reflejar lo recién creado antes de validar el resto.
REPOS=$(json_get "${BASE}/repositories" "' '.join(r['name'] for r in d)")

# Estos no se crean aquí (se asumen parte del setup de Nexus): si faltan, avisan.
for repo in maven-releases maven-snapshots maven-public; do
    echo " ${REPOS} " | grep -q " ${repo} " || warn "el repositorio '${repo}' no existe (los privilegios del rol quedarían sin efecto)"
done

# 2. Roles --------------------------------------------------------------------
log "Roles"
# /security/roles devuelve un ARRAY (no un objeto con clave "roles")
ROLES=$(json_get "${BASE}/security/roles" "' '.join(r['id'] for r in (d if isinstance(d,list) else d.get('roles',[])))")

ensure_role() { # ensure_role <id> <privilegios-json>
    local id="$1" privs="$2" body
    body=$(python3 -c "
import json,sys
print(json.dumps({'id':sys.argv[1],'name':sys.argv[1],'description':'Rol de CircleGuard (config-as-code)','privileges':json.loads(sys.argv[2]),'roles':[]}))
" "${id}" "${privs}")
    if echo " ${ROLES} " | grep -q " ${id} "; then
        ok "rol '${id}'"
    else
        make "rol '${id}'"
        run "post_json 'security/roles' '${body}'"
    fi
}

CI_PUBLISHER_PRIVS='[
  "nx-repository-view-maven2-maven-releases-*",
  "nx-repository-view-maven2-maven-snapshots-*",
  "nx-repository-view-maven2-maven-public-read",
  "nx-repository-view-raw-raw-releases-*",
  "nx-repository-view-docker-docker-hosted-*"
]'

DEPLOY_READER_PRIVS='[
  "nx-repository-view-maven2-maven-releases-read",
  "nx-repository-view-maven2-maven-releases-browse",
  "nx-repository-view-raw-raw-releases-read",
  "nx-repository-view-raw-raw-releases-browse"
]'

ensure_role "role-ci-publisher"  "${CI_PUBLISHER_PRIVS}"
ensure_role "role-deploy-reader" "${DEPLOY_READER_PRIVS}"

# 3. Usuarios -----------------------------------------------------------------
log "Usuarios"
# /security/users devuelve un ARRAY de usuarios
USERS=$(json_get "${BASE}/security/users" "' '.join(u['userId'] for u in (d if isinstance(d,list) else d.get('users',[])))")

ensure_user() { # ensure_user <userId> <firstName> <lastName> <password-var> <rol>
    local id="$1" first="$2" last="$3" pass_var="$4" role="$5" pass body current
    if echo " ${USERS} " | grep -q " ${id} "; then
        ok "usuario '${id}' (rol ${role})"
        # Asegura el rol aunque el usuario ya exista
        # GET /security/users/{userId} no existe (405): se leen los roles desde
        # la lista completa de usuarios.
        current=$(json_get "${BASE}/security/users" \
            "str([r for u in (d if isinstance(d,list) else []) if u.get('userId')=='${id}' for r in u.get('roles',[])])")
        if echo "${current}" | grep -q "${role}"; then
            ok "  '${id}' ya tiene el rol '${role}'"
        else
            make "  asignar rol '${role}' a '${id}'"
            run "request PUT 'security/users/${id}/roles' -H 'Content-Type: application/json' -d '{\"roles\":[\"${role}\"]}' >/dev/null"
        fi
        return 0
    fi
    pass="${!pass_var:-}"
    [[ -n "${pass}" ]] || { warn "usuario '${id}' no existe y falta ${pass_var} en .env (no se crea)"; return 0; }
    # Contraseña = usuario: se permite (no bloquea) pero se avisa.
    if [[ "${pass}" == "${id}" ]]; then
        warn "la contraseña de '${id}' es igual al usuario (débil) - ${pass_var}"
    fi
    body=$(python3 -c "
import json,sys
print(json.dumps({'userId':sys.argv[1],'firstName':sys.argv[2],'lastName':sys.argv[3],
 'emailAddress':sys.argv[4],'password':sys.argv[5],'status':'active','roles':[sys.argv[6]]}))
" "${id}" "${first}" "${last}" "${id}@circleguard.local" "${pass}" "${role}")
    make "usuario '${id}' con rol '${role}'"
    run "post_json 'security/users' '${body}'"
}

ensure_user "ci-publisher"  "CI"      "Publisher" "NEXUS_CI_PUBLISHER_PASSWORD"  "role-ci-publisher"
ensure_user "deploy-reader" "Deploy"  "Reader"    "NEXUS_DEPLOY_READER_PASSWORD" "role-deploy-reader"

# ------------------------------------------------------------------------------
echo
if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY-RUN: no se modificó nada."
else
    log "Listo: ${CREATED} creación(es), ${EXISTED} ya existente(s), ${WARNED} advertencia(s)."
fi
log "Verificación:"
echo "  curl -u \$NEXUS_USER:\$NEXUS_PASSWORD \$NEXUS_URL/service/rest/v1/security/roles | python3 -m json.tool"
