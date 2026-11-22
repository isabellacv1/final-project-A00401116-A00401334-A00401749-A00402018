# Despliegue

Este documento describe cómo se construyen las imágenes de CircleGuard, dónde se publican,
cómo se despliegan en Kubernetes y cómo se promueven entre entornos. El pipeline que ejecuta
estos pasos se explica en [`pipeline.md`](pipeline.md); el detalle de los manifiestos está en
[`infra/k8s/README.md`](../../infra/k8s/README.md). Las secciones de Compose al final se
conservan como referencia del despliegue anterior y para ejecución local.

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

## Despliegue actual en Kubernetes

El pipeline ya no usa SSH ni Docker Compose para desplegar. La etapa `Deploy` llama a
`deployKubernetes()`, que:

1. Copia el overlay de aplicación `infra/k8s/overlays/<entorno>` a un directorio temporal.
2. Fija las nueve imágenes a `env.IMAGE_VERSION` con `kustomize edit set image`.
3. Renderiza con `kubectl kustomize` (sin acceso al clúster) y valida el resultado antes de
   archivarlo: no puede estar vacío, todos los recursos deben estar en `circleguard` y los
   únicos kinds permitidos son `ConfigMap`, `Deployment`, `Service`, `Ingress` y
   `PersistentVolumeClaim`.
4. Comprueba el contexto activo y ejecuta `apply --dry-run=server` y `apply` con `--context` y
   `--namespace` explícitos. No se usa `--prune`.
5. Espera el rollout de los nueve Deployments y archiva el manifiesto validado como artefacto.

La plataforma es un root independiente: `infra/k8s/platform/overlays/<entorno>` contiene
namespaces, RBAC, cuotas, límites, NetworkPolicies y observabilidad. Lo aplica infraestructura
con una identidad administradora, antes de la aplicación. El middleware sigue en
`infra/k8s/data/`, también como root separado. La librería no crea Secrets ni concede permisos
nuevos.

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

Las imágenes se publican en el repositorio Docker de Nexus y los nodos k3s las descargan por su
dirección interna:

```
<registry-de-publicación>/circleguard/<servicio>:<version>   # docker push del pipeline
10.20.1.230:8082/circleguard/<servicio>:<version>            # imágenes de los overlays Kubernetes
```

- `registry` controla el `docker push` del pipeline. Su valor por defecto es `localhost:8082`,
  que funciona cuando Jenkins y Nexus comparten el host.
- `k8sRegistry` controla el prefijo que `deployKubernetes()` escribe en las imágenes del overlay;
  su valor por defecto es `10.20.1.230:8082`, la dirección interna de Nexus en la VPC.
- Cada nodo k3s debe confiar en el registro HTTP (`insecure-registries` en containerd) y tener
  el Secret de pull `nexus-pull-secret` en `circleguard`, creado fuera de Git.
- No se usa `latest`: todas las referencias llevan la versión semántica de este build.

## Entornos

| Entorno | Overlay de aplicación | Perfil Spring | Cuándo se despliega |
|---------|-----------------------|---------------|---------------------|
| `dev` | `infra/k8s/overlays/dev` | `dev` | Automático en cada push a `dev`. |
| `stage` | `infra/k8s/overlays/stage` | `stage` | Promoción automática desde `dev` tras las validaciones y E2E. |
| `prod` | `infra/k8s/overlays/prod` | `prod` | Promoción desde `stage` con aprobación manual (`input`). |

Cada overlay parchea `circleguard-common-config` con el perfil activo y los valores de CORS y SMTP
del entorno. Antes de desplegar, hay que sustituir los marcadores `.invalid` y los secretos
`REEMPLAZAR` por valores reales fuera de Git. El namespace es fijo: `circleguard`.

### Credenciales y configuración de Jenkins

| Credencial / parámetro | Uso |
|------------------------|-----|
| `dev-kubeconfig`, `stage-kubeconfig`, `prod-kubeconfig` | *Secret file* con el kubeconfig de cada clúster; se sustituye con `kubeconfigCredentialId`. |
| `k8sContext` / `k8sContexts` | Contexto activo esperado por entorno. Debe coincidir con `kubectl config current-context`. |
| `k8sIngressUrls` | URL base por entorno para verificación, smoke tests y E2E. |
| `k8sRegistry` | Registro interno usado por los nodos k3s (`10.20.1.230:8082` por defecto). |
| `nexus-credential` | Usuario y contraseña para publicar las imágenes. |
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
Deploy dev (Kustomize + kubectl apply, sin prune)
   │
   ▼
Verify deployment (HTTP contra el Ingress)
   │
   ▼
Smoke tests (HTTP funcional contra el Ingress)
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

La librería `deployKubernetes()` no copia archivos a hosts remotos. Trabaja sobre una copia local
del overlay de aplicación y ejecuta este orden:

1. `mkdir`, `rm -rf` y `cp -R` para preparar `.deploy-<entorno>-<build>`.
2. Nueve `kustomize edit set image` con `k8sRegistry/circleguard/<servicio>:IMAGE_VERSION`.
3. `kubectl kustomize <overlay-temporal>` capturado en memoria.
4. Validación de alcance: render no vacío, namespace `circleguard` en todos los recursos y kinds
   permitidos. Si falla, no se archiva ni se aplica nada.
5. `writeFile` + `archiveArtifacts` del manifiesto validado en `k8s/rendered-<entorno>-<build>.yaml`.
6. `kubectl config current-context`, `apply --dry-run=server -k` y `apply -k`, todos con
   `--context` y `--namespace` explícitos.
7. Nueve `kubectl rollout status deployment/...` con el timeout configurado.
8. `rm -rf` del overlay temporal en `finally`, incluso si falla render, apply o rollout.

`verifyIngress()` comprueba las rutas HTTP contra `k8sIngressUrls`, `smokeTests()` ejecuta las
comprobaciones funcionales y `runE2E()` ejecuta Playwright posteriormente. Ninguno usa SSH ni
NodePort.

## Verificación

El despliegue no se considera exitoso solo porque los pods arranquen:

| Etapa | Qué comprueba |
|-------|---------------|
| `deployKubernetes` | Rollout de los nueve Deployments con `kubectl rollout status`. |
| `verifyIngress` | Petición HTTP a cada ruta del Ingress con reintentos; un `404` siempre falla. |
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
publicada con su tag (`10.20.1.230:8082/circleguard/<servicio>:<version>` en Kubernetes), por lo
que volver a una versión anterior consiste en desplegar de nuevo ese tag. El pipeline actual
todavía no expone un paso automatizado de reversión.

## Operación manual

Desde la raíz del repositorio, primero renderiza y revisa los tres roots; no sustituyas el
contexto real ni apliques nada hasta comprobarlo:

```bash
kubectl config current-context

# Plataforma (identidad administradora)
kubectl kustomize infra/k8s/platform/overlays/dev
kubectl diff -k infra/k8s/platform/overlays/dev

# Datos (identidad administradora)
kubectl kustomize infra/k8s/data
kubectl diff -k infra/k8s/data

# Aplicación (28 recursos en circleguard)
kubectl kustomize infra/k8s/overlays/dev
kubectl diff -k infra/k8s/overlays/dev
```

Repite con `stage` y `prod`. El pipeline hace el mismo render de aplicación, añade la validación
de alcance y ejecuta `apply` con el contexto y namespace configurados.

## Requisitos del clúster y de Jenkins

- Los tres clústeres k3s deben existir y los namespaces de plataforma deben estar creados.
- El registro interno `10.20.1.230:8082` debe ser alcanzable desde los nodos; cada nodo debe
  confiar en el registro HTTP según su configuración de containerd.
- `nexus-pull-secret` y los Secrets de aplicación deben existir previamente en `circleguard`;
  la librería no los crea ni los imprime.
- Las credenciales `<entorno>-kubeconfig`, los contextos y las URLs del Ingress deben estar
  configurados en Jenkins antes de habilitar `deploy: true`.
- El Ingress de Traefik debe ser alcanzable desde el agente de Jenkins para las verificaciones
  HTTP, los smoke tests y E2E.
