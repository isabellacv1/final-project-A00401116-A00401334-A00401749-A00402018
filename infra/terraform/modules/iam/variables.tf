# Entradas del módulo iam. Se conectan en envs/<env>/main.tf con las salidas
# de shared (name_prefix, region, tags y, solo en prod, el nombre del
# parámetro del token).

variable "env" {
  description = "Ambiente que recibe los roles y perfiles."
  type        = string

  validation {
    condition     = contains(["dev", "stage", "prod"], var.env)
    error_message = "env debe ser dev, stage o prod."
  }
}

variable "name_prefix" {
  description = "Prefijo de nombres (shared.name_prefix: cg-k3s)."
  type        = string
  default     = "cg-k3s"
}

variable "region" {
  description = "Región de la infraestructura (shared.region); se usa para componer el ARN del parámetro y la condición SourceArn del rol DLM."
  type        = string
}

variable "token_parameter_name" {
  description = "Nombre del parámetro SecureString del token de unión (shared.token_parameter_name). SOLO se pasa en prod; en dev/stage se omite y no se concede ningún permiso de Parameter Store."
  type        = string
  default     = null

  validation {
    condition     = var.token_parameter_name == null || startswith(var.token_parameter_name, "/")
    error_message = "token_parameter_name debe empezar por barra (p. ej. /circleguard/k3s/prod-join-token)."
  }
}

variable "tags" {
  description = "Etiquetas comunes (shared.common_tags)."
  type        = map(string)
  default     = {}
}
