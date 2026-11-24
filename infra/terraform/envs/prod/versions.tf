# Versiones fijadas para el root de PROD (HU 1, B5). Sin "latest":
#   - Terraform >= 1.6 (check blocks, preconditions y startswith usados en
#     los módulos) y < 2.0 (promesa de compatibilidad v1.x).
#   - Provider AWS hashicorp/aws ~> 6.72 (mínimo definido en el diseño de la
#     HU 1; la versión exacta quedará en .terraform.lock.hcl al primer init).
#
# Backend remoto (HU 2): estado en S3 con locking nativo. La clave es
# exclusiva de PROD; use_lockfile crea prod/terraform.tfstate.tflock durante
# las operaciones (sin DynamoDB). Ver docs/operaciones para el procedimiento
# de migración y recuperación.
terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }

  backend "s3" {
    bucket       = "circleguard-tfstate-718875641310"
    key          = "prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true

    allowed_account_ids = ["718875641310"]
  }
}
