# =============================================================================
# Variables del root de backend-bootstrap (HU 2).
#
# Solo valores no sensibles: nombres, región, cuenta y etiquetas. Sin
# credenciales, claves, tokens ni secretos (las credenciales llegan por la
# cadena estándar de AWS: perfil compartido, variables de entorno o rol).
# =============================================================================

variable "bucket_name" {
  description = "Nombre globalmente único del bucket S3 que guardará los estados remotos de Terraform."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name debe cumplir las reglas de nombres de S3: minúsculas, números, puntos y guiones (3-63 caracteres), sin guiones consecutivos ni IPs."
  }
}

variable "region" {
  description = "Región del bucket; por defecto la misma que la infraestructura de CircleGuard."
  type        = string
  default     = "us-east-1"
}

variable "account_id" {
  description = "Cuenta AWS propietaria; se usa para validar que el bucket no se crea en una cuenta equivocada."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id debe ser un identificador de cuenta AWS de 12 dígitos."
  }
}

variable "noncurrent_version_retention_days" {
  description = "Días que se conservan las versiones NO actuales de los objetos de estado antes de expirarlas (rollback window)."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_retention_days >= 1 && var.noncurrent_version_retention_days <= 3650
    error_message = "noncurrent_version_retention_days debe estar entre 1 y 3650."
  }
}

variable "abort_incomplete_multipart_days" {
  description = "Días tras los cuales se abortan cargas multipart incompletas (limpieza de huérfanos)."
  type        = number
  default     = 7

  validation {
    condition     = var.abort_incomplete_multipart_days >= 1 && var.abort_incomplete_multipart_days <= 365
    error_message = "abort_incomplete_multipart_days debe estar entre 1 y 365."
  }
}

variable "tags" {
  description = "Etiquetas comunes aplicadas a todos los recursos del bootstrap."
  type        = map(string)
  default = {
    Project   = "circleguard"
    ManagedBy = "terraform"
    Component = "tfstate-backend"
  }
}
