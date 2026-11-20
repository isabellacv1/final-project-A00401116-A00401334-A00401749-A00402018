# Entradas del root DEV. Los valores específicos del ambiente viven en
# terraform.tfvars (versionado; sin secretos).

variable "aws_region" {
  description = "Región de AWS del estado. Debe coincidir con shared.region (validado por el check de main.tf)."
  type        = string
  default     = "us-east-1"
}

variable "key_name" {
  description = "Key pair existente de este ambiente (reutiliza las credenciales SSH actuales de Jenkins)."
  type        = string
}

variable "root_volume_size" {
  description = "Tamaño del volumen raíz gp3 cifrado de cada nodo, en GB (DEV:40)."
  type        = number
}

variable "agent_count" {
  description = "Cantidad de nodos agent adicionales (DEV:0; el server siempre es1)."
  type        = number
}
