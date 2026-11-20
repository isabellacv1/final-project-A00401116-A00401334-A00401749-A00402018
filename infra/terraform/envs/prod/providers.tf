# Configuración del provider AWS para el root de PROD.
# La región llega como variable de entrada (los bloques provider se evalúan
# antes que los módulos); el check "aws_region_vs_shared" de main.tf garantiza
# que coincida con la constante definida en shared.region.
#
# Sin default_tags aquí: las etiquetas comunes y por ambiente las aplican los
# módulos (shared.common_tags + Environment/Role), en todas las capas B1-B4.
provider "aws" {
  region = var.aws_region
}
