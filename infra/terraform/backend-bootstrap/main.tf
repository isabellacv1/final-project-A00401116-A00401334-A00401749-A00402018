# =============================================================================
# Root: backend-bootstrap (HU 2)
#
# Crea el bucket S3 que alojará los estados remotos de Terraform de los tres
# ambientes (DEV, STAGE, PROD) y todos sus controles de seguridad:
#
#   1. Bucket con versionamiento (recuperación ante borrado/sobrescritura).
#   2. Cifrado del lado del servidor SSE-S3 (AES256) aplicado por defecto.
#   3. S3 Block Public Access con las cuatro opciones habilitadas.
#   4. Object Ownership BucketOwnerEnforced (ACLs deshabilitadas).
#   5. Política de bucket que deniega el tráfico sin TLS.
#   6. Lifecycle: expiración de versiones no actuales + abort de multipart.
#
# Este root usa el backend LOCAL por defecto (no hay bloque backend "s3"):
# no puede guardar su estado en el bucket que todavía no existe. Su estado
# local debe conservarse y respaldarse (ver README.md).
#
# ADVERTENCIA: prevent_destroy en el bucket es una salvaguarda de Terraform
# (impide que un apply/destroy de este root lo elimine), NO una protección
# absoluta a nivel de AWS: alguien con permisos AWS podría borrarlo fuera de
# Terraform. La recuperación real la otorgan el versionado y los respaldos.
# =============================================================================

# --- Identidad consultada ------------------------------------------------------
# Comprueba que las credenciales con las que opera este root pertenecen a la
# cuenta esperada ANTES de crear recursos: si var.account_id difiere de la
# cuenta real del proveedor, el check "account_matches" hace fallar el plan.
data "aws_caller_identity" "current" {}

check "account_matches" {
  assert {
    condition     = data.aws_caller_identity.current.account_id == var.account_id
    error_message = "Las credenciales apuntan a la cuenta ${data.aws_caller_identity.current.account_id}, pero var.account_id es ${var.account_id}: revisa el perfil/entorno antes de aplicar."
  }
}

# --- Bucket -------------------------------------------------------------------
resource "aws_s3_bucket" "tfstate" {
  bucket = var.bucket_name

  # Salvaguarda de Terraform: cualquier apply/destroy de este root que intente
  # eliminar o reemplazar el bucket fallará. NO protege contra borrado fuera
  # de Terraform (CLI/consola con permisos). Ver README.md.
  lifecycle {
    prevent_destroy = true
  }

  tags = var.tags
}

# --- Versionamiento -----------------------------------------------------------
# HashiCorp lo recomienda explícitamente para el estado: permite recuperar una
# versión anterior del objeto si se pierde o se escribe de más.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

# --- Cifrado SSE-S3 -----------------------------------------------------------
# Cifrado del lado del servidor con la clave de S3 (AES256). Es el valor
# predeterminado para buckets nuevos, se declara de forma explícita para que
# la intención quede como código. Sin KMS: no hay secretos criptográficos en
# el estado y KMS añadiría gestión de claves y costo sin necesidad.
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# --- Acceso público bloqueado -------------------------------------------------
# Las cuatro opciones: niega ACLs públicas, ignora ACLs públicas existentes,
# niega políticas de bucket públicas y restringe cualquier acceso público.
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Object ownership ---------------------------------------------------------
# BucketOwnerEnforced deshabilita las ACLs: solo el propietario del bucket
# puede ser dueño de los objetos. El backend S3 de Terraform no usa ACLs, así
# que no hay conflicto de funcionalidad.
resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# --- Política TLS-only --------------------------------------------------------
# Deniega cualquier petición que NO use transporte seguro, tanto sobre el ARN
# del bucket (operaciones a nivel bucket: list, versioning, policy) como sobre
# los objetos (bucket/*: estados y lockfiles). Principal "*" con Deny es la
# forma estándar: no requiere conocer principals concretos y no bloquea a
# servicios AWS que siempre usan HTTPS (S3, Terraform, consola).
data "aws_iam_policy_document" "tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.tfstate.arn,
      "${aws_s3_bucket.tfstate.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tls_only" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tls_only.json

  # La política depende de que los controles de acceso público estén aplicados
  # (si no, S3 rechazaría una política pública; aquí la política NO es pública
  # porque la condición restringe el transporte, pero se mantiene el orden
  # explícito para que la creación sea determinista).
  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}

# --- Lifecycle ---------------------------------------------------------------
# Regla 1: expira las versiones NO actuales de los objetos después de N días.
# La versión actual NUNCA se purga: el estado vigente siempre está disponible.
# Esto limita el costo del versionado manteniendo una ventana de rollback.
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }
  }

  # Regla 2: aborta cargas multipart incompletas después de N días para que no
  # acumulen objetos huérfanos y su costo de almacenamiento.
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_days
    }
  }

  # El versionado debe estar habilitado antes de definir reglas de lifecycle
  # sobre versiones; el orden queda explícito con depends_on.
  depends_on = [aws_s3_bucket_versioning.tfstate]
}
