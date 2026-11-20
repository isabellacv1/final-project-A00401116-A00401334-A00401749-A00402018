# Patrones de configuración, resiliencia y despliegue

Este documento reúne los patrones implementados en CircleGuard para el taller: **qué** patrón se
eligió en cada área, **por qué**, **cómo** está implementado, sus **trade-offs** y la **evidencia**
de que funciona.

| Área | Patrón | Historia | Sección |
|------|--------|----------|---------|
| Configuración | External Configuration | HU-34 | [1](#1-configuración-external-configuration) |
| Resiliencia | Health Check + Restart Policy + Timeout, Retry y Circuit Breaker | HU-28 | [2](#2-resiliencia) |
| Despliegue | Immutable Artifact + Environment Promotion + Health-gated Deployment | HU-13, HU-14, HU-15 | [3](#3-despliegue) |

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

Cada servicio expone **solo** `health`, sin detalles (`show-details: never`):

| Endpoint | Pregunta | Incluye |
|----------|----------|---------|
| `/actuator/health/liveness` | ¿El proceso responde? | Estado interno |
| `/actuator/health/readiness` | ¿Puede atender solicitudes? | Estado interno + dependencias imprescindibles |

| Servicio | Puerto | Readiness incluye |
|----------|--------|-------------------|
| auth | 8180 | PostgreSQL |
| identity | 8083 | PostgreSQL |
| promotion | 8088 | PostgreSQL, Neo4j, Redis |
| form | 8086 | PostgreSQL |
| gateway | 8087 | Redis |
| notification | 8082 | — (Kafka y correo son asíncronos/externos) |
| dashboard | 8084 | PostgreSQL |
| file | 8085 | Espacio en disco |

Se excluyen a propósito LDAP en auth (si cae, auth sigue autenticando cuentas locales) y el correo
en notification (canal externo): incluirlos marcaría como caído un servicio que funciona en modo
degradado. identity protege todo con JWT, así que `/actuator/health/**` se abrió explícitamente.

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
| 1 | — | 9 contenedores de aplicación `healthy`; readiness `200` en los 8 servicios; `/actuator/env` → `401` |
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

Llevar una versión de CircleGuard de `dev` a `prod` de forma repetible, sabiendo que lo que llega
a producción es **exactamente** lo que se probó, y sin dar por bueno un despliegue solo porque los
contenedores arrancaron.

### 3.2 Patrones y justificación

| Patrón | Qué resuelve | Implementación |
|--------|--------------|----------------|
| **Immutable Artifact** (*build once, deploy many*) | Lo que llega a prod es lo que se probó en dev | Cada build publica en Nexus `circleguard/<servicio>:<versión semántica>`; los hosts nunca construyen, solo hacen `pull` de ese tag. Nunca `latest` |
| **Environment Promotion** | Avanzar entre ambientes con controles crecientes | `dev → stage` automático si pasan pruebas, smoke y E2E; `stage → prod` con aprobación manual registrada en `promotion-record.txt` |
| **Health-gated Deployment** | No declarar éxito con un servicio caído | `docker compose up -d --wait` espera a que los healthchecks (sección 2.3) estén `healthy`; luego `verifyServices` y `smokeTests` por HTTP |

Encaja con los otros dos patrones: la imagen inmutable es la misma en los tres ambientes porque
la configuración se inyecta desde afuera (sección 1), y el *gate* de salud usa los healthchecks
de readiness (sección 2).

| Alternativa | Por qué no |
|-------------|------------|
| Construir en cada host | Lo desplegado en prod no sería lo probado en dev |
| Blue-green / canary | Requieren balanceador y capacidad duplicada que la infraestructura actual (un host por ambiente) no tiene |
| Promoción totalmente automática a prod | Producción exige una decisión humana trazable |

### 3.3 Flujo

```
push a dev ─► Build ─► Tests ─► Integration ─► SonarQube ─► Publish images (Nexus, tag semántico)
                                                                   │
   Deploy dev (pull + up --wait) ─► Verify ─► Smoke ─► E2E ◄───────┘
                                                        │
                    Promote to stage (automático, misma versión) ─► Verify + Smoke
                                                        │
                    Promote to prod (aprobación manual, misma versión) ─► Verify + Smoke
```

### 3.4 Trade-offs

| Decisión | Ventaja | Costo | Mitigación |
|----------|---------|-------|------------|
| Imagen inmutable por versión | Trazabilidad total versión ↔ imagen | Cada cambio exige un build y publicación | El pipeline lo automatiza |
| Recreación en sitio (sin blue-green) | Sin infraestructura extra | Corte breve durante el `up` | `--wait` limita la ventana; los servicios arrancan en < 20 s |
| Aprobación manual a prod | Decisión humana trazable | Más lenta | Solo en el último salto |
| Rollback por tag semántico | Volver atrás es redesplegar un tag existente | Aún no hay un paso automatizado | Documentado en [`despliegue.md`](despliegue.md#rollback) |

### 3.5 Evidencia

| Evidencia | Dónde |
|-----------|-------|
| Tag semántico de cada imagen publicada | Nexus `100.31.132.57:8082/circleguard/*` |
| Misma versión en los tres ambientes | `promotion-record.txt` (artefacto del build) |
| Despliegue condicionado a salud | Etapas *Deploy*, *Verify deployment* y *Smoke tests* del pipeline |
| Aprobador de prod | Registro del `input` de Jenkins y `promotion-record.txt` |

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

## 5. Referencias

- `services/*/Dockerfile`: HEALTHCHECK y `ExitOnOutOfMemoryError`.
- `services/*/src/main/resources/application.yml`: variables de entorno, `management` y `resilience4j`.
- `deploy/environments/*.env`, `deploy/secrets/secrets.env.example`, `.env.example`: configuración por ambiente.
- `docker-compose.dev.yml`, `docker-compose.app.yml`, `deploy/docker-compose.yml`: interpolación y `restart`.
- `scripts/resilience-test.sh`: pruebas de inyección de fallos.
- [`despliegue.md`](despliegue.md), [`pipeline.md`](pipeline.md), [`deploy/README.md`](../../deploy/README.md).
