# Entradas del módulo security. Se conectan en envs/<env>/main.tf con las
# salidas de shared, networks y registry (sin referencias directas entre
# módulos: el módulo no conoce ningún otro).

variable "env" {
  description = "Ambiente que recibe los Security Groups."
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

variable "vpc_id" {
  description = "ID de la VPC existente (module.networks.vpc_id); la VPC no se administra."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR de la VPC existente (module.networks.vpc_cidr); se usa para derivar el resolver DNS (base+2)."
  type        = string
}

variable "devops_security_group_id" {
  description = "Security Group de cg-devops (module.registry.security_group_ids): origen de SSH, kubectl y, en dev/stage, de 80/443."
  type        = string
}

variable "registry_security_group_id" {
  description = "Security Group de la instancia del registro Nexus (module.registry.security_group_ids): destino de la egress tcp 8082. Nunca se usa un CIDR de IP pública."
  type        = string
}

variable "registry_port" {
  description = "Puerto del registro Nexus (module.registry.registry_port)."
  type        = number
  default     = 8082
}

variable "tags" {
  description = "Etiquetas comunes (shared.common_tags)."
  type        = map(string)
  default     = {}
}
