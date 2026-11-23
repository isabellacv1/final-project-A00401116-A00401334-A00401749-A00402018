# Informe de evaluación de carga y fallos (HU-32)

Comandos, escenarios y perfiles: [`tests/performance-locust/README.md`](../../tests/performance-locust/README.md).
Datos crudos de Locust (CSV por tipo de petición, historia cada segundo y errores):
[`results/`](results/).

## 1. Escenario de evaluación

| Elemento | Valor |
|---|---|
| Ambiente | **dev** |
| Destino | Ingress de Traefik en `cg-k3s-dev-server` (`http://184.198.182.160`): auth, gateway y form por la misma URL |
| Versión probada | imágenes `1.0.0-dev.23` (build #66 de `dev`) |
| Infraestructura | k3s en **1 nodo `m7i-flex.large`** (2 vCPU, 8 GiB) con la app (9 Deployments, 1 réplica cada uno salvo el HPA del gateway), los datos (Postgres, Redis, Kafka, Neo4j, LDAP) y la observabilidad |
| Recursos de los servicios | 50 m de CPU pedidos / **500 m de límite**, 256 Mi / 768 Mi (promotion: 150 m / 1 CPU) |
| Origen de la carga | Locust 2.32.4 desde un portátil en Colombia, por Internet (latencia de red mínima observada ≈ 90 ms) |
| Usuario | `super_admin` (mismo usuario de las E2E) |
| Fecha | 2026-11-23 |

**Escenarios** (pesos relativos de los usuarios virtuales):

- **Validación de acceso (peso 3):** login, generar QR en auth (se renueva cada 45 s porque dura 60 s) y validarlo en el gateway en bucle.
- **Envío de encuestas (peso 1):** login y envío de la encuesta de síntomas (sin síntomas, para no cambiar el estado del usuario).

**Objetivos:** p95 ≤ 500 ms por tipo de petición y tasa de error ≤ 1 %.

## 2. Resultados de carga

| Perfil | Usuarios | Duración | Peticiones | Throughput | Errores | Objetivos |
|---|---:|---:|---:|---:|---:|---|
| smoke | 5 | 1 min | 131 | 2,2 req/s | **0 %** | ✅ salvo login (p95 1 s) |
| load | 50 (5/s) | 5 min | 4 614 | 15,4 req/s (pico 22) | 1,73 % | ❌ login y QR; ✅ validación y encuestas |
| stress | 200 | — | — | — | — | **no ejecutado** (ver §6) |

Latencia por tipo de petición (ms):

| Petición | smoke p50 / p95 | load p50 / p95 / p99 | load máx | Fallos (load) |
|---|---|---|---:|---:|
| `auth: login` | 880 / **1 000** | **20 000 / 32 000** / 36 000 | 35 686 | 0 |
| `auth: generate QR` | 120 / 370 | 130 / **33 000** / 39 000 | 40 181 | 38 (14 × 503) |
| `gateway: validate QR` | 120 / 210 | 120 / **240** / 30 000 | 48 707 | 40 |
| `form: submit survey` | 150 / 300 | 120 / **240** / 590 | 35 499 | 2 |
| **Total** | 130 / 370 | 120 / 310 / 33 000 | 48 707 | 80 |

### Comportamiento en el tiempo (perfil load)

| Segundo | Usuarios | req/s | Fallos acumulados | p95 total |
|---:|---:|---:|---:|---:|
| 20 | 50 | 5,3 | 0 | 14 000 ms |
| 40 | 50 | 15,3 | 14 | 19 000 ms |
| 60 | 50 | 22,1 | 14 | 9 400 ms |
| 80 | 50 | 20,5 | 14 | 490 ms |
| 120 | 50 | 18,1 | 14 | 370 ms |
| 160 | 50 | 17,1 | 24 | 320 ms |
| 220 | 50 | 14,6 | 46 | 300 ms |
| 280 | 50 | 12,4 | 74 | 310 ms |

La corrida tiene tres fases:

1. **Avalancha de logins (0–60 s).** Los 50 usuarios inician sesión en 10 s. El login es la
   operación más cara (hash de la contraseña y autenticación contra LDAP/Postgres) y `auth`
   tiene una sola réplica limitada a medio núcleo: el login sube a una mediana de **20 s** y,
   mientras `auth` está saturado, también se atasca la generación de QR, que vive en el mismo
   servicio (p95 33 s). Hay 14 errores, entre ellos **503** del Ingress: `auth` dejó de pasar
   su sonda de readiness y Traefik se quedó sin backend.
2. **Régimen estable (60–140 s).** Ya autenticados, los usuarios solo generan y validan QR y
   envían encuestas: **p95 entre 340 y 490 ms, 18–22 req/s y ningún error nuevo**. Se cumple el
   objetivo.
3. **Errores de conexión (140–300 s).** Los fallos crecen de forma constante (14 → 74) y el
   throughput baja (18 → 12 req/s) **sin que suba la latencia** (≈ 310 ms). Todos son errores de
   conexión (código 0), no respuestas del servidor. Coincide con un cambio en el security group
   del nodo durante la prueba: la regla del puerto 80 pasó a admitir otra IP y dejó fuera la del
   equipo que ejecutaba Locust (las conexiones ya abiertas siguen, las nuevas se rechazan). Se
   interpretan como un artefacto de la prueba y no como una falla del sistema, aunque no se pudo
   confirmar con las métricas porque el acceso se perdió.

**Lectura principal:** el gateway (73 % del tráfico) y form sostienen la carga con **p95 de
240 ms**; el límite de la plataforma está en **`auth-service`**, que no soporta picos de logins
concurrentes con los recursos actuales.

## 3. Resultados de las pruebas de fallos

**No ejecutadas en esta entrega.** El script (`tests/performance-locust/run-failure-test.sh`)
está listo; requiere ejecutar `kubectl scale` en el clúster durante la carga y el acceso al
ambiente se perdió durante la prueba de carga. Escenarios planificados y lo que se espera según
el diseño:

| Falla | Comando | Impacto esperado | Qué medir |
|---|---|---|---|
| Redis abajo | `kubectl -n circleguard-data scale deploy/redis --replicas=0` | El gateway no puede leer el estado de salud: las validaciones de QR fallan | Tasa de error mientras está abajo y tiempo de recuperación |
| promotion abajo | `kubectl -n circleguard scale deploy/circleguard-promotion-service --replicas=0` | Las encuestas se siguen aceptando (form solo publica en Kafka) | Que form siga respondiendo y que los eventos se procesen al volver |
| identity abajo | `kubectl -n circleguard scale deploy/circleguard-identity-service --replicas=0` | Fallan los logins nuevos | Errores de login frente a validaciones de usuarios ya autenticados |
| Caída de un nodo de prod | detener `cg-k3s-prod-agent` | Los pods se reprograman en el otro nodo | Tiempo sin servicio y errores durante la reprogramación |

Las alertas de la HU-27 (`CircleGuardServiceDown`, `CircleGuardDeploymentUnavailable`) son las
que deben dispararse en estos escenarios, así que la prueba sirve también como prueba en vivo de
las alertas.

## 4. Limitaciones y riesgos encontrados

| # | Hallazgo | Evidencia | Riesgo |
|---|---|---|---|
| 1 | **`auth-service` es el cuello de botella.** Una réplica con 500 m de CPU no soporta 50 logins en 10 s. | Login p50 20 s / p95 32 s; QR p95 33 s durante el pico | En el inicio de clases (todos abren la app a la vez) el acceso al campus se bloquea varios minutos. |
| 2 | **El login es lento incluso sin carga.** | smoke: login p95 1 000 ms con 5 usuarios | Mala experiencia y poca capacidad por réplica. |
| 3 | **Generar el QR depende del mismo servicio que el login.** | QR p95 33 s mientras `auth` está saturado por logins | Usuarios ya autenticados tampoco pueden entrar durante un pico de logins. |
| 4 | **Sin autoescalado en `auth`.** El HPA solo existe para el gateway. | — | No hay forma de absorber picos sin intervención manual. |
| 5 | **`auth` deja de estar listo bajo carga** y el Ingress devuelve 503. | 14 respuestas 503 en `generate QR` | Errores visibles para el usuario en vez de solo latencia. |
| 6 | **Un solo nodo para app, datos y observabilidad** en dev. | Nodo al 54 % de CPU y 65 % de memoria en reposo | La carga de un servicio afecta a los demás; los resultados de dev son una cota inferior de lo que daría prod (2 nodos). |
| 7 | Cambios del security group durante una prueba la invalidan. | Fase 3 del perfil load | Resultados no reproducibles si el acceso no se fija en Terraform. |

## 5. Oportunidades de mejora

| Hallazgo | Mejora propuesta | Prioridad |
|---|---|---|
| 1, 4 | **HPA para `auth-service`** (CPU 70 %, 1–3 réplicas), como el del gateway, y subir su límite de CPU a 1 núcleo. | Alta |
| 1, 3 | **Separar la generación de QR del login** (o darle un pool de hilos propio): un QR solo firma un JWT y no debería esperar a los logins. | Alta |
| 2 | Revisar el costo del login: factor de bcrypt, consulta a LDAP solo si el usuario no es local, caché del resultado durante la vida del token. | Media |
| 1 | **Limitar la tasa de logins** en el Ingress (middleware `rateLimit` de Traefik) para degradar de forma controlada en lugar de saturar `auth`. | Media |
| 5 | Ajustar la readiness de `auth` para que la saturación no lo saque del balanceo (o al menos combinarla con el HPA). | Media |
| 6 | Repetir la prueba en **prod (2 nodos)**, donde la app y los datos no compiten por la misma CPU. | Media |
| 7 | Fijar en Terraform las IPs autorizadas para las pruebas de carga y ejecutar Locust desde la máquina de Jenkins (misma VPC, sin latencia de Internet). | Baja |

## 6. Pendiente

- Perfil **stress** (200 usuarios) y las **pruebas de fallos** de la §3: se ejecutan con
  `./run-load-test.sh stress` y `./run-failure-test.sh` en cuanto se recupere el acceso al ambiente.
- Repetir el perfil load después de aplicar el HPA de `auth` para medir la mejora.

## 7. Criterios de aceptación → evidencia (HU-32)

| Criterio | Evidencia | Estado |
|---|---|---|
| Se define un escenario de evaluación | Sección 1 (ambiente, versión, infraestructura, escenarios, pesos y objetivos) y [`tests/performance-locust/`](../../tests/performance-locust/) | ✅ |
| Se ejecutan pruebas de carga y/o resiliencia | Perfiles smoke (5 usuarios) y load (50 usuarios, 5 min) contra dev; datos crudos en [`results/`](results/) | ✅ carga · ⏳ resiliencia (sección 3) |
| Se registran los resultados obtenidos | Sección 2: tablas por tipo de petición, línea de tiempo en tres fases y su interpretación | ✅ |
| Se identifican oportunidades de mejora | Secciones 4 (7 riesgos con evidencia) y 5 (7 mejoras priorizadas) | ✅ |
