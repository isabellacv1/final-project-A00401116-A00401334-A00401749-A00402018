# Despliegue

Este documento describe cómo se construyen las imágenes de CircleGuard, dónde se publican,
cómo se despliegan en AWS y cómo se promueven entre entornos. El pipeline que ejecuta estos
pasos se explica en [`pipeline.md`](pipeline.md); el detalle de los archivos de despliegue
está en [`deploy/README.md`](../../deploy/README.md).

## Qué se despliega

El compose de despliegue (`deploy/docker-compose.yml`) levanta nueve componentes:

| Componente | Imagen | Puerto publicado | Dockerfile |
|------------|--------|------------------|------------|
| Auth | `circleguard/auth-service` | 8180 | `services/circleguard-auth-service/Dockerfile` |
| Identity | `circleguard/identity-service` | 8083 | `services/circleguard-identity-service/Dockerfile` |
| Promotion | `circleguard/promotion-service` | 8088 | `services/circleguard-promotion-service/Dockerfile` |
| Form | `circleguard/form-service` | 8086 | `services/circleguard-form-service/Dockerfile` |
| Gateway | `circleguard/gateway-service` | 8087 | `services/circleguard-gateway-service/Dockerfile` |
| Notification | `circleguard/notification-service` | 8082 | `services/circleguard-notification-service/Dockerfile` |
| Dashboard | `circleguard/dashboard-service` | 8084 | `services/circleguard-dashboard-service/Dockerfile` |
| File | `circleguard/file-service` | 8085 | `services/circleguard-file-service/Dockerfile` |
| Web | `circleguard/web` | 8081 → 8080 | `mobile/Dockerfile` |

Configuración de los servicios agregados en la Parte 2:

| Servicio | Depende de | Variables principales |
|----------|------------|-----------------------|
| Notification | Kafka | `SPRING_KAFKA_BOOTSTRAP_SERVERS`, `AUTH_API_URL`, `IDENTITY_API_URL`. Los canales externos (SMTP, Twilio, Gotify, LMS) usan los valores por defecto de desarrollo. |
| Dashboard | PostgreSQL (`circleguard_dashboard`, creada por `init-db.sql`) | `SPRING_DATASOURCE_*`, `CIRCLEGUARD_PROMOTION_SERVICE_URL`. |
| File | — | Guarda los archivos en `/app/uploads`, montado sobre el volumen `fileuploads` para que no se pierdan al recrear el contenedor. |

## Imágenes Docker

### Servicios Spring Boot

Los ocho Dockerfiles de `services/` siguen el mismo patrón de dos etapas:

1. **Build:** `eclipse-temurin:21.0.13_9-jdk-jammy`. Copia `gradlew`, `gradle/`,
   `settings.gradle.kts`, `build.gradle.kts` y `services/`, y ejecuta
   `./gradlew :services:<módulo>:bootJar -x test`. Las pruebas no se ejecutan dentro del
   build de la imagen.
2. **Runtime:** `eclipse-temurin:21.0.13_9-jre-jammy`. Copia el JAR como `app.jar`, crea un
   usuario de sistema `app` y ejecuta el proceso sin privilegios con
   `java -XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError -jar /app/app.jar`.

Cada imagen declara `EXPOSE` en su puerto y un `HEALTHCHECK` que consulta
`/actuator/health/readiness` por HTTP usando `bash` (el JRE base no trae `curl`). Los
detalles están en [`patrones.md`](patrones.md#2-resiliencia).

El Dockerfile de `file` además crea `/app/uploads` con dueño `app`: el servicio crea ese
directorio al arrancar y, como `/app` pertenece a root, el usuario sin privilegios no podría
crearlo.

### App web

`mobile/Dockerfile` también usa dos etapas:

1. **Build:** `node:22.21.1-alpine3.22`. Instala dependencias con `npm ci` y genera el sitio
   estático con `npx expo export --platform web --output-dir dist`.
2. **Runtime:** `nginxinc/nginx-unprivileged:1.31.7-alpine3.24`. Sirve `dist` en el puerto
   8080 y ejecuta `docker/40-env-config.sh` al arrancar para generar `env-config.js` con las
   URLs de los servicios. Por eso la misma imagen funciona en todos los entornos sin
   reconstruirla: las URLs se inyectan como variables de entorno en el contenedor. La etapa
   ejecuta `apk upgrade` (como root, y vuelve al usuario sin privilegios 101) para aplicar
   los parches de Alpine publicados después de la etiqueta base.

### Seguridad de las imágenes

El pipeline escanea cada imagen con Trivy antes de publicarla y bloquea cualquier hallazgo
HIGH o CRITICAL. Para mantener las imágenes limpias:

| Capa | Cómo se corrige |
|------|-----------------|
| Sistema operativo (servicios) | Etiqueta reciente de `eclipse-temurin` en las dos etapas |
| Sistema operativo (web) | Etiqueta reciente de `nginx-unprivileged` + `apk upgrade` |
| Librerías Java | Spring Boot 3.5.x y, en `build.gradle.kts`, versiones de parche más recientes para las librerías transitivas reportadas (Jackson, Tomcat, Netty, PostgreSQL, FreeMarker, snappy, lz4, commons-io), siempre dentro de la misma línea |

Las vulnerabilidades sin corrección disponible para la línea en uso y que el código no puede
alcanzar se registran en `.trivyignore.yaml` (sección `vulnerabilities:`) con su justificación
(`statement`) y una fecha de vencimiento (`expired_at`); al vencer, Trivy vuelve a bloquear y
obliga a revisarlas. Para escanear en local con la misma política:

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD/.trivyignore.yaml:/work/.trivyignore.yaml:ro" aquasec/trivy:0.76.2 image \
  --scanners vuln --severity HIGH,CRITICAL --ignorefile /work/.trivyignore.yaml \
  --exit-code 1 circleguard/auth-service:1.0.0
```

### Contextos de build

| Imagen | Contexto | Dockerfile |
|--------|----------|------------|
| Servicios backend | raíz del repositorio (`.`) | `services/<servicio>/Dockerfile` |
| Web | `mobile/` | `mobile/Dockerfile` |

Las imágenes se construyen con BuildKit y se etiquetan con la versión semántica resuelta por
el pipeline. **Nunca se usa `latest`.**

Para construir una imagen suelta en local (por ejemplo, `notification`) y ejecutarla con sus
dependencias:

```bash
# Contexto: la raíz del repositorio, porque el Dockerfile copia gradle/ y services/
docker build -t circleguard/notification-service:1.0.0 \
  -f services/circleguard-notification-service/Dockerfile .

# Compose construye y arranca el servicio con Kafka y el resto de dependencias
docker compose -f docker-compose.dev.yml -f docker-compose.app.yml up -d --build notification

# Verificar que queda saludable
docker compose -f docker-compose.dev.yml -f docker-compose.app.yml ps notification
```

Las mismas instrucciones aplican a `file` y `dashboard` cambiando el nombre del servicio.

## Registro Nexus

Las imágenes se publican en el repositorio Docker de Nexus:

```
100.31.132.57:8082/circleguard/<servicio>:<version>
```

- El registro de los entornos de AWS es `100.31.132.57:8082` (definido en
  `deploy/environments/*.env`).
- Las instancias tienen ese registro en `insecure-registries` de
  `/etc/docker/daemon.json`, porque el conector no usa TLS.
- La librería recibe el registro por el parámetro `registry` de `circleguardPipeline()`. Su
  valor por defecto es `localhost:8082`, que funciona cuando Jenkins y Nexus comparten el
  host: el `docker push` lo ejecuta el daemon del host a través del socket de Docker.
- Los entornos remotos usan `100.31.132.57:8082`, la dirección pública del mismo Nexus.

## Entornos

| Entorno | Archivo | Host | Perfil Spring | Cuándo se despliega |
|---------|---------|------|---------------|---------------------|
| `dev` | `deploy/environments/dev.env` | `54.83.254.142` | `dev` | Automático en cada push a `dev`. |
| `stage` | `deploy/environments/stage.env` | `184.192.198.69` | `stage` | Promoción automática desde `dev` tras las validaciones y E2E. |
| `prod` | `deploy/environments/prod.env` | `98.92.231.157` | `prod` | Promoción desde `stage` con aprobación manual (`input`). |

Cada archivo define `HOST`, `SSH_USER`, `REGISTRY`, `SPRING_PROFILES_ACTIVE`, `WEB_HOST`, el nivel
de logs (`LOG_LEVEL`), las vigencias (`JWT_EXPIRATION`, `QR_EXPIRATION`) y el endpoint de
PostgreSQL (`DB_HOST`, `DB_PORT`). La versión (`VERSION`) no se guarda en el archivo: la escribe el
pipeline con la versión publicada por el mismo build.

Las credenciales no están en estos archivos: viven en la credencial de Jenkins
`<ambiente>-app-secrets` (tipo *Secret file*, formato de `deploy/secrets/secrets.env.example`). El
paso de despliegue la agrega al archivo de entorno y copia el resultado al host como `.env`
(permisos `600`); ver [`deploy/README.md`](../../deploy/README.md#secrets-on-the-host).

### Credenciales de Jenkins

| Credencial | Uso |
|------------|-----|
| `dev-credential`, `stage-credential`, `prod-credential` | Clave SSH del usuario `ubuntu` de cada entorno. |
| `dev-app-secrets`, `stage-app-secrets`, `prod-app-secrets` | *Secret file* con los secretos de la aplicación de cada entorno (HU-34). Obligatoria para desplegar. |
| `nexus-credential` | Usuario y contraseña para publicar en Nexus. |
| `e2e-credential` / `e2e-credentials` | Usuario de prueba para los smoke tests y para Playwright. |
| `git-credential` | Lectura del repositorio y reporte de estado a GitHub. |
| `discord-webhook-url` | Webhook de Discord para notificar fallos. |

## Flujo de despliegue

```
push a dev
   │
   ▼
Build ─► Tests ─► Integration tests ─► SonarQube ─► Publish images
   │
   ▼
Deploy dev (SSH + docker compose pull/up --wait)
   │
   ▼
Verify deployment (HTTP)
   │
   ▼
Smoke tests (HTTP funcional en el host)
   │
   ▼
E2E tests (Playwright contra dev)
   │
   ├─► Promote to stage (automático, misma versión)
   │        └─► Verify + smoke tests en stage
   │
   └─► Promote to prod (aprobación manual, misma versión)
            └─► Verify + smoke tests en prod
```

Solo la rama `dev` dispara las etapas de despliegue y promoción (`deployBranches`). En `main`
el pipeline construye, prueba, analiza y publica imágenes, pero no despliega.

## Cómo se ejecuta el despliegue

La librería `deployEnvironment` copia al host los archivos necesarios y ejecuta Docker Compose
por SSH:

1. Copia `docker-compose.dev.yml`, `init-db.sql`, `deploy/docker-compose.yml` y un archivo
   `.env` generado con la configuración del entorno más `VERSION`.
2. Ejecuta `docker compose -f docker-compose.dev.yml -f deploy/docker-compose.yml pull`.
3. Ejecuta `docker compose ... up -d --wait --wait-timeout 600`, de modo que el paso solo
   termina cuando los contenedores están saludables.
4. Muestra `docker compose ... ps`.

Los dos compose se combinan:

- `docker-compose.dev.yml` aporta el middleware: PostgreSQL, Neo4j, Zookeeper, Kafka, Redis
  y OpenLDAP, con sus healthchecks, la red `circleguard-net` y los volúmenes de datos.
- `deploy/docker-compose.yml` aporta la capa de aplicación y consume las imágenes
  `${REGISTRY}/circleguard/*:${VERSION}`.

`docker-compose.app.yml` es la variante de **desarrollo local**: construye las imágenes en el
host y usa la etiqueta fija `1.0.0`. No se usa para desplegar en AWS.

## Verificación

El despliegue no se considera exitoso solo porque los contenedores arranquen:

| Etapa | Qué comprueba |
|-------|---------------|
| `verifyServices` | Hace una petición HTTP a cada componente. Un código menor a 500 cuenta como disponible; reintenta hasta 20 veces. |
| `smokeTests` | Comprueba códigos y contenido concretos: home de la web, `env-config.js`, validación del gateway, listado de formularios, estadísticas de promotion, identidad protegida y login válido/inválido. |
| `runE2E` | Ejecuta Playwright en un contenedor contra la app desplegada en `dev`. Es la condición para promover a `stage`. |

Los resultados se publican en la pestaña **Tests** del build y los reportes quedan como
artefactos.

## Promoción

`promoteEnvironment` despliega en el entorno destino **la misma versión** que se publicó en
el build (`env.IMAGE_VERSION`), nunca una versión nueva ni `latest`. Después de desplegar,
verifica los servicios y ejecuta los smoke tests del entorno destino.

- `dev → stage`: automático, solo si build, tests, integración, despliegue de `dev`,
  smoke tests y E2E pasaron.
- `stage → prod`: siempre detrás de una aprobación manual (`input`). Jenkins registra quién
  aprobó y cuándo.
- Cada promoción agrega una entrada a `promotion-record.txt` (build, versión, ruta, condición,
  aprobador y fecha) y archiva el archivo como artefacto del build.

## Rollback

El rollback se apoyará en los **tags semánticos**: cada versión desplegada tiene una imagen
publicada con su tag (`100.31.132.57:8082/circleguard/<servicio>:<version>`), por lo que
volver a una versión anterior consiste en desplegar de nuevo ese tag. Esta funcionalidad la
está implementando otro integrante del equipo; el pipeline actual todavía no expone un paso
automatizado de reversión.

## Operación manual

Desde la raíz del repositorio, con `REGISTRY` y `VERSION` definidos:

```bash
# Validar la configuración combinada
docker compose -f docker-compose.dev.yml -f deploy/docker-compose.yml config

# Desplegar (en el host de destino)
docker compose -f docker-compose.dev.yml -f deploy/docker-compose.yml up -d --wait
```

## Requisitos del host de destino

- Docker Engine con el registro en `insecure-registries`.
- Usuario SSH `ubuntu` y la credencial correspondiente en Jenkins.
- Acceso al registro `100.31.132.57:8082`.
- Los puertos publicados por el compose deben ser alcanzables desde donde se ejecutan las
  verificaciones y desde el navegador del usuario.
