# Configuración como código (Jenkins · SonarQube · Nexus)

Esta carpeta convierte lo que antes se hacía **a mano en las UIs** en archivos
versionados y scripts **idempotentes** (pueden correrse N veces sin romper nada).

```
infra/config-as-code/
├── .env.example                  # plantilla de credenciales (copiar a .env)
├── .env                          # ← SU USO LOCAL, ignorado por git
├── README.md                     # este archivo
├── jenkins/
│   ├── export-jenkins.sh         # exporta la config actual de Jenkins a YAML
│   └── jenkins.yaml              # JCasC generado (secretos como ${ENV:...})
└── sonarqube/
    └── configure-sonarqube.sh    # quality gate + webhook + proyecto (check-then-create)
```

Orquestador de todo (el "un comando" de la rúbrica):

```
infra/bootstrap-all.sh
```

## Puesta en marcha

```bash
# 1. Credenciales (una sola vez)
cp infra/config-as-code/.env.example infra/config-as-code/.env
$EDITOR infra/config-as-code/.env          # quedan en gitignore, nunca se suben

# 2. Dry-run: qué haría, sin tocar nada
./infra/bootstrap-all.sh --dry-run

# 3. La corrida real
./infra/bootstrap-all.sh
```

`bootstrap-all.sh` valida SSH, asegura Docker, levanta Jenkins + Nexus (cg-devops)
y SonarQube (cg-sonarqube), espera cada healthcheck y aplica la configuración de
SonarQube. Opciones:

| Opción | Efecto |
|---|---|
| `--dry-run` | muestra las acciones sin ejecutarlas |
| `--sync` | copia los `docker-compose.yml` del repo a las instancias |
| `--rebuild` | reconstruye las imágenes (`docker compose up -d --build`) |
| `--apply-jenkins` | aplica `jenkins.yaml` (ver nota abajo) |

## Jenkins como código (2 comandos)

```bash
# 1. Exporta la configuración ACTUAL de la instancia a YAML (solo lectura)
./infra/config-as-code/jenkins/export-jenkins.sh

# 2. Aplica credenciales + config del servidor (idempotente, SIN reiniciar)
./infra/config-as-code/jenkins/configure-jenkins.sh
./infra/config-as-code/jenkins/configure-jenkins.sh --dry-run
```

`configure-jenkins.sh` usa la API de Jenkins (check-then-create) y **no toca la
seguridad ni el usuario admin**:

| Elemento | Cómo |
|---|---|
| `nexus-credential` | creada si falta (usuario `ci-publisher` + `NEXUS_CI_PUBLISHER_PASSWORD`) |
| `sonarqube-token` | creada si falta; si no está en `.env` **se genera** con la API de SonarQube y se guarda en `.env` |
| `discord-webhook-url` | creada si falta, a partir de `DISCORD_WEBHOOK_URL` en `.env` (Secret text) |
| `git-credential` | solo si hay `GIT_USERNAME` / `GIT_PASSWORD` en `.env` (si no, `[WARN]`) |
| `ssh-deploy-dev/-stage/-prod` | **[MANUAL] a propósito** (decisión de seguridad: la llave SSH más sensible no se automatiza) → Manage Jenkins > Credentials |
| `location.url` | `http://<IP>:8080/` |
| GitHub `hookUrl` | `http://<IP>:8080/github-webhook/` |
| Instalación SonarQube | `CircleGuard-SonarQube` @ `SONARQUBE_URL` con credencial `sonarqube-token` |

> El `jenkins.yaml` sigue siendo el **export/referencia** de la configuración
> completa; aplicarlo (JCasC) es opcional y requiere reinicio — ver abajo.

```bash
./infra/config-as-code/jenkins/export-jenkins.sh      # escribe jenkins.yaml
./infra/config-as-code/jenkins/export-jenkins.sh --stdout
```

- **Solo lectura**: consulta `/manage/configuration-as-code/viewExport` y extrae el YAML.
- Los secretos cifrados por la instancia (`{AQAA...}`) se reemplazan por
  `${ENV:GIT_PASSWORD}`, `${ENV:SONARQUBE_TOKEN}`, `${ENV:DISCORD_WEBHOOK_URL}`,
  `${ENV:SSH_DEPLOY_*_KEY}`, etc.
  Así el archivo es portable y no lleva secretos versionados.
- **Aplicarlo es opcional y requiere reinicio**: montar `jenkins.yaml` en el
  contenedor y pasar las variables en `infra/bootstrap/jenkins/docker-compose.yml`:

```yaml
    environment:
      CASC_JENKINS_CONFIG: /var/jenkins_home/casc/jenkins.yaml
      GIT_PASSWORD: ${GIT_PASSWORD}          # ...resto de variables del YAML
    volumes:
      - ./../config-as-code/jenkins/jenkins.yaml:/var/jenkins_home/casc/jenkins.yaml:ro
```

> No se aplica automáticamente para no arriesgar la instancia en producción.

## SonarQube como código

```bash
./infra/config-as-code/sonarqube/configure-sonarqube.sh --dry-run
./infra/config-as-code/sonarqube/configure-sonarqube.sh
```

Garantiza que existan (crea solo lo que falta):

| Elemento | Valor deseado |
|---|---|
| Quality gate | `circle-guard` |
| Condiciones | `new_coverage ≥ 60`, `new_duplicated_lines_density ≤ 3`, `new_security_hotspots_reviewed ≥ 100`, `new_violations = 0` |
| Proyecto asociado | `circleGuard` |
| Webhook | `Jenkins-Webhook` → `http://10.20.1.230:8080/sonarqube-webhook/` |
| Seguridad | `sonar.forceAuthentication = true` |

## Evidencia de idempotencia

```text
$ ./configure-sonarqube.sh          # corrida 1
  [EXISTS] quality gate 'circle-guard' / condiciones (4) / proyecto / webhook / forceAuthentication
  Listo: 0 creación(es), 5 ya existente(s).

$ ./configure-sonarqube.sh          # corrida 2 -> idéntico
  Listo: 0 creación(es), 5 ya existente(s).
```

Prueba negativa (con una quality gate inexistente el script **sí crea** y asocia
el proyecto), y tras destruirla el script **recupera** la asociación a
`circle-guard` automáticamente.

## Reglas de secretos

- `infra/config-as-code/.env` está en `.gitignore` (verificado con `git check-ignore`).
- `jenkins.yaml` **no** contiene contraseñas: solo placeholders `${ENV:...}`.
- Nunca commitear `*.pem` ni passwords; las llaves SSH viven en `~/.ssh/` del operador.
