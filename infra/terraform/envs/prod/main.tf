# Raíz: AMBIENTE PROD (HU 1, B5)
#
# Cablea los módulos de las capas B1-B4 sin duplicar lógica y sin backend
# remoto (el estado local con bloqueo es una limitación conocida; el backend
# S3 con locking se introduce en una HU posterior).
#
# Cadena de dependencias:
#   shared ─┬─ networks ─┬─ security ─┬─ k3s-cluster
#           │            │            │
#           ├─ registry ─┘            │
#           └─ iam ───────┬─ storage  │
#                         └───────────┘
# Topología PROD:1 server +1 agent (agent_count=1), EBS raíz50 GB por nodo.
# PROD es el ÚNICO ambiente que usa Parameter Store: el server publica el
# token de unión (SecureString) y el agent lo lee, ambos con permisos exactos
# sobre el ARN del parámetro (módulo iam, B3).

locals {
  environment = "prod"
}

# --- Constantes (B1) ----------------------------------------------------------
module "shared" {
  source = "../../shared"
}

# --- Infraestructura existente, solo lectura (B2) -----------------------------
module "networks" {
  source = "../../modules/networks"
}

module "registry" {
  source = "../../modules/registry"
}

# --- Seguridad (B3) -----------------------------------------------------------
module "security" {
  source = "../../modules/security"

  env      = local.environment
  vpc_id   = module.networks.vpc_id
  vpc_cidr = module.networks.vpc_cidr

  # Nexus vive en cg-devops: un único SG cumple a la vez el origen de
  # SSH/kubectl (capa B3) y el destino del egress tcp 8082 del registro
  # (capa B3). one() falla si cg-devops no tiene exactamente un SG.
  devops_security_group_id   = one(module.registry.security_group_ids)
  registry_security_group_id = one(module.registry.security_group_ids)
  registry_port              = module.registry.registry_port

  tags = module.shared.common_tags
}

# --- Acceso SSH de la colaboradora k8s (acotado por IP) -----------------------
# Reglas INDEPENDIENTES de las reglas del módulo security: las reglas
# principales de SSH (tcp/22) siguen siendo exclusivamente desde cg-devops-sg y
# no se modifican. PROD tiene DOS nodos (server y agent), por lo que se agrega
# una regla por SG con el mismo CIDR. No toca instancias, key pairs, user_data
# ni otras reglas.
resource "aws_vpc_security_group_ingress_rule" "ssh_k8s_partner" {
  for_each = {
    server = module.security.server_sg_id
    agent  = module.security.agent_sg_id
  }

  security_group_id = each.value
  description       = "SSH desde161.18.64.23 (colaboradora k8s, nodo ${each.key})"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = "161.18.64.23/32"
}

# --- Identidad y perfiles (B3) ------------------------------------------------
module "iam" {
  source = "../../modules/iam"

  env    = local.environment
  region = module.shared.region
  # PROD: único ambiente con permisos de Parameter Store (Put en el server,
  # Get en el agent) sobre el ARN exacto del parámetro del token.
  token_parameter_name = module.shared.token_parameter_name
  tags                 = module.shared.common_tags
}

# --- Snapshots EBS (B4) -------------------------------------------------------
module "storage" {
  source = "../../modules/storage"

  env          = local.environment
  dlm_role_arn = module.iam.dlm_role_arn
  # schedule_time="03:00" (UTC) y retention_count=7: valores por defecto del
  # módulo; se mantienen sin sobrescribir en el root.
  tags = module.shared.common_tags
}

# --- Nodo(s) k3s + bootstrap (B4) --------------------------------------------
module "k3s-cluster" {
  source = "../../modules/k3s-cluster"

  env           = local.environment
  region        = module.shared.region
  ami_id        = module.shared.ami_id
  instance_type = module.shared.instance_type
  k3s_version   = module.shared.k3s_version

  subnet_id = module.networks.subnet_ids[local.environment]

  server_sg_id = module.security.server_sg_id
  agent_sg_id  = module.security.agent_sg_id # id del SG del agent en PROD

  server_profile_name = module.iam.server_profile_name
  agent_profile_name  = module.iam.agent_profile_name

  key_name = var.key_name

  registry_endpoint = module.registry.registry_endpoint
  registry_scheme   = module.registry.registry_scheme

  root_volume_size = var.root_volume_size
  agent_count      = var.agent_count
  # PROD publica/lee el token en Parameter Store (SecureString).
  token_parameter_name = module.shared.token_parameter_name
  tags                 = module.shared.common_tags
}

# --- Invariante: la región del provider y la de shared deben coincidir -------
# (los providers se configuran antes que los módulos, por eso el provider usa
# la variable; este check lo detecta en el primer plan si algo cambia).
check "aws_region_vs_shared" {
  assert {
    condition     = var.aws_region == module.shared.region
    error_message = "aws_region (var) difiere de shared.region (constante única de shared)."
  }
}
