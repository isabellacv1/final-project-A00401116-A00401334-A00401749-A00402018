# =============================================================================
# Constantes globales de la HU 1 (Parte 2 - CircleGuard).
#
# Este directorio NO crea recursos AWS: centraliza los valores compartidos
# para que los tres estados (envs/dev, envs/stage, envs/prod) los consuman
# sin duplicarlos. Se usa como módulo:
#
#   module "shared" {
#     source = "../../shared"
#   }
#
# y cada valor se accede por el alias del bloque: `module.shared.ami_id`,
# `module.shared.k3s_version`, `module.shared.common_tags`, etc. (sin `.outputs.`).
#
# Reglas del repositorio aplicadas aquí: sin secretos, sin credenciales y sin
# valores que deban variar por ambiente (esos viven en envs/<env>/terraform.tfvars).
# =============================================================================

locals {
  # Región única de la infraestructura.
  region = "us-east-1"

  project     = "circleguard"
  name_prefix = "cg-k3s"

  # --- Ubuntu Server 24.04 LTS (noble) x86_64, AMI fijada ---------------
  # Canonical (owner 099720109477), build 20261108, raíz EBS, verificada
  # con describe-images el 2026-11-14. No se usa un lookup dinámico para
  # que el plan sea determinista; para actualizarla hay que cambiarla aquí.
  ami_id   = "ami-08b275ac6cc5dbefb"
  ami_name = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-20261108"

  # --- Cómputo ------------------------------------------------------------
  # Tipo de instancia fijado para los cuatro nodos k3s (2 vCPU / 8 GiB).
  # No es configurable: todos los nodos usan el mismo tipo.
  instance_type = "m7i-flex.large"

  # --- k3s ----------------------------------------------------------------
  # Versión fijada (última estable publicada el 2026-11-03, verificada el
  # 2026-11-14). Se pasa a cloud-init como INSTALL_K3S_VERSION.
  k3s_version = "v1.37.2+k3s1"

  # Usuario de la AMI de Ubuntu (SSH y cloud-init).
  ssh_user = "ubuntu"

  # --- Parameter Store ----------------------------------------------------
  # Solo PROD publica/lee el token de unión: DEV y STAGE son clústeres de un
  # solo nodo y no requieren parámetros (mínimo privilegio por ambiente).
  token_parameter_name = "/circleguard/k3s/prod-join-token"

  # --- Etiquetas comunes --------------------------------------------------
  # Los volúmenes raíz reciben además "DailySnapshot=true" desde
  # modules/k3s-cluster para que DLM los tome por target_tags.
  common_tags = {
    Project   = "circleguard"
    ManagedBy = "terraform"
    Part      = "2"
    HU        = "HU-1"
  }
}
