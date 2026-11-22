# CircleGuard — configuración base de Kubernetes

Esta carpeta prepara K3s para CircleGuard y separa dos responsabilidades: la aplicación que despliega Jenkins y la plataforma que aplica infraestructura. La aplicación son nueve componentes (ocho servicios backend y la web) más su configuración; el middleware de datos vive en `data/` y se aplica como root independiente.

Los overlays de aplicación (`overlays/<entorno>`) solo renderizan recursos en el namespace `circleguard`. Los overlays de plataforma (`platform/overlays/<entorno>`) contienen namespaces, cuotas, límites, reglas de red, RBAC y observabilidad. Terraform y AWS se configuran fuera de esta carpeta; el pipeline se configura en el `Jenkinsfile` raíz. K3s ya trae Traefik y `local-path`; aquí no se cambian.

## 1. Estructura

```text
infra/k8s/
├── base/
│   ├── apps/
│   │   ├── common-config.yaml
│   │   ├── file-uploads-pvc.yaml
│   │   ├── ingress.yaml
│   │   ├── kustomization.yaml
│   │   ├── nexus-pull-secret.yaml
│   │   └── <servicio>/
│   │       ├── configmap.yaml
│   │       ├── deployment.yaml
│   │       ├── secret.yaml
│   │       └── service.yaml
│   └── kustomization.yaml
├── data/                   # PostgreSQL, Neo4j, Redis, ZooKeeper, Kafka y OpenLDAP
│   ├── kustomization.yaml
│   ├── postgres/
│   ├── neo4j/
│   ├── redis/
│   ├── zookeeper/
│   ├── kafka/
│   └── ldap/
├── platform/
│   ├── base/
│   │   ├── namespaces.yaml
│   │   ├── resourcequotas.yaml
│   │   ├── limitranges.yaml
│   │   ├── networkpolicies.yaml
│   │   ├── rbac-deployer.yaml
│   │   ├── observability/  # Prometheus, Grafana, Loki y Alloy
│   │   └── kustomization.yaml
│   └── overlays/
│       ├── dev/kustomization.yaml
│       ├── stage/kustomization.yaml
│       └── prod/kustomization.yaml
├── overlays/               # aplicación desplegada por Jenkins
│   ├── dev/kustomization.yaml
│   ├── stage/kustomization.yaml
│   └── prod/kustomization.yaml
└── README.md
```

- `base/`: base de aplicación. Fija `namespace: circleguard` y solo incluye `base/apps/`.
- `data/`: middleware de HU-25 (PostgreSQL, Neo4j, Redis, ZooKeeper, Kafka y OpenLDAP). No lo incluyen los overlays; se aplica como root independiente.
- `platform/`: base y overlays de plataforma. `platform/base/observability/` contiene métricas y dashboards (Prometheus, Grafana) y logs centralizados (Loki, Alloy). Ver [`metrics.md`](../../docs/observability/metrics.md) y [`logs.md`](../../docs/observability/logs.md).
- `overlays/`: ajustes por ambiente de la aplicación; incluyen `base`, el componente `scrape-annotations` y las transformaciones de imágenes de las nueve aplicaciones. No incluyen plataforma ni observabilidad.
- `README.md`: esta guía.

No se usa `namePrefix` porque los servicios ya se llaman `postgres`, `kafka`, `auth`, etc. Los tres namespaces se declaran en la plataforma y se crean antes de desplegar la aplicación.

## 2. Antes de empezar

- Necesitas `kubectl` configurado con acceso a los clústeres.
- Comprueba siempre en qué clúster estás. Los tres ambientes usan los mismos nombres de namespaces.
- Las cuotas son **provisionales**: se estimaron desde Terraform, no se compararon con los nodos reales.
- Los manifiestos de aplicación usan tags definidos y existentes como tags de Git; la disponibilidad real de las imágenes en Nexus debe verificarse antes de aplicar. Los Secret de aplicación siguen con valores `REEMPLAZAR` y deben inyectarse fuera de Git antes de aplicar.
- Los `.env` de `infra/k8s/data/` están ignorados por Git y no deben versionarse; los `secretGenerator` de `data/kustomization.yaml` los consumen desde el workspace/Jenkins.
- En esta entrega **no se aplicó nada**. Falta validar con acceso real.

## 3. Conectarse al clúster

```bash
kubectl config get-contexts
kubectl config use-context <contexto-dev-o-stage-o-prod>
kubectl config current-context
kubectl get nodes -o wide
```

El nombre que muestra `kubectl config current-context` debe coincidir con el ambiente que quieres cambiar. Si no coincide, cambia de contexto antes de continuar.

Para comprobar que el clúster responde:

```bash
kubectl get namespaces
kubectl get pods -A
```

## 4. Comandos útiles del día a día

### Ver qué hay

```bash
kubectl get namespaces
kubectl get pods -A -o wide
kubectl get services -A
kubectl get deployments -n circleguard
kubectl get statefulsets -n circleguard-data
```

### Ver detalles cuando algo falla

```bash
kubectl describe pod <pod> -n <namespace>
kubectl describe service <servicio> -n <namespace>
kubectl describe node <nodo>
kubectl get events -n <namespace> --sort-by=.lastTimestamp
```

### Ver logs

```bash
kubectl logs <pod> -n <namespace>
kubectl logs -f <pod> -n <namespace>
kubectl logs <pod> -n <namespace> --previous
kubectl logs <pod> -c <contenedor> -n <namespace> --tail=100
```

### Seguir un despliegue

Para los manifiestos de aplicación:

```bash
kubectl rollout status deployment/<nombre> -n circleguard
kubectl rollout history deployment/<nombre> -n circleguard
kubectl rollout undo deployment/<nombre> -n circleguard
```

Para componentes de datos:

```bash
kubectl rollout status statefulset/<nombre> -n circleguard-data
```

### Revisar cuotas y reglas

```bash
kubectl get resourcequota,limitrange -A
kubectl describe resourcequota circleguard-observability-quota -n circleguard-observability
kubectl get networkpolicy -A
```

`describe resourcequota` muestra cuánto se está usando y cuánto queda. Es lo primero que conviene mirar si un pod no se crea por un error de cuota.

## 5. Usuario deployer

La configuración base la aplica una identidad administradora. El usuario `circleguard-deployer` sirve para desplegar aplicaciones después, no para crear namespaces ni cambiar reglas de red.

Para obtener un token:

```bash
kubectl -n circleguard create token circleguard-deployer --duration=1h
```

El token dura una hora. No debe guardarse en Git ni compartirse.

Para usarlo en un contexto aparte:

```bash
kubectl config set-credentials circleguard-deployer --token="<TOKEN>"
kubectl config set-context circleguard-deployer \
  --cluster=<nombre-del-cluster> \
  --user=circleguard-deployer \
  --namespace=circleguard
kubectl config use-context circleguard-deployer
```

Comprobaciones rápidas:

```bash
kubectl auth can-i create deployments -n circleguard
kubectl auth can-i create secrets -n circleguard
kubectl auth can-i update secrets -n circleguard
kubectl auth can-i delete secrets -n circleguard
kubectl auth can-i update networkpolicies -n circleguard
kubectl auth can-i create namespaces
```

Resultado esperado:

- Crear deployments: sí.
- Crear y actualizar Secrets: sí.
- Borrar Secrets: no.
- Modificar NetworkPolicies: no.
- Crear Namespaces: no.

Con ese contexto se pueden usar comandos normales:

```bash
kubectl apply -f manifiesto-de-app.yaml -n circleguard
kubectl get pods -n circleguard
kubectl logs -f <pod> -n circleguard
kubectl rollout status deployment/<nombre> -n circleguard
```

Dos detalles importantes:

- `kubectl get secrets` no listará secretos con este usuario. Sí funciona `kubectl get secret <nombre>`.
- Si el pipeline necesita borrar o listar secretos, debe usar otra identidad. No se añadieron esos permisos “por si acaso”.

## 6. Aplicar cada root

El orden es plataforma → datos → aplicación. Comprueba siempre el contexto antes de aplicar.

### Plataforma

Con la identidad administradora, para cada entorno:

```bash
kubectl config current-context
kubectl kustomize infra/k8s/platform/overlays/dev
kubectl diff -k infra/k8s/platform/overlays/dev
kubectl apply -k infra/k8s/platform/overlays/dev
```

Repetir con `stage` y `prod`. Este root crea los namespaces, cuotas, límites, reglas de red, RBAC y el stack de observabilidad.

### Datos

Los manifiestos de datos no están en los overlays. Si aún no están aplicados, renderizarlos y aplicarlos por separado con la identidad administradora:

```bash
kubectl kustomize infra/k8s/data
kubectl diff -k infra/k8s/data
kubectl apply -k infra/k8s/data
```

El namespace `circleguard-data` se crea en la plataforma, así que aplica primero el overlay de plataforma del entorno.

### Aplicación

Jenkins aplica los overlays de `infra/k8s/overlays/<entorno>` con `deployKubernetes()`. Antes de cualquier comando contra el clúster, el paso renderiza el overlay, valida que todos los recursos sean `ConfigMap`, `Deployment`, `Service`, `Ingress` o `PersistentVolumeClaim` en `circleguard`, y rechaza cualquier recurso de plataforma, otro namespace o un render vacío. No hay `--prune`.

Para revisar manualmente el render sin aplicar:

```bash
kubectl kustomize infra/k8s/overlays/dev     # o stage / prod
```

Reglas:

- `kubectl kustomize` solo muestra lo que se aplicaría. No cambia nada.
- `kubectl diff` compara con el clúster. Tampoco cambia nada.
- `kubectl apply -k` sí aplica. Solo debe ejecutarse después de las validaciones.
- `prod` requiere aprobación explícita.
- La plataforma debe aplicarla un administrador. El deployer no puede crear namespaces ni ClusterRoles.

Después de aplicar:

```bash
kubectl get namespaces
kubectl get resourcequota,limitrange,networkpolicy -A
kubectl get serviceaccount circleguard-deployer -n circleguard
```

## 7. Qué hacen los manifiestos

### Namespaces

- `circleguard`: aplicaciones.
- `circleguard-data`: PostgreSQL, Neo4j, Redis, ZooKeeper, Kafka y OpenLDAP.
- `circleguard-observability`: Prometheus, Grafana, Loki, Grafana Alloy, kube-state-metrics y node-exporter.

### Cuotas

Son valores **provisionales**. No están validados contra la capacidad real de los nodos.

`dev` y `stage`:

| Namespace | CPU pedido | Memoria pedida | Límite CPU | Límite memoria | PVC solicitados |
|---|---:|---:|---:|---:|---:|
| `circleguard` | 600 m | 2560 Mi | 5 | 7 Gi | 8 Gi |
| `circleguard-data` | 700 m | 2560 Mi | 4 | 6 Gi | 16 Gi |
| `circleguard-observability` | 400 m | 1536 Mi | 2 | 3 Gi | 4 Gi |

`prod`:

| Namespace | CPU pedido | Memoria pedida | Límite CPU | Límite memoria | PVC solicitados |
|---|---:|---:|---:|---:|---:|
| `circleguard` | 1400 m | 6 Gi | 6 | 12 Gi | 10 Gi |
| `circleguard-data` | 1200 m | 4 Gi | 4 | 8 Gi | 20 Gi |
| `circleguard-observability` | 600 m | 2 Gi | 2 | 4 Gi | 6 Gi |

Los límites de memoria suman más de lo que tienen los nodos. Es una decisión consciente para permitir picos, pero no garantiza que todo quepa. La programación real depende de la capacidad disponible, de los pods ya creados y de posibles taints.

### Límites por defecto

Si un manifiesto no indica recursos, se aplican estos valores:

| Namespace | Pedido por defecto | Límite por defecto |
|---|---|---|
| `circleguard` | 50 m / 256 Mi | 500 m / 768 Mi |
| `circleguard-data` | 100 m / 256 Mi | 500 m / 1 Gi |
| `circleguard-observability` | 50 m / 128 Mi | 200 m / 384 Mi |

Conviene declarar recursos en los manifiestos de aplicación en lugar de depender de estos valores.

### Reglas de red

Cada namespace empieza con todo bloqueado. Después se permiten solo estos flujos:

- DNS hacia `kube-system`.
- Comunicación entre pods del mismo namespace.
- Entrada desde Traefik a aplicaciones y observabilidad.
- Aplicaciones hacia datos en los puertos 5432, 7687, 29092, 6379 y 389.
- Observabilidad hacia aplicaciones y datos para scraping.
- Prometheus y kube-state-metrics hacia la API de Kubernetes (`observability/networkpolicies.yaml`).

No hay salida general a Internet. Si luego se necesita SMTP, Gotify, alertas u otros servicios externos, habrá que añadir reglas explícitas.

Las reglas `allow-app-to-data` permiten desde `circleguard` hacia `circleguard-data` en los puertos 5432, 7687, 29092, 6379 y 389; `allow-observability-scrape` permite el scraping desde `circleguard-observability` hacia aplicaciones y datos. Las dos reglas `allow-traefik-ingress` incluyen ahora `namespaceSelector` para `kube-system` y `podSelector` con `app.kubernetes.io/name: traefik` (aporte de HU-24). No se crearon políticas nuevas ni cambió el diseño general de seguridad: verificar en `dev` que Traefik tiene esa etiqueta antes de aplicar. No hay salida general a Internet; SMTP y proveedores externos siguen pendientes.

### RBAC del deployer

El deployer puede:

- Crear, leer, actualizar y borrar Deployments, StatefulSets, Services, ConfigMaps e Ingress.
- Crear y actualizar Secrets, pero no listarlos, observarlos ni borrarlos.
- Crear y actualizar PVC, pero no borrarlos.
- Leer Pods, logs, eventos, cuotas, límites y NetworkPolicies.

No puede:

- Crear Namespaces ni ClusterRoles.
- Tocar `kube-system`.
- Modificar NetworkPolicies.
- Hacer `pods/exec` ni `pods/portforward`.

## 8. Aplicaciones CircleGuard

Los manifiestos de aplicación están en `base/apps/` y se incluyen desde `base/kustomization.yaml`. Cubren nueve Deployments, nueve Services, sus ConfigMaps y Secrets, un PVC y un Ingress. Los objetos declaran `namespace: circleguard`. `nexus-pull-secret.yaml` queda fuera del render: el Secret real del clúster se administra fuera de Git.

### Servicios

| Deployment | Service | Puerto |
|---|---|---:|
| `circleguard-auth-service` | `auth` | 8180 |
| `circleguard-identity-service` | `identity` | 8083 |
| `circleguard-promotion-service` | `promotion` | 8088 |
| `circleguard-notification-service` | `notification` | 8082 |
| `circleguard-form-service` | `form` | 8086 |
| `circleguard-gateway-service` | `gateway` | 8087 |
| `circleguard-dashboard-service` | `dashboard` | 8084 |
| `circleguard-file-service` | `file` | 8085 |
| `circleguard-web` | `web` | 8080 |

### Imágenes

La base usa imágenes fully-qualified `10.20.1.230:8082/circleguard/<servicio>:<tag>`, el registro interno que usan los nodos k3s. Los tags definidos en los manifiestos y existentes como tags de Git son `1.0.0` para auth, identity, promotion, form y gateway, y `1.0.0-dev.10` para notification, file y dashboard, que no existían en `v1.0.0`. El overlay `dev` fija las nueve imágenes en `1.0.0-dev.10`; `stage` y `prod` conservan los tags definidos por servicio. En el pipeline, `deployKubernetes` sobrescribe las nueve imágenes con `env.IMAGE_VERSION`. La disponibilidad real de las imágenes en Nexus debe verificarse antes del despliegue. No se usa `latest`.

### Configuración sensible

Los Secret de aplicación no se generan desde estos manifiestos: `base/apps/kustomization.yaml` no incluye los archivos `secret.yaml` y los overlays no renderizan objetos `Secret` de aplicación. Deben aprovisionarse externamente, antes de aplicar el overlay, con los nombres y claves exactos de la tabla siguiente. No hay valores reales en Git. Esto no aplica a los `secretGenerator` de `infra/k8s/data/`, que consumen archivos `.env` ignorados del workspace para el middleware.

`nexus-pull-secret.yaml` es solo un manifiesto de ejemplo sin credenciales reales y no está incluido en `base/apps/kustomization.yaml`, por lo que no aparece en el render de Kustomize. El Secret real `nexus-pull-secret` debe existir previamente en el namespace `circleguard`, se administra fuera de Git y su presencia real debe verificarse en el clúster antes del despliegue.

| Secret | Claves |
|---|---|
| `circleguard-auth-secret` | `SPRING_DATASOURCE_PASSWORD`, `SPRING_LDAP_PASSWORD`, `JWT_SECRET`, `QR_SECRET` |
| `circleguard-identity-secret` | `SPRING_DATASOURCE_PASSWORD`, `JWT_SECRET`, `VAULT_SECRET`, `VAULT_SALT`, `VAULT_HASH_SALT` |
| `circleguard-promotion-secret` | `SPRING_DATASOURCE_PASSWORD`, `SPRING_NEO4J_AUTHENTICATION_PASSWORD`, `JWT_SECRET` |
| `circleguard-notification-secret` | `JWT_SECRET`, `QR_SECRET` |
| `circleguard-form-secret` | `SPRING_DATASOURCE_PASSWORD` |
| `circleguard-gateway-secret` | `JWT_SECRET`, `QR_SECRET` |
| `circleguard-dashboard-secret` | `SPRING_DATASOURCE_PASSWORD` |

### Configuración por entorno

Cada overlay parchea:

- `circleguard-common-config`: `SPRING_PROFILES_ACTIVE` = `dev`, `stage` o `prod`.
- `circleguard-auth-config` y `circleguard-gateway-config`: `CORS_ALLOWED_ORIGINS` = `http://reemplazar-host-web-<entorno>.invalid:8081`.
- `circleguard-notification-config`: `SPRING_MAIL_HOST` = `reemplazar-smtp-host-<entorno>.invalid`.

Los dominios `.invalid` son marcadores deliberados; reemplazarlos por orígenes y hosts reales. No se ha inventado host público ni origen CORS.

### Dependencias externas

Los manifiestos de aplicación consumen estos Services desde `circleguard-data`:

- `postgres.circleguard-data.svc.cluster.local:5432`
- `neo4j.circleguard-data.svc.cluster.local:7687`
- `kafka.circleguard-data.svc.cluster.local:29092`
- `redis.circleguard-data.svc.cluster.local:6379`
- `openldap.circleguard-data.svc.cluster.local:389`

Los manifiestos de esos componentes están en `infra/k8s/data/` y se aplican como root separado; los overlays no los renderizan. Confirmar nombres reales, bases de datos y credenciales antes de aplicar. Las bases de datos usadas por las URLs JDBC son `circleguard_auth`, `circleguard_identity`, `circleguard_promotion`, `circleguard_form` y `circleguard_dashboard`.

### Probes

Los ocho Deployments backend usan:

- `startupProbe` y `livenessProbe`: `GET /actuator/health/liveness`.
- `readinessProbe`: `GET /actuator/health/readiness`.
- `port: http` apunta al puerto de negocio de cada servicio.

`readinessState` se combina con `db` en identity, form y dashboard; con `db,ldap` en auth; con `db,neo4j,redis` en promotion; con `redis` en gateway. File y notification solo usan `readinessState`. Notification tiene `management.health.mail.enabled=false` porque SMTP es externo y no debe impedir el arranque. Spring Boot 3.2.4 no registra HealthIndicator estándar de Kafka; no se asumió uno.

### Recursos

Siete servicios usan request `50m`/`256Mi` y limit `500m`/`768Mi`. Promotion usa request `150m`/`512Mi` y limit `1000m`/`1Gi`.

El total de los ocho backends es requests `500m`/`2304Mi` y limits `4500m`/`6400Mi` (6,25Gi). La cuota dev/stage de `circleguard` es requests `600m`/`2560Mi`, limits `5`/`7Gi`, storage `8Gi`, PVC `4`, Services `12`, Deployments `12`, Ingress `1`, ConfigMaps `8` y Secrets `8`. El frontend `web` también se despliega desde estos overlays, así que la cuota real debe revisarse con los nueve componentes antes de aplicar.

### Storage

`file-service` monta el PVC `file-uploads` de 1Gi en `/app/uploads`, con `ReadWriteOnce` y `storageClassName: local-path`. `form-service` usa `emptyDir` en `/tmp/circleguard-uploads`; esos archivos temporales no sobreviven a un reinicio. Con `ReadWriteOnce`, `replicas` debe permanecer en 1 salvo que se migre a una StorageClass RWX. Ver la sección 9 para las limitaciones de `local-path`.

### Ingress

No se define `host` porque no se proporcionó ninguno y no se debe inventar. El Ingress usa `ingressClassName: traefik` y rutas Prefix:

| Prefijo | Servicio |
|---|---|
| `/api/v1/auth`, `/api/v1/users` | `auth:8180` |
| `/api/v1/identities` | `identity:8083` |
| `/api/v1/circles`, `/api/v1/mesh`, `/api/v1/buildings`, `/api/v1/floors`, `/api/v1/access-points`, `/api/v1/encounters`, `/api/v1/sessions`, `/api/v1/location`, `/api/v1/health`, `/api/v1/health-status`, `/api/v1/admin/settings` | `promotion:8088` |
| `/api/v1/gate` | `gateway:8087` |
| `/api/v1/questionnaires`, `/api/v1/surveys`, `/api/v1/attachments`, `/api/v1/certificates` | `form:8086` |
| `/api/v1/files` | `file:8085` |
| `/api/v1/analytics` | `dashboard:8084` |

`notification` no se expone públicamente. `gateway` no actúa como proxy inverso; solo valida `POST /api/v1/gate/validate`. Si se requiere host o TLS, añadir reglas reales y secrets de certificado; no se hizo sin datos.

### Reglas de red de las aplicaciones

Solo se ajustaron las dos reglas `allow-traefik-ingress` existentes para añadir el `podSelector` de Traefik junto al `namespaceSelector`. No se crearon políticas nuevas ni cambió el diseño general de seguridad. Notification necesita reglas adicionales para SMTP y proveedores externos (Gotify, Twilio, LMS/booking); no se crearon porque no se conocen hosts ni puertos definitivos.

### Validación de las aplicaciones

`kubectl kustomize infra/k8s/overlays/dev` renderiza 28 recursos de aplicación, todos en `circleguard`: 9 Deployments, 9 Services, 8 ConfigMaps, 1 Ingress y 1 PVC. No incluye observabilidad ni recursos cluster-scoped. Las nueve imágenes apuntan al registry del entorno con el tag correspondiente; no se usa `latest`. Repetir para `stage` y `prod`.

`kubectl kustomize infra/k8s/platform/overlays/dev` renderiza 61 recursos de plataforma: 3 Namespaces, 3 ResourceQuota, 3 LimitRange, 17 NetworkPolicies, 4 ClusterRole, 3 ClusterRoleBinding, 3 RoleBinding, 4 ServiceAccount, 6 ConfigMaps, 4 Deployments, 2 DaemonSets, 5 Services, 3 PVC y 1 Ingress de observabilidad. `prod` mantiene los aumentos de cuotas. `kubectl kustomize infra/k8s/data` renderiza 5 StatefulSets, 1 Deployment, 6 Services, 5 PVC, 1 ConfigMap y 3 Secrets. No se aplicó nada al clúster.

## 9. Almacenamiento: qué no promete esta configuración

`requests.storage` limita la suma de capacidad solicitada por PVC. No es espacio reservado ni una garantía de que el disco tenga ese espacio libre.

`local-path`:

- Usa el disco raíz del nodo.
- No es alta disponibilidad y no replica datos.
- Un PVC queda ligado al nodo donde se creó.
- Si ese nodo falla, el pod no puede moverse a otro con sus datos.
- No evita que los logs o los datos llenen el disco.

Por eso hacen falta monitorización de disco y backups en historias posteriores. Esta configuración no garantiza por sí sola que el stack de observabilidad funcione.

## 10. Validaciones pendientes

Antes de aplicar en un clúster real:

- Consultar la capacidad real de los nodos: `kubectl get nodes -o wide` y `kubectl describe nodes`.
- Revisar pods existentes: `kubectl get pods -A -o wide`.
- Revisar cuotas actuales: `kubectl get resourcequota,limitrange -A`.
- Comprobar etiquetas de CoreDNS y Traefik en `dev` con `kubectl -n kube-system get pods --show-labels`; Traefik debe tener `app.kubernetes.io/name: traefik`.
- Sustituir los secretos `REEMPLAZAR` y los dominios `.invalid` antes de renderizar para aplicar. No sustituir `nexus-pull-secret`: se administra fuera de Git.
- Ejecutar `kubectl kustomize` en los tres overlays de aplicación y comprobar 28 recursos, todos en `circleguard`: 9 Deployments, 9 Services, 8 ConfigMaps, 1 Ingress y 1 PVC, sin Secrets ni recursos cluster-scoped.
- Ejecutar `kubectl kustomize` en los tres overlays de plataforma y comprobar 61 recursos, incluidos 3 Namespaces, 17 NetworkPolicies y el stack de observabilidad; ejecutarlo también en `data/` y comprobar 5 StatefulSets, 1 Deployment, 6 Services y 5 PVC.
- Validar esquema con `kubeconform`, si está disponible.
- Usar `kubectl diff -k` y `kubectl apply --dry-run=server`.

El render real se validó localmente con `kubectl kustomize` en los tres overlays de aplicación, los tres de plataforma y en `data/`. No se ejecutó `kubeconform` y no se aplicó nada contra un clúster; siguen pendientes `kubectl diff`, `apply --dry-run=server` y la comprobación de etiquetas reales de Traefik.

## 11. Decisiones y riesgos

- Las cuotas son provisionales: no se validaron contra nodos reales.
- El `podSelector` de Traefik está añadido en las dos reglas `allow-traefik-ingress`, pero no se verificó en clúster.
- Los tags de imagen están definidos en los manifiestos y existen como tags de Git; la disponibilidad real en Nexus debe verificarse antes del despliegue. Siguen pendientes los secretos `REEMPLAZAR`, los hosts CORS y SMTP.
- El deployer tiene menos permisos sobre Secrets; los flujos que necesiten listar o borrar deberán usar otra identidad.
- `local-path` no garantiza espacio ni disponibilidad.
- La capacidad de `dev` y `stage` es ajustada para todos los componentes previstos.
- Los manifiestos de Prometheus, Grafana, Loki y Alloy están incluidos en los overlays de plataforma; su funcionamiento real no se validó contra un clúster.
- No se añadió TLS, cert-manager, backups ni External Secrets.

## 12. Alcance

Dentro de este alcance:

- Namespaces, cuotas, límites, reglas de red, RBAC y overlays.
- Manifiestos de aplicación, Services, ConfigMaps, Secrets, PVC e Ingress.
- Manifiestos base de middleware en `data/` y manifiestos de observabilidad incluidos en los overlays de plataforma.
- Documentación de uso y de validaciones pendientes.

Fuera de este alcance:

- Migración de datos y verificación en clúster de PostgreSQL, Neo4j, Kafka, Redis y OpenLDAP.
- Gestión de Secrets reales, contexts/kubeconfigs ni cambios de Terraform o AWS desde esta carpeta.
- Reglas de egress para SMTP y proveedores externos.
- TLS, cert-manager, backups y verificación real de observabilidad.
