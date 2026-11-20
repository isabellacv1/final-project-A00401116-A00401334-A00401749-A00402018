# Salidas del módulo k3s-cluster. Desde un ambiente:
#   server_public_ip = module.k3s-cluster.server_public_ip
# En dev/stage no hay agent: agent_* y agent_instance_id son null (one() sobre
# una lista vacía devuelve null).

output "server_instance_id" {
  description = "ID de la instancia server del clúster."
  value       = aws_instance.server.id
}

output "server_private_ip" {
  description = "IP privada del server (la usa el agent para unirse: https://ip:6443)."
  value       = aws_instance.server.private_ip
}

output "server_public_ip" {
  description = "IP pública del server (URL de acceso al Ingress en prod; expuesta solo según los Security Groups definidos)."
  value       = aws_instance.server.public_ip
}

output "agent_instance_id" {
  description = "ID de la instancia agent (solo prod; null en dev/stage)."
  value       = one([for instance in aws_instance.agent : instance.id])
}

output "agent_private_ip" {
  description = "IP privada del agent (solo prod; null en dev/stage)."
  value       = one([for instance in aws_instance.agent : instance.private_ip])
}

output "agent_public_ip" {
  description = "IP pública del agent (solo prod; null en dev/stage). No expone servicios: sus SG no abren80/443."
  value       = one([for instance in aws_instance.agent : instance.public_ip])
}

output "root_volume_ids" {
  description = "IDs de los volúmenes raíz gp3 cifrados de todos los nodos (evidencia y verificación de DLM)."
  value = concat(
    [aws_instance.server.root_block_device[0].volume_id],
    [for instance in aws_instance.agent : instance.root_block_device[0].volume_id],
  )
}

output "node_names" {
  description = "Nombres k3s de los nodos de este clúster."
  value       = var.agent_count > 0 ? [local.server_name, local.agent_name] : [local.server_name]
}
