# Valores del bootstrap del backend de estado (HU 2).
# Solo datos no sensibles: nombre del bucket, región, cuenta y etiquetas.
# Sin credenciales ni claves: las credenciales AWS llegan por la cadena
# estándar (perfil compartido, variables de entorno o rol asumido).

bucket_name = "circleguard-tfstate-718875641310"
region      = "us-east-1"
account_id  = "718875641310"

# Retención de versiones no actuales (ventana de rollback) y limpieza de
# multipart incompletos: valores aprobados en el diseño de HU 2.
noncurrent_version_retention_days = 90
abort_incomplete_multipart_days   = 7

tags = {
  Project   = "circleguard"
  ManagedBy = "terraform"
  HU        = "HU-2"
  Component = "tfstate-backend"
}
