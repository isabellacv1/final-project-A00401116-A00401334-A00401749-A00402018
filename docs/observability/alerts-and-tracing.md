# Alertas (Alertmanager) y trazas distribuidas (Jaeger) — HU-27

Complementa [metrics.md](metrics.md) (métricas y dashboards) y [logs.md](logs.md) (logs).

## 1. Alertmanager

```text
Prometheus ──(alertas que se disparan)──► Alertmanager ──(HTTPS)──► canal de Discord del equipo
   alerts.yml                              agrupa, silencia y
                                           repite cada 1 h / 4 h
```

| Pieza | Dónde |
|---|---|
| Reglas de alerta | `infra/k8s/platform/base/observability/prometheus/alerts.yml` |
| Conexión Prometheus → Alertmanager | `prometheus/prometheus.yml` → `alerting` |
| Rutas y receptor Discord | `alertmanager/alertmanager.yml` |
| Despliegue | `alertmanager/alertmanager.yaml` (Deployment + Service) |
| Webhook de Discord | Secret `alertmanager-discord`, **no está en el repositorio** |
| Pruebas de las alertas | `prometheus/alerts-test.yml` |

### Rutas

| Severidad | Espera antes del primer aviso | Se repite cada | Al resolverse |
|---|---|---|---|
| `critical` | 10 s | 1 h | mensaje ✅ RESOLVED |
| `warning` | 30 s | 4 h | mensaje ✅ RESOLVED |

Las alertas se agrupan por `alertname` y servicio/deployment/nodo: un servicio con 3 pods caídos
genera un solo mensaje.

### Alertas críticas

| Alerta | Condición | Qué significa |
|---|---|---|
| `CircleGuardServiceDown` | `up == 0` durante 1 min | Prometheus no puede leer el servicio: caído o reiniciando. |
| `CircleGuardDeploymentUnavailable` | réplicas disponibles < pedidas durante 5 min | Pods que no arrancan o no pasan readiness. |
| `CircleGuardHighErrorRate` | más del 5 % de respuestas 5xx durante 5 min | El servicio falla (base de datos, Redis, Kafka…). |
| `NodeLowMemory` | menos del 10 % de memoria libre durante 5 min | El nodo está por matar procesos. |

Además hay 5 alertas `warning` (latencia p95, heap, reinicios, CPU y disco); ver [metrics.md](metrics.md#7-alertas).

### Activarlo

```bash
kubectl apply -k infra/k8s/platform/overlays/dev
infra/k8s/platform/base/observability/create-alertmanager-secret.sh   # pide la URL del webhook sin mostrarla
kubectl get pods -n circleguard-observability -l app.kubernetes.io/name=alertmanager
```

La URL del webhook es la misma credencial `discord-webhook-url` que usa Jenkins para sus
notificaciones (o un webhook nuevo de otro canal). El script valida que sea un webhook de Discord,
la pasa a `kubectl` sin que aparezca en la lista de procesos y reinicia Alertmanager.

### Cómo se prueban las alertas

**1. Pruebas unitarias (sin clúster).** `prometheus/alerts-test.yml` alimenta a Prometheus con
series sintéticas y comprueba que cada alerta crítica se dispara cuando debe, con sus etiquetas y
mensajes, y que **no** se dispara antes de tiempo ni en los servicios sanos:

```bash
promtool test rules infra/k8s/platform/base/observability/prometheus/alerts-test.yml
amtool check-config infra/k8s/platform/base/observability/alertmanager/alertmanager.yml
```

| Prueba | Escenario | Se comprueba |
|---|---|---|
| ServiceDown | auth deja de responder; form sigue arriba | a los 45 s nada; a los 2 min alerta solo para auth |
| DeploymentUnavailable | gateway pasa de 2 a 1 réplica disponible | a los 4 min nada; a los 8 min alerta con "Only 1 replicas" |
| HighErrorRate | promotion responde 10 % con 500; auth 0 % | alerta solo para promotion con "10%" |
| NodeLowMemory | el nodo baja a 5 % de memoria libre | a los 3 min nada; a los 9 min alerta con "5%" |

**2. Prueba en vivo (con una falla provocada).** Deja un servicio sin pods y observa el ciclo
completo Prometheus → Alertmanager → Discord:

```bash
kubectl -n circleguard scale deploy/circleguard-file-service --replicas=0
# ~1-2 min: Prometheus muestra CircleGuardServiceDown en "Alerts" y llega 🔥 [FIRING] a Discord
# ~5-6 min: también CircleGuardDeploymentUnavailable
kubectl -n circleguard scale deploy/circleguard-file-service --replicas=1
# al recuperarse llega ✅ [RESOLVED]
```

Se usa `file-service` porque ningún flujo crítico (login, QR, encuestas) depende de él. Las
capturas de Prometheus (pestaña *Alerts*), de Alertmanager y de los mensajes de Discord son la
evidencia de la prueba.

Para ver Alertmanager sin publicarlo: `kubectl port-forward -n circleguard-observability svc/alertmanager 9093:9093`.

## 2. Trazas distribuidas con Jaeger

```text
gateway/form ──HTTP──►  form  ──Kafka survey.submitted──►  promotion  ──Kafka promotion.status.changed──►  notification
      │                  │                                      │                                           │
      └──────────────────┴──────────── OTLP/HTTP :4318 ─────────┴───────────────────────────────────────────┴──► Jaeger ──► /jaeger
```

### Cómo funciona

| Pieza | Qué hace |
|---|---|
| `micrometer-tracing-bridge-otel` + `opentelemetry-exporter-otlp` (`build.gradle.kts`) | Crean spans para cada petición HTTP y los envían a Jaeger por OTLP. |
| `management.tracing.enabled: ${TRACING_ENABLED:false}` (cada `application.yml`) | Las trazas están **apagadas** al correr en local y en las pruebas. |
| Componente `platform/base/observability/tracing` | En Kubernetes añade a los 8 servicios `TRACING_ENABLED=true`, el endpoint de Jaeger y la observación de Kafka. |
| `SPRING_KAFKA_TEMPLATE_OBSERVATIONENABLED=true` | El productor (`KafkaTemplate`) añade la cabecera `traceparent` a cada mensaje. |
| `SPRING_KAFKA_LISTENER_OBSERVATIONENABLED=true` | Cada `@KafkaListener` continúa la traza del mensaje que recibe. |
| `management.tracing.sampling.probability: 1.0` | Se guarda el 100 % de las trazas (volumen bajo en el proyecto). |
| Jaeger all-in-one (`jaeger/jaeger.yaml`) | Recibe OTLP en el puerto 4318, guarda las últimas 20 000 trazas en memoria y sirve la interfaz en `/jaeger`. |

Gracias a las cabeceras de Kafka, el envío de una encuesta es **una sola traza** que pasa por
`form` (HTTP + publicación en `survey.submitted`), `promotion` (consumo, cambio de estado y
publicación en `promotion.status.changed`) y `notification` (consumo y envío del aviso).

### Ver una traza de extremo a extremo

1. Enviar una encuesta con síntomas desde la app (o con la prueba E2E de reporte de síntomas).
2. Abrir `http://<IP del nodo>/jaeger` → *Service* `circleguard-form-service` → *Find Traces*.
3. Abrir la traza de `POST /api/v1/surveys`: deben verse los spans de `form`, `survey.submitted send`,
   `survey.submitted receive` en `promotion`, `promotion.status.changed send` y su `receive` en
   `notification`, con sus tiempos.
4. *System Architecture* en Jaeger muestra el grafo form → promotion → notification.

También desde Grafana: datasource **Jaeger** en *Explore*. En los logs (dashboard *CircleGuard - Logs*)
cada línea con traza tiene el campo `trace_id`, con un enlace **TraceID** que abre esa traza en Jaeger.

### Reglas de red y recursos

- `allow-traces-to-jaeger` (namespace `circleguard`) y `allow-traces-from-apps` (observabilidad):
  solo el puerto 4318 de Jaeger desde los servicios.
- `allow-alertmanager-discord`: Alertmanager puede salir por HTTPS a Internet, excluyendo los rangos
  privados.
- Cuota de `circleguard-observability`: 6 Deployments, 8 Services, 12 pods; dev 500 m / 1536 Mi
  pedidos (usa 425 m / 1344 Mi), prod 600 m / 2 Gi (usa 500 m / 1536 Mi).

## 3. Criterios de aceptación → evidencia (HU-27)

### 3.1 Alertas probadas

Pruebas unitarias de las reglas con `promtool` 3.16.0 y de la configuración de Alertmanager con
`amtool` 0.28.1 (la misma versión de la imagen):

```text
$ promtool check rules alerts.yml
Checking alerts.yml
  SUCCESS: 9 rules found

$ promtool test rules alerts-test.yml
Processing test file: alerts-test.yml
  SUCCESS

$ amtool check-config alertmanager.yml
Checking 'alertmanager.yml'  SUCCESS
Found:
 - global config
 - route
 - 1 inhibit rules
 - 1 receivers

$ amtool config routes test severity=critical alertname=CircleGuardServiceDown   → discord
$ amtool config routes test severity=warning  alertname=NodeHighCpu              → discord
```

Las 4 alertas críticas (`CircleGuardServiceDown`, `CircleGuardDeploymentUnavailable`,
`CircleGuardHighErrorRate`, `NodeLowMemory`) se disparan en el momento esperado, con sus
etiquetas y mensajes, y no se disparan antes de tiempo ni para los servicios sanos (tabla de la
sección 1). En dev, Alertmanager está `Running` con el webhook de Discord en el Secret
`alertmanager-discord` y Prometheus evalúa las 9 reglas
([metrics.md, figura 5](metrics.md#9-criterios-de-aceptación--evidencia-hu-27)).

Pendiente: la prueba en vivo de la sección 1 (escalar `file-service` a 0 y ver el aviso
🔥 FIRING / ✅ RESOLVED en Discord) requiere ejecutar `kubectl scale` en el clúster.

### 3.2 Trazas de extremo a extremo

Los 8 servicios envían trazas a Jaeger (`circleguard-auth-service`, `-dashboard-`, `-file-`,
`-form-`, `-gateway-`, `-identity-`, `-notification-` y `-promotion-service`). El envío de una
encuesta produce **una sola traza** que cruza Kafka:

```text
traceID ba6792a724abe5e1425b0286b0dd92d6   (68.72 ms, 2 servicios, 3 spans)
form-service       http post /api/v1/surveys      40.6 ms
form-service       survey.submitted send          52.7 ms   → Kafka
promotion-service  survey.submitted receive        1.8 ms   ← misma traza
```

La encuesta de la prueba se envió **sin síntomas**, así que promotion no cambió el estado del
usuario y no publicó `promotion.status.changed`; con síntomas la traza continúa hasta
notification por el mismo mecanismo (`SPRING_KAFKA_LISTENER_OBSERVATIONENABLED`).

![Traza en Jaeger](../evidencias/jaeger-trace-survey.png)
