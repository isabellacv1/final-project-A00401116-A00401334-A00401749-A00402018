# CircleGuard — configuración base de Kubernetes

Esta carpeta prepara K3s para CircleGuard. No despliega microservicios ni bases de datos: solo deja lista la configuración.

Incluye namespaces, cuotas, límites, reglas de red y un usuario de despliegue. No modifica Terraform, AWS ni Jenkins. K3s ya trae Traefik y `local-path`; aquí no se cambian.

## 1. Estructura

```text
infra/k8s/
├── base/
│   ├── namespaces.yaml
│   ├── resourcequotas.yaml
│   ├── limitranges.yaml
│   ├── networkpolicies.yaml
│   ├── rbac-deployer.yaml
│   └── kustomization.yaml
├── overlays/
│   ├── dev/kustomization.yaml
│   ├── stage/kustomization.yaml
│   └── prod/kustomization.yaml
└── README.md
```

- `base/`: configuración común para los tres ambientes.
- `overlays/`: ajustes pequeños por ambiente. `prod` tiene más recursos; `dev` y `stage` usan los valores base.
- `README.md`: esta guía.

No se usa `namePrefix` porque los servicios ya se llaman `postgres`, `kafka`, `auth`, etc. Tampoco se cambia el namespace de forma automática porque hay tres namespaces distintos.

## 2. Antes de empezar

- Necesitas `kubectl` configurado con acceso a los clústeres.
- Comprueba siempre en qué clúster estás. Los tres ambientes usan los mismos nombres de namespaces.
- Las cuotas son **provisionales**: se estimaron desde Terraform, no se compararon con los nodos reales.
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

Cuando ya existan los manifiestos de aplicación:

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

## 6. Aplicar cada overlay

Siempre con la identidad administradora y después de comprobar el contexto:

```bash
kubectl config current-context

kubectl kustomize infra/k8s/overlays/dev
kubectl diff -k infra/k8s/overlays/dev
kubectl apply -k infra/k8s/overlays/dev
```

Repetir para los otros ambientes:

```bash
kubectl kustomize infra/k8s/overlays/stage
kubectl diff -k infra/k8s/overlays/stage
kubectl apply -k infra/k8s/overlays/stage

kubectl kustomize infra/k8s/overlays/prod
kubectl diff -k infra/k8s/overlays/prod
kubectl apply -k infra/k8s/overlays/prod
```

Reglas:

- `kubectl kustomize` solo muestra lo que se aplicaría. No cambia nada.
- `kubectl diff` compara con el clúster. Tampoco cambia nada.
- `kubectl apply -k` sí aplica. Solo debe ejecutarse después de las validaciones.
- `prod` requiere aprobación explícita.
- La base debe aplicarla un administrador. El deployer no puede crear namespaces ni ClusterRoles.

Después de aplicar:

```bash
kubectl get namespaces
kubectl get resourcequota,limitrange,networkpolicy -A
kubectl get serviceaccount circleguard-deployer -n circleguard
```

## 7. Qué hacen los manifiestos

### Namespaces

- `circleguard`: aplicaciones.
- `circleguard-data`: PostgreSQL, Neo4j, Kafka, Redis y OpenLDAP.
- `circleguard-observability`: Prometheus, Grafana, Alertmanager, Jaeger, Loki y Promtail.

### Cuotas

Son valores **provisionales**. No están validados contra la capacidad real de los nodos.

`dev` y `stage`:

| Namespace | CPU pedido | Memoria pedida | Límite CPU | Límite memoria | PVC solicitados |
|---|---:|---:|---:|---:|---:|
| `circleguard` | 600 m | 2560 Mi | 5 | 7 Gi | 8 Gi |
| `circleguard-data` | 700 m | 2560 Mi | 4 | 6 Gi | 16 Gi |
| `circleguard-observability` | 300 m | 1 Gi | 1500 m | 3 Gi | 4 Gi |

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

No hay salida general a Internet. Si luego se necesita SMTP, Gotify, alertas u otros servicios externos, habrá que añadir reglas explícitas.

Las reglas de red **no se modificaron** en esta entrega. No se pudo comprobar en `dev` que CoreDNS y Traefik tengan las etiquetas esperadas. Hasta verificarlo, se conservan las reglas amplias actuales.

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

## 8. Almacenamiento: qué no promete esta configuración

`requests.storage` limita la suma de capacidad solicitada por PVC. No es espacio reservado ni una garantía de que el disco tenga ese espacio libre.

`local-path`:

- Usa el disco raíz del nodo.
- No es alta disponibilidad y no replica datos.
- Un PVC queda ligado al nodo donde se creó.
- Si ese nodo falla, el pod no puede moverse a otro con sus datos.
- No evita que los logs o los datos llenen el disco.

Por eso hacen falta monitorización de disco y backups en historias posteriores. Esta configuración no garantiza por sí sola que el stack de observabilidad funcione.

## 9. Validaciones pendientes

Antes de aplicar en un clúster real:

- Consultar la capacidad real de los nodos: `kubectl get nodes -o wide` y `kubectl describe nodes`.
- Revisar pods existentes: `kubectl get pods -A -o wide`.
- Revisar cuotas actuales: `kubectl get resourcequota,limitrange -A`.
- Comprobar etiquetas de CoreDNS y Traefik en `dev` con `kubectl -n kube-system get pods --show-labels`.
- Ejecutar `kubectl kustomize` en los tres overlays.
- Validar esquema con `kubeconform`, si está disponible.
- Usar `kubectl diff -k` y `kubectl apply --dry-run=server`.

En el entorno donde se preparó esta entrega no había `kubectl`, `kustomize` ni kubeconfig. Solo se verificó la sintaxis YAML y una simulación simple de los overlays. El render real sigue pendiente.

## 10. Decisiones y riesgos

- Las cuotas son provisionales: no se validaron contra nodos reales.
- Las reglas de red siguen amplias hasta verificar etiquetas reales.
- El deployer tiene menos permisos sobre Secrets; los flujos que necesiten listar o borrar deberán usar otra identidad.
- `local-path` no garantiza espacio ni disponibilidad.
- La capacidad de `dev` y `stage` es ajustada para todos los componentes previstos.
- No se desplegó Prometheus, Grafana, Loki, Jaeger ni ningún otro componente.
- No se añadió TLS, cert-manager, backups ni External Secrets.

## 11. Alcance

Dentro de HU-23:

- Namespaces, cuotas, límites, reglas de red, RBAC y overlays.
- Documentación de uso y de validaciones pendientes.

Fuera de HU-23:

- Manifiestos de aplicación, Services e Ingress.
- Migración de PostgreSQL, Neo4j, Kafka, Redis y OpenLDAP.
- Cambios en Jenkins, Terraform o AWS.
- Endurecimiento de reglas de red hasta verificar etiquetas.
- TLS, cert-manager, backups y observabilidad real.
