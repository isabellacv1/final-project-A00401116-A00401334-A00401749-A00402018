#!/usr/bin/env bash
# ==============================================================================
# Jenkins como código, por API (sin reiniciar y SIN tocar la seguridad/usuario):
#
#   Credenciales : git-credential, nexus-credential, sonarqube-token,
#                  discord-webhook-url,
#                  ssh-deploy-dev / ssh-deploy-stage / ssh-deploy-prod
#   Config       : location.url, hook de GitHub, instalación de SonarQube
#
# Idempotente: solo crea lo que falta; lo existente se reporta como [EXISTS].
#
# Uso:
#   ./configure-jenkins.sh            # aplica
#   ./configure-jenkins.sh --dry-run  # qué haría, sin modificar nada
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

: "${JENKINS_URL:?JENKINS_URL no definida}"
: "${JENKINS_USER:?JENKINS_USER no definida}"
: "${JENKINS_PASSWORD:?JENKINS_PASSWORD no definida}"

CREATED=0; EXISTED=0; WARNED=0
log()  { echo "[jenkins] $*"; }
ok()   { echo "  [EXISTS]  $*"; EXISTED=$((EXISTED + 1)); }
make() { echo "  [CREATE]  $*"; CREATED=$((CREATED + 1)); }
warn() { echo "  [WARN]    $*"; WARNED=$((WARNED + 1)); }

BASE="${JENKINS_URL%/}"
JAR="$(mktemp)"; trap 'rm -f "${JAR}" /tmp/jenkins-api-body /tmp/jenkins-cred.xml' EXIT
AUTH=(-u "${JENKINS_USER}:${JENKINS_PASSWORD}")

crumb() {
    curl -sS --max-time 20 "${AUTH[@]}" -c "${JAR}" \
        "${BASE}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)"
}

# post_xml <ruta> <archivo-xml>  -> HTTP 2xx/3xx = ok
post_xml() {
    local code
    code=$(curl -sS --max-time 30 -o /tmp/jenkins-api-body -w "%{http_code}" \
        "${AUTH[@]}" -b "${JAR}" -H "$(crumb)" -H 'Content-Type: application/xml' \
        -X POST "${BASE}/$1" --data-binary "@$2" 2>/dev/null || echo 000)
    if [[ "${code}" =~ ^[23] ]]; then return 0; fi
    echo "  [FAIL]    HTTP ${code} en POST /$1: $(head -c 200 /tmp/jenkins-api-body)" >&2
    return 1
}

# groovy <scripta>  -> imprime la salida del script console (recortada en errores)
groovy() {
    local out
    out=$(curl -sS --max-time 60 -o /tmp/jenkins-api-body -w "\n__HTTP__%{http_code}" \
        "${AUTH[@]}" -b "${JAR}" -H "$(crumb)" -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode "script=$1" "${BASE}/scriptText" 2>/dev/null || echo "__HTTP__000")
    local code="${out##*__HTTP__}"
    if [[ "${code}" =~ ^2 ]]; then
        # Éxito: se muestra tal cual (corto).
        head -c 2000 /tmp/jenkins-api-body
    else
        # Error: solo la primera línea del fallo, no el stack trace completo.
        echo "  [FAIL]    script console HTTP ${code}: $(grep -m1 -E 'ERROR|Exception|unable to resolve' /tmp/jenkins-api-body || head -c 200 /tmp/jenkins-api-body)" >&2
        return 1
    fi
}

run() { if [[ "${DRY_RUN}" == "true" ]]; then echo "  [DRY]     $*"; else eval "$@"; fi; }

# ------------------------------------------------------------------------------
log "Autenticando contra ${JENKINS_URL}"
CODE=$(curl -sS -o /tmp/jenkins-api-body -w "%{http_code}" --max-time 30 "${AUTH[@]}" "${BASE}/whoAmI/api/json" || echo 000)
[[ "${CODE}" == "200" ]] || { echo "[ERROR] Autenticación fallida (HTTP ${CODE})."; exit 1; }

# 0. Token de SonarQube (si no está en .env se genera y se guarda) -------------
: "${SONARQUBE_URL:=}"
: "${SONARQUBE_USER:=admin}"
: "${SONARQUBE_PASSWORD:=}"
if [[ -z "${SONARQUBE_TOKEN:-}" && -n "${SONARQUBE_URL}" && -n "${SONARQUBE_PASSWORD}" ]]; then
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "  [DRY]     generaría un token de SonarQube para el usuario ${SONARQUBE_USER}"
    else
        TOKEN_JSON=$(curl -sS --max-time 30 -u "${SONARQUBE_USER}:${SONARQUBE_PASSWORD}" \
            -X POST "${SONARQUBE_URL}/api/user_tokens/generate?name=jenkins&login=${SONARQUBE_USER}" 2>/dev/null || true)
        SONARQUBE_TOKEN=$(printf '%s' "${TOKEN_JSON}" | python3 -c "import json,sys;print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)
        if [[ -n "${SONARQUBE_TOKEN}" ]]; then
            grep -q '^SONARQUBE_TOKEN=' "${ENV_FILE}" \
                && sed -i "s|^SONARQUBE_TOKEN=.*|SONARQUBE_TOKEN=${SONARQUBE_TOKEN}|" "${ENV_FILE}" \
                || printf '\n# Token generado para Jenkins (instalación SonarQube)\nSONARQUBE_TOKEN=%s\n' "${SONARQUBE_TOKEN}" >> "${ENV_FILE}"
            log "Token de SonarQube generado y guardado en $(basename "${ENV_FILE}")"
        else
            warn "no se pudo generar el token de SonarQube (se omitirá la credencial sonarqube-token)"
        fi
    fi
fi

# 1. Credenciales --------------------------------------------------------------
log "Credenciales"
# El endpoint .../domain/_/api/json es un DomainWrapper: el tree correcto es
# credentials[id] (NO stores[...], que devuelve vacío).  -g evita que curl
# interprete los corchetes como globbing.
EXISTING_IDS=$(curl -sS -g --max-time 30 "${AUTH[@]}" \
    "${BASE}/credentials/store/system/domain/_/api/json?tree=credentials[id]" 2>/dev/null \
    | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(' '.join(c.get('id','') for c in d.get('credentials',[])))
except Exception: print('')
")

has_credential() { echo " ${EXISTING_IDS} " | grep -q " $1 "; }

# xml_credential <tipo> <id> <campo> <valor> ...  -> imprime el XML.
# Los campos se pasan como pares (no como JSON) para que python haga el escape:
# así contraseñas con comillas/ampersands o llaves con saltos de línea no rompen.
xml_credential() {
    python3 - "$@" <<'PY'
import sys, xml.sax.saxutils as x
kind, cid = sys.argv[1], sys.argv[2]
rest = sys.argv[3:]
fields = {rest[i]: rest[i + 1] for i in range(0, len(rest), 2)}
esc = x.escape

if kind == "userpass":
    xml = ('<com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>'
           f'<scope>GLOBAL</scope><id>{esc(cid)}</id>'
           f'<description>{esc(fields.get("description",""))}</description>'
           f'<username>{esc(fields["username"])}</username>'
           f'<password>{esc(fields["password"])}</password>'
           '</com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>')
elif kind == "secret":
    xml = ('<org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl>'
           f'<scope>GLOBAL</scope><id>{esc(cid)}</id>'
           f'<description>{esc(fields.get("description",""))}</description>'
           f'<secret>{esc(fields["secret"])}</secret>'
           '</org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl>')
elif kind == "sshkey":
    xml = ('<com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey>'
           f'<scope>GLOBAL</scope><id>{esc(cid)}</id>'
           f'<description>{esc(fields.get("description",""))}</description>'
           f'<username>{esc(fields["username"])}</username>'
           '<privateKeySource class="com.cloudbees.jenkins.plugins.sshcredentials.impl.'
           'BasicSSHUserPrivateKey$DirectEntryPrivateKeySource">'
           f'<privateKey>{esc(fields["privateKey"])}</privateKey>'
           '</privateKeySource>'
           '</com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey>')
else:
    sys.exit("tipo desconocido: " + kind)
print(xml)
PY
}

ensure_credential() { # ensure_credential <tipo> <id> <campo> <valor> ...
    local kind="$1" cid="$2"; shift 2
    if has_credential "${cid}"; then ok "credencial '${cid}'"; return 0; fi
    # El XML se escribe en un archivo: nunca pasa por eval.
    xml_credential "${kind}" "${cid}" "$@" > /tmp/jenkins-cred.xml
    make "credencial '${cid}'"
    run "post_xml 'credentials/store/system/domain/_/createCredentials' /tmp/jenkins-cred.xml"
}

GIT_USERNAME="${GIT_USERNAME:-}"
GIT_PASSWORD="${GIT_PASSWORD:-}"
if [[ -n "${GIT_USERNAME}" && -n "${GIT_PASSWORD}" ]]; then
    ensure_credential userpass "git-credential" \
        username "${GIT_USERNAME}" password "${GIT_PASSWORD}" \
        description "Credencial para clonar el repositorio (GitHub)"
else
    warn "falta GIT_USERNAME / GIT_PASSWORD en .env -> se omite 'git-credential'"
fi

NEXUS_PUBLISHER_USERNAME="${NEXUS_PUBLISHER_USERNAME:-ci-publisher}"
NEXUS_PUBLISHER_PASSWORD="${NEXUS_PUBLISHER_PASSWORD:-${NEXUS_CI_PUBLISHER_PASSWORD:-}}"
if [[ -n "${NEXUS_PUBLISHER_PASSWORD}" ]]; then
    ensure_credential userpass "nexus-credential" \
        username "${NEXUS_PUBLISHER_USERNAME}" password "${NEXUS_PUBLISHER_PASSWORD}" \
        description "Usuario de Nexus que publica artefactos"
else
    warn "falta NEXUS_PUBLISHER_PASSWORD / NEXUS_CI_PUBLISHER_PASSWORD en .env -> se omite 'nexus-credential'"
fi

if [[ -n "${SONARQUBE_TOKEN:-}" ]]; then
    ensure_credential secret "sonarqube-token" \
        secret "${SONARQUBE_TOKEN}" \
        description "Token de SonarQube para el job"
else
    warn "SONARQUBE_TOKEN vacío -> se omite 'sonarqube-token'"
fi

DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
if [[ -n "${DISCORD_WEBHOOK_URL}" && "${DISCORD_WEBHOOK_URL}" != "REEMPLAZAR" ]]; then
    ensure_credential secret "discord-webhook-url" \
        secret "${DISCORD_WEBHOOK_URL}" \
        description "Webhook de Discord para notificaciones de fallo del pipeline"
else
    warn "falta DISCORD_WEBHOOK_URL en .env -> se omite 'discord-webhook-url'"
fi

# Usuario de la aplicación que usan las pruebas E2E (Playwright) — HU-14.
E2E_USERNAME="${E2E_USERNAME:-}"
E2E_PASSWORD="${E2E_PASSWORD:-}"
if [[ -n "${E2E_USERNAME}" && -n "${E2E_PASSWORD}" && "${E2E_PASSWORD}" != "REEMPLAZAR" ]]; then
    ensure_credential userpass "e2e-credential" \
        username "${E2E_USERNAME}" password "${E2E_PASSWORD}" \
        description "Usuario de la aplicación para las pruebas E2E (Playwright)"
else
    warn "falta E2E_USERNAME / E2E_PASSWORD en .env -> se omite 'e2e-credential'"
fi

# Las llaves SSH NO se automatizan a propósito: es una decisión de seguridad
# (el secreto más sensible vive solo en el admin de Jenkins y en ~/.ssh del operador).
echo "  [MANUAL]  ssh-deploy-dev / ssh-deploy-stage / ssh-deploy-prod"
echo "            -> Manage Jenkins > Credentials > System > Global credentials"
echo "               (SSH Username with private key, id: ssh-deploy-*, usuario: ubuntu)"

# 2. Configuración del servidor ------------------------------------------------
log "Configuración del servidor"
JENKINS_PUBLIC_URL="${JENKINS_URL%/}"
SONAR_PRIVATE_URL="${SONARQUBE_WEBHOOK_URL%%/sonarqube-webhook*}"
SONAR_PRIVATE_URL="${SONAR_PRIVATE_URL:-${SONARQUBE_URL}}"
SONAR_SERVER_URL="${SONARQUBE_URL:-}"

CONFIG_OUT=$(groovy "
import jenkins.model.*
import jenkins.model.JenkinsLocationConfiguration
def out = []
def want = '${JENKINS_PUBLIC_URL}/'

try {
    def loc = JenkinsLocationConfiguration.get()
    if (loc.url != want) { loc.url = want; loc.save(); out << \"location.url -> \${want}\" }
    else out << 'location.url ya correcto'
} catch (e) { out << 'location.url ERROR: ' + e.message }

try {
    def cfgs = Jenkins.instance.getExtensionList('org.jenkinsci.plugins.github.config.GitHubPluginConfig')
    if (cfgs) {
        def cfg = cfgs[0]
        def wantHook = want + 'github-webhook/'
        def current = cfg.metaClass.respondsTo(cfg, 'getHookUrl') ? cfg.hookUrl : null
        if (current != wantHook) {
            cfg.metaClass.setProperty(cfg, 'hookUrl', wantHook)
            cfg.save()
            out << \"GitHub hookUrl -> \${wantHook}\"
        } else out << 'GitHub hookUrl ya correcto'
    } else out << 'GitHub plugin no disponible'
} catch (e) { out << 'GitHub hookUrl ERROR: ' + e.message }

def wantSonar = '${SONAR_SERVER_URL}'
if (wantSonar) {
  try {
    def g = Jenkins.instance.getExtensionList('hudson.plugins.sonar.SonarGlobalConfiguration')[0]
    def name = 'CircleGuard-SonarQube'
    def existing = (g.installations ?: []).find { it.name == name }
    def values = [name: name, serverUrl: wantSonar, credentialsId: 'sonarqube-token',
                  triggers: new hudson.plugins.sonar.model.TriggersConfig()]
    if (existing && existing.serverUrl == wantSonar && existing.credentialsId == 'sonarqube-token') {
        out << 'instalación SonarQube ya correcta'
    } else {
        // Se elige el constructor que expone serverUrl + credentialsId (el
        // @DataBoundConstructor) y se rellena por NOMBRE de parámetro (la clase
        // está compilada con -parameters): lo que no se declara queda en null.
        def cl = hudson.plugins.sonar.SonarInstallation
        def ctor = cl.getDeclaredConstructors().findAll { c ->
            def ns = c.getParameters().collect { p -> p.name }
            ns.contains('serverUrl') && ns.contains('credentialsId')
        }.max { c -> c.parameterCount }
        if (ctor == null) throw new IllegalStateException('constructor de SonarInstallation no encontrado')
        def names = ctor.getParameters().collect { p -> p.name }
        def args = names.collect { values.containsKey(it) ? values[it] : null }
        def inst = ctor.newInstance(args.toArray() as Object[])
        def list = (g.installations ?: []).findAll { it.name != name }
        list << inst
        g.installations = list as hudson.plugins.sonar.SonarInstallation[]
        g.save()
        def check = (g.installations ?: []).find { it.name == name }
        out << \"instalación SonarQube -> \${check.name} @ \${check.serverUrl} (credencial: \${check.credentialsId})\"
    }
  } catch (e) { out << 'SonarQube ERROR: ' + e.message }
}

out.join('\n')
" || true)

if [[ "${DRY_RUN}" == "true" ]]; then
    echo "  [DRY]     aplicaría location.url, GitHub hookUrl y la instalación SonarQube"
else
    echo "${CONFIG_OUT}" | sed 's/^/  [OK]      /'
fi

# ------------------------------------------------------------------------------
echo
if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY-RUN: no se modificó nada."
else
    log "Listo: ${CREATED} creación(es), ${EXISTED} ya existente(s), ${WARNED} advertencia(s)."
fi
log "Verificación:"
echo "  curl -g -u \$JENKINS_USER:\$JENKINS_PASSWORD \$JENKINS_URL/credentials/store/system/domain/_/api/json?tree=credentials[id]"
