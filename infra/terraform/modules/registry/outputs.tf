# Salidas del registro Nexus existente (solo lectura). Desde un ambiente:
#   registry_endpoint = module.registry.registry_endpoint
#
# Decisiones incorporadas al cierre de B2:
#   - El endpoint se construye con la IP PRIVADA de cg-devops: los nodos k3s
#     están en la misma VPC, el pull no sale por la IP pública (inmune a un
#     cambio de IP pública de cg-devops y sin tránsito por el IGW).
#   - La regla de egress tcp 8082 que se implementará en B3 usará una
#     referencia al Security Group de la instancia
#     (module.registry.security_group_ids[...]) como destino, en lugar de un
#     CIDR con la IP pública: la documentación AWS indica que las reglas de
#     egress con grupo de destino permiten tráfico hacia "the private IP
#     addresses" de las ENIs de ese grupo, que es el caso de esta implementación.
#   - Puerto 8082 y HTTP sin TLS: limitación conocida (deuda documentada en
#     el README; endurecer con TLS queda fuera del alcance de esta HU).

output "instance_id" {
  description = "ID de la instancia cg-devops que aloja Nexus."
  value       = data.aws_instance.nexus.id
}

output "instance_private_ip" {
  description = "IP privada de cg-devops dentro de la VPC (base del endpoint interno)."
  value       = data.aws_instance.nexus.private_ip
}

output "security_group_ids" {
  description = "Security Groups asociados a cg-devops (attribute vpc_security_group_ids). En B3 son el destino de la regla de egress tcp 8082; hoy la instancia tiene un solo grupo: cg-devops-sg."
  value       = data.aws_instance.nexus.vpc_security_group_ids

  precondition {
    condition     = length(data.aws_instance.nexus.vpc_security_group_ids) > 0
    error_message = "cg-devops no tiene Security Groups asociados: no se puede construir la referencia de egress del registro."
  }
}

output "registry_public_ip" {
  description = "IP pública de cg-devops: la usan los consumidores de Parte 1 (deploy/environments/*.env). Los nodos k3s NO la usan."
  value       = data.aws_instance.nexus.public_ip
}

output "registry_port" {
  description = "Puerto del repositorio Docker de Nexus."
  value       = var.registry_port
}

output "registry_endpoint" {
  description = "Endpoint INTERNO del registro (IP privada): <ip-privada:puerto>. Ej.: 10.20.1.230:8082 — el que usarán los nodos k3s en su registries.yaml."
  value       = "${data.aws_instance.nexus.private_ip}:${var.registry_port}"

  precondition {
    condition     = data.aws_instance.nexus.instance_state == "running"
    error_message = "La instancia del registro Nexus debe estar en ejecución (state != running)."
  }

  precondition {
    condition     = data.aws_instance.nexus.private_ip != null && data.aws_instance.nexus.private_ip != ""
    error_message = "cg-devops no tiene IP privada: no se puede construir el endpoint del registro Nexus."
  }
}

output "registry_scheme" {
  description = "Esquema del registro (http: Nexus se expone por HTTP temporalmente; deuda en el README)."
  value       = "http"
}

output "registry_insecure" {
  description = "true si containerd/k3s deben tratar el registro como inseguro (HTTP sin TLS)."
  value       = true
}
