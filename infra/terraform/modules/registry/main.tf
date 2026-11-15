# =============================================================================
# Módulo: registry (HU 1)
#
# Representa el registro de imágenes Docker YA EXISTENTE (Nexus en la instancia
# cg-devops) para que el resto de la HU lo consuma como dato, sin crear ECR ni
# administrar la configuración interna de Nexus (restricción aprobada).
#
#   - El registro sigue exponiéndose por HTTP temporalmente (decisión aceptada);
#     modules/k3s-cluster traduce esta salida al registries.yaml de containerd.
#   - Decisión de cierre de B2: el endpoint se construye con la IP PRIVADA de
#     cg-devops, y la regla de egress tcp 8082 (B3) referenciará su Security
#     Group en lugar de un CIDR con la IP pública.
#   - Este módulo solo consulta la instancia con data sources y expone el
#     endpoint; nada se crea ni se modifica (el Security Group existente de
#     cg-devops se lee, nunca se edita).
#   - La disponibilidad de Nexus se verifica además en bootstrap/preflight.sh.
# =============================================================================

data "aws_instance" "nexus" {
  filter {
    name   = "tag:Name"
    values = [var.instance_name]
  }
}
