# Operaciones de Terraform — estado, planes y ciclo de vida

## Descripción

Manual operativo para trabajar con la infraestructura Terraform de CircleGuard:
cómo inicializar el entorno, detectar cambios, revisar y aplicar planes,
destruir con control, recuperar estados y operar con locking, sin importar si
el operador participó en las historias de usuario previas.

**Convención de este documento:**

- **[RUTINA]** — procedimientos recomendados para el día a día.
- **[AUTORIZACIÓN]** — operaciones que **no** se ejecutan sin aprobación
  explícita y documentada (se indica el motivo en cada sección).

Todo lo que aparece aquí está verificado contra la infraestructura real de
cuenta `718875641310`, región `us-east-1`.

---

## 1. Arquitectura del estado

### 1.1 Bucket y claves por entorno

Los tres estados viven en **un** bucket S3 compartido con **claves
independientes** por ambiente:

| Entorno | Raíz Terraform | Clave del estado | Lockfile |
|---|---|---|---|
| DEV | `infra/terraform/envs/dev` | `dev/terraform.tfstate` | `dev/terraform.tfstate.tflock` |
| STAGE | `infra/terraform/envs/stage` | `stage/terraform.tfstate` | `stage/terraform.tfstate.tflock` |
| PROD | `infra/terraform/envs/prod` | `prod/terraform.tfstate` | `prod/terraform.tfstate.tflock` |

- **Bucket:** `circleguard-tfstate-718875641310` (`us-east-1`).
- Cada root declara su bloque `backend "s3"` en `versions.tf` con
  `encrypt = true`, `use_lockfile = true` y
  `allowed_account_ids = ["718875641310"]` (red de seguridad contra cuenta
  equivocada).

### 1.2 Controles de seguridad del bucket

| Control | Estado |
|---|---|
| Cifrado del lado del servidor | SSE-S3 (`AES256`) |
| Versionamiento | Habilitado: cada escritura crea una versión recuperable |
| S3 Block Public Access | Las cuatro opciones en `true` |
| Object Ownership | `BucketOwnerEnforced` (ACLs deshabilitadas) |
| Política de transporte | Deniega `s3:*` con `aws:SecureTransport = false`, sobre el ARN del bucket y `bucket/*` |
| Lifecycle | Versiones no actuales expiran a **90 días**; uploads multipart incompletos se abortan a **7 días** |

### 1.3 Locking nativo (sin DynamoDB)

Con `use_lockfile = true`, Terraform crea un objeto `<clave>.tflock` junto al
estado durante cada operación y lo elimina al terminar: solo una operación por
ambiente a la vez. **No existe tabla DynamoDB**: el locking vía
`dynamodb_table` está deprecado en Terraform y no se usa.

### 1.4 Estado del bootstrap vs estados de entornos

- `infra/terraform/backend-bootstrap/` administra el bucket y sus controles.
  Usa **backend local** (no puede guardar su estado en el bucket que crea:
  dependencia circular) y su `aws_s3_bucket` tiene `prevent_destroy`.
- Los tres `envs/<ambiente>` usan el **bucket** como backend.
- **El estado local del bootstrap debe conservarse y respaldarse** (está en
  `.gitignore`): es la única referencia de qué existe en el bucket.

### 1.5 Respaldos locales

Junto a cada root se conservan copias históricas (ignoradas por git):

- `terraform.tfstate.bak-migracion-20261117` — copia previa a la migración.
- `terraform.tfstate.backup` — respaldo automático de Terraform.
- Copia independiente fuera del repositorio (`/tmp/opencode/backups/`).

**Precaución:** el `.tfstate` local de los tres ambientes quedó **vacío**
tras migrar (la fuente de verdad es S3). No editar, no "rellenar" y no
versionar esos archivos.

---

## 2. Inicialización en una máquina nueva **[RUTINA]**

### 2.1 Requisitos

- Terraform `>= 1.6.0, < 2.0.0` (verificado con `1.17.2`).
- AWS CLI v2 con credenciales para la cuenta `718875641310`.
- Repositorio clonado.

### 2.2 Credenciales e identidad (antes de tocar Terraform)

```bash
aws sts get-caller-identity    # debe devolver Account718875641310
aws configure get region       # us-east-1
```

**Nunca** guardar credenciales en el repositorio: sin `.env`, sin claves en
`tfvars` (los `tfvars` versionados solo contienen `key_name`, tamaños y
contadores).

### 2.3 Inicializar un entorno

```bash
./infra/terraform/bootstrap/preflight.sh        # verificación previa, solo lectura
terraform -chdir=infra/terraform/envs/dev init
```

`terraform init` descarga el proveedor (fijado en `.terraform.lock.hcl`,
que **debe versionarse**), verifica el módulo y **configura el backend S3**
leyendo el bloque de `versions.tf`.

### 2.4 Cuándo NO usar flags de reconfiguración **[AUTORIZACIÓN]**

- `terraform init` normal es **idempotente**: repetirlo no cambia nada.
- `-reconfigure` **ignora la configuración previa sin migrar estado**: usarlo
  a ciegas puede dejar el backend apuntando a otro lado. Solo con
  autorización y diagnóstico previo.
- `-migrate-state` **copia estado** entre backends: solo en migraciones
  planificadas (procedimiento histórico documentado en el README de
  `infra/terraform/`), nunca rutinariamente.

---

## 3. Detección de cambios y drift **[RUTINA]**

| Comando | ¿Consulta infraestructura? | ¿Genera propuesta? | ¿Persiste cambios en el estado? | ¿Modifica recursos? |
|---|---|---|---|---|
| `terraform plan` | **Sí** (refresca contra AWS) | **Sí**: agregados/modificados/destruidos | No | **No** |
| `terraform plan -refresh-only` | **Sí** | Solo cambios de estado (drift), sin propuesta de recursos | No (solo muestra) | **No** |
| `terraform apply -refresh-only` | **Sí** | — | **Sí** (escribe en el estado los valores refreshados) | **No** |

Claridades importantes:

- **Ninguno de los tres modifica recursos de infraestructura.** El único que
  escribe es `apply -refresh-only`, y escribe **solo en el estado** (registra
  en el estado lo que AWS ya tiene).
- `plan` normal responde *"¿qué cambiaría si aplico?"*; `-refresh-only`
  responde *"¿qué cambió en AWS respecto de lo que tengo registrado?"*.
- Usar `-refresh-only` cuando hay drift **externo** (alguien tocó algo en la
  consola); usar `plan` normal para decidir cambios de configuración.
- Interpretar el drift **antes** de corregirlo: una diferencia puede ser un
  cambio real, una deuda del provider o un cambio no autorizado (ver el
  análisis histórico en los reportes de HU2).

---

## 4. Revisión y aprobación de planes **[RUTINA]**

Checklist antes de aprobar cualquier plan:

- [ ] **Ambiente y cuenta correctos** (`-chdir=infra/terraform/envs/<env>`,
      `allowed_account_ids`, outputs de `environment`).
- [ ] **Recursos a crear** (`+`): ¿se esperan? ¿es correcta su cantidad?
- [ ] **Actualizaciones in-place** (`~`): ¿se entiende cada una?
- [ ] **Reemplazos** (`must be replaced`): destruyen y crean → riesgo alto.
- [ ] **Destrucciones** (`-`): cualquier `-` es **parada obligatoria**.
- [ ] **Impacto por tipo:** IAM (roles/políticas), Security Groups, SSM,
      EC2, volúmenes EBS y políticas DLM.
- [ ] **`user_data` en `aws_instance`** (ver §12: puede implicar stop/start).
- [ ] **Cero recursos de otros ambientes** en el plan.
- [ ] **Aprobación explícita registrada** antes de ejecutar el `apply`.

Guardar el plan como evidencia: `terraform plan -out=<nombre>.tfplan`.

---

## 5. Aplicación controlada **[RUTINA]**

Flujo completo:

```bash
terraform fmt -check
terraform -chdir=<root> validate
terraform -chdir=<root> plan -out=plan-<env>-<fecha>.tfplan
# → revisión con el checklist §4 → aprobación explícita
terraform -chdir=<root> apply "plan-<env>-<fecha>.tfplan"
# → verificación §13
```

Reglas:

- **Aplicar solo el plan revisado**, no un `apply` a ciegas.
- **No aplicar planes obsoletos:** si entre la aprobación y el `apply`
  pasó tiempo, hubo otros cambios o el archivo del plan cambió, **regenerar
  el plan y reverificar**. El plan aprobado es válido solo mientras nada
  haya cambiado.
- Un plan sin `-out` no garantiza que el `apply` ejecute exactamente lo
  revisado (así lo advierte el propio Terraform).

### 5.1 Aplicación desde CI (Jenkins) **[RUTINA]**

El pipeline automatiza este mismo flujo **sin sustituir** el procedimiento
manual de la §5: la vela manual sigue siendo el camino para cambios puntuales,
recuperaciones y cualquier caso que no pase por el CI.

```text
Plan  →  Approval  →  Apply        (por entorno, dentro de un mismo build)
```

| Fase | Qué ejecuta el pipeline | DEV | PROD |
|------|-------------------------|-----|------|
| **Plan** | `terraform init -backend=true` + `terraform plan -detailed-exitcode -out=ci-<env>-b<build>.tfplan` sobre `infra/terraform/envs/<env>` | habilitado (`terraformPlan: true`, rama `dev`) | deshabilitado (`terraformApplyProd: false`); correría solo en `main` |
| **Approval** | `input` manual (`submitter`, `submitterParameter: approvedBy`, `timeout`) | no aplica (DEV nunca pide aprobación) | deshabilitado (`terraformApproval: false` y `terraformApprovalProd: false`) |
| **Apply** | `terraform apply -lock=true ci-<env>-b<build>.tfplan` | habilitado (`terraformApply: true`, rama `dev`) | deshabilitado (`terraformApplyProd: false`) |

**Diferencias entre DEV y PROD**

- **DEV**: root `infra/terraform/envs/dev`, **sin aprobación**, en la rama `dev`.
- **PROD**: root `infra/terraform/envs/prod`, **solo desde la rama `main`**
  (`terraformApplyProdBranches`; cualquier otra rama, y cualquier rama
  configurada a la vez para DEV y para PROD, se rechaza) y **con aprobación
  obligatoria** (`requireApproval: true` en `terraformApply`).

**Validación de procedencia del plan** (ambos entornos, **antes** de tocar
credenciales o ejecutar `init`/`apply`):

- El nombre lleva el build (`ci-<env>-b<build>.tfplan`) y el sidecar
  `<plan>.info` guarda `build`, `commit`, `root`, `changes`, `status`, `sha256`
  y `createdAt`.
- `build`, `commit`, `root` y el hash del sidecar deben coincidir con el build
  actual (`TF_PLAN_BUILD/ROOT/FILE/INFO/SHA256/CHANGES`); además el **SHA-256**
  se recalcula con `sha256sum` y se compara con el del sidecar (**fail closed**
  si falta `sha256sum` o si el archivo cambió).
- **Vigencia**: `createdAt` debe ser un instante válido y no futuro, y el plan
  no puede tener más de `terraformApprovalMaxAgeMinutes` (60) de antigüedad.

**Aprobación explícita antes del Apply** (solo PROD):

- Se solicita **entre el Plan y el Apply**, con `submitter`
  (`terraformApprovalSubmitter`, `admin`), `submitterParameter: approvedBy` y
  `timeout` (`terraformApprovalTimeout`, 30 min).
- Persiste `TF_APPROVED_BY`, `TF_APPROVED_AT`, `TF_APPROVED_PLAN_SHA` y
  `TF_APPROVED_BUILD`; el apply los revalida —incluida la regla
  `createdAt <= approvedAt`— **antes de `withCredentials`**. Una aprobación no
  puede usarse para otro plan, otro build ni otro ambiente.
- **Sin cambios no se pide aprobación ni se aplica.** Un `input` fallido o
  interrumpido detiene el pipeline: el apply no se ejecuta.
- Antes de mostrar el `input`, `requireApprovalTimeLeft()` exige que queden al
  menos `terraformApprovalTimeout` minutos del presupuesto global de 120 min.

**Evidencia de aplicación**

- `terraform-apply-<env>-b<build>.txt`, archivado con el build: build, rama,
  commit, root, plan, cambios, resultado, fecha y —cuando corresponde—
  aprobador, fecha, hash y build aprobados y antigüedad del plan. **No** contiene
  credenciales, variables sensibles ni `outputs` de Terraform.
- El log conserva la salida de `terraform init` / `terraform apply`; ante un
  `AccessDenied` indica registrar la acción y el recurso **sin ampliar IAM**.

**Estados:** la librería nace con todos los switches de Terraform en `false`. En el
`Jenkinsfile` del proyecto están habilitados `terraformValidate`, `terraformPlan` y
`terraformApply` (solo la rama `dev`, sobre el plan del mismo build), mientras
`terraformApproval`, `terraformApprovalProd` y `terraformApplyProd` siguen en
`false`, así que **PROD nunca se aplica automáticamente**.

> Las validaciones unitarias de la librería (Groovy con mocks) comprueban la
> lógica de los steps; **no sustituyen** una validación en Jenkins real de
> `init`, `plan`, `apply`, el `input` y los locks, que sigue pendiente.

---

## 6. Destrucción controlada **[AUTORIZACIÓN]**

**Ningún `terraform destroy` se ejecuta sin aprobación explícita y un plan de
destrucción revisado.**

1. Generar y revisar **`terraform plan -destroy`**: lista exacta de todo lo
   que se eliminaría (recurso por recurso).
2. Evaluar **dependencias**: destruir un componente puede dejar huérfanos a
   otros (p. ej. destruir la red con nodos vivos).
3. **`prevent_destroy`:** el bucket del backend lo declara y **bloqueará**
   cualquier destroy del root `backend-bootstrap`. Es una salvaguarda de
   Terraform, **no** una protección absoluta a nivel AWS (alguien con
   permisos S3 podría borrarlo por fuera). Documentarlo en la solicitud.
4. Aprobación explícita (doble para PROD, ver §7).
5. Ejecutar y **verificar después** (ver §13): en AWS y en el estado.
6. **Recursos externos que Terraform NO elimina automáticamente:**
   - Instancias legacy `cg-dev`, `cg-stage`, `cg-prod` (y sus volúmenes) y
     los SG legacy — fuera de los estados.
   - VPC `circleguard-vpc`, subredes, ruta, IGW y la instancia `cg-devops`
     con Nexus (solo *data sources*).
   - Key pairs (`cg-*-key`) y el parámetro SSM
     `/circleguard/k3s/prod-join-token` (creado por cloud-init, no por
     Terraform).
   - Los volúmenes/snapshots gestionados por DLM según su propia política.

---

## 7. Protección especial de PROD **[AUTORIZACIÓN]**

Controles más estrictos para `envs/prod`:

1. **Confirmar cuenta y entorno** antes de cualquier operación
   (`aws sts get-caller-identity`, `outputs.environment == "prod"`).
2. **Revisar el plan completo**, no solo el resumen (los cambios de PROD
   afectan server **y** agent).
3. **Verificar impacto y disponibilidad:** PROD es el único entorno con
   ingress público (`80/443`) y con Parameter Store del token de k3s.
4. **Aprobación explícita** (doble verificación) antes del `apply`.
5. **Separar plan y apply:** generar el plan, aprobarlo y aplicarlo como
   acto distinto; no ejecutar `apply` en la misma improvisación que el plan.
6. **Sin operaciones concurrentes:** un solo operador; esperar el lock.

---

## 8. Respaldos y recuperación **[AUTORIZACIÓN para restaurar]**

### 8.1 Qué respaldo ya existe

- **Versionado S3** (capa principal): cada escritura del estado es una
  versión con `VersionId` y `LastModified`; la ventana útil es de ~90 días
  (lifecycle).
- **Copias locales** junto a cada root (`.bak-migracion-*`, `.backup`).
- **Estado del bootstrap** local (conservarlo y respaldarlo).

### 8.2 Recuperación desde una versión del objeto S3

**Descargar una versión no la restaura automáticamente.** Procedimiento:

1. Detener operaciones concurrentes del ambiente (`.tflock` ausente).
2. Identificar la versión correcta:
   `aws s3api list-object-versions --bucket circleguard-tfstate-718875641310 --prefix <env>/terraform.tfstate`
3. Descargarla **a un archivo aparte** (sin tocar nada):
   `aws s3api get-object --bucket … --key <env>/terraform.tfstate --version-id <id> candidato.tfstate`
4. **Respaldar también la versión actual** (`IsLatest=true`) como evidencia.
5. Comparar: direcciones, IDs, outputs, `lineage` y `serial`; confirmar que el
   candidato corresponde al entorno correcto (`outputs.environment`).
6. **Validar el candidato antes de cualquier escritura:** inspeccionarlo
   desde archivo con `terraform show candidato.tfstate` (o
   `terraform show -json candidato.tfstate`) para revisar direcciones y
   metadatos; si se necesita `state list` o un `plan`, usar un directorio
   temporal con backend local que apunte al archivo, **nunca** el backend real.
7. **Restaurar de forma explícita y verificar:** con aprobación registrada,
   la vía nativa es `terraform state push <candidato>` desde el root del
   entorno (valida `lineage`/`serial`; si el `lineage` difiere, se detiene →
   **no usar `-force` sin aprobación extraordinaria**). Alternativa
   controlada: subir el objeto con `aws s3api put-object` conservando la
   versión actual como respaldo. Verificar después con `state list`, un
   `plan` sin destrucciones y la nueva versión en `list-object-versions`.

### 8.3 Recuperación con `terraform state push` (diferencias)

- `state push` **sobrescribe** el estado remoto: es la vía de escritura
  manual, no la habitual de recuperación.
- Protecciones: rechaza si el **`lineage`** difiere (estás escribiendo sobre
  otro estado) o si el **`serial`** destino es mayor (podrías pisar cambios).
- **`-force`** salta esas protecciones: **no es una opción normal de
  recuperación**; exige aprobación extraordinaria y respaldo previo.
- Preferir siempre la recuperación por **versionado** (§8.2): respeta el
  historial y deja rastro.

---

## 9. Comandos de inspección del estado **[RUTINA]**

| Comando | Qué hace | Notas |
|---|---|---|
| `terraform state list` | Lista las direcciones del estado | Para verificar integridad tras operaciones |
| `terraform state show <dir>` | Muestra los atributos de un recurso | **Puede contener información sensible** |
| `terraform state pull` | Descarga el estado completo a stdout | Guardarlo a archivo con permisos `600`; **no imprimirlo ni compartirlo** |
| `terraform state rm <dir>` | **Deja de gestionar** el recurso en Terraform | **NO lo destruye en AWS**; el recurso queda huérfano de IaC **[AUTORIZACIÓN]** |

Advertencia general: el estado contiene datos sensibles (IPs, IDs, scripts de
arranque). No imprimirlo en canales compartidos ni pegarlo en tickets/chats.

---

## 10. Locking y concurrencia **[RUTINA]**

- Durante cada operación, Terraform crea `<clave>.tflock` en S3 y lo borra al
  terminar. Verificar ausencia de locks antes de operar:
  `aws s3api head-object --bucket circleguard-tfstate-718875641310 --key <env>/terraform.tfstate.tflock` (esperado: `404`).
- **Operaciones concurrentes:** un solo operador por ambiente. Los ambientes
  son independientes entre sí (claves distintas).
- **`-lock-timeout=5m`**: hace que la operación *espere* el lock en lugar de
  fallar — útil para esperar a quien termina, nunca para saltarse un lock.
- **Bloqueo aparentemente abandonado:** antes de tocar nada, verificar si hay
  una operación en curso (¿quién/qué máquina?), revisar el contenido del
  lockfile (contiene la información de la operación que lo retiene) y
  confirmar que nadie está aplicando. **No borrar el objeto `.tflock`
  manualmente sin diagnóstico**: borrarlo con una operación viva permite dos
  escrituras simultáneas del estado. Solo con diagnóstico cerrado y
  autorización.

---

## 11. Comandos avanzados y riesgos **[AUTORIZACIÓN para todos]**

| Comando | Consecuencia | Uso excepcional |
|---|---|---|
| `terraform apply -target=<dir>` | Aplica **solo** ese recurso pero el plan puede ignorar dependencias → estado parcial, recursos huérfanos; el propio Terraform lo desaconseja | Recuperación puntual tras un fallo, nunca como flujo normal |
| `terraform apply -replace=<dir>` | **Destruye y recrea** el recurso (posible interrupción) | Reemplazo forzoso de un recurso dañado, con plan revisado y aprobación |
| `terraform state push` | Sobrescribe el estado remoto | Solo recuperaciones autorizadas (§8.3) |
| `terraform state rm` | Deja de gestionar; **no destruye** en AWS | Adoptar/quitar recursos del estado con análisis previo |
| `terraform init -reconfigure` | Reconfigura backend **sin migrar estado** | Cambios de backend con diagnóstico (§2.4) |
| `terraform init -migrate-state` | Copia estado entre backends | Solo migraciones planificadas y verificadas |
| `state push -force` | Ignora protecciones de `lineage`/`serial` | **Nunca** como opción normal; aprobación extraordinaria |

Ninguno de estos comandos forma parte de la operación rutinaria.

---

## 12. Cambios de `user_data` **[AUTORIZACIÓN por entorno]**

Existe una **diferencia conocida y documentada** entre el `user_data`
registrado en las instancias y el código actual, relacionada con el fix de
AWS CLI (`chmod +x` de los binarios del instalador, commit `2043a77`):

- **DEV: aplicado y verificado** durante HU2 (ciclo controlado con plan
  guardado y aprobación explícita): la instancia `i-090c5ab5c3196f8d3`
  quedó sincronizada con el código y el plan posterior resultó en
  `No changes`. La actualización **provocó un stop/start** y la IP pública
  cambió (`18.213.113.102` → `34.232.48.248`, sin Elastic IP): verificar
  siempre las referencias a la IP antes de repetir el procedimiento.
- **STAGE y PROD: pendientes.** Sus planes muestran cambios in-place de
  `user_data` (1 en STAGE, 2 en PROD). En STAGE el único drift es la línea
  `chmod` (sin efecto funcional allí: dev/stage no instalan AWS CLI); en
  PROD el drift afecta al server (sí instala AWS CLI) y al agent.
- **No están autorizados automáticamente:** cada uno se revisa y aprueba
  **por entorno**.
- **Impacto posible:** una actualización de `user_data` **puede provocar
  stop/start de la EC2** (así ocurrió en DEV) incluso con
  `user_data_replace_on_change=false`; no describirla como un cambio inocuo.
- Antes de aplicar: revisar el diff completo, evaluar ventana de
  mantenimiento, verificar referencias a la IP pública del entorno y
  comprobar la instancia después.

---

## 13. Procedimiento de cierre **[RUTINA]**

Checklist posterior a cualquier operación Terraform:

- [ ] `terraform fmt -check` y `terraform validate` en verde.
- [ ] Plan final revisado (sin recursos inesperados pendientes).
- [ ] Verificación en AWS según el tipo de cambio (para EC2: estado de la
      instancia y `ssm describe-instance-information`; para IAM/SG/DLM:
      descripción de los recursos afectados).
- [ ] Lockfile ausente (`head-object` → `404`).
- [ ] Estado consistente: `terraform state list` con las direcciones
      esperadas (referencia actual: **DEV27, STAGE27, PROD49**).
- [ ] **Registro de evidencias:** plan guardado (`-out`), outputs, salida de
      la verificación en AWS, fecha/hora y quién aprobó.
- [ ] Cambios de código: `git status` limpio, mensaje de commit en
      minúsculas (ver `docs/CONTRIBUTING.md`), commit y push con revisión.

---

## Referencias

- Arquitectura y alcance: [`infra/terraform/README.md`](../../infra/terraform/README.md)
- Bucket y bootstrap: [`infra/terraform/backend-bootstrap/README.md`](../../infra/terraform/backend-bootstrap/README.md)
- Validación de instancias/servicios: [`infraestructura.md`](infraestructura.md)
- Política de commits: [`../CONTRIBUTING.md`](../CONTRIBUTING.md)
