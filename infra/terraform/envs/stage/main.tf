# Raíz: AMBIENTE STAGE (HU 1, B5)
#
# Cablea los módulos aprobados B1-B4 sin duplicar lógica y sin backend
# remoto (el estado local con bloqueo corresponde a HU 2).
#
# Cadena de dependencias:
#   shared ─┬─ networks ─┬─ security ─┬─ k3s-cluster
#           │            │            │
#           ├─ registry ─┘            │
#           └─ iam ───────┬─ storage  │
#                         └───────────┘
# Topología STAGE: 1 nodo server, SIN agent (agent_count=0), EBS raíz 40 GB,
# sin Parameter Store (el token de unión es solo de PROD).

locals {
  environment = "stage"
}

# --- Constantes aprobadas (B1) ------------------------------------------------
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
  # SSH/kubectl (decisión2) y el destino del egress tcp 8082 del registro
  # (decisión B3). one() falla si cg-devops no tiene exactamente un SG.
  devops_security_group_id   = one(module.registry.security_group_ids)
  registry_security_group_id = one(module.registry.security_group_ids)
  registry_port              = module.registry.registry_port

  tags = module.shared.common_tags
}

# --- Identidad y perfiles (B3) ------------------------------------------------
module "iam" {
  source = "../../modules/iam"

  env    = local.environment
  region = module.shared.region
  # STAGE no usa Parameter Store: token_parameter_name se omite (default null)
  # y este estado no recibe ningún permiso de parámetros.
  tags = module.shared.common_tags
}

# --- Snapshots EBS (B4) -------------------------------------------------------
module "storage" {
  source = "../../modules/storage"

  env          = local.environment
  dlm_role_arn = module.iam.dlm_role_arn
  # schedule_time="03:00" (UTC) y retention_count=7: valores aprobados, se
  # mantienen como defaults del módulo.
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
  agent_sg_id  = module.security.agent_sg_id # null en STAGE (sin agente)

  server_profile_name = module.iam.server_profile_name
  agent_profile_name  = module.iam.agent_profile_name # null en STAGE

  key_name = var.key_name

  registry_endpoint = module.registry.registry_endpoint
  registry_scheme   = module.registry.registry_scheme

  root_volume_size = var.root_volume_size
  agent_count      = var.agent_count
  # STAGE no publica ni lee el token de unión: token_parameter_name se omite.
  tags = module.shared.common_tags
}

# --- Invariante: la región del provider y la de shared deben coincidir -------
# (los providers se configuran antes que los módulos, por eso el provider usa
# la variable; este check lo detecta en el primer plan si algo cambia).
check "aws_region_vs_shared" {
  assert {
    condition     = var.aws_region == module.shared.region
    error_message = "aws_region (var) difiere de shared.region (constante aprobada)."
  }
}
