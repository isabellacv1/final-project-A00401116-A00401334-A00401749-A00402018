# Entradas del módulo storage. Se conectan en envs/<env>/main.tf con las
# salidas de iam (dlm_role_arn) y shared (common_tags).

variable "env" {
  description = "Ambiente de la política de snapshots."
  type        = string

  validation {
    condition     = contains(["dev", "stage", "prod"], var.env)
    error_message = "env debe ser dev, stage o prod."
  }
}

variable "dlm_role_arn" {
  description = "ARN del rol de ejecución de DLM del ambiente (module.iam.dlm_role_arn)."
  type        = string
}

variable "schedule_time" {
  description = "Hora de creación de los snapshots, en formato 24h UTC (API DLM: times está en UTC)."
  type        = string
  default     = "03:00"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.schedule_time))
    error_message = "schedule_time debe tener formato HH:MM en24 h (UTC), p. ej. 03:00."
  }
}

variable "retention_count" {
  description = "Cuántos snapshots conservar (DLM elimina los más antiguos)."
  type        = number
  default     = 7

  validation {
    condition     = var.retention_count >= 1 && var.retention_count <= 365
    error_message = "retention_count debe estar entre1 y365."
  }
}

variable "tags" {
  description = "Etiquetas comunes (shared.common_tags); su clave 'Project' alimenta el target_tags."
  type        = map(string)
  default     = {}
}
