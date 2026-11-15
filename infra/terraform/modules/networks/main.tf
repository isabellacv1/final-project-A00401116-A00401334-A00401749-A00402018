# =============================================================================
# Módulo: networks (HU 1)
#
# SOLO LECTURA: este módulo no crea ni modifica VPC, subredes, tablas de rutas
# ni Internet Gateways. Los describe con data sources para que los tres
# ambientes (y los módulos security/k3s-cluster) consuman sus identificadores
# sin hardcodearlos en cada estado.
#
# Supuestos verificados con el preflight (2026-11-14):
#   - VPC única circleguard-vpc = 10.20.0.0/16
#   - 4 subredes con tag Name, todas en us-east-1a
#   - 1 tabla de rutas circleguard-public-rt con salida0.0.0.0/0 -> IGW
#   - 1 Internet Gateway adjunto
#
# Si alguno de esos recursos no existiera, o coincidiera más de una vez, la
# consulta falla durante el refresh (fail-fast) en lugar de apuntar a otra red.
# =============================================================================

data "aws_vpc" "circleguard" {
  filter {
    name = "tag:Name"
    values = [var.vpc_name]
  }

  # Doble condición: además del nombre, el CIDR esperado. Garantiza que la
  # VPC encontrada es exactamente la del diseño (y que no haya dos homónimas).
  filter {
    name   = "cidr-block"
    values = [var.expected_vpc_cidr]
  }
}

data "aws_subnet" "by_name" {
  for_each = var.subnet_names

  filter {
    name = "tag:Name"
    values = [each.value]
  }

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.circleguard.id]
  }
}

data "aws_route_table" "public" {
  filter {
    name = "tag:Name"
    values = [var.route_table_name]
  }

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.circleguard.id]
  }
}

data "aws_internet_gateway" "main" {
  filter {
    name   = "attachment.vpc-id"
    values = [data.aws_vpc.circleguard.id]
  }
}
