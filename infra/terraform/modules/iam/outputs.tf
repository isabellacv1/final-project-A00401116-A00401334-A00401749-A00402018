# Salidas del módulo iam. Desde un ambiente:
#   server_profile_name = module.iam.server_profile_name
# En dev/stage no existe el rol del agent: sus salidas son null (try evita el
# índice sobre un recurso cuyo for_each no incluye esa clave).

output "server_role_name" {
  description = "Nombre del rol del nodo server del ambiente."
  value       = aws_iam_role.node["server"].name
}

output "server_profile_name" {
  description = "Nombre del instance profile del server (se inyecta en la EC2 en B4)."
  value       = aws_iam_instance_profile.node["server"].name
}

output "server_profile_arn" {
  description = "ARN del instance profile del server."
  value       = aws_iam_instance_profile.node["server"].arn
}

output "agent_role_name" {
  description = "Nombre del rol del nodo agent (solo prod; null en dev/stage)."
  value       = try(aws_iam_role.node["agent"].name, null)
}

output "agent_profile_name" {
  description = "Nombre del instance profile del agent (solo prod; null en dev/stage)."
  value       = try(aws_iam_instance_profile.node["agent"].name, null)
}

output "agent_profile_arn" {
  description = "ARN del instance profile del agent (solo prod; null en dev/stage)."
  value       = try(aws_iam_instance_profile.node["agent"].arn, null)
}

output "dlm_role_name" {
  description = "Nombre del rol de ejecución de DLM del ambiente."
  value       = aws_iam_role.dlm.name
}

output "dlm_role_arn" {
  description = "ARN del rol de ejecución de DLM (execution_role_arn de la política de snapshots en B4)."
  value       = aws_iam_role.dlm.arn
}

output "token_parameter_arn" {
  description = "ARN exacto del parámetro del token de unión (solo prod; null en dev/stage)."
  value       = local.token_parameter_arn
}
