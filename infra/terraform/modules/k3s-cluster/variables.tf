# Entradas del módulo k3s-cluster. Se conectan en envs/<env>/main.tf con las
# salidas de shared, networks, registry, security e iam (B1-B3).

variable "env" {
  description = "Ambiente del clúster (dev, stage o prod): un clúster k3s independiente por ambiente."
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
  description = "Región (shared.region): se usa en las llamadas de AWS CLI del bootstrap."
  type        = string
}

variable "ami_id" {
  description = "AMI fijada (shared.ami_id): Ubuntu24.04 LTS x86_64."
  type        = string
}

variable "instance_type" {
  description = "Tipo de instancia aprobado (shared.instance_type: m7i-flex.large)."
  type        = string
}

variable "k3s_version" {
  description = "Versión FIJADA de k3s (shared.k3s_version); nunca 'latest'."
  type        = string
}

variable "subnet_id" {
  description = "Subred existente del ambiente (module.networks.subnet_ids[env])."
  type        = string
}

variable "server_sg_id" {
  description = "Security Group del server (module.security.server_sg_id)."
  type        = string
}

variable "agent_sg_id" {
  description = "Security Group del agent (module.security.agent_sg_id); solo requerido con agent_count >0."
  type        = string
  default     = null
}

variable "server_profile_name" {
  description = "Instance profile del server (module.iam.server_profile_name)."
  type        = string
}

variable "agent_profile_name" {
  description = "Instance profile del agent (module.iam.agent_profile_name); solo requerido con agent_count >0."
  type        = string
  default     = null
}

variable "key_name" {
  description = "Key pair existente del ambiente (cg-dev-key / cg-stage-key / cg-prod-key): mantiene válidas las credenciales SSH actuales de Jenkins."
  type        = string
}

variable "registry_endpoint" {
  description = "Endpoint interno del registro Nexus (module.registry.registry_endpoint, IP privada)."
  type        = string
}

variable "registry_scheme" {
  description = "Esquema del registro (module.registry.registry_scheme): http, decisión aceptada temporalmente."
  type        = string
  default     = "http"
}

variable "root_volume_size" {
  description = "Tamaño del volumen raíz gp3 cifrado en GB (DEV/STAGE40, PROD50 por nodo)."
  type        = number

  validation {
    condition     = var.root_volume_size >= 16 && var.root_volume_size <= 16384
    error_message = "root_volume_size debe estar entre16 y16384 GB."
  }
}

variable "agent_count" {
  description = "Nodos agent adicionales (0 en dev/stage,1 en prod). El server es siempre1."
  type        = number
  default     =0

  validation {
    condition     = contains([0, 1], var.agent_count)
    error_message = "agent_count solo admite0 o1 (topología aprobada)."
  }
}

variable "token_parameter_name" {
  description = "Nombre del parámetro SecureString del token (shared.token_parameter_name). SOLO prod; en dev/stage se omite (null) y el server no publica nada."
  type        = string
  default     = null
}

variable "awscli_version" {
  description = "Versión FIJADA de AWS CLI v2 usada por el bootstrap si la AMI no lo trae (aprobación D1/A2)."
  type        = string
  default     = "2.40.3"

  validation {
    condition     = can(regex("^2\\.[0-9]+\\.[0-9]+$", var.awscli_version))
    error_message = "awscli_version debe ser una versión concreta2.x.y (nunca latest)."
  }
}

variable "awscli_sha256" {
  description = "SHA256 oficial del paquete awscli-exe-linux-x86_64-<ver>.zip. Verificado contra la firma GPG de 'AWS CLI Team' (huella FB5D B77F D5C1 18B8 0511 ADA8 A631 0ACC 4672 475C publicada en la guía oficial de AWS); el bootstrap aborta si no coincide."
  type        = string
  default     = "4770c06c4ecfc8ba94b60d89e6c7018ab7ea2cf5341b1ef05f6f93c5d6e8b705"

  validation {
    condition     = can(regex("^[a-f0-9]{64}$", var.awscli_sha256))
    error_message = "awscli_sha256 debe ser un SHA256 hex de64 caracteres."
  }
}

variable "tags" {
  description = "Etiquetas comunes (shared.common_tags)."
  type        = map(string)
  default     = {}
}
