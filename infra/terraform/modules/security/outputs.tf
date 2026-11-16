# Salidas del módulo security. Desde un ambiente:
#   server_sg_id = module.security.server_sg_id
# En dev/stage el agente no existe: agent_sg_id es null (try evita el índice
# sobre un recurso con count = 0).

output "server_sg_id" {
  description = "ID del Security Group del nodo k3s server del ambiente."
  value       = aws_security_group.server.id
}

output "server_sg_name" {
  description = "Nombre del Security Group del server."
  value       = aws_security_group.server.name
}

output "agent_sg_id" {
  description = "ID del Security Group del nodo k3s agent (solo prod; null en dev/stage)."
  value       = try(aws_security_group.agent[0].id, null)
}

output "agent_sg_name" {
  description = "Nombre del Security Group del agent (solo prod; null en dev/stage)."
  value       = try(aws_security_group.agent[0].name, null)
}
