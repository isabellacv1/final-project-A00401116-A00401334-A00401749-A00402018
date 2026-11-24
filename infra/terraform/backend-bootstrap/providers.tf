# Configuración del provider AWS para el root de backend-bootstrap.
# La región llega como variable de entrada (por defecto us-east-1, la misma
# de la infraestructura de CircleGuard) para que el bucket quede en la misma
# región que los recursos que administra.
#
# Sin default_tags aquí: las etiquetas del proyecto se aplican por recurso
# desde var.tags (mismo criterio que envs/<env>/providers.tf).
provider "aws" {
  region = var.region
}
