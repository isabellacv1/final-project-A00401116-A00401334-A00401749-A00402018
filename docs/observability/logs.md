# Logs centralizados (HU-26)

Cómo se recogen los logs de CircleGuard en un punto central y cómo consultarlos para investigar
errores y eventos.

## 1. Arquitectura

```text
 Nodo k3s                                              circleguard-observability
 ┌───────────────────────────────────────────┐        ┌───────────────────────────────┐
 │ pods de circleguard, circleguard-data y   │        │                               │
 │ circleguard-observability                 │        │  Loki (7 días, PVC 1 Gi)      │
 │        │ stdout/stderr                    │        │    ▲                │         │
 │        ▼                                  │  push  │    │                ▼         │
 │ /var/log/pods/... ──► Grafana Alloy ──────┼────────┼────┘            Grafana       │
 │                      (1 pod por nodo)     │        │              (Explore y       │
 └───────────────────────────────────────────┘        │               dashboard Logs) │
                                                      └───────────────────────────────┘
```

| Componente | Imagen | Función |
|---|---|---|
| Grafana Alloy | `grafana/alloy:v1.5.1` (DaemonSet) | Lee los archivos de log de los contenedores de su nodo, les añade etiquetas (servicio, pod, namespace, nivel) y los envía a Loki. Sustituye a Promtail, que Grafana dejó de mantener. |
| Loki | `grafana/loki:3.3.2` | Guarda e indexa los logs. Retención de **7 días**. |
| Grafana | el mismo de la HU-27 | Datasource `Loki` y dashboard **CircleGuard - Logs**. |

Los servicios **no necesitan cambios**: escriben en la salida estándar con el formato de Spring Boot,
y Kubernetes guarda esa salida en `/var/log/pods`, de donde la lee Alloy.

Manifiestos:

- [`infra/k8s/platform/base/observability/loki/`](../../infra/k8s/platform/base/observability/loki/): Deployment, Service, PVC y configuración (`loki.yml`).
- [`infra/k8s/platform/base/observability/alloy/`](../../infra/k8s/platform/base/observability/alloy/): DaemonSet, permisos y configuración (`config.alloy`).

## 2. Cómo se identifica cada registro

Cada línea llega a Loki con estas **etiquetas** (se usan para filtrar):

| Etiqueta | Ejemplo | Origen |
|---|---|---|
| `app` | `circleguard-auth-service` | Etiqueta `app.kubernetes.io/name` del pod (o el nombre del contenedor si no la tiene). **Identifica el servicio.** |
| `namespace` | `circleguard`, `circleguard-data` | Namespace del pod. |
| `pod` | `circleguard-auth-service-7c9d…` | Pod exacto (útil con varias réplicas). |
| `container` | `auth-service` | Contenedor dentro del pod. |
| `node` | `cg-k3s-prod-server` | Nodo donde corre (útil al probar la caída de un nodo). |
| `level` | `ERROR`, `WARN`, `INFO`, `DEBUG` | Extraído del texto, solo en los servicios Spring Boot. |

Y estos **metadatos** (se ven al abrir una línea, no son etiquetas para no crear demasiados índices):

| Campo | Ejemplo |
|---|---|
| `logger` | `c.c.auth.service.AuthService` (clase que escribió el log) |
| `thread` | `nio-8180-exec-1` (hilo de la petición) |

Además, la propia línea de Spring Boot 3.2 ya incluye el nombre del servicio:

```text
2026-11-18T10:15:30.123Z ERROR 1 --- [circleguard-form-service] [nio-8086-exec-3] c.c.form.service.SurveyService : Could not publish survey
```

**Stack traces:** en los servicios, Alloy une las líneas de una excepción (`at …`, `Caused by: …`) con
la línea que la registró, así que cada error aparece como **una sola entrada** con su traza completa.

## 3. Despliegue

Va incluido en el stack de observabilidad, así que se aplica con el overlay de plataforma:

```bash
kubectl apply -k infra/k8s/platform/overlays/dev     # o stage / prod
kubectl get pods -n circleguard-observability
```

Deben quedar en `Running` el pod `loki` y un pod `alloy` por nodo. Grafana necesita el Secret
`grafana-admin` (ver [metrics.md](metrics.md#31-crear-el-usuario-administrador-de-grafana)).

Comprobación rápida:

```bash
# Loki listo
kubectl exec -n circleguard-observability deploy/loki -- wget -qO- localhost:3100/ready
# Alloy no tiene errores enviando
kubectl logs -n circleguard-observability ds/alloy | grep -i error
```

## 4. Cómo consultar los logs

### 4.1 Dashboard "CircleGuard - Logs"

En Grafana (`http://<IP del nodo>/grafana`) → carpeta **CircleGuard** → **CircleGuard - Logs**.

Arriba hay tres filtros: **Service** (uno o varios servicios), **Level** y **Search** (texto libre).

| Panel | Qué muestra |
|---|---|
| Errors / Warnings / Exceptions / Log lines | Cuántos hay en el rango de tiempo elegido. |
| Log volume per service | Líneas por servicio en el tiempo. Un servicio que de pronto escribe mucho más suele estar fallando o reintentando. |
| Errors and warnings per service | Cuándo empezó a fallar cada servicio. |
| Logs | Los registros filtrados por los tres filtros. Al hacer clic en una línea se ven pod, nodo, logger e hilo. |
| Errors with stack trace | Solo los `ERROR`, cada uno con su traza. |
| Data layer | Errores de Postgres, Kafka, Redis, Neo4j y LDAP. |

### 4.2 Explore (consultas libres)

Grafana → **Explore** → datasource **Loki**. Las consultas usan LogQL: primero se eligen las
etiquetas entre `{}` y después se filtra el texto.

| Para… | Consulta |
|---|---|
| Ver todos los logs de un servicio | `{app="circleguard-auth-service"}` |
| Ver solo los errores de todos los servicios | `{namespace="circleguard", level="ERROR"}` |
| Buscar un texto | `{namespace="circleguard"} \|= "Invalid or Expired Token"` |
| Buscar sin distinguir mayúsculas | `{namespace="circleguard"} \|~ "(?i)timeout"` |
| Excluir ruido | `{app="circleguard-gateway-service"} != "actuator"` |
| Encontrar excepciones | `{namespace="circleguard"} \|~ "Exception\|Caused by"` |
| Logs de una clase concreta | `{app="circleguard-form-service"} \| logger=~".*SurveyService"` |
| Logs de un pod (una réplica) | `{pod="circleguard-auth-service-7c9d…"}` |
| Logs de un nodo | `{node="cg-k3s-prod-agent"}` |
| Errores de la base de datos | `{namespace="circleguard-data", app=~".*postgres.*"} \|~ "(?i)error\|fatal"` |
| Contar errores por servicio (5 min) | `sum by (app) (count_over_time({namespace="circleguard", level="ERROR"}[5m]))` |

Consejo: elegir siempre el rango de tiempo más corto posible (arriba a la derecha); las consultas
sobre 7 días son más lentas.

### 4.3 Ejemplos de investigación

**Un usuario no puede entrar al campus (QR rechazado).**
1. `{app="circleguard-gateway-service"} |= "validate"` en el momento del reporte.
2. Si aparece `Invalid or Expired Token`, el QR caducó (dura 60 s). Si aparece `Health Risk Detected`,
   el estado del usuario es de riesgo: revisar `{app="circleguard-promotion-service"}` para ver cuándo cambió.
3. Si hay errores de Redis en el gateway, el problema es de infraestructura: `{namespace="circleguard-data", app=~".*redis.*"}`.

**Las encuestas no cambian el estado de salud.**
1. `{app="circleguard-form-service", level=~"ERROR|WARN"}` → ¿se publicó el evento en Kafka?
2. `{app="circleguard-promotion-service"} |~ "(?i)survey|kafka"` → ¿se consumió?
3. `{namespace="circleguard-data", app=~".*kafka.*"}` → ¿el broker está disponible?

**Un servicio se reinicia (alerta `CircleGuardPodRestarting` de la HU-27).**
1. En el dashboard, filtrar ese servicio y nivel `ERROR` alrededor de la hora del reinicio.
2. Los logs del contenedor anterior siguen en Loki aunque Kubernetes ya haya creado otro
   (con `kubectl logs` solo se ven con `--previous` y únicamente el último reinicio).

### 4.4 Sin Grafana

Para un vistazo rápido desde la terminal (solo logs actuales, sin historial ni búsqueda entre servicios):

```bash
kubectl logs -n circleguard deploy/circleguard-auth-service --since=15m
kubectl logs -n circleguard deploy/circleguard-auth-service --previous   # contenedor anterior
```

## 5. Retención y límites

| Parámetro | Valor | Dónde |
|---|---|---|
| Retención | 7 días (el compactor borra lo más antiguo) | `loki.yml` → `retention_period` |
| Almacenamiento | PVC de 1 Gi | `loki.yaml` |
| Ingesta | 4 MB/s (ráfagas de 8 MB/s) | `loki.yml` → `limits_config` |
| Recursos Loki | 100 m / 256 Mi pedidos, 400 m / 768 Mi límite | `loki.yaml` |
| Recursos Alloy (por nodo) | 50 m / 128 Mi pedidos, 200 m / 384 Mi límite | `alloy.yaml` |

Con todo el stack de observabilidad, el namespace usa en `prod` (2 nodos) 425 m de CPU y 1,3 Gi de
memoria pedidos, dentro de su cuota.

## 6. Problemas frecuentes

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| El dashboard no muestra nada | Alloy no llega a Loki o no lee archivos | `kubectl logs ds/alloy -n circleguard-observability`; comprobar que el pod `loki` está `Ready`. |
| Un servicio no aparece en el filtro Service | El pod no tiene logs en el rango elegido o no tiene la etiqueta `app.kubernetes.io/name` | Ampliar el rango; en ese caso aparece con el nombre del contenedor. |
| Las líneas no tienen `level` | No son de un servicio Spring Boot (bases de datos, Kafka) | Filtrar por texto: `\|~ "(?i)error"`. |
| `too many outstanding requests` o consultas lentas | Rango de tiempo muy largo | Reducir el rango o filtrar primero por `app`. |
| Loki en `CrashLoopBackOff` por disco | PVC lleno | Reducir `retention_period` o ampliar el PVC. |
