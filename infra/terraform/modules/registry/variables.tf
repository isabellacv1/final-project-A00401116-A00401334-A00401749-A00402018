# Entradas del módulo registry.

variable "instance_name" {
  description = "Tag Name de la instancia que aloja el registro Nexus existente."
  type        = string
  default     = "cg-devops"
}

variable "registry_port" {
  description = "Puerto del repositorio Docker de Nexus (docker-hosted)."
  type        = number
  default     = 8082
}
