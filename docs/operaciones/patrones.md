# Patrones de configuración, resiliencia y despliegue

Este documento reúne los patrones implementados en CircleGuard para el taller: **qué** patrón se
eligió en cada área, **por qué**, **cómo** está implementado, sus **trade-offs** y la **evidencia**
de que funciona.

| Área | Patrón | Historia | Sección |
|------|--------|----------|---------|
| Configuración | External Configuration | HU-34 | [1](#1-configuración-external-configuration) |
| Resiliencia | Health Check + Restart Policy + Timeout, Retry y Circuit Breaker | HU-28 | [2](#2-resiliencia) |
| Despliegue | Immutable Artifact + Environment Promotion + Health-gated Deployment; **Rolling Update + Canary** | HU-13, HU-14, HU-15, HU-30 | [3](#3-despliegue) |

La operación diaria (imágenes, registro, pipeline) está en [`despliegue.md`](despliegue.md) y
[`pipeline.md`](pipeline.md); los archivos de despliegue, en
[`deploy/README.md`](../../deploy/README.md).

Los tres patrones se apoyan entre sí:

```
           ┌──────────────── la misma imagen ────────────────┐
 build ─► publish ─► deploy dev ─► verify ─► stage ─► (aprobación) ─► prod      (3. Despliegue)
                        ▲                                              ▲
            configuración inyectada por ambiente (.env + secretos)              (1. Configuración)
                        ▼                                              ▼
            healthchecks · restart · timeout · retry · circuit breaker          (2. Resiliencia)
```

---

## 1. Configuración: External Configuration

### 1.1 Propósito

Una misma imagen Docker debe desplegarse en `dev`, `stage` y `prod` cambiando **solo** la
configuración que recibe al ejecutarse. Antes de este cambio:

1. Secretos en texto plano (`jwt.secret`, `qr.secret`, `vault.*`, contraseñas de PostgreSQL,
   Neo4j y LDAP) escritos en los `application.yml` y en los compose.
2. Valores por ambiente (URLs, nivel de logs, expiración de tokens) mezclados con literales.
3. Sin evidencia de que un cambio de configuración altere el comportamiento sin reconstruir.

### 1.2 Decisión y justificación

**Se elige External Configuration**: los valores dependientes del ambiente y los secretos salen
del código y de la imagen, y se inyectan al ejecutar el contenedor.

1. El problema es de **parametrización** (credenciales, URLs, expiraciones, logs), no de
   comportamiento condicional.
2. El mecanismo ya existe: Spring resuelve variables de entorno y Compose las inyecta; no se
   añade infraestructura.
3. Un secreto que no está en la imagen ni en Git no queda en el historial ni en las capas.
4. El pipeline ya escribía un archivo de entorno en el host: el canal de inyección existía.

| Alternativa | Por qué no |
|-------------|------------|
| Feature Toggle | Requiere lógica nueva por bandera y no administra secretos ni URLs |
| Spring Profiles (`application-<perfil>.yml`) | El valor sigue dentro de la imagen: cambiarlo exige reconstruir |
| Spring Cloud Config Server | Un componente más que operar y un punto único de fallo |
| HashiCorp Vault | Solución objetivo para secretos, pero exige operar un servidor; queda como evolución |

### 1.3 Implementación

| Fuente | Contenido | ¿Se versiona? |
|--------|-----------|---------------|
| `deploy/environments/<ambiente>.env` | Host, registro, `WEB_HOST`, `LOG_LEVEL`, `JWT_EXPIRATION`, `QR_EXPIRATION` | Sí |
| Credencial de Jenkins `<ambiente>-app-secrets` (*Secret file*) | `JWT_SECRET`, `QR_SECRET`, `DB_PASSWORD`, `NEO4J_PASSWORD`, `LDAP_PASSWORD`, `VAULT_*` | **No** |
| `.env.example`, `deploy/secrets/secrets.env.example` | Solo los nombres de las variables | Sí |

- **Servicios**: los ocho `application.yml` leen `${VAR}`. Los secretos no tienen valor por
  defecto (`${JWT_SECRET}`), tampoco en los `@Value` del código: si falta uno, el servicio no
  arranca en lugar de usar un valor conocido.
- **Compose**: interpolación `${VAR:?mensaje}` para secretos, que aborta **antes** de crear
  cualquier contenedor; `${VAR:-valor}` solo para valores no sensibles.
- **Entrega en el host**: el paso `deployEnvironment` une el `.env` del ambiente con la credencial
  de Jenkins en el shell (nunca pasa por el log), lo copia al host como `circleguard/.env` con
  permisos `600` y borra la copia del workspace.
- **Secretos compartidos**: `JWT_SECRET` (auth firma; identity y promotion validan) y `QR_SECRET`
  (auth emite; gateway valida) deben ser idénticos en sus consumidores, por eso los secretos son
  por ambiente y no por servicio.

### 1.4 Trade-offs

| Decisión | Ventaja | Costo | Mitigación |
|----------|---------|-------|------------|
| Config no sensible versionada | Cambios revisables en Git | Riesgo de que alguien añada un secreto | Revisión de PR y plantillas `*.example` |
| Secretos fuera de Git | No quedan en historial ni en capas | Un ambiente nuevo no arranca solo | `:?` con mensaje que nombra la variable |
| Secretos como variables de entorno | Compatible con Compose, sin código nuevo | Visibles con `docker inspect` | Acceso restringido al host; evolución a `secrets:` de Compose |
| Recrear el contenedor al cambiar config | No se reconstruye la imagen | Corte breve del servicio | Recrear solo el servicio afectado |

### 1.5 Evidencia

Cambio de **solo** `LOG_LEVEL` y `JWT_EXPIRATION` en el `.env`, recreando el contenedor de auth
sin `--build` ni `pull`:

| Medición | Antes | Después |
|----------|-------|---------|
| `.env`: `LOG_LEVEL` / `JWT_EXPIRATION` | `INFO` / `3600000` | `DEBUG` / `7200000` |
| `docker inspect -f '{{.Image}}'` | `sha256:3f43a4b6…4215cc` | `sha256:3f43a4b6…4215cc` (idéntica) |
| `exp - iat` del JWT emitido | `3600` s | `7200` s |
| Líneas `DEBUG` en el arranque | `0` de 49 | `1514` de 3239 |

Secreto ausente: `docker compose ... config --quiet` termina con
`required variable DB_PASSWORD is missing a value` sin crear ningún contenedor.

---

## 2. Resiliencia

### 2.1 Propósito

| Problema previo | Consecuencia |
|-----------------|--------------|
| El healthcheck solo abría el puerto (`/dev/tcp`) | Un servicio sin base de datos aparecía `healthy` |
| Ningún contenedor tenía política `restart:` | Un servicio caído quedaba caído hasta un despliegue manual |
| `new RestTemplate()` sin timeouts | Un identity o promotion colgado bloqueaba indefinidamente a auth y dashboard |
| Cliente de Redis con timeout de 60 s | Con Redis caído, el propio chequeo de salud se colgaba |

Objetivo: **detectar** el fallo, **recuperarse** solo cuando el entorno lo permite y **contener**
el impacto en el servicio afectado.

### 2.2 Decisiones y justificación

| Decisión | Justificación |
|----------|---------------|
| Spring Boot Actuator | Los ocho servicios son Spring Boot: el endpoint de salud y sus indicadores (BD, Redis, Neo4j) vienen incluidos |
| Liveness y Readiness | Distinguen un proceso que no responde de uno vivo cuya dependencia falla, que no se arregla reiniciando |
| Docker restart policy | Compatible con la infraestructura actual (Compose en EC2), sin componentes nuevos |
| Resilience4j | Implementa *retry* y *circuit breaker* probados para Java, sin construirlos a mano |
| Pruebas de fallos | Configurar no basta: hay que demostrar el comportamiento ante el fallo |

### 2.3 Detección: verificaciones de salud

Cada servicio expone `health`, `info` y `prometheus` (métricas para la observabilidad en
Kubernetes), sin detalles ni componentes (`show-details` y `show-components: never`). Los
endpoints sensibles (`env`, `beans`, `heapdump`) no se exponen:

| Endpoint | Pregunta | Incluye |
|----------|----------|---------|
| `/actuator/health/liveness` | ¿El proceso responde? | Estado interno |
| `/actuator/health/readiness` | ¿Puede atender solicitudes? | Estado interno + dependencias imprescindibles |

| Servicio | Puerto | Readiness incluye |
|----------|--------|-------------------|
| auth | 8180 | PostgreSQL, LDAP |
| identity | 8083 | PostgreSQL |
| promotion | 8088 | PostgreSQL, Neo4j, Redis |
| form | 8086 | PostgreSQL |
| gateway | 8087 | Redis |
| notification | 8082 | — (Kafka y correo son asíncronos/externos) |
| dashboard | 8084 | PostgreSQL |
| file | 8085 | — (almacenamiento local en volumen) |

El correo de notification queda fuera (`management.health.mail.enabled: false`): es un canal
externo y su caída no impide procesar eventos. Los mismos grupos alimentan las sondas de
Kubernetes. identity protege todo con JWT, así que los endpoints de actuator expuestos se
abrieron explícitamente en su `SecurityConfig`.

Los ocho Dockerfiles consultan **readiness**, no el puerto. La imagen JRE trae `bash` pero no
`curl`, así que la petición HTTP se hace por `/dev/tcp`:

```dockerfile
HEALTHCHECK --interval=15s --timeout=5s --start-period=90s --retries=3 \
    CMD bash -c 'exec 3<>/dev/tcp/127.0.0.1/<puerto> && printf "GET /actuator/health/readiness ..." >&3 \
                 && head -n1 <&3 | grep -q " 200 "' || exit 1
```

La salud se usa en `depends_on: condition: service_healthy` (orden de arranque), en
`docker compose up --wait` (el despliegue falla si un servicio no llega a `healthy`) y en
`docker ps` (`(unhealthy)` visible sin entrar al contenedor). La infraestructura ya tenía
healthchecks propios (`pg_isready`, `cypher-shell`, `redis-cli ping`, etc.).

### 2.4 Recuperación

Los mecanismos se eligieron según lo que permite **Docker Compose en EC2**, sin orquestador.

| Fallo | Mecanismo | Comportamiento |
|-------|-----------|----------------|
| El proceso termina | `restart: unless-stopped` en los 15 contenedores | Docker lo vuelve a arrancar; respeta un `docker stop` manual |
| `OutOfMemoryError` | `-XX:+ExitOnOutOfMemoryError` | La JVM termina en lugar de seguir en estado indefinido, y el reinicio arranca un proceso limpio |
| Cae una dependencia (BD, Redis) | Readiness `503` → `unhealthy`, **sin** reinicio | Reiniciar no arregla la dependencia; el pool (Hikari, Lettuce) reconecta solo y el servicio vuelve a `healthy` |
| Servicio remoto lento o caído | Timeout + Retry + Circuit Breaker | Ver abajo |

Llamadas HTTP síncronas entre servicios:

| Llamada | Timeout | Retry + Circuit Breaker | Si falla |
|---------|---------|-------------------------|----------|
| auth → identity (`/identities/map`) | 2 s / 5 s | Sí (`identity`) | Error rápido: no hay login válido sin id anónimo |
| dashboard → promotion (estadísticas) | 2 s / 5 s | Sí (`promotion`) | *Fallback* `{"error":"Service unavailable"}` con HTTP 200 |
| notification → auth (alertas, desde Kafka) | 2 s / 5 s | No | Se registra el error, como antes |

- **Circuit breaker**: si falla el 50 % de las últimas 10 llamadas (mínimo 5), se **abre** 30 s y
  responde de inmediato sin llamar al servicio; luego deja pasar 2 llamadas de prueba
  (*half-open*). Cuentan como fallo los errores de E/S y los `5xx`; un `4xx` es una respuesta válida.
- **Retry**: hasta 3 intentos separados 500 ms, solo ante errores de E/S y nunca con el circuito
  abierto. `/identities/map` es *get-or-create*, así que reintentarlo no crea duplicados.

### 2.5 Trade-offs

| Decisión | Ventaja | Costo | Mitigación |
|----------|---------|-------|------------|
| Healthcheck por readiness | Detecta servicios vivos sin su BD | Un fallo de BD marca `unhealthy` a varios servicios | Es la señal correcta; la causa se ve en el contenedor de la BD |
| No reiniciar un `unhealthy` | Evita bucles de reinicio con la dependencia caída | Un proceso colgado con el puerto abierto no se reinicia solo | Visible en `docker ps` y en `--wait`; evolución: orquestador con *liveness probe* |
| `restart: unless-stopped` | Recuperación automática sin componentes nuevos | Un error permanente se reinicia en bucle | Docker espacia los intentos; `RestartCount` lo hace visible |
| Retry | Absorbe fallos transitorios | Más carga sobre un servicio que ya sufre | 3 intentos, solo E/S, nunca con el circuito abierto |
| Circuit breaker | Falla rápido y protege al servicio caído | 30 s de rechazos aunque ya se haya recuperado | *Half-open* automático |
| Fallback en dashboard | El panel sigue respondiendo | Muestra "Service unavailable" | Preferible a un 500 o a una pantalla colgada |

Fuera del alcance del entorno actual: reemplazo automático de contenedores `unhealthy`, réplicas,
balanceo y conmutación entre hosts. Requieren un orquestador (Kubernetes, ECS o Swarm).

### 2.6 Evidencia

**Pruebas automatizadas** (corren en el pipeline con `./gradlew test`):

| Prueba | Qué demuestra |
|--------|---------------|
| `IdentityClientResilienceTest` (auth) | Un identity colgado termina por timeout en < 3 s; un identity caído se reintenta; tras fallos repetidos el circuito se abre y rechaza sin tocar la red |
| `PromotionClientResilienceTest` (dashboard) | Datos reales si promotion responde; *fallback* en < 3 s si se cuelga; con el circuito abierto no se vuelve a llamar a promotion; reintento antes del *fallback* |
| `HealthProbesTest` (identity) | Liveness y readiness son públicos y `UP`; no revelan componentes; `/actuator/env` no está expuesto; las rutas de negocio siguen exigiendo token |

**Inyección de fallos sobre contenedores reales** con `scripts/resilience-test.sh`, que inyecta
cada fallo y lo repara:

```bash
docker compose -f docker-compose.dev.yml -f docker-compose.app.yml up -d --build --wait
scripts/resilience-test.sh            # o: scripts/resilience-test.sh <ip-del-ambiente>
```

Resultado medido el 2026-11-20 en el stack local completo (15 contenedores): **30 de 30 checks**.

| # | Fallo inyectado | Resultado medido |
|---|-----------------|------------------|
| 1 | — | 9 contenedores de aplicación `healthy`; readiness `200` en los 8 servicios; `/actuator/env` no expuesto (`401`) |
| 2 | El proceso de auth termina (`kill -TERM 1`) | Docker lo reinició solo (`RestartCount` 1 → 2) y volvió a `healthy` en **17 s** |
| 3 | Se detiene Redis | gateway: readiness `503`, liveness `200`; `unhealthy` a los **49 s**; al volver Redis, `healthy` en **13 s** sin reiniciarse (`RestartCount` 0 → 0) |
| 4 | Se detiene promotion | dashboard respondió `200` con el *fallback* en las 8 llamadas: la primera en 668 ms, las siguientes en ~70 ms con el circuito abierto. Al volver promotion (17 s) y cerrarse el circuito, entregó datos reales |

### 2.7 Cómo detectar un problema

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'          # (healthy) / (unhealthy) / Restarting
docker inspect -f '{{.RestartCount}}' <contenedor>          # cuántas veces se reinició
docker inspect -f '{{json .State.Health.Log}}' <contenedor> # últimos sondeos del healthcheck
curl -s http://<host>:<puerto>/actuator/health/readiness    # {"status":"UP"} o 503
docker logs <contenedor> | grep "Circuit breaker"           # circuito abierto en dashboard
```

| Síntoma | Causa probable | Qué hacer |
|---------|----------------|-----------|
| Varios servicios `unhealthy` a la vez | Cayó una dependencia común (PostgreSQL, Redis) | Revisar ese contenedor; los servicios se recuperan solos |
| `RestartCount` creciente | Error al arrancar (configuración, secreto, BD) | `docker logs <contenedor>` |
| Dashboard muestra "Service unavailable" | promotion caído o circuito abierto | Revisar promotion; el circuito se cierra solo |
| El despliegue falla en `--wait` | Un servicio no llegó a `healthy` | `docker inspect` del servicio indicado |

---

## 3. Despliegue

### 3.1 Propósito

Llevar una versión de CircleGuard de `dev` a `prod` de forma repetible y **reducir el riesgo de
publicar una versión nueva**: que lo que llega a producción sea exactamente lo que se probó, que
publicar no provoque caídas y que una versión defectuosa afecte a la menor cantidad posible de
usuarios.

### 3.2 Base: patrones del pipeline

| Patrón | Qué resuelve | Implementación |
|--------|--------------|----------------|
| **Immutable Artifact** (*build once, deploy many*) | Lo que llega a prod es lo que se probó en dev | Cada build publica en Nexus `circleguard/<servicio>:<versión semántica>`; los ambientes nunca construyen, solo descargan ese tag. Nunca `latest` |
| **Environment Promotion** | Avanzar entre ambientes con controles crecientes | `dev → stage` automático si pasan pruebas, smoke y E2E; `stage → prod` con aprobación manual registrada en `promotion-record.txt` |
| **Health-gated Deployment** | No declarar éxito con un servicio caído | El despliegue espera a que las sondas de readiness (sección 2.3) estén sanas; luego `verifyServices` y `smokeTests` por HTTP |

```
push a dev ─► Build ─► Tests ─► Integration ─► SonarQube ─► Trivy ─► Publish images (tag semántico)
                                                                          │
   Deploy dev ─► Verify ─► Smoke ─► E2E ◄─────────────────────────────────┘
                                     │
          Promote to stage (automático, misma versión) ─► Verify + Smoke
                                     │
          Promote to prod (aprobación manual, misma versión) ─► Verify + Smoke
```

Estos patrones deciden **qué** versión se publica y **cuándo**. La HU-30 decide **cómo** se
reemplaza la versión en ejecución dentro de cada ambiente, ahora que los servicios se despliegan en
Kubernetes (k3s, HU-23 a HU-25).

### 3.3 Patrones de despliegue evaluados (HU-30)

Restricciones medidas en el proyecto:

| Evidencia | Dónde |
|-----------|-------|
| Tag semántico de cada imagen publicada | Nexus `<registry>/circleguard/*`; overlays Kubernetes usan `10.20.1.230:8082/circleguard/*` |
| Misma versión en los tres ambientes | `promotion-record.txt` (artefacto del build) |
| Despliegue condicionado a salud | Etapas *Deploy*, *Verify deployment* y *Smoke tests* del pipeline |
| Aprobador de prod | Registro del `input` de Jenkins y `promotion-record.txt` |

Restricciones medidas en el proyecto:

| Restricción | Valor | Fuente |
|-------------|-------|--------|
| Nodos | `m7i-flex.large` (2 vCPU, 8 GB); **un solo nodo** en dev y stage, dos en prod | `infra/terraform/shared`, `envs/*` |
| Cuota del namespace `circleguard` | 3072 Mi en dev/stage; los nueve componentes piden **2368 Mi** | `infra/k8s/platform/base/resourcequotas.yaml` |
| El mismo nodo aloja | Middleware (cuota 2560 Mi) y observabilidad (cuota 1536 Mi) | `circleguard-data`, `circleguard-observability` |
| Enrutamiento disponible | Traefik incluido en k3s (soporta reparto por pesos) | k3s `v1.37.2+k3s1` |
| Réplicas por componente | 1 | Manifiestos de la HU-24 |
| Alcance del pipeline | Solo `ConfigMap`, `Deployment`, `Service`, `Ingress` y `PersistentVolumeClaim`; el deployer no tiene RBAC sobre `traefik.io` | `deployKubernetes()` y `rbac-deployer.yaml` |

Criterios de decisión, tomados de la HU y de esas restricciones:

| # | Criterio |
|---|----------|
| C1 | Reduce cuántos usuarios ven una versión defectuosa (objetivo de la HU) |
| C2 | Cabe en los recursos disponibles |
| C3 | Publica sin caída del servicio |
| C4 | Permite volver atrás rápido |
| C5 | No agrega componentes que operar |
| C6 | Detecta errores que pasan las sondas de salud (errores de lógica) |

| Patrón | C1 | C2 | C3 | C4 | C5 | C6 |
|--------|----|----|----|----|----|----|
| **Recreate** (lo que hacía Compose) | ❌ 100 % expuesto | ✅ | ❌ hay corte | ❌ redesplegar | ✅ | ❌ |
| **Rolling Update** | 🟡 todos al terminar | ✅ +1 pod | ✅ | 🟡 `rollout undo` | ✅ | ❌ |
| **Blue-Green completo** | 🟡 100 % de golpe | ❌ **4608 Mi** frente a 3072 Mi de cuota | ✅ | ✅ instantáneo | ✅ | ❌ |
| **Blue-Green por servicio** | 🟡 100 % de golpe | ✅ +1 pod | ✅ | ✅ instantáneo | ✅ | ❌ |
| **Canary** | ✅ **~10 %** | ✅ +1 pod | ✅ | ✅ peso a 0 % | ✅ Traefik de k3s | ✅ con tráfico real limitado |
| **Shadow** | ✅ 0 % | ❌ duplica el tráfico | ✅ | ✅ | ❌ *service mesh* | 🟡 sin respuesta real |
| **A/B testing** | 🟡 | ✅ | ✅ | ✅ | ❌ *mesh* o lógica de negocio | 🟡 mide negocio, no estabilidad |

### 3.4 Decisión: Rolling Update + Canary

**Canary es el único patrón que cumple los seis criterios.** Frente a su alternativa más cercana,
Blue-Green por servicio, cuesta lo mismo y revierte igual de rápido, pero Blue-Green envía el
100 % del tráfico de golpe: un error que pasa las sondas lo sufren todos los usuarios. Con Canary
lo sufre ~1 de cada 10 peticiones mientras se detecta. Blue-Green completo queda descartado por
recursos: duplicar los ocho backends casi dobla la cuota y no cabe en el nodo único de dev y stage.

Se combinan dos patrones que cubren fallas distintas:

| Patrón | Se usa en | Protege contra |
|--------|-----------|----------------|
| **Rolling Update + rollback automático** | Jenkins: los nueve Deployments y ocho ConfigMaps del overlay; scripts: un servicio | Una versión que **no arranca** o no queda sana: nunca recibe tráfico y se revierte sola |
| **Canary** | Cambios riesgosos (implementado en `dashboard`) | Una versión que **arranca pero funciona mal**: solo la ve una fracción del tráfico |

### 3.5 Implementación

| Pieza | Archivo | Qué hace |
|-------|---------|----------|
| Estrategia de Rolling Update | `infra/k8s/components/rolling-update/` | Componente de Kustomize aplicado a los 9 Deployments sin editar sus manifiestos: `maxUnavailable: 0`, `maxSurge: 1`, `minReadySeconds: 10`, `progressDeadlineSeconds: 300`, `revisionHistoryLimit: 5`, `preStop` de 10 s; el margen de cuota está en la plataforma |
| Rollout con rollback | `scripts/k8s/rollout.sh <servicio> <imagen>` | Cambia la imagen, espera `kubectl rollout status` y, si la versión no queda lista a tiempo, ejecuta `kubectl rollout undo` y sale con código 1 |
| Reparto por pesos | `infra/k8s/components/canary-dashboard/` | `Service dashboard-canary`, `TraefikService dashboard-weighted` y una `IngressRoute` con prioridad sobre el Ingress general para `/api/v1/analytics`. Se aplica aparte; no entra en los overlays del pipeline |
| Ciclo del canary | `scripts/k8s/canary.sh start <imagen> [peso] \| weight \| promote \| abort \| status` | `start` copia el Deployment estable con la imagen nueva y le da tráfico solo cuando está listo; `promote` actualiza el estable con `rollout.sh`; `abort` devuelve el 100 % al estable |
| Demo local | `infra/k8s/demo/deployment-patterns/`, `scripts/k8s/demo-*.sh` | Clúster k3d con la misma versión de k3s y Traefik; dashboard + PostgreSQL |
| Rollback del pipeline | `circleguard-jenkins-library/vars/kubernetesSnapshot.groovy` + `rollbackKubernetes.groovy` | Snapshot previo de Deployments/ConfigMaps; si `apply -k`, un rollout o la verificación fallan, restaura solo lo cambiado, verifica imagen/estado y falla el build si no puede garantizar la recuperación |
| Autoescalado | `infra/k8s/components/hpa/` | HPA `autoscaling/v2` del gateway (`1→2`) con CPU 70 % / memoria 80 %; elimina `spec.replicas` del Deployment para que Kustomize no sobrescriba la réplica gestionada por el HPA |

Decisiones de detalle:

- **`maxUnavailable: 0` + `maxSurge: 1`.** Con una réplica por componente, el pod nuevo arranca
  junto al viejo y solo cuando está listo se retira el viejo. Uno a la vez, para no saturar el nodo.
- **En los ambientes, `maxSurge: 0` + `maxUnavailable: 1`.** El pipeline aplica los nueve
  Deployments a la vez, así que con `maxSurge: 1` los nueve piden su pod extra al mismo tiempo y la
  cuota `limits.cpu: 6` del namespace los rechaza (`exceeded quota`). En prod (build #73) los pods
  en ejecución ya usaban 5250m con el gateway escalado a 2 por el HPA, e identity, notification y
  promotion (1 CPU) quedaron en la versión anterior. Los overlays `dev`, `stage` y `prod`
  reemplazan cada pod en lugar de añadir uno: no se pasa de la cuota, a cambio de que cada servicio
  (una réplica) no responda mientras arranca su pod nuevo. El despliegue sin cortes requiere subir
  `limits.cpu` o tener dos réplicas por servicio; la estrategia del componente `rolling-update`
  queda como base y se demuestra en el clúster k3d (sección 3.6).
- **Readiness de la HU-28.** Un pod que no puede llegar a su base de datos nunca queda listo, así
  que nunca reemplaza a uno sano.
- **`preStop` de 10 s.** Kubernetes retira el pod de los endpoints y lo detiene casi a la vez;
  Traefik podía enviarle una petición durante ese instante (se midió 1 error de cada ~330 sin él).
  El pod sigue atendiendo 10 s mientras Traefik deja de enrutarle.
- **El canary es una copia del Deployment estable** hecha en el momento: misma configuración,
  sondas y recursos; solo cambian la imagen y la etiqueta `instance`. Con esa etiqueta distinta, el
  Service `dashboard` del estable no lo selecciona por accidente.
- **El canary entra al reparto solo cuando existe.** Traefik descarta una ruta cuyo Service no tiene
  pods, así que en estado normal el reparto contiene solo al estable.
- **Margen en la cuota.** Con 2368 de 3072 Mi reservados, el pod extra de promotion (512 Mi) cabe;
  con la cuota anterior de 2560 Mi habría sido rechazado y su rollout habría quedado trabado. El
  valor se fija en `infra/k8s/platform/base/resourcequotas.yaml`; `prod` ya usa 6 Gi / 12 Gi.

### 3.6 Demostración

Clúster k3d local con k3s `v1.37.2+k3s1` (la versión de los ambientes) y su Traefik. Imagen estable
`dashboard-service:1.0.0`; la versión nueva `1.1.0` es la misma build re-etiquetada, porque lo que
se prueba es el mecanismo de despliegue. El reparto se mide con las métricas de Prometheus de cada
pod; la caída, con tráfico continuo (~10 peticiones/s) durante el despliegue.

```bash
scripts/k8s/demo-up.sh          # crea el clúster y despliega
scripts/k8s/demo-scenarios.sh   # ejecuta los cinco escenarios
scripts/k8s/demo-down.sh        # elimina el clúster
```

Resultado medido el 2026-11-20: **10 de 10 checks en dos corridas consecutivas**.

| # | Escenario | Resultado |
|---|-----------|-----------|
| 1 | Canary al 10 % | 200 peticiones: **180 al estable, 20 al canary** |
| 2 | Canary al 50 % | 200 peticiones: **100 / 100** |
| 3 | Abortar | El canary desaparece; el estable responde **50 de 50** |
| 4 | Promover bajo tráfico continuo | El estable pasa a 1.1.0 con **0 errores** (338 y 381 peticiones) |
| 5 | Versión que nunca queda lista | `rollout.sh` la detecta a los 60 s, revierte sola y el servicio sigue en 1.1.0 con **0 errores** (298 y 299 peticiones) |

### 3.7 Ventajas y limitaciones

| Ventajas | Limitaciones |
|----------|--------------|
| Publicar no corta el servicio | Con 1 réplica, no protege contra la caída del **nodo**: eso requiere más réplicas o nodos |
| Una versión que no arranca nunca recibe tráfico y se revierte sola | El rollback del pipeline cubre Deployments y ConfigMaps; no revierte Secrets, PVC, esquemas de BD ni estado de Kafka, y no detecta errores de lógica que pasan las sondas; para eso está el Canary |
| Un error de lógica lo ve solo la fracción asignada al canary | El reparto es **por petición**, no por usuario: un mismo usuario puede alternar entre versiones. Para flujos con estado haría falta afinidad |
| Volver atrás es mover un peso o un `rollout undo`, en segundos | Estable y canary comparten la base de datos: los cambios de esquema deben ser compatibles con ambas versiones |
| Sin componentes nuevos: Kubernetes y el Traefik de k3s | La promoción es manual, apoyada en métricas; no hay análisis automático del canary |
| Cabe en los nodos actuales (+1 pod) | El Canary está implementado para `dashboard`; extenderlo a otro servicio es repetir su componente |

### 3.8 Operación

```bash
# Desplegar una versión de un servicio (rollback manual del script si no queda lista)
scripts/k8s/rollout.sh promotion 10.20.1.230:8082/circleguard/promotion-service:1.3.0

# Canary de dashboard
scripts/k8s/canary.sh start 10.20.1.230:8082/circleguard/dashboard-service:1.3.0 10
scripts/k8s/canary.sh status       # pesos, imágenes y pods
scripts/k8s/canary.sh weight 50    # subir la fracción si las métricas son buenas
scripts/k8s/canary.sh promote      # o: scripts/k8s/canary.sh abort
kubectl -n circleguard rollout history deploy/circleguard-dashboard-service
```

Los overlays `dev`, `stage` y `prod` incluyen
`../../platform/base/observability/scrape-annotations`, `../../components/rolling-update` y
`../../components/hpa`, así que un `kubectl apply -k infra/k8s/overlays/<ambiente>` despliega los
nueve componentes con Rolling Update y el HPA del gateway. El HPA requiere `metrics-server` y el
decreto `6/8Gi` de límites de la cuota: con `maxSurge: 1` el pico del gateway eleva los límites a
`5750m/8192Mi`. El componente `canary-dashboard` **no** está en esos overlays: el
pipeline solo acepta cinco tipos de recursos y el RBAC del deployer no cubre `traefik.io`, por lo
que se aplica aparte con una identidad con permisos (o en la demo de k3d) antes de usar
`canary.sh`. En `prod`, la cuota de plataforma ya es 6 Gi / 12 Gi.

---

## 4. Criterios de aceptación → evidencia

| Historia | Criterio | Sección |
|----------|----------|---------|
| HU-34 | Se selecciona y justifica un patrón | 1.2 |
| HU-34 | La configuración sensible y por ambiente sale del código | 1.3 |
| HU-34 | Cambio de comportamiento sin reconstruir la imagen | 1.5 |
| HU-34 | Propósito, trade-offs y evidencia documentados | 1.1, 1.4, 1.5 |
| HU-28 | Verificaciones de salud de los contenedores | 2.3 |
| HU-28 | Mecanismos de recuperación según las capacidades del entorno | 2.4 |
| HU-28 | Pruebas del comportamiento ante fallos | 2.6 |
| HU-28 | Mecanismos documentados | 2.2 a 2.7 |
| HU-30 | Se evalúan los patrones aplicables a la arquitectura | 3.3 |
| HU-30 | Se selecciona al menos un patrón según los requisitos | 3.4 |
| HU-30 | Se implementa el patrón seleccionado | 3.5 |
| HU-30 | Se demuestra su funcionamiento y se documentan ventajas y limitaciones | 3.6, 3.7 |

## 5. Referencias

- `services/*/Dockerfile`: HEALTHCHECK y `ExitOnOutOfMemoryError`.
- `services/*/src/main/resources/application.yml`: variables de entorno, `management` y `resilience4j`.
- `deploy/environments/*.env`, `deploy/secrets/secrets.env.example`, `.env.example`: configuración por ambiente.
- `docker-compose.dev.yml`, `docker-compose.app.yml`, `deploy/docker-compose.yml`: interpolación y `restart`.
- `scripts/resilience-test.sh`: pruebas de inyección de fallos.
- `infra/k8s/components/rolling-update/`, `infra/k8s/components/canary-dashboard/`: patrones de despliegue en Kubernetes.
- `scripts/k8s/rollout.sh`, `scripts/k8s/canary.sh`, `scripts/k8s/demo-*.sh`: despliegue, canary y demostración.
- [`despliegue.md`](despliegue.md), [`pipeline.md`](pipeline.md), [`deploy/README.md`](../../deploy/README.md).
