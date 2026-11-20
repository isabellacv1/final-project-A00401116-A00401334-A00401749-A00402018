# backend-bootstrap — Bucket S3 de estados de Terraform (HU 2)

## Propósito

Root independiente que administra el **bucket S3 donde vivirán los estados
remotos** de los tres ambientes de CircleGuard (DEV, STAGE, PROD) una vez que
los roots de `envs/` migren su backend. Es el "estado del estado": no crea
infraestructura de la aplicación, solo el almacén de estados y sus controles
de seguridad.

> **Estado actual:** este directorio **ya fue ejecutado** en HU 2: el código
> pasó revisión, `init`/`validate`/`plan` y un `apply` autorizado crearon el
> bucket, y sus controles fueron verificados por API. Los tres estados de
> `envs/` **ya migraron** a este backend (ver más abajo).

## Por qué usa backend local

Este root administra el bucket que servirá de backend para los demás roots.
Si usara ese mismo bucket como backend, existiría una **dependencia circular**:
Terraform necesitaría leer/escribir su estado en un bucket que aún no ha
creado (y no podría ni iniciarlo). Por eso `backend-bootstrap` no declara
bloque `backend "s3"` y opera con el backend local por defecto.

**El estado local de este bootstrap debe conservarse y respaldarse**: es la
única referencia de qué existe en el bucket. Está excluido de git por las
reglas `*.tfstate` / `*.tfstate.*` del `.gitignore` raíz; se recomienda
copiarlo con fecha tras cada apply (por ejemplo
`terraform.tfstate.bak-YYYYMMDD`) y tratarlo con el mismo cuidado que los
estados de los ambientes.

## Recursos y controles creados

| Recurso | Control |
|---|---|
| `aws_s3_bucket.tfstate` | Bucket `circleguard-tfstate-718875641310` con `prevent_destroy` (ver límite abajo) |
| `aws_s3_bucket_versioning.tfstate` | Versionamiento **Enabled**: cada escritura del estado crea una versión recuperable |
| `aws_s3_bucket_server_side_encryption_configuration.tfstate` | Cifrado SSE-S3 (`AES256`), aplicado por defecto a todos los objetos |
| `aws_s3_bucket_public_access_block.tfstate` | Las cuatro opciones de Block Public Access en `true` |
| `aws_s3_bucket_ownership_controls.tfstate` | `BucketOwnerEnforced`: ACLs deshabilitadas (el backend S3 de Terraform no usa ACLs) |
| `aws_s3_bucket_policy.tls_only` | Deniega `s3:*` cuando `aws:SecureTransport = false`, sobre el ARN del bucket **y** `bucket/*` (estados y lockfiles) |
| `aws_s3_bucket_lifecycle_configuration.tfstate` | Ver sección siguiente |

### Lifecycle y versionamiento

- **Expire noncurrent versions** a **90 días**: la versión *actual* del estado
  nunca se purga; solo se limpia el histórico, lo que limita el costo del
  versionado y mantiene una ventana de rollback de ~3 meses.
- **Abort incomplete multipart uploads** a **7 días**: evita objetos huérfanos
  y su costo residual.

El versionado es la base del procedimiento de recuperación: si un estado se
escribe mal o se pierde, puede restaurarse una versión anterior del objeto.
**Descargar una versión no la restaura automáticamente**: el procedimiento
completo (7 pasos, sin sobrescrituras improvisadas) está en
[`docs/operaciones/terraform.md`](../../../docs/operaciones/terraform.md),
sección *Respaldos y recuperación*, y se resume en *Recuperación desde
versiones S3* más abajo.

## Protección `prevent_destroy` y sus limitaciones

El bucket declara `lifecycle { prevent_destroy = true }`: cualquier
`terraform apply` o `terraform destroy` de **este root** que intente eliminar
o reemplazar el bucket fallará antes de tocar AWS.

**No es una protección absoluta a nivel de AWS:** no evita que una persona con
permisos S3 borre el bucket (o sus versiones) por fuera de Terraform, ni un
`aws s3 rb`. La protección real la combinan:

1. `prevent_destroy` (bloquea la destrucción vía Terraform),
2. el versionado (permite restaurar objetos),
3. los permisos IAM de mínimo privilegio (limitan quién puede borrar),
4. el respaldo local del estado de este bootstrap.

En esta fase **no** se agregó ninguna regla opcional de denegación de
`s3:DeleteObjectVersion` (queda fuera de alcance por decisión de diseño).

## Backend S3 de los ambientes (implementado)

Los roots de `envs/` ya declaran su bloque `backend "s3"` en `versions.tf`,
sin DynamoDB (el locking nativo de S3 reemplaza a la tabla de DynamoDB):

```hcl
terraform {
  backend "s3" {
    bucket         = "circleguard-tfstate-718875641310"
    key            = "dev/terraform.tfstate"   # stage/... y prod/...
    region         = "us-east-1"
    encrypt        = true
    use_lockfile   = true   # bloqueo nativo: crea <key>.tflock
  }
}
```

Cada ambiente usa una **clave independiente** (`dev/`, `stage/`, `prod/`),
con lo que los tres estados quedan aislados lógicamente dentro del mismo
bucket. El lockfile asociado a cada clave (`terraform.tfstate.tflock`) es el
mecanismo de exclusión mutua entre operaciones concurrentes. El bloque real
incluye además `allowed_account_ids = ["718875641310"]`.

## Comandos utilizados (ya ejecutados con autorización; referencia)

```bash
# 1) Inicializar y validar el bootstrap (no aprovisiona nada)
cd infra/terraform/backend-bootstrap
terraform init
terraform validate

# 2) Revisar el plan y aplicarlo SOLO con autorización explícita
terraform plan -out=bootstrap.tfplan
terraform apply "bootstrap.tfplan"        # →7 recursos creados,0 modificados,0 destruidos

# 3) Verificaciones post-apply (solo lectura) — ejecutadas y correctas
terraform output
aws s3api get-bucket-versioning --bucket circleguard-tfstate-718875641310
aws s3api get-public-access-block --bucket circleguard-tfstate-718875641310
aws s3api get-bucket-encryption --bucket circleguard-tfstate-718875641310
```

## Migración de estados (realizada)

Los estados de DEV, STAGE y PROD se migraron **de manera individual y en ese
orden** (DEV → STAGE → PROD), cada uno con `terraform init -migrate-state`
tras respaldar el estado local. Cada migración fue verificada antes de
continuar: destino correcto, direcciones e IDs idénticos a los respaldos
previos, plan sin recursos por crear/destruir y lockfile liberado.
`serial` y `lineage` se regeneraron en los tres casos (comportamiento
observado en las tres migraciones y consistente con el código fuente de
Terraform; el contenido semántico no cambió).

Los respaldos previos se conservan junto a cada root
(`terraform.tfstate.bak-migracion-20261117`) y en copia independiente; el
`.tfstate` local de cada ambiente quedó vacío (el backend remoto es la fuente
de verdad).

## Recuperación desde versiones S3

El versionado conserva cada escritura del estado. **Descargar una versión
anterior no equivale a restaurarla**: es solo un paso de diagnóstico. La
restauración es una operación explícita que requiere aprobación. Procedimiento
completo en [`docs/operaciones/terraform.md`](../../../docs/operaciones/terraform.md);

1. **Detener operaciones concurrentes:** verificar que nadie ejecute
   `plan`/`apply` sobre el ambiente (`.tflock` ausente) y coordinar una
   ventana de mantenimiento.
2. **Identificar la versión correcta:**
   `aws s3api list-object-versions --bucket circleguard-tfstate-718875641310 --prefix <env>/terraform.tfstate`
   y elegir la versión por `VersionId`/`LastModified` (no "la más vieja"
   por defecto).
3. **Descargarla sin sobrescribir:** `aws s3api get-object … --version-id <id> <archivo-candidato>`;
   el estado actual **no se toca** en este paso.
4. **Respaldar la versión remota actual:** descargar también la versión
   `IsLatest=true` como evidencia antes de cualquier restauración.
5. **Comparar:** contenido (direcciones, IDs, outputs), `lineage` y `serial`
   entre candidato y actual; el candidato debe corresponder al entorno
   correcto (revisar `outputs.environment`).
6. **Validar el estado candidato:** con una copia en un directorio aislado,
   `terraform state list` (y opcionalmente un `plan` de solo lectura) para
   confirmar que describe la infraestructura esperada.
7. **Restaurar de forma explícita y verificar:** con aprobación registrada,
   la vía nativa es `terraform state push <candidato>` desde el root del
   entorno (valida `lineage`/`serial`) o, como alternativa controlada, subir
   el objeto con `aws s3api put-object` conservando la versión actual como
   respaldo. Verificar después con `state list`, un `plan` sin destrucciones
   y una nueva versión visible en `list-object-versions`. Si el `lineage`
   difiere, `state push` rechaza la escritura: **no usar `-force` como opción
   normal de recuperación**.

## Seguridad de las credenciales

Este root no contiene credenciales: las credenciales AWS llegan por la
cadena estándar (perfil compartido, variables de entorno o rol asumido). Los
valores de `terraform.tfvars` son públicos (nombre de bucket, región, cuenta
y etiquetas). Nunca commitear archivos con claves; `.env` y credenciales
están excluidos por `.gitignore`.
