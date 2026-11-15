# =============================================================================
# Módulo: storage (HU 1)
#
# Snapshots EBS diarios de los VOLÚMENES RAÍZ de los nodos k3s mediante AWS
# Data Lifecycle Manager (DLM):
#   - Programación: cada24 h a las 03:00 UTC (times = UTC según la API de DLM).
#   - Retención: 7 snapshots (los más antiguos los elimina el propio DLM).
#   - Selección por TAGS acordados: Project + Environment + DailySnapshot.
#     Los volúmenes raíz los crea modules/k3s-cluster con esos tags; este
#     módulo NO recibe IDs de volumen (DIM apunta por tags), por lo que no
#     hay dependencia dura entre módulos.
#   - Rol de ejecución: el rol DLM del módulo iam (B3), sin modificar.
#
# Alcance: solo snapshots de volúmenes raíz. No hay volúmenes de datos
# adicionales ni almacenamiento persistente de aplicaciones (decisión aprobada).
#
# Costo (precios oficiales verificados): gp3 $0.08/GB-mes; snapshot $0.05/GB-mes
# sobre BLOQUES ALMACENADOS (incremental), no sobre el tamaño provisionado.
# =============================================================================

locals {
  # Convención de tags de volumen: debe coincidir con root_block_device.tags
  # de modules/k3s-cluster. "Environment" diferencia los tres ambientes para
  # que la política de un estado jamás capture volúmenes de otro.
  snapshot_target_tags = {
    Project       = lookup(var.tags, "Project", "circleguard")
    Environment   = var.env
    DailySnapshot = "true"
  }
}

resource "aws_dlm_lifecycle_policy" "root_snapshots" {
  description = "CircleGuard HU1 snapshots diarios a las0300 UTC volumenes raices k3s ${var.env} retencion ${var.retention_count}"
  # Rol creado por modules/iam (B3). Trust dlm.amazonaws.com + condiciones
  # anti confused-deputy; politica AWSDataLifecycleManagerServiceRole (snapshots).
  execution_role_arn = var.dlm_role_arn
  state              = "ENABLED"

  policy_details {
    # Por defecto EBS_SNAPSHOT_MANAGEMENT (politica de SNAPSHOT de volumenes);
    # NO IMAGE_MANAGEMENT (esa seria la de AMI, con otra politica IAM).
    policy_type    = "EBS_SNAPSHOT_MANAGEMENT"
    resource_types = ["VOLUME"]
    target_tags    = local.snapshot_target_tags

    schedule {
      name = "diario-0300-utc"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = [var.schedule_time] # UTC
      }

      retain_rule {
        count = var.retention_count
      }

      # Los snapshots heredan los tags del volumen (auditoría por ambiente).
      copy_tags = true
      tags_to_add = {
        SnapshotBy  = "dlm"
        Environment = var.env
      }
    }
  }

  tags = merge(var.tags, {
    Name        = "cg-snapshots-${var.env}"
    Environment = var.env
    Component   = "dlm-snapshots"
  })
}
