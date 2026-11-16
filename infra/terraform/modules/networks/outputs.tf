# Salidas de la red existente (solo lectura). Desde un ambiente:
#   module.networks.subnet_ids["dev"]     (alias del bloque + salida + índice)

output "vpc_id" {
  description = "ID de la VPC existente circleguard-vpc (data source, no administrada)."
  value       = data.aws_vpc.circleguard.id
}

output "vpc_cidr" {
  description = "CIDR de la VPC existente."
  value       = data.aws_vpc.circleguard.cidr_block
}

output "subnet_ids" {
  description = "Mapa ambiente => ID de subred (dev, stage, prod, devops)."
  value       = { for env, subnet in data.aws_subnet.by_name : env => subnet.id }
}

output "subnet_cidrs" {
  description = "Mapa ambiente => CIDR de la subred."
  value       = { for env, subnet in data.aws_subnet.by_name : env => subnet.cidr_block }
}

output "subnet_azs" {
  description = "Mapa ambiente => Zona de Disponibilidad de la subred."
  value       = { for env, subnet in data.aws_subnet.by_name : env => subnet.availability_zone }
}

output "subnet_map_public_ip_on_launch" {
  description = "Mapa ambiente => si la subred asigna IP pública en el arranque (stage es false: k3s-cluster debe pedirla explícitamente)."
  value       = { for env, subnet in data.aws_subnet.by_name : env => subnet.map_public_ip_on_launch }
}

output "availability_zones" {
  description = "Zonas de Disponibilidad distintas usadas por las subredes (hoy: una sola, limitación aceptada)."
  value       = distinct([for subnet in data.aws_subnet.by_name : subnet.availability_zone])
}

output "route_table_id" {
  description = "ID de la tabla de rutas pública existente (asociada a las cuatro subredes)."
  value       = data.aws_route_table.public.id
}

output "internet_gateway_id" {
  description = "ID del Internet Gateway adjunto a la VPC existente."
  value       = data.aws_internet_gateway.main.id
}
