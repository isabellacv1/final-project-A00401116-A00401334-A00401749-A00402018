# =============================================================================
# Módulo: security (HU 1)
#
# Crea los Security Groups NUEVOS de los nodos k3s con sus reglas administradas
# por separado (aws_vpc_security_group_ingress_rule / aws_vpc_security_group_
# egress_rule). No usa reglas inline (la documentación del proveedor prohíbe
# mezclarlas) y no toca ningún Security Group existente: cg-devops-sg solo se
# referencia como origen/destino.
#
# Comportamiento verificado del proveedor: al crear un Security Group dentro de
# una VPC, Terraform ELIMINA la regla de egress "ALLOW ALL" que AWS agrega por
# defecto, por lo que el tráfico saliente queda limitado a las reglas E1..E9,
# con una excepción documentada (E1): AWS no permite filtrar con Security
# Groups el DNS dirigido al resolver AmazonProvidedDNS.
#
# LIMITACIÓN DE AWS (E1 es declarativa, NO un control efectivo de DNS): los
# Security Groups NO filtran el tráfico destinado al Route 53 Resolver
# (AmazonProvidedDNS, "VPC+2", p. ej. 10.20.0.2) ni el que viene de él. Por eso
# la regla E1 documenta el destino DNS previsto pero no restringe ese tráfico;
# para filtrar DNS habría que usar Route 53 Resolver DNS Firewall.
# Fuentes:
#   https://docs.aws.amazon.com/vpc/latest/userguide/security-group-rules.html
#     ("Limitation: Security groups cannot block DNS requests to or from the
#      Route 53 Resolver, sometimes referred to as the 'VPC+2 IP address'")
#   https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html
#     ("Security groups do not filter traffic destined to and from the
#      following: Amazon Domain Name Services (DNS) ...")
#
# Cuatro SG (nombres aprobados en el diseño):
#   cg-k3s-dev-sg          dev    server único
#   cg-k3s-stage-sg        stage  server único
#   cg-k3s-prod-server-sg  prod   server (80/443 públicos)
#   cg-k3s-prod-agent-sg   prod   agent  (SIN 80/443 públicos)
#
# Ingress:
#   - 22 (SSH) y 6443 (kubectl) solo desde cg-devops-sg; SSM es la alternativa
#     preferida. Nunca hay 6443 público.
#   - 80/443: públicos SOLO en el server PROD; en dev/stage solo desde
#     cg-devops-sg (decisión A aprobada).
#   - prod interno: server acepta 6443/udp8472 desde el agent; agent acepta
#     10250/udp8472 desde el server. Sin NodePorts, sin etcd (2379-2380).
#
# Egress (E1..E9 del diseño aprobado): DNS del VPC (E1 declarativa: AWS no
# permite filtrar con Security Groups el tráfico al resolver VPC+2, ver
# LIMITACIÓN DE AWS en la cabecera de este archivo), 443, 80, 123; Nexus tcp
# 8082 por REFERENCIA AL SG del registro (module.registry.security_group_ids,
# nunca un CIDR de IP pública); en prod, los pares internos 10250/8472/6443.
# No se habilita egress irrestricto en ningún SG.
# =============================================================================

locals {
  is_prod = var.env == "prod"

  # Nombres aprobados: dev/stage son de un solo nodo; prod separa server/agent.
  server_sg_name = local.is_prod ? "${var.name_prefix}-prod-server-sg" : "${var.name_prefix}-${var.env}-sg"
  agent_sg_name  = "${var.name_prefix}-prod-agent-sg"

  # AmazonProvidedDNS del VPC (base + 2): 10.20.0.2 en la VPC 10.20.0.0/16.
  # LIMITACIÓN AWS: los Security Groups no filtran el tráfico hacia/desde este
  # resolver (VPC+2), así que la regla E1 documenta el destino pero no restringe
  # el DNS (fuentes en la cabecera del archivo).
  vpc_dns_cidr = "${cidrhost(var.vpc_cidr, 2)}/32"

  # SGs de este módulo por rol. El agente solo existe en prod; la lista
  # aws_security_group.agent queda vacía en dev/stage (count = 0).
  node_sg_ids = merge(
    { server = aws_security_group.server.id },
    { for sg in aws_security_group.agent : "agent" => sg.id },
  )

  # Egress común a todos los nodos (E1..E5). Todas las entradas llevan las
  # mismas claves: cidr_ipv4 XOR referenced_sg_id.
  # Nota de E1: regla DECLARATIVA — AWS no permite filtrar con Security Groups
  # el DNS hacia AmazonProvidedDNS (limitación citada en la cabecera del archivo).
  common_egress = {
    dns_udp = {
      protocol         = "udp"
      port             = 53
      cidr_ipv4        = local.vpc_dns_cidr
      referenced_sg_id = null
      description      = "E1: DNS al resolver del VPC (AmazonProvidedDNS base+2); declarativa: AWS exime ese trafico del filtrado por Security Groups"
    }
    dns_tcp = {
      protocol         = "tcp"
      port             = 53
      cidr_ipv4        = local.vpc_dns_cidr
      referenced_sg_id = null
      description      = "E1: DNS fallback TCP al resolver del VPC; declarativa (misma limitacion de AWS)"
    }
    https = {
      protocol         = "tcp"
      port             = 443
      cidr_ipv4        = "0.0.0.0/0"
      referenced_sg_id = null
      description      = "E2: HTTPS saliente: k3s, imagenes (Docker Hub, registry.k8s.io, Rancher), apt, snap, SSM"
    }
    http = {
      protocol         = "tcp"
      port             = 80
      cidr_ipv4        = "0.0.0.0/0"
      referenced_sg_id = null
      description      = "E3: HTTP saliente: mirrors de Ubuntu y ACME http-01 futuro"
    }
    ntp = {
      protocol         = "udp"
      port             = 123
      cidr_ipv4        = "0.0.0.0/0"
      referenced_sg_id = null
      description      = "E4: NTP (AWS Time Sync es link-local y no requiere regla)"
    }
    nexus = {
      protocol         = "tcp"
      port             = var.registry_port
      cidr_ipv4        = null
      referenced_sg_id = var.registry_security_group_id
      description      = "E5: pull de Nexus existente por referencia al SG del registro (IP privada, HTTP)"
    }
  }
}

# ----------------------------------------------------------- Security Groups --

resource "aws_security_group" "server" {
  name        = local.server_sg_name
  description = "CircleGuard ${var.env}: nodo k3s server (SSH y API desde cg-devops${local.is_prod ? "; 80/443 publicos" : "; 80/443 solo cg-devops"})"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name        = local.server_sg_name
    Environment = var.env
    Role        = "k3s-server"
  })
}

resource "aws_security_group" "agent" {
  count = local.is_prod ? 1 : 0

  name        = local.agent_sg_name
  description = "CircleGuard prod: nodo k3s agent (SSH desde cg-devops; flannel 8472 y kubelet 10250 desde el server; sin puertos de aplicacion)"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name        = local.agent_sg_name
    Environment = var.env
    Role        = "k3s-agent"
  })
}

# ----------------------------------------------------------------- Ingress --

# SSH (22) desde cg-devops en todos los nodos; SSM es la alternativa preferida.
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = local.node_sg_ids

  security_group_id            = each.value
  description                  = "SSH desde cg-devops; SSM Session Manager es la alternativa preferida"
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = var.devops_security_group_id
}

# API de Kubernetes (kubectl) desde cg-devops. Nunca expuesta públicamente.
resource "aws_vpc_security_group_ingress_rule" "server_api_devops" {
  security_group_id            = aws_security_group.server.id
  description                  = "API de Kubernetes (kubectl) desde cg-devops; nunca publica"
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  referenced_security_group_id = var.devops_security_group_id
}

# 80/443 del server: publicos en prod (usuarios via Ingress); en dev/stage
# unicamente desde cg-devops (E2E y smoke tests) - decision A aprobada.
resource "aws_vpc_security_group_ingress_rule" "server_web" {
  for_each = toset(["80", "443"])

  security_group_id = aws_security_group.server.id
  description       = local.is_prod ? "Entrada publica de usuarios via Ingress (Traefik)" : "Entrada de usuario solo desde cg-devops (E2E y smoke tests)"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)

  cidr_ipv4                    = local.is_prod ? "0.0.0.0/0" : null
  referenced_security_group_id = local.is_prod ? null : var.devops_security_group_id
}

# --- Internos PROD (server <-> agent); count = 0 en dev/stage ----------------

resource "aws_vpc_security_group_ingress_rule" "server_api_from_agent" {
  count = local.is_prod ? 1 : 0

  security_group_id            = aws_security_group.server.id
  description                  = "API de Kubernetes desde el node agent (contraparte de la egress E8)"
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  referenced_security_group_id = aws_security_group.agent[0].id
}

resource "aws_vpc_security_group_ingress_rule" "server_flannel_from_agent" {
  count = local.is_prod ? 1 : 0

  security_group_id            = aws_security_group.server.id
  description                  = "Flannel VXLAN desde el node agent udp 8472 (contraparte de la egress E9)"
  ip_protocol                  = "udp"
  from_port                    = 8472
  to_port                      = 8472
  referenced_security_group_id = aws_security_group.agent[0].id
}

resource "aws_vpc_security_group_ingress_rule" "agent_kubelet_from_server" {
  count = local.is_prod ? 1 : 0

  security_group_id            = aws_security_group.agent[0].id
  description                  = "Kubelet desde el server: logs, exec y metrics (contraparte de la egress E6)"
  ip_protocol                  = "tcp"
  from_port                    = 10250
  to_port                      = 10250
  referenced_security_group_id = aws_security_group.server.id
}

resource "aws_vpc_security_group_ingress_rule" "agent_flannel_from_server" {
  count = local.is_prod ? 1 : 0

  security_group_id            = aws_security_group.agent[0].id
  description                  = "Flannel VXLAN desde el server udp 8472 (contraparte de la egress E7)"
  ip_protocol                  = "udp"
  from_port                    = 8472
  to_port                      = 8472
  referenced_security_group_id = aws_security_group.server.id
}

# ------------------------------------------------------------------ Egress --

# E1..E5 comunes a todos los nodos (dev/stage solo tienen el server).
resource "aws_vpc_security_group_egress_rule" "common" {
  for_each = {
    for pair in setproduct(keys(local.node_sg_ids), keys(local.common_egress)) :
    "${pair[0]}-${pair[1]}" => {
      sg_id = local.node_sg_ids[pair[0]]
      rule  = local.common_egress[pair[1]]
    }
  }

  security_group_id            = each.value.sg_id
  description                  = each.value.rule.description
  ip_protocol                  = each.value.rule.protocol
  from_port                    = each.value.rule.port
  to_port                      = each.value.rule.port
  cidr_ipv4                    = each.value.rule.cidr_ipv4
  referenced_security_group_id = each.value.rule.referenced_sg_id
}

# --- Internos PROD (E6..E9); count = 0 en dev/stage --------------------------

resource "aws_vpc_security_group_egress_rule" "server_kubelet_to_agent" {
  count = local.is_prod ? 1 : 0

  security_group_id            = aws_security_group.server.id
  description                  = "E6: kubelet del server hacia el agent (logs, exec, metrics)"
  ip_protocol                  = "tcp"
  from_port                    = 10250
  to_port                      = 10250
  referenced_security_group_id = aws_security_group.agent[0].id
}

resource "aws_vpc_security_group_egress_rule" "server_flannel_to_agent" {
  count = local.is_prod ? 1 : 0

  security_group_id            = aws_security_group.server.id
  description                  = "E7: Flannel VXLAN del server hacia el agent udp 8472"
  ip_protocol                  = "udp"
  from_port                    = 8472
  to_port                      = 8472
  referenced_security_group_id = aws_security_group.agent[0].id
}

resource "aws_vpc_security_group_egress_rule" "agent_api_to_server" {
  count = local.is_prod ? 1 : 0

  security_group_id            = aws_security_group.agent[0].id
  description                  = "E8: agente hacia la API del server (join y kubelet) tcp 6443"
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  referenced_security_group_id = aws_security_group.server.id
}

resource "aws_vpc_security_group_egress_rule" "agent_flannel_to_server" {
  count = local.is_prod ? 1 : 0

  security_group_id            = aws_security_group.agent[0].id
  description                  = "E9: Flannel VXLAN del agent hacia el server udp 8472"
  ip_protocol                  = "udp"
  from_port                    = 8472
  to_port                      = 8472
  referenced_security_group_id = aws_security_group.server.id
}
