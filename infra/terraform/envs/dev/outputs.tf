# Salidas del root DEV: identificación de instancias, direcciones IP y
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
  description = "ID de la instancia server de DEV."
  value       = module.k3s-cluster.server_instance_id
}

output "server_private_ip" {
  description = "IP privada del server (API k3s en6443)."
  value       = module.k3s-cluster.server_private_ip
}

output "server_public_ip" {
  description = "IP pública del server (sujeta a los SG de B3)."
  value       = module.k3s-cluster.server_public_ip
}

output "agent_instance_id" {
  description = "ID de la instancia agent (null en DEV: no hay agent)."
  value       = module.k3s-cluster.agent_instance_id
}

output "agent_private_ip" {
  description = "IP privada del agent (null en DEV)."
  value       = module.k3s-cluster.agent_private_ip
}

output "agent_public_ip" {
  description = "IP pública del agent (null en DEV: no hay agent)."
  value       = module.k3s-cluster.agent_public_ip
}

output "node_names" {
  description = "Nombres k3s de los nodos de DEV."
  value       = module.k3s-cluster.node_names
}

output "root_volume_ids" {
  description = "IDs de los volúmenes raíz gp3 cifrados de DEV."
  value       = module.k3s-cluster.root_volume_ids
}

output "server_sg_id" {
  description = "Security Group del nodo server."
  value       = module.security.server_sg_id
}

output "agent_sg_id" {
  description = "Security Group del nodo agent (null en DEV)."
  value       = module.security.agent_sg_id
}

output "dlm_policy_id" {
  description = "Política DLM de snapshots diarios de DEV."
  value       = module.storage.dlm_policy_id
}

output "registry_endpoint" {
  description = "Endpoint interno del registro Nexus que usan los nodos."
  value       = module.registry.registry_endpoint
}
