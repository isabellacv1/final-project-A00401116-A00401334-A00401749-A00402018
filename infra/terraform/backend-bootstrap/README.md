# backend-bootstrap — Bucket S3 de estados de Terraform (HU 2)

## Propósito

Root independiente que administra el **bucket S3 donde vivirán los estados
remotos** de los tres ambientes de CircleGuard (DEV, STAGE, PROD) una vez que
los roots de `envs/` migren su backend. Es el "estado del estado": no crea
infraestructura de la aplicación, solo el almacén de estados y sus controles
de seguridad.

> **Este directorio aún no se ha ejecutado.** El bucket **no existe**; esta
> fase solo creó el código. El aprovisionamiento, la validación y la migración
> de estados ocurren en fases posteriores, con autorización explícita.

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
escribe mal o se pierde, se restaura una versión anterior del objeto (procedimiento
documentado en la fase de operación).

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

## Backend S3 de los ambientes (fase posterior)

Cuando se migren los roots de `envs/`, cada uno usará un bloque como este,
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
mecanismo de exclusión mutua entre operaciones concurrentes.

## Comandos previstos (fase posterior — NO ejecutar todavía)

```bash
# 1) Inicializar y validar el bootstrap (no aprovisiona nada)
cd infra/terraform/backend-bootstrap
terraform init
terraform validate

# 2) Revisar el plan y aplicarlo SOLO con autorización explícita
terraform plan -out=bootstrap.tfplan
terraform apply "bootstrap.tfplan"

# 3) Verificaciones post-apply (solo lectura)
terraform output
aws s3api get-bucket-versioning --bucket circleguard-tfstate-718875641310
aws s3api get-public-access-block --bucket circleguard-tfstate-718875641310
aws s3api get-bucket-encryption --bucket circleguard-tfstate-718875641310
```

## Migración de estados (fases posteriores)

Los estados de DEV, STAGE y PROD se migrarán **de manera individual y en ese
orden** (DEV → STAGE → PROD), con `terraform init -migrate-state` en cada root
tras respaldar el estado local. **No se ha realizado ninguna migración.**
Cada migración exige autorización explícita y sus verificaciones
(conteo de direcciones, plan sin recursos por crear/destruir, versionado).

## Seguridad de las credenciales

Este root no contiene credenciales: las credenciales AWS llegan por la
cadena estándar (perfil compartido, variables de entorno o rol asumido). Los
valores de `terraform.tfvars` son públicos (nombre de bucket, región, cuenta
y etiquetas). Nunca commitear archivos con claves; `.env` y credenciales
están excluidos por `.gitignore`.
