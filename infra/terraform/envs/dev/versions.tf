# Versiones fijadas para el root de DEV (HU 1, B5). Sin "latest":
#   - Terraform >= 1.6 (check blocks, preconditions y startswith usados en
#     los módulos) y < 2.0 (promesa de compatibilidad v1.x).
#   - Provider AWS hashicorp/aws ~> 6.72 (mínimo aprobado en el diseño de la
#     HU 1; la versión exacta quedará en .terraform.lock.hcl al primer init).
terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }
}
