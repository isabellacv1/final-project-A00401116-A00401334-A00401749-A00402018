# Configuración externa por ambiente 

Este documento justifica y prueba cómo CircleGuard cambia el comportamiento de sus servicios por
ambiente sin reconstruir las imágenes. La operación del despliegue está en
[`despliegue.md`](despliegue.md).

> **Estado:** implementado y medido. Los ocho servicios, los compose de aplicación y las
> credenciales del middleware leen su configuración del entorno; la suite de pruebas pasa y la
> sección 8 registra la medición con la misma imagen.

## 1. Propósito

Una misma imagen Docker debe desplegarse en `dev`, `stage` y `prod` cambiando **solo** la
configuración que recibe al ejecutarse. Se cierran tres problemas existentes:

1. **Secretos en texto plano**: `jwt.secret`, `qr.secret`, `vault.secret`, `vault.salt`,
   `vault.hash-salt` y las contraseñas de PostgreSQL, Neo4j y LDAP están escritas en los
   repositorios y en los compose (limitación reconocida en [`docs/README.md`](../README.md)).
2. **Valores por ambiente mezclados con literales**: URLs públicas, nivel de logs, expiración de
   tokens y credenciales.
3. **Falta de evidencia** de que un cambio de configuración altere el comportamiento usando la
   misma imagen.

Alcance: los ocho servicios Spring Boot, la app web, los compose de aplicación y las
credenciales del middleware en `docker-compose.dev.yml` (mismo archivo para los tres ambientes).
Fuera de alcance: Kubernetes, Vault, Config Server, rotación automática de secretos y cambios de
topología.

## 2. Situación de partida

El proyecto ya tiene configuración externa parcial; la HU la completa y la demuestra.

| Ya existe | Evidencia |
|-----------|-----------|
| Config por ambiente | `deploy/environments/{dev,stage,prod}.env` (`HOST`, `REGISTRY`, `SPRING_PROFILES_ACTIVE`, `WEB_HOST`) |
| Compose parametrizado | `deploy/docker-compose.yml` con `${REGISTRY}`, `${VERSION}`, `${WEB_HOST:-localhost}` |
| Interpolación en YAML | `cors.allowed-origins` e `identity.api.url` en `auth` |
| Config de frontend en ejecución | `mobile/docker/40-env-config.sh` genera `env-config.js`; `mobile/constants/Config.ts` lo consume |

| Falta | Dónde |
|-------|-------|
| Secretos fuera del repositorio | `services/*/src/main/resources/application.yml`, ambos compose |
| Credenciales de datos | `docker-compose.dev.yml` (`POSTGRES_PASSWORD`, `NEO4J_AUTH`, `LDAP_ADMIN_PASSWORD`) |
| Expiración, logs y rutas | `jwt.expiration`, `qr.expiration`, `logging.level`, `Paths.get("uploads")` |
| Fallo temprano ante valor ausente | hoy cae en un literal de desarrollo |
| Higiene de Git | `.gitignore` no cubre `.env` ni `deploy/secrets/*.env` |

## 3. Patrón elegido: External Configuration

**Se selecciona External Configuration.** Los valores dependientes del ambiente y los secretos
salen del código y de la imagen, y se inyectan al ejecutar el contenedor: un archivo versionado
por ambiente para lo no sensible y un archivo no versionado para los secretos.

**Justificación**

1. El problema es de **parametrización**, no de comportamiento condicional: cambian credenciales,
   URLs, expiraciones y nivel de logs, no ramas de lógica.
2. **El mecanismo ya existe** en el proyecto (Spring resuelve variables de entorno, Compose las
   inyecta y la app web ya demuestra el patrón completo); no añade infraestructura.
3. Es el requisito literal de la HU: cambiar el comportamiento sin reconstruir imágenes.
4. **Resuelve la seguridad**: un secreto que no está en la imagen ni en Git no queda en el
   historial ni en las capas del artefacto.
5. **Encaja con el pipeline**: el despliegue ya escribe un archivo de entorno en el host, así que
   el canal de inyección está construido.

### 3.1 Mecanismo y alcance real del cambio

Spring Boot resuelve propiedades con precedencia: **variables de entorno > `application.yml`
empaquetado > default del placeholder**. Por el *relaxed binding*, `JWT_EXPIRATION` ya sobrescribe
`jwt.expiration` **sin tocar el YAML**. Declarar `${VAR:...}` en el YAML no crea el mecanismo:
aporta que la propiedad quede declarada como contrato, que los secretos sean obligatorios y que el
nombre de la variable sea explícito y estable. Se documenta así para no atribuir al cambio de
YAML un efecto que produce Spring.

## 4. Alternativas descartadas

| Alternativa | Por qué no se elige |
|-------------|---------------------|
| **Feature Toggle** | Requiere lógica de negocio nueva por bandera y no administra secretos, credenciales ni URLs. El problema de CircleGuard no es habilitar funcionalidades. |
| **Spring Profiles** (`application-<perfil>.yml`) | El valor sigue dentro de la imagen: cambiarlo exige reconstruir. Además serían 24 archivos con riesgo de divergencia. Ver 5.5. |
| **Spring Cloud Config Server** | Añade un componente desplegado, un repositorio de configuración y un punto único de fallo; no resuelve por sí mismo los secretos. |
| **HashiCorp Vault** | Solución objetivo para secretos en una organización real, pero exige operar un servidor y autenticación de servicios; excede la HU. Se documenta como evolución. |

## 5. Decisiones clave

### 5.1 Configuración versionada y secretos no versionados

| Archivo | Contenido | ¿Se versiona? |
|---------|-----------|---------------|
| `deploy/environments/<ambiente>.env` | Host, registro, `WEB_HOST`, nivel de logs, expiraciones, CORS | Sí |
| Credencial de Jenkins `<ambiente>-app-secrets` (*Secret file*) | `JWT_SECRET`, `QR_SECRET`, `DB_PASSWORD`, `VAULT_*`, credenciales de middleware | **No** |
| `deploy/secrets/<ambiente>-secrets.env` | Los mismos secretos, solo para ejecutar en local | **No** |
| `*.example` | Solo nombres de variables | Sí |

Proveedor de secretos: **credenciales de Jenkins**. El paso `deployEnvironment` de la librería
del pipeline lee `<ambiente>-app-secrets` y lo entrega al host en cada despliegue. Así no queda
ningún archivo de secretos administrado a mano en los servidores, y para rotar un secreto basta
con actualizar la credencial y volver a desplegar. El compose no depende del proveedor: consume
las mismas variables en local y en los tres ambientes.

`SPRING_PROFILES_ACTIVE` se mantiene porque lo envía la librería, pero **no activa nada**: no
existe ningún `application-<perfil>.yml`, así que no se usa como evidencia.

### 5.2 Inyección con interpolación `${VAR:?}`, no `env_file` mezclado

En Docker Compose, `environment:` **tiene prioridad sobre `env_file:`**: si se añade `env_file`
mientras quedan literales en `environment:`, las variables del archivo se ignoran en silencio.
Además, `env_file` no participa en la interpolación `${...}` del propio compose.

Decisión: una sola técnica, interpolación explícita en `environment:`.

- `${VAR:?mensaje}` para secretos y obligatorios: Compose falla antes de crear el contenedor.
- `${VAR:-valor}` para defaults seguros de desarrollo.

Los dos compose de aplicación y `docker-compose.dev.yml` ya usan esta técnica para todas sus
variables. `docker compose config --quiet` valida la interpolación sin imprimir los valores.

### 5.2.1 Cómo llegan los dos archivos al contenedor

Compose solo lee **un** archivo de entorno (`.env` en el directorio del proyecto, o `--env-file`).
Por eso el host recibe un solo archivo, que el pipeline arma en cada despliegue:

1. Variables de `deploy/environments/<ambiente>.env` más la `VERSION` publicada por el build.
2. El contenido de la credencial `<ambiente>-app-secrets` se agrega **en el shell**
   (`withCredentials` + `file`), así que nunca pasa por variables de Groovy ni aparece en el log.
   Se eliminan los `\r` para que un archivo escrito en Windows no meta ese carácter dentro de las
   contraseñas.
3. El resultado se copia por `scp` a `circleguard/.env` del host, con permisos `600`. Después se
   borra la copia del workspace de Jenkins, aunque el paso falle.

El equivalente manual, por ejemplo para ejecutar en local, es:

```bash
cat deploy/environments/dev.env deploy/secrets/dev-secrets.env > .env   # permisos 600
docker compose -f docker-compose.dev.yml -f deploy/docker-compose.yml up -d --wait
```

Así el secreto no viaja en Git ni en la imagen, y el contrato de variables es el mismo en local
(`.env` de la raíz) y en los tres ambientes.

### 5.3 Fallo temprano y defaults

Un secreto ausente debe impedir el arranque, nunca degradar a un valor de desarrollo: `${JWT_SECRET}`
sin default en el YAML y `:?` en el compose. Los defaults solo se admiten en lo no sensible y
existen para que `bootRun` y el compose local funcionen sin configuración.

### 5.4 Variables compartidas entre servicios

Deben ser **idénticas** en todos sus consumidores; si divergen, la integración falla aunque cada
servicio esté "sano":

| Variable | Consumidores | Si difiere |
|----------|--------------|------------|
| `JWT_SECRET` | `auth` (firma), `identity` y `promotion` (validan) | 401 en los endpoints protegidos. Debe tener **≥32 bytes** o JJWT lanza `WeakKeyException` |
| `QR_SECRET` | `auth` (emite el QR) y `gateway` (lo valida) | El QR deja de validar en portería |
| Credenciales de datos | Cada servicio y su middleware | El servicio no conecta a la base |

Por eso los archivos de secretos son **por ambiente**, no por servicio.

### 5.5 Riesgos operativos que condicionan la implementación

- **`.gitignore` primero**: crear un archivo de secretos antes de ignorarlo lo deja en el historial.
- **Las variables de entorno son visibles** con `docker inspect` y `/proc/<pid>/environ`; el
  *masking* de Jenkins solo protege logs. Mitigación: acceso restringido al host y evolución a
  `secrets:` de Compose en `/run/secrets`.
- **`qr.expiration` se interpreta en milisegundos**: el YAML de `auth` declara `300` (300 ms) y el
  compose lo sobreescribe con `60000`. Al externalizar, el default **no** debe ser `300`.
- **Las pruebas cargan contexto con placeholders obligatorios**: `form`, `notification` y
  `promotion` necesitan archivos de prueba; sin ellos el pipeline no publica ni despliega.

## 6. Inventario de variables

Clases: **S** sensible (obligatoria, sin default), **A** dependiente del ambiente, **D** default de
desarrollo permitido.

| Servicio | Variables | Sensibles (S) |
|----------|-----------|---------------|
| auth | `DB_URL`, `DB_USERNAME`, `DB_PASSWORD`, `LDAP_URL`, `LDAP_BASE`, `LDAP_USERNAME`, `LDAP_PASSWORD`, `CORS_ALLOWED_ORIGINS`, `IDENTITY_API_URL`, `JWT_SECRET`, `JWT_EXPIRATION`, `QR_SECRET`, `QR_EXPIRATION`, `LOG_LEVEL` | `DB_PASSWORD`, `LDAP_PASSWORD`, `JWT_SECRET`, `QR_SECRET` |
| identity | `DB_URL`, `DB_USERNAME`, `DB_PASSWORD`, `KAFKA_BOOTSTRAP_SERVERS`, `VAULT_SECRET`, `VAULT_SALT`, `VAULT_HASH_SALT`, `JWT_SECRET`, `LOG_LEVEL` | `DB_PASSWORD`, `VAULT_SECRET`, `VAULT_SALT`, `VAULT_HASH_SALT`, `JWT_SECRET` |
| promotion | `DB_URL`, `DB_USERNAME`, `DB_PASSWORD`, `NEO4J_URI`, `NEO4J_USERNAME`, `NEO4J_PASSWORD`, `REDIS_HOST`, `REDIS_PORT`, `KAFKA_BOOTSTRAP_SERVERS`, `JWT_SECRET`, `LOG_LEVEL` | `DB_PASSWORD`, `NEO4J_PASSWORD`, `JWT_SECRET` |
| form | `DB_URL`, `DB_USERNAME`, `DB_PASSWORD`, `KAFKA_BOOTSTRAP_SERVERS`, `LOG_LEVEL` | `DB_PASSWORD` |
| gateway | `REDIS_HOST`, `REDIS_PORT`, `CORS_ALLOWED_ORIGINS`, `QR_SECRET`, `LOG_LEVEL` | `QR_SECRET` |
| notification | `KAFKA_BOOTSTRAP_SERVERS`, `MAIL_HOST`, `MAIL_PORT`, `AUTH_API_URL`, `IDENTITY_API_URL`, `TWILIO_*`, `GOTIFY_*`, `LMS_API_URL`, `ROOM_BOOKING_API_URL`, `NOTIFICATION_URL_*`, `LOG_LEVEL` | — (ver nota) |
| dashboard | `DB_URL`, `DB_USERNAME`, `DB_PASSWORD`, `CIRCLEGUARD_PROMOTION_SERVICE_URL`, `LOG_LEVEL` | `DB_PASSWORD` |
| file | `FILE_STORAGE_PATH`, `LOG_LEVEL` | — |
| web | `AUTH_BASE_URL`, `IDENTITY_BASE_URL`, `FORM_BASE_URL`, `GATEWAY_BASE_URL`, `PROMOTION_BASE_URL`, `NOTIFICATION_BASE_URL`, `FILE_BASE_URL`, `DASHBOARD_BASE_URL` | — |
| middleware | `DB_USERNAME`, `DB_PASSWORD`, `NEO4J_USERNAME`, `NEO4J_PASSWORD`, `LDAP_PASSWORD` (`POSTGRES_DB`, `LDAP_ORGANISATION`, `LDAP_DOMAIN` son fijos) | `DB_PASSWORD`, `NEO4J_PASSWORD`, `LDAP_PASSWORD` |

Defaults de desarrollo: URLs `localhost`, `JWT_EXPIRATION=3600000`, `QR_EXPIRATION=60000`,
`LOG_LEVEL=INFO`, `KAFKA_BOOTSTRAP_SERVERS=localhost:9092`. Los secretos no tienen default.
Los canales externos de `notification` (`TWILIO_*`, `GOTIFY_*`) conservan marcadores de
desarrollo (`MOCK_TOKEN`); al habilitarlos, sus credenciales se suministran desde el archivo de
secretos.

`LOG_LEVEL` necesita declaración explícita (`logging.level.root: ${LOG_LEVEL:INFO}`); no es una
propiedad de Spring por sí sola. El compose de infraestructura traduce el contrato a los nombres
que espera cada imagen: `DB_USERNAME`/`DB_PASSWORD` → `POSTGRES_USER`/`POSTGRES_PASSWORD`,
`NEO4J_USERNAME`/`NEO4J_PASSWORD` → `NEO4J_AUTH`, `LDAP_PASSWORD` → `LDAP_ADMIN_PASSWORD`.
Dentro de un `healthcheck`, la contraseña se referencia como `$$VAR` para que la expanda el shell
del contenedor y no Compose. Neo4j es la excepción: su imagen convierte cualquier variable
`NEO4J_*` en un setting de `neo4j.conf` y aborta ante uno desconocido (`NEO4J_PASSWORD` →
`Unrecognized setting: PASSWORD`), así que el contenedor solo recibe `NEO4J_AUTH` y el
healthcheck extrae la contraseña con `$${NEO4J_AUTH#*/}`.

## 7. Trade-offs

| Decisión | Ventaja | Costo | Mitigación |
|----------|---------|-------|------------|
| External Configuration vs Feature Toggle | Sin lógica condicional nueva; resuelve secretos y valores | No sirve para despliegues graduales de funcionalidades | Adoptar Feature Toggle si surge esa necesidad de producto |
| Config no sensible versionada | Cambios revisables y trazables en Git | Riesgo de que alguien añada un secreto | Revisión de PR, `*.example` y carpetas separadas |
| Secretos fuera de Git | No quedan en historial ni en capas de imagen | Un ambiente nuevo no arranca solo | Plantilla `secrets.env.example` y `:?` con mensaje claro |
| Secretos como variables de entorno | Compatible con Compose y la librería, sin código nuevo | Visibles en `docker inspect` | Acceso restringido al host; evolución a `secrets:` de Compose |
| Recrear contenedores al cambiar config | No se reconstruye la imagen | Corte breve por servicio | Recrear solo el servicio afectado; `--wait` valida el resultado |
| Configuración separada del artefacto | Misma imagen en los tres ambientes | La config desplegada no viaja con la imagen | Registrar versión y ambiente en `promotion-record.txt` |
| Sin Config Server ni Vault | No se opera infraestructura extra | Sin configuración centralizada ni rotación | Evolución documentada |

## 8. Evidencia

Medición del 2026-11-15 en el equipo local con el compose de desarrollo
(`docker-compose.dev.yml` + `docker-compose.app.yml`). El procedimiento es el mismo en los
ambientes desplegados, sustituyendo el compose local por `deploy/docker-compose.yml`, **sin**
`--build` y **sin** `pull`.

### 8.1 Procedimiento

1. Levantar `auth` con sus dependencias y registrar la huella de imagen.
2. Pedir un token a `POST /api/v1/auth/visitor/handoff` (no exige credenciales) y calcular `exp - iat`.
3. Cambiar **solo** `LOG_LEVEL` y `JWT_EXPIRATION` en el archivo de entorno.
4. Recrear el contenedor (`up -d --force-recreate`, sin `--build`) y repetir la medición.

```powershell
docker compose -f docker-compose.dev.yml -f docker-compose.app.yml up -d --no-deps auth
docker inspect -f '{{.Image}}' circleguard-auth-service
$r = Invoke-RestMethod -Method Post -Uri http://localhost:8180/api/v1/auth/visitor/handoff `
       -ContentType 'application/json' -Body '{"anonymousId":"11111111-1111-1111-1111-111111111111"}'
```

### 8.2 Resultado medido

| Medición | Antes | Después |
|----------|-------|---------|
| `.env`: `LOG_LEVEL` / `JWT_EXPIRATION` | `INFO` / `3600000` | `DEBUG` / `7200000` |
| `docker inspect -f '{{.Image}}'` | `sha256:3f43a4b6…4215cc` | `sha256:3f43a4b6…4215cc` |
| `RepoDigests` del artefacto | `circleguard/auth-service@sha256:3f43a4b6…4215cc` | idéntico |
| `exp - iat` del JWT emitido | `3600` s | `7200` s |
| Líneas `DEBUG` en el arranque | `0` de 49 | `1514` de 3239 |

Conclusión: el comportamiento cambió (vigencia del token y nivel de trazas) y la imagen fue la
misma: no hubo `--build` ni `pull` entre las dos mediciones.

### 8.3 Fallo temprano ante un secreto ausente

```
$ docker compose --env-file deploy/environments/dev.env \
    -f docker-compose.dev.yml -f deploy/docker-compose.yml config --quiet
error while interpolating services.postgres.environment.POSTGRES_PASSWORD:
required variable DB_PASSWORD is missing a value: DB_PASSWORD is required
(deploy/secrets/<environment>-secrets.env)
...
```

El stack no arranca a medias: Compose aborta antes de crear el primer contenedor y nombra la
variable que falta.

### 8.4 URLs del frontend (ya existente)

`curl -s http://<host>:8081/env-config.js` cambia con `WEB_HOST` sin reconstruir la imagen de la
web.

### 8.5 Qué se registra

| Evidencia | Cómo | Qué demuestra |
|-----------|------|---------------|
| `git diff` del archivo de entorno | `git diff deploy/environments/<ambiente>.env` | El cambio es solo configuración |
| Huella antes/después | `docker inspect -f '{{.Image}}' <contenedor>` | El contenedor nuevo usa la **misma** imagen |
| Digest publicado | `docker image inspect ... --format '{{json .RepoDigests}}'` | El artefacto del registro no cambió |
| Variables efectivas | `docker exec <servicio> env \| grep -E '^(JWT_EXPIRATION\|LOG_LEVEL)='` | Solo se inspecciona lo no sensible |
| Comportamiento | vigencia del JWT, líneas de log | El comportamiento cambió |
| Ausencia de literales | `git grep -n "my-super-secret\|my-qr-secret"` sin resultados | Los secretos salieron del repositorio |

No se captura `docker compose config` como evidencia: resuelve e imprime los valores, incluidos
los secretos.

## 9. Criterios de aceptación → evidencia

| Criterio | Sección | Evidencia |
|----------|---------|-----------|
| Se selecciona un patrón y se justifica | 3 y 4 | Comparación con Feature Toggle, perfiles, Config Server y Vault |
| Lo sensible y lo dependiente del ambiente sale del código | 5 y 6 | Inventario, archivos por ambiente y `git grep` sin literales |
| Cambio de comportamiento sin reconstruir la imagen | 8 | Huella de imagen idéntica, vigencia del JWT, logs, `env-config.js` |
| Propósito, trade-offs y evidencia documentados | 1, 7 y 8 | Este documento y el registro de 8.4 |

## 10. Referencias

- [`despliegue.md`](despliegue.md): imágenes, registro, entornos, promoción y verificación.
- [`pipeline.md`](pipeline.md): etapas y credenciales de Jenkins.
- [`deploy/README.md`](../../deploy/README.md): archivos de despliegue y variables.
- `mobile/docker/40-env-config.sh`: precedente de configuración en tiempo de ejecución.
