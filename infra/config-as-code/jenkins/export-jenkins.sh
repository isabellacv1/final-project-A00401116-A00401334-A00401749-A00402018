#!/usr/bin/env bash
# ==============================================================================
# Exporta la configuración ACTUAL de Jenkins a código (JCasC / jenkins.yaml).
#
#   ./export-jenkins.sh            # escribe jenkins.yaml
#   ./export-jenkins.sh --stdout   # imprime en pantalla
#
# Es SOLO LECTURA: no modifica Jenkins.  Los secretos cifrados por la instancia
# se reemplazan por placeholders ${ENV:...}, de modo que el archivo puede
# versionarse y aplicarse en una instancia nueva.
#
# Requiere: infra/config-as-code/.env (ver .env.example) y curl + python3.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
OUT_FILE="${SCRIPT_DIR}/jenkins.yaml"
MODE="file"
[[ "${1:-}" == "--stdout" ]] && MODE="stdout"

[[ -f "${ENV_FILE}" ]] || { echo "[ERROR] Falta ${ENV_FILE}. Copie .env.example y complete las credenciales."; exit 1; }
set -a; source "${ENV_FILE}"; set +a

: "${JENKINS_URL:?JENKINS_URL no definida}"
: "${JENKINS_USER:?JENKINS_USER no definida}"
: "${JENKINS_PASSWORD:?JENKINS_PASSWORD no definida}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "[jenkins] Autenticando contra ${JENKINS_URL} como ${JENKINS_USER}"
CODE=$(curl -sS -o "${TMP}/who.json" -w "%{http_code}" --max-time 30 \
    -u "${JENKINS_USER}:${JENKINS_PASSWORD}" "${JENKINS_URL}/whoAmI/api/json") || true
[[ "${CODE}" == "200" ]] || { echo "[ERROR] Autenticación fallida (HTTP ${CODE})."; exit 1; }

echo "[jenkins] Obteniendo el crumb"
CRUMB=$(curl -sS --max-time 30 -u "${JENKINS_USER}:${JENKINS_PASSWORD}" -c "${TMP}/jar" \
    "${JENKINS_URL}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)")

echo "[jenkins] Exportando configuración (JCasC)"
CODE=$(curl -sS -o "${TMP}/export.html" -w "%{http_code}" --max-time 120 \
    -u "${JENKINS_USER}:${JENKINS_PASSWORD}" -b "${TMP}/jar" -H "${CRUMB}" \
    -X POST "${JENKINS_URL}/manage/configuration-as-code/viewExport") || true
[[ "${CODE}" == "200" ]] || { echo "[ERROR] Exportación fallida (HTTP ${CODE})."; exit 1; }

echo "[jenkins] Limpiando secretos y generando jenkins.yaml"
python3 - "${TMP}/export.html" "${TMP}/jenkins.yaml" <<'PY'
import html, re, sys

src, dst = sys.argv[1], sys.argv[2]
raw = open(src, encoding="utf-8", errors="replace").read()

m = re.search(r'<pre><code class="language-yaml">(.*?)</code></pre>', raw, re.S)
if not m:
    sys.exit("[ERROR] No se encontró el YAML dentro de la respuesta de Jenkins.")
yaml = html.unescape(m.group(1))

# Los valores {AQAA...} son secretos cifrados con la clave de ESTA instancia:
# no sirven en otra y no deben versionarse.  Se reemplazan por placeholders.
PLACEHOLDERS = {
    "git-credential":        ("username", "${ENV:GIT_USERNAME}",           "password", "${ENV:GIT_PASSWORD}"),
    "nexus-credential":      ("username", "${ENV:NEXUS_PUBLISHER_USERNAME}", "password", "${ENV:NEXUS_PUBLISHER_PASSWORD}"),
    "sonarqube-token":       (None, None,                                  "secret",   "${ENV:SONARQUBE_TOKEN}"),
    "discord-webhook-url":   (None, None,                                  "secret",   "${ENV:DISCORD_WEBHOOK_URL}"),
}
SSH_KEY_ENV = {"ssh-deploy-dev": "${ENV:SSH_DEPLOY_DEV_KEY}",
               "ssh-deploy-stage": "${ENV:SSH_DEPLOY_STAGE_KEY}",
               "ssh-deploy-prod": "${ENV:SSH_DEPLOY_PROD_KEY}"}

lines, current_id, changed = [], None, 0
for line in yaml.splitlines():
    id_match = re.match(r'^(\s*)id:\s*"([^"]+)"\s*$', line)
    if id_match:
        current_id = id_match.group(2)

    if current_id in PLACEHOLDERS and re.match(r'^\s*(password|secret):\s*"\{AQAA', line):
        key, _, field, placeholder = PLACEHOLDERS[current_id]
        indent = re.match(r'^(\s*)', line).group(1)
        line = f'{indent}{field}: "{placeholder}"'
        changed += 1
    elif current_id in SSH_KEY_ENV and re.match(r'^\s*privateKey:\s*"\{AQAA', line):
        indent = re.match(r'^(\s*)', line).group(1)
        line = f'{indent}privateKey: "{SSH_KEY_ENV[current_id]}"'
        changed += 1

    lines.append(line)

header = (
    "# ==============================================================================\n"
    "# Jenkins como código (JCasC) - EXPORTADO AUTOMÁTICAMENTE desde la instancia\n"
    "#   ./infra/config-as-code/jenkins/export-jenkins.sh\n"
    "# Los secretos se referencian con ${ENV:...}: definirlos en el contenedor de\n"
    "# Jenkins (ver infra/bootstrap/jenkins/docker-compose.yml) antes de aplicar.\n"
    "# ==============================================================================\n"
)
open(dst, "w", encoding="utf-8").write(header + "\n".join(lines) + "\n")
print(f"    secretos reemplazados por placeholders: {changed}")
PY

if [[ "${MODE}" == "stdout" ]]; then
    cat "${TMP}/jenkins.yaml"
else
    cp "${TMP}/jenkins.yaml" "${OUT_FILE}"
    echo "[jenkins] Escrito: ${OUT_FILE} ($(wc -l < "${OUT_FILE}") líneas)"
    echo "[jenkins] Para aplicarlo (requiere reinicio): vea README.md"
fi
