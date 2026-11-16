# Entradas del módulo networks. Los valores por defecto son la infraestructura
# existente de Parte 1: se sobrescriben solo si la red cambia de nombre.

variable "vpc_name" {
  description = "Tag Name de la VPC existente que se consulta (no se administra)."
  type        = string
  default     = "circleguard-vpc"
}

variable "expected_vpc_cidr" {
  description = "CIDR esperado de la VPC; se usa como filtro para asegurar que se encontró la red correcta."
  type        = string
  default     = "10.20.0.0/16"
}

variable "route_table_name" {
  description = "Tag Name de la tabla de rutas pública existente."
  type        = string
  default     = "circleguard-public-rt"
}

variable "subnet_names" {
  description = "Mapa ambiente => tag Name de la subred existente que consume ese ambiente."
  type        = map(string)
  default = {
    dev    = "cg-dev-subnet"
    stage  = "cg-stage-subnet"
    prod   = "cg-prod-subnet"
    devops = "cg-devops-subnet"
  }

  validation {
    condition     = alltrue([for env in ["dev", "stage", "prod"] : contains(keys(var.subnet_names), env)])
    error_message = "subnet_names debe incluir al menos las llaves dev, stage y prod."
  }
}
