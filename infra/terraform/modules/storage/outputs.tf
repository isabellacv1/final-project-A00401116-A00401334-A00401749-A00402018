# Salidas del módulo storage. Desde un ambiente:
#   dlm_policy_id = module.storage.dlm_policy_id

output "dlm_policy_id" {
  description = "ID de la política DLM de snapshots del ambiente (evidencia para el README)."
  value       = aws_dlm_lifecycle_policy.root_snapshots.id
}

output "snapshot_target_tags" {
  description = "Tags exactos que seleccionan los volúmenes raíz (deben coincidir con los tags de k3s-cluster)."
  value       = local.snapshot_target_tags
}

output "schedule_summary" {
  description = "Resumen legible del horario y retención configurados."
  value       = "cada 24h a las ${var.schedule_time} UTC, retiene ${var.retention_count} snapshots"
}
