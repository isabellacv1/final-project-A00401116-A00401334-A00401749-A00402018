# =============================================================================
# Salidas del root de backend-bootstrap (HU 2).
#
# Valores públicos (no sensibles): nombre/ARN del bucket, región y las claves
# que se usarán al migrar cada ambiente. Se consumen al ejecutar este root y
# quedan documentados en su README; no contienen credenciales.
# =============================================================================

output "bucket_name" {
  description = "Nombre del bucket S3 que alojará los estados remotos de Terraform."
  value       = aws_s3_bucket.tfstate.id
}

output "bucket_arn" {
  description = "ARN del bucket S3 de estados."
  value       = aws_s3_bucket.tfstate.arn
}

output "bucket_region" {
  description = "Región del bucket S3 de estados."
  value       = aws_s3_bucket.tfstate.region
}

output "owner_account_id" {
  description = "Cuenta AWS real consultada por el proveedor (aws_caller_identity); difiere de var.account_id si las credenciales apuntan a otra cuenta, y en ese caso el check account_matches falla antes de crear recursos."
  value       = data.aws_caller_identity.current.account_id
}

output "expected_account_id" {
  description = "Cuenta esperada según var.account_id (valor de configuración, para comparar con owner_account_id)."
  value       = var.account_id
}

output "state_keys" {
  description = "Claves previstas del estado por ambiente (una clave independiente por ambiente)."
  value = {
    dev   = "dev/terraform.tfstate"
    stage = "stage/terraform.tfstate"
    prod  = "prod/terraform.tfstate"
  }
}

output "lockfile_keys" {
  description = "Claves de los lockfiles que creará Terraform con use_lockfile = true (una por ambiente)."
  value = {
    dev   = "dev/terraform.tfstate.tflock"
    stage = "stage/terraform.tfstate.tflock"
    prod  = "prod/terraform.tfstate.tflock"
  }
}

output "versioning_status" {
  description = "Estado del versionamiento del bucket (debe ser Enabled para permitir recuperación)."
  value       = aws_s3_bucket_versioning.tfstate.versioning_configuration[0].status
}
