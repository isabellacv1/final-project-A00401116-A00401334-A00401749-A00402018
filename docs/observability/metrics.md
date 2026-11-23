# Métricas y dashboards (HU-27)

Cómo se recopilan las métricas de CircleGuard, cómo se despliega el stack de monitoreo y cómo
interpretar los dashboards y las alertas.

## 1. Arquitectura

```text
        circleguard (namespace)                     circleguard-observability (namespace)
 ┌──────────────────────────────────┐        ┌─────────────────────────────────────────────┐
 │ auth, identity, form, gateway,   │ scrape │ Prometheus ──► Grafana (/grafana)           │
 │ promotion, notification,         │◄───────│     ▲   ▲                                   │
 │ dashboard, file                  │        │     │   └── kube-state-metrics (estado k8s) │
 │   /actuator/prometheus           │        │     └────── node-exporter (1 por nodo)      │
 └──────────────────────────────────┘        │ cAdvisor (CPU/memoria por contenedor),      │
                                             │ leído a través de la API de Kubernetes      │
                                             └─────────────────────────────────────────────┘
```

| Componente | Imagen | Qué aporta |
|---|---|---|
| Spring Boot Actuator + Micrometer | dependencias en `build.gradle.kts` | Cada servicio expone `/actuator/prometheus` (HTTP, JVM, pool de base de datos) y las sondas `/actuator/health/liveness` y `/actuator/health/readiness`. |
| Prometheus | `prom/prometheus:v2.55.1` | Recoge las métricas cada 15 s, las guarda 7 días (máx. 1,5 GB) y evalúa las alertas. |
| kube-state-metrics | `kube-state-metrics:v2.13.0` | Estado de los objetos: réplicas disponibles, fase de los pods, reinicios, cuotas. |
| node-exporter | `prom/node-exporter:v1.8.2` | CPU, memoria, disco y red de cada nodo (DaemonSet). |
| Grafana | `grafana/grafana:11.3.1` | Dashboards. El datasource y los dashboards se cargan solos al arrancar. |

Los manifiestos están en [`infra/k8s/platform/base/observability/`](../../infra/k8s/platform/base/observability/) y cada
overlay de plataforma (`dev`, `stage`, `prod`) los incluye. Los overlays de aplicación usan solo el componente
`scrape-annotations` para añadir anotaciones a los Deployments de `circleguard`.

## 2. Configuración de scraping de Prometheus

El archivo es [`infra/k8s/platform/base/observability/prometheus/prometheus.yml`](../../infra/k8s/platform/base/observability/prometheus/prometheus.yml).

| Job | Cómo encuentra los targets | Qué lee |
|---|---|---|
| `circleguard-services` | Pods del namespace `circleguard` con la anotación `prometheus.io/scrape: "true"` | `/actuator/prometheus` en el puerto del contenedor llamado `http` |
| `kube-state-metrics` | Servicio `kube-state-metrics:8080` | Estado de Deployments, pods y cuotas |
| `node-exporter` | Endpoints del servicio `node-exporter` | Métricas de cada nodo |
| `cadvisor` | Nodos del clúster, a través de `kubernetes.default.svc/api/v1/nodes/<nodo>/proxy/metrics/cadvisor` | `container_cpu_usage_seconds_total` y `container_memory_working_set_bytes` |
| `prometheus` | `localhost:9090` | El propio Prometheus |

### Anotaciones de los microservicios

Los Deployments de los servicios no llevan las anotaciones escritas a mano. Las agrega el
componente de Kustomize [`observability/scrape-annotations`](../../infra/k8s/platform/base/observability/scrape-annotations/kustomization.yaml),
que cada overlay incluye en `components:`. Parcha todos los Deployments del namespace
`circleguard` cuyo nombre sigue el patrón `circleguard-<servicio>-service`:

```yaml
spec:
  template:
    metadata:
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/path: /actuator/prometheus
```

Requisitos para que un servicio nuevo aparezca en Prometheus:

1. Llamar al Deployment `circleguard-<servicio>-service` en el namespace `circleguard`.
2. Declarar el puerto del contenedor con el nombre `http`. Si las métricas están en otro puerto,
   se puede añadir la anotación `prometheus.io/port: "<puerto>"`.
3. Exponer `/actuator/prometheus` sin autenticación (en identity ya se permite en `SecurityConfig`).

Prometheus añade a cada métrica las etiquetas `service` (de `app.kubernetes.io/name`), `namespace`,
`pod` y `node`. Micrometer añade `application` (el `spring.application.name`).

### Reglas de red

La política base ya permite que el namespace de observabilidad entre a `circleguard` y
`circleguard-data`. [`observability/networkpolicies.yaml`](../../infra/k8s/platform/base/observability/networkpolicies.yaml)
permite además que Prometheus y kube-state-metrics lleguen a la API de Kubernetes
(`10.43.0.1:443` y los nodos en `:6443`), necesaria para descubrir los targets y leer cAdvisor.

## 3. Despliegue

### 3.1 Crear el usuario administrador de Grafana

La contraseña **no se guarda en el repositorio**. Grafana la lee del Secret `grafana-admin`, que se
crea con el script [`create-grafana-secret.sh`](../../infra/k8s/platform/base/observability/create-grafana-secret.sh):

```bash
kubectl config use-context <contexto-del-ambiente>
kubectl apply -k infra/k8s/platform/overlays/dev # crea el namespace si no existe
infra/k8s/platform/base/observability/create-grafana-secret.sh
```

- Sin variables, crea el usuario `admin` con una contraseña aleatoria de 32 caracteres y la muestra
  **una sola vez**. Guárdala en el gestor de contraseñas del equipo o como credencial de Jenkins.
- Para usar una contraseña propia: `GRAFANA_ADMIN_PASSWORD='...' infra/k8s/platform/base/observability/create-grafana-secret.sh`
  (mínimo 12 caracteres). `GRAFANA_ADMIN_USER` cambia el usuario.
- La contraseña pasa a `kubectl` por un descriptor de archivo, no queda en el historial de la
  terminal ni en la lista de procesos.
- Pide confirmación mostrando el contexto actual, para no crearla en el clúster equivocado.
- Se puede volver a ejecutar para **rotar** la contraseña: actualiza el Secret y reinicia Grafana.

Mientras el Secret no exista, el pod de Grafana queda en `CreateContainerConfigError`; el resto del
stack funciona igual.

Para recuperar la contraseña (requiere permisos sobre Secrets en el namespace):

```bash
kubectl get secret grafana-admin -n circleguard-observability \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

### 3.2 Aplicar

```bash
kubectl apply -k infra/k8s/platform/overlays/dev     # o stage / prod
kubectl get pods -n circleguard-observability
```

Deben quedar en `Running`: `prometheus`, `grafana`, `kube-state-metrics` y un `node-exporter` por nodo.

## 4. Acceso

| Herramienta | Cómo entrar |
|---|---|
| Grafana | `http://<IP del nodo>/grafana` (Ingress de Traefik). Usuario y contraseña del Secret `grafana-admin`. Los dashboards están en la carpeta **CircleGuard**. |
| Prometheus | No se publica. `kubectl port-forward -n circleguard-observability svc/prometheus 9090:9090` y abrir `http://localhost:9090`. |

### Comprobar que el scraping funciona

En Prometheus, **Status → Targets**: todos los jobs deben estar en `UP`. Si un servicio no aparece:

```bash
# ¿El pod tiene las anotaciones?
kubectl get pod -n circleguard -l app.kubernetes.io/name=circleguard-gateway-service \
  -o jsonpath='{.items[0].metadata.annotations}'
# ¿El endpoint responde?
kubectl port-forward -n circleguard deploy/circleguard-gateway-service 8087:8087
curl -s localhost:8087/actuator/prometheus | head
```

Consulta rápida en Prometheus: `up{job="circleguard-services"}` debe devolver `1` por cada pod.

## 5. Métricas y su interpretación

### Servicios (Actuator / Micrometer)

| Métrica | Consulta | Cómo interpretarla |
|---|---|---|
| Disponibilidad | `up{job="circleguard-services"}` | `1` = Prometheus lee el servicio; `0` = no responde (caído, reiniciando o sin red). |
| Tráfico | `sum by (application) (rate(http_server_requests_seconds_count[5m]))` | Peticiones por segundo. Una caída brusca sin motivo puede indicar que el Ingress o un servicio anterior falla. |
| Errores de servidor | `... {status=~"5.."} / total` | Porcentaje de respuestas 5xx. Normal: cercano a 0 %. **Alerta** si supera 5 % durante 5 min. |
| Errores de cliente | `rate(http_server_requests_seconds_count{status=~"4.."}[5m])` | 401/403 = problemas de autenticación; 404 = rutas incorrectas; 400 = datos inválidos. Un pico de 401 en login puede ser un intento de adivinar contraseñas. |
| Latencia p95 | `histogram_quantile(0.95, sum by (application, le) (rate(http_server_requests_seconds_bucket[5m])))` | El 95 % de las peticiones tarda menos que este valor. Objetivo: **≤ 500 ms** (el mismo de las pruebas de carga de la HU-32). |
| Heap de la JVM | `jvm_memory_used_bytes{area="heap"}` | Memoria Java en uso. Si se mantiene cerca del máximo, el servicio se vuelve lento por el recolector de basura o termina en `OutOfMemoryError`. |
| CPU del proceso | `process_cpu_usage` | 1 = un núcleo completo. Valores altos sostenidos indican que hace falta más CPU o más réplicas. |
| Pausas del GC | `rate(jvm_gc_pause_seconds_sum[5m])` | Segundos por segundo en recolección de basura. Si crece junto al heap, falta memoria. |
| Hilos | `jvm_threads_live_threads` | Si crecen sin parar, hay peticiones bloqueadas (por ejemplo esperando una base de datos lenta). |
| Pool de conexiones | `hikaricp_connections_active`, `hikaricp_connections_pending` | Conexiones pendientes > 0 de forma sostenida = el pool está agotado y las peticiones esperan a la base de datos. |

Las rutas `/actuator/*` se excluyen de las consultas de tráfico y latencia para no mezclar las
sondas de Kubernetes y el scraping con el tráfico real.

### Kubernetes (kube-state-metrics y cAdvisor)

| Métrica | Cómo interpretarla |
|---|---|
| `kube_deployment_status_replicas_available` vs. `kube_deployment_spec_replicas` | Si hay menos réplicas disponibles que las pedidas, el Deployment está degradado (pods que no arrancan o no pasan readiness). |
| `kube_pod_container_status_restarts_total` | Reinicios de contenedores. Varios seguidos = *crash loop* o límite de memoria alcanzado (`OOMKilled`). |
| `kube_pod_status_phase{phase="Pending"}` | Pods que no se pueden programar: normalmente falta CPU/memoria en los nodos o en la cuota del namespace. |
| `kube_resourcequota` (used / hard) | Uso de la cuota del namespace. Al llegar al 100 % se rechazan pods nuevos. |
| `container_memory_working_set_bytes` | Memoria real de cada contenedor. Al alcanzar su límite, Kubernetes lo mata. |
| `container_cpu_usage_seconds_total` | CPU usada por contenedor. |

### Nodos (node-exporter)

| Métrica | Cómo interpretarla |
|---|---|
| CPU: `1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))` | Uso de CPU del nodo. Sostenido por encima de 85 % = el nodo está saturado. |
| Memoria: `1 - MemAvailable / MemTotal` | Por debajo de 10 % libre el kernel empieza a matar procesos. |
| Disco: `1 - avail / size` | Por encima de 85 %, riesgo de no poder bajar imágenes ni escribir logs (k3s también empieza a desalojar pods). |
| Red: `node_network_receive/transmit_bytes_total` | Tráfico de entrada y salida. Útil para correlacionar picos de carga. |

## 6. Dashboards

Están en [`infra/k8s/platform/base/observability/grafana/dashboards/`](../../infra/k8s/platform/base/observability/grafana/dashboards/)
y Grafana los carga al arrancar (carpeta **CircleGuard**, no editables desde la interfaz: los cambios
se hacen en el JSON y se aplican con `kubectl apply -k`).

| Dashboard | Para qué sirve | Paneles |
|---|---|---|
| **CircleGuard - Services** | Estado técnico de los microservicios. Tiene un selector de servicio. | Servicios arriba/abajo, reinicios, alertas activas, línea de tiempo de disponibilidad, peticiones/s, % de 5xx, 4xx por código, p95 por servicio, endpoints más lentos, heap, CPU, hilos, GC y conexiones a base de datos. |
| **CircleGuard - Infrastructure** | Capacidad del clúster. | Nodos, pods en ejecución, pods no listos, Deployments degradados, CPU/memoria/disco/red por nodo, memoria y CPU por pod, uso de la cuota. |
| **CircleGuard - Business** | Actividad del campus. | Validaciones de QR, encuestas enviadas, logins y logins fallidos en 24 h; validaciones y QR generados por minuto, encuestas aceptadas/rechazadas, logins por código y p95 de la validación en la entrada. |

Cómo leerlos ante un problema:

1. **¿Algo está caído?** Services → *Services down* y *Service status*. Infrastructure → *Deployments degraded*.
2. **¿Va lento?** Services → *p95 latency per service* y *Slowest endpoints*. Si sube la latencia
   junto con *DB connections pending*, el cuello de botella es la base de datos; si sube con *Heap
   used* y *GC pause time*, falta memoria.
3. **¿Falla?** Services → *Server error rate (5xx)* para ver qué servicio y cuándo empezó.
4. **¿Faltan recursos?** Infrastructure → CPU, memoria y disco de los nodos, y *Quota used*.

Las métricas de negocio se calculan a partir de las peticiones HTTP. Una validación de QR denegada
(usuario en riesgo) también responde 200, así que el panel cuenta validaciones, no accesos permitidos.

## 7. Alertas

Definidas en [`prometheus/alerts.yml`](../../infra/k8s/platform/base/observability/prometheus/alerts.yml). Se ven en
Prometheus (**Alerts**) y en el panel *Firing alerts* del dashboard de servicios, y **Alertmanager las
envía a Discord**: rutas, pruebas unitarias y prueba en vivo en [alerts-and-tracing.md](alerts-and-tracing.md).

| Alerta | Condición | Severidad | Qué revisar |
|---|---|---|---|
| `CircleGuardServiceDown` | `up == 0` durante 1 min | critical | `kubectl get pods -n circleguard`, logs del pod y eventos (`kubectl describe pod`). |
| `CircleGuardDeploymentUnavailable` | Réplicas disponibles < pedidas durante 5 min | critical | Pods en `CrashLoopBackOff`, `ImagePullBackOff` o que no pasan readiness. |
| `CircleGuardPodRestarting` | Más de 2 reinicios en 15 min | warning | `kubectl describe pod`: si dice `OOMKilled`, subir el límite de memoria. |
| `CircleGuardHighErrorRate` | 5xx > 5 % durante 5 min | critical | Logs del servicio y de sus dependencias (base de datos, Redis, Kafka). |
| `CircleGuardHighLatency` | p95 > 500 ms durante 5 min | warning | Endpoints más lentos, conexiones pendientes, CPU y heap. |
| `CircleGuardJvmHeapHigh` | Heap > 90 % durante 10 min | warning | Posible fuga de memoria o límite bajo; revisar GC y reinicios. |
| `NodeHighCpu` | CPU del nodo > 85 % durante 10 min | warning | Qué pods consumen más (dashboard de infraestructura). |
| `NodeLowMemory` | Memoria disponible < 10 % durante 5 min | critical | Memoria por pod; reducir réplicas o ampliar el nodo. |
| `NodeDiskAlmostFull` | Disco libre < 15 % durante 10 min | warning | Imágenes y volúmenes sin usar en el nodo. |

## 8. Recursos y límites

| Componente | Pedido (CPU / memoria) | Límite (CPU / memoria) | Almacenamiento |
|---|---|---|---|
| Prometheus | 100 m / 512 Mi | 500 m / 1 Gi | PVC 2 Gi |
| Grafana | 50 m / 128 Mi | 250 m / 384 Mi | PVC 512 Mi |
| kube-state-metrics | 25 m / 64 Mi | 100 m / 128 Mi | — |
| node-exporter (por nodo) | 25 m / 64 Mi | 100 m / 128 Mi | — |

La cuota de `circleguard-observability` se amplió a 10 pods y 2 DaemonSets para dejar espacio a
Loki y Grafana Alloy, que recogen los logs (HU-26, ver [logs.md](logs.md)).
