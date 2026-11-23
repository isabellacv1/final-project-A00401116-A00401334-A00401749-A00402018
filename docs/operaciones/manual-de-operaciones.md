# Manual de operaciones de CircleGuard

Guía para operar CircleGuard en el día a día: dónde corre cada cosa, cómo desplegar,
cómo saber si el sistema está sano, qué hacer ante una falla y cómo recuperarse. Este
manual es el punto de entrada para operar el sistema. Cuando un tema necesita más detalle,
remite al documento especializado.

> Actualizado al cierre del Sprint 2 (22 de noviembre de 2026). Reemplaza la operación
> sobre Docker Compose de la Parte 1: hoy los ambientes corren en Kubernetes (k3s).

## 1. Mapa del sistema

### 1.1 Componentes

| Capa | Componentes | Namespace |
|---|---|---|
| Aplicación | 8 microservicios Spring Boot (auth, identity, promotion, form, gateway, notification, dashboard, file) y la app web | `circleguard` |
| Datos y mensajería | PostgreSQL, Neo4j, Redis, Kafka, Zookeeper, LDAP | `circleguard-data` |
| Observabilidad | Prometheus, Grafana, Loki, Grafana Alloy, kube-state-metrics, node-exporter | `circleguard-observability` |
| Entrada | Ingress de Traefik (incluido en k3s) | `kube-system` |

### 1.2 Infraestructura (AWS `us-east-1`)

| Servidor | Función | Cómo se gestiona |
|---|---|---|
| `cg-devops` | Jenkins y Nexus (registro de imágenes, `10.20.1.230:8082`) | Bootstrap con `infra/bootstrap/` |
| `cg-sonarqube` | SonarQube | Bootstrap con `infra/bootstrap/` |
| Clúster k3s **dev** | 1 nodo server (`m7i-flex.large`, 40 GB) | Terraform, `infra/terraform/envs/dev` |
| Clúster k3s **stage** | 1 nodo server (`m7i-flex.large`, 40 GB) | Terraform, `infra/terraform/envs/stage` |
| Clúster k3s **prod** | 1 server + 1 agent (`m7i-flex.large`, 50 GB c/u) | Terraform, `infra/terraform/envs/prod` |
| `cg-dev`, `cg-stage`, `cg-prod` | Ambientes Docker Compose de la Parte 1 | Manual. Reemplazados por los clústeres k3s |

### 1.3 Accesos

| Herramienta | URL / forma de acceso | Credenciales |
|---|---|---|
| Jenkins | `http://<IP cg-devops>:8080` | Usuario personal de Jenkins |
| Nexus | `http://<IP cg-devops>:8081` | `ci-publisher` (CI), `deploy-reader` (despliegue) |
| SonarQube | `http://<IP cg-sonarqube>:9092` | Usuario personal |
| App web (dev) | `http://10.20.2.113/` (Ingress) | Usuario de prueba de LDAP |
| Grafana | `http://<IP del nodo>/grafana` | Secret `grafana-admin` |
| Prometheus | `kubectl port-forward -n circleguard-observability svc/prometheus 9090:9090` | — |
| Clústeres | `kubectl` con el kubeconfig del ambiente | Credenciales `<ambiente>-kubeconfig` en Jenkins |
| Nodos | SSH con `cg-<ambiente>-key` desde la IP autorizada en el security group | Llave privada del ambiente |

Regla de oro: **antes de cualquier comando, confirmar el ambiente** con
`kubectl config current-context`. Los tres clústeres usan los mismos nombres de namespace.

## 2. Operación diaria

### 2.1 Encender y apagar la infraestructura

Para controlar el costo (ver [`../costos/costos-infraestructura.md`](../costos/costos-infraestructura.md)),
las instancias se apagan cuando nadie las usa.

```bash
# Encender (primero DevOps, luego los clústeres)
aws ec2 start-instances --instance-ids <id-cg-devops> <id-cg-sonarqube>
aws ec2 start-instances --instance-ids <ids de los nodos k3s del ambiente>

# Apagar al terminar la jornada
aws ec2 stop-instances --instance-ids <ids>
```

Después de encender:

1. Las instancias no tienen Elastic IP: **la IP pública cambia** en cada arranque.
   Actualizarla en `scripts/infrastructure.env`, en el kubeconfig local y en las URLs que
   la usen.
2. Ejecutar `scripts/check-infrastructure.sh`: verifica que las instancias estén `running`
   y que Jenkins, Nexus y SonarQube respondan. Detalle en [`infraestructura.md`](infraestructura.md).
3. Comprobar el clúster: `kubectl get nodes` (todos `Ready`) y `kubectl get pods -A`.

Los volúmenes EBS y los snapshots se cobran aunque las instancias estén apagadas.

### 2.2 Chequeo rápido de salud

```bash
kubectl get nodes
kubectl get pods -n circleguard            # 9 Deployments en Running/Ready
kubectl get pods -n circleguard-data
kubectl get hpa -n circleguard             # autoescalado del gateway
kubectl top nodes
```

En Grafana, el dashboard **CircleGuard - Services** debe mostrar todos los servicios
arriba y el panel *Firing alerts* vacío.

## 3. Despliegues

### 3.1 Flujo normal (automático)

Todo cambio entra por Pull Request a `dev`. Al integrarse, Jenkins ejecuta:

```
Build → Tests → Integration tests → SonarQube → Terraform validate/plan/apply (dev)
→ Trivy (IaC e imágenes) → Publish images (Nexus) → Deploy dev (Kustomize)
→ Verify → Smoke tests → E2E (Playwright)
```

- Las imágenes se etiquetan con la versión semántica del build. **Nunca se usa `latest`**.
- Trivy bloquea la publicación si una imagen tiene vulnerabilidades HIGH o CRITICAL.
- Si un build falla, llega una notificación a Discord con el job, la rama y el commit.

Detalle: [`pipeline.md`](pipeline.md) y [`despliegue.md`](despliegue.md).

### 3.2 Promoción a stage y prod

- `dev → stage`: automática si pasan las E2E. `stage → prod`: con aprobación manual en
  Jenkins (queda registrado quién aprobó).
- Siempre se promueve **la misma versión** que se probó en dev.
- **Estado actual:** las etapas están implementadas, pero el `Jenkinsfile` tiene
  `promote: false` hasta validar con evidencia los clústeres de stage y prod
  (credenciales, contextos, DNS/CORS, TLS y capacidad). Para habilitarla, cambiar a
  `promote: true` y añadir los contextos y URLs de stage y prod en `k8sContexts` y
  `k8sIngressUrls`.

### 3.3 Despliegue manual de un servicio

```bash
scripts/k8s/rollout.sh promotion 10.20.1.230:8082/circleguard/promotion-service:1.3.0
kubectl -n circleguard rollout status deploy/circleguard-promotion-service
```

El despliegue usa **Rolling Update** (`maxSurge: 1`): no hay caída del servicio mientras se
reemplazan los pods.

### 3.4 Canary (dashboard)

```bash
scripts/k8s/canary.sh start 10.20.1.230:8082/circleguard/dashboard-service:1.3.0 10   # 10 % del tráfico
scripts/k8s/canary.sh status
scripts/k8s/canary.sh weight 50      # subir si las métricas están bien
scripts/k8s/canary.sh promote        # o abort para volver atrás
```

Durante el canary, vigilar en Grafana el % de 5xx y la latencia p95 del dashboard. Detalle
en [`patrones.md`](patrones.md) §3.

## 4. Rollback

| Situación | Qué pasa / qué hacer |
|---|---|
| Falla el `apply`, el rollout o la verificación en el pipeline | **Automático**: la librería restaura solo los Deployments y ConfigMaps que cambiaron y publica `k8s/rollback-<build>.txt`. Revisar ese artefacto. |
| Una versión ya desplegada se comporta mal | `kubectl -n circleguard rollout undo deploy/<servicio>` o desplegar la versión anterior con `scripts/k8s/rollout.sh`. |
| Canary con errores | `scripts/k8s/canary.sh abort`. |
| Cambio de Secrets, datos, esquema de base de datos o Kafka | **No** se revierte automáticamente. Requiere decisión del equipo y procedimiento manual. |

Ver historial de versiones: `kubectl -n circleguard rollout history deploy/<servicio>`.

## 5. Monitoreo y alertas

| Dashboard (Grafana → carpeta CircleGuard) | Para qué |
|---|---|
| CircleGuard - Services | Disponibilidad, peticiones/s, errores 5xx, latencia p95, heap, conexiones a BD |
| CircleGuard - Infrastructure | CPU, memoria y disco de nodos y pods; uso de cuotas |
| CircleGuard - Business | Validaciones de QR, encuestas, logins |
| CircleGuard - Logs | Logs centralizados con filtros por servicio, nivel y texto |

Las alertas se ven en Prometheus (**Alerts**) y en el panel *Firing alerts*. No hay
Alertmanager, así que **no llegan notificaciones**: hay que revisar el dashboard.

| Alerta | Severidad | Primera acción |
|---|---|---|
| `CircleGuardServiceDown` | critical | Ver runbook 6.1 |
| `CircleGuardDeploymentUnavailable` | critical | Ver runbook 6.2 |
| `CircleGuardHighErrorRate` (5xx > 5 %) | critical | Ver runbook 6.3 |
| `NodeLowMemory` | critical | Ver runbook 6.5 |
| `CircleGuardPodRestarting` | warning | `kubectl describe pod`: si dice `OOMKilled`, subir el límite de memoria |
| `CircleGuardHighLatency` (p95 > 500 ms) | warning | Ver runbook 6.4 |
| `CircleGuardJvmHeapHigh` | warning | Revisar GC y reinicios del servicio |
| `NodeHighCpu` / `NodeDiskAlmostFull` | warning | Ver runbook 6.5 |

Detalle: [`../observability/metrics.md`](../observability/metrics.md) y
[`../observability/logs.md`](../observability/logs.md).

## 6. Runbooks de incidentes

### 6.1 Un servicio está caído

1. `kubectl get pods -n circleguard` → identificar el pod que no está `Running`/`Ready`.
2. `kubectl describe pod <pod> -n circleguard` → leer los eventos al final.
3. `kubectl logs <pod> -n circleguard --previous` → por qué murió el contenedor anterior.
4. En Grafana → CircleGuard - Logs, filtrar el servicio con nivel `ERROR`.
5. Si el problema es una dependencia (base de datos, Redis, Kafka), ir a 6.6.

### 6.2 Deployment sin réplicas disponibles

| Estado del pod | Causa probable | Acción |
|---|---|---|
| `ImagePullBackOff` | La versión no existe en Nexus o falta `nexus-pull-secret` | Verificar el tag en Nexus y `kubectl get secret nexus-pull-secret -n circleguard` |
| `CrashLoopBackOff` | Error al arrancar: configuración o secreto faltante | Logs con `--previous`; revisar ConfigMap y Secrets del servicio |
| `Pending` | Sin capacidad o cuota agotada | `kubectl describe resourcequota -n circleguard` y `kubectl describe node` |
| `Running` pero no `Ready` | Falla la readiness probe | Revisar `/actuator/health/readiness` y dependencias |

### 6.3 Muchos errores 5xx

1. Services → *Server error rate (5xx)*: qué servicio y desde cuándo.
2. ¿Coincide con un despliegue? Si sí, hacer rollback (sección 4).
3. Si no, buscar en Loki: `{app="<servicio>", level="ERROR"}`.
4. Los clientes entre servicios tienen timeouts, reintentos y circuit breaker
   (Resilience4j): un circuito abierto indica que la dependencia está fallando.

### 6.4 El sistema va lento

- Latencia alta + *DB connections pending* altas → cuello de botella en la base de datos.
- Latencia alta + heap y pausas de GC altas → falta memoria en el servicio.
- CPU del gateway alta → el HPA debería escalarlo a 2 réplicas (`kubectl get hpa`). Si no
  escala, revisar que `metrics-server` funcione (`kubectl top pods`).

### 6.5 Nodo sin recursos

1. Dashboard Infrastructure → qué pod consume más.
2. Disco lleno: limpiar imágenes sin usar en el nodo (`sudo k3s crictl rmi --prune`).
3. Memoria: reducir réplicas temporales o pasar a un tipo de instancia mayor en Terraform
   (`infra/terraform/shared/main.tf`, cambio con plan revisado y aprobación).

### 6.6 Falla una dependencia de datos

```bash
kubectl get pods -n circleguard-data
kubectl logs <pod> -n circleguard-data --tail=100
```

| Dependencia caída | Impacto esperado |
|---|---|
| Redis | El gateway no puede validar QR en la entrada al campus |
| Kafka | Las encuestas no cambian el estado de salud; los eventos se reintentan |
| PostgreSQL | Login, formularios y dashboard fallan |
| Neo4j | No se propaga el riesgo entre contactos |
| LDAP | No se puede iniciar sesión |

### 6.7 Un usuario no puede entrar al campus (QR rechazado)

1. Loki: `{app="circleguard-gateway-service"} |= "validate"` a la hora del reporte.
2. `Invalid or Expired Token` → el QR caducó (dura 60 s); generar uno nuevo.
3. `Health Risk Detected` → el usuario está en riesgo; revisar en promotion cuándo cambió.
4. Errores de Redis → incidente de infraestructura (6.6).

## 7. Secretos y configuración

- La configuración no sensible va en ConfigMaps por ambiente (`infra/k8s/overlays/<ambiente>`).
- Los secretos **nunca** se versionan. Plantilla: `deploy/secrets/secrets.env.example`.
- En Kubernetes, los Secrets de aplicación y `nexus-pull-secret` se crean antes del
  despliegue, fuera de Git. El usuario `deployer` puede crearlos y actualizarlos, pero no
  listarlos ni borrarlos.
- `JWT_SECRET` y `QR_SECRET` deben tener al menos 32 caracteres
  (`openssl rand -base64 48`) y ser distintos en cada ambiente.

**Rotar un secreto:** generar el valor nuevo, actualizar el Secret del ambiente (y la
credencial de Jenkins si aplica), reiniciar los servicios que lo usan con
`kubectl -n circleguard rollout restart deploy/<servicio>` y verificar con los smoke tests.
Al rotar `JWT_SECRET` se invalidan las sesiones activas.

## 8. Infraestructura como código (Terraform)

| Operación | Cómo |
|---|---|
| Cambio en dev | Por PR: Jenkins ejecuta `validate`, Trivy, `plan` y `apply` solo del plan que generó ese build |
| Cambio en stage o prod | Manual, con plan revisado y aprobación explícita del equipo |
| Detectar drift | `terraform plan` en el root del ambiente; si muestra cambios sin PR, investigar antes de aplicar |
| Destruir un ambiente | Solo con autorización; nunca prod sin decisión del equipo |
| Recuperar el estado | El bucket S3 tiene versionamiento: restaurar la versión anterior del objeto |

El estado vive en `s3://circleguard-tfstate-718875641310` con bloqueo nativo: si un
`plan` falla por *lock*, otra persona está aplicando; esperar en lugar de forzarlo.
Procedimientos completos en [`terraform.md`](terraform.md).

## 9. Respaldos y recuperación

| Qué | Respaldo | Retención | Cómo recuperar |
|---|---|---|---|
| Disco raíz de los nodos k3s | Snapshot diario 03:00 UTC (AWS DLM) | 7 días | Crear volumen desde el snapshot y reemplazar el volumen raíz |
| Estado de Terraform | Versionamiento del bucket S3 | 90 días | [`terraform.md`](terraform.md) §8 |
| Imágenes de la aplicación | Nexus, una por versión semántica | Indefinida | Desplegar el tag anterior |
| Código y configuración | GitHub (`main`, `dev`, tags) | — | Revertir con PR |
| Logs | Loki | 7 días | — |

Limitación conocida: los datos de PostgreSQL y Neo4j viven en volúmenes del clúster y solo
quedan cubiertos por el snapshot del disco del nodo. No hay respaldo lógico de las bases de
datos (por ejemplo, `pg_dump` programado).

## 10. Mantenimiento periódico

| Frecuencia | Tarea |
|---|---|
| Diaria | Revisar *Firing alerts* y builds fallidos en Discord; apagar instancias al terminar |
| Semanal | Revisar el costo en AWS Budgets; revisar el Quality Gate de SonarQube |
| Por release | Revisar las release notes generadas por semantic-release |
| Mensual | Revisar las excepciones aceptadas de Trivy; actualizar imágenes base y dependencias; ejecutar `terraform plan` en los tres ambientes para detectar drift |

## 11. Limitaciones conocidas

- La promoción a stage y prod está implementada pero deshabilitada (`promote: false`).
- No hay Alertmanager: las alertas no notifican, solo se ven en Grafana y Prometheus.
- Sin Elastic IPs: la IP pública cambia al reiniciar una instancia.
- No hay respaldo lógico de las bases de datos.
- El canary solo está implementado para el servicio dashboard y se aplica fuera del pipeline.
- Las instancias Docker Compose de la Parte 1 siguen existiendo y generan costo hasta que
  se eliminen.

## 12. Documentos relacionados

| Tema | Documento |
|---|---|
| Pipeline de Jenkins | [`pipeline.md`](pipeline.md) |
| Despliegue, promoción y rollback | [`despliegue.md`](despliegue.md) |
| Patrones de configuración, resiliencia y despliegue | [`patrones.md`](patrones.md) |
| Terraform | [`terraform.md`](terraform.md) |
| Validación de la infraestructura AWS | [`infraestructura.md`](infraestructura.md) |
| Kubernetes (manifiestos, RBAC, cuotas) | [`../../infra/k8s/README.md`](../../infra/k8s/README.md) |
| Métricas y alertas | [`../observability/metrics.md`](../observability/metrics.md) |
| Logs | [`../observability/logs.md`](../observability/logs.md) |
| Versionado y releases | [`versionado.md`](versionado.md), [`release-process.md`](release-process.md) |
| Costos | [`../costos/costos-infraestructura.md`](../costos/costos-infraestructura.md) |
