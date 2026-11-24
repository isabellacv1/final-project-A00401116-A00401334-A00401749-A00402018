# Salidas del root PROD: identificación de instancias, direcciones IP y
# recursos principales (sin secretos: nunca se expone el token).

output "environment" {
  description = "Ambiente de este estado."
  value       = local.environment
}

output "subnet_id" {
  description = "Subred existente que consume este ambiente."
  value       = module.networks.subnet_ids[local.environment]
}

output "server_instance_id" {
  description = "ID de la instancia server de PROD."
  value       = module.k3s-cluster.server_instance_id
}

output "server_private_ip" {
  description = "IP privada del server (API k3s en6443; la usa el agent)."
  value       = module.k3s-cluster.server_private_ip
}

output "server_public_ip" {
  description = "IP pública del server (URL del Ingress; expuesta solo según los Security Groups definidos)."
  value       = module.k3s-cluster.server_public_ip
}

output "agent_instance_id" {
  description = "ID de la instancia agent de PROD."
  value       = module.k3s-cluster.agent_instance_id
}

output "agent_private_ip" {
  description = "IP privada del agent de PROD."
  value       = module.k3s-cluster.agent_private_ip
}

output "agent_public_ip" {
  description = "IP pública del agent de PROD (sujeta a sus SG: sin80/443 públicos)."
  value       = module.k3s-cluster.agent_public_ip
}

output "node_names" {
  description = "Nombres k3s de los nodos de PROD (server y agent)."
  value       = module.k3s-cluster.node_names
}

output "root_volume_ids" {
  description = "IDs de los volúmenes raíz gp3 cifrados de PROD (server y agent)."
  value       = module.k3s-cluster.root_volume_ids
}

output "server_sg_id" {
  description = "Security Group del nodo server (acepta80/443 públicos)."
  value       = module.security.server_sg_id
}

output "agent_sg_id" {
  description = "Security Group del nodo agent (sin puertos de aplicación públicos)."
  value       = module.security.agent_sg_id
}

output "dlm_policy_id" {
  description = "Política DLM de snapshots diarios de PROD."
  value       = module.storage.dlm_policy_id
}

output "registry_endpoint" {
  description = "Endpoint interno del registro Nexus que usan los nodos."
  value       = module.registry.registry_endpoint
}
