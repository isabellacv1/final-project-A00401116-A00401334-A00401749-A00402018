# Salidas del módulo de constantes compartidas. Desde un ambiente se leen con
# la sintaxis de módulos de Terraform (alias del bloque + nombre de la salida):
#
#   module "shared" { source = "../../shared" }
#   ami_id = module.shared.ami_id
#
# y NO como `module.shared.outputs.ami_id` (ese atributo no existe).

output "region" {
  description = "Región única de la infraestructura (us-east-1)."
  value       = local.region
}

output "project" {
  description = "Nombre del proyecto, usado en etiquetas."
  value       = local.project
}

output "name_prefix" {
  description = "Prefijo de nombres de recursos nuevos (cg-k3s-<env>-<rol>)."
  value       = local.name_prefix
}

output "ami_id" {
  description = "AMI fijada para los nodos k3s (Ubuntu 24.04 LTS x86_64)."
  value       = local.ami_id
}

output "ami_name" {
  description = "Nombre canónico de la AMI fijada (para verificación)."
  value       = local.ami_name
}

output "instance_type" {
  description = "Tipo de instancia de los nodos k3s."
  value       = local.instance_type
}

output "k3s_version" {
  description = "Versión fijada de k3s (INSTALL_K3S_VERSION)."
  value       = local.k3s_version
}

output "ssh_user" {
  description = "Usuario SSH de la AMI de Ubuntu."
  value       = local.ssh_user
}

output "token_parameter_name" {
  description = "Nombre del parámetro SecureString del token de unión (solo PROD)."
  value       = local.token_parameter_name
}

output "common_tags" {
  description = "Etiquetas comunes aplicables a todos los recursos nuevos."
  value       = local.common_tags
}
