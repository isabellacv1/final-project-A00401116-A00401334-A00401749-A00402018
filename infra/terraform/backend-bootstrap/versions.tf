# =============================================================================
# Root: backend-bootstrap (HU 2)
#
# Versiones fijadas, idénticas a las de los roots de ambientes para que el
# operador use un único binario de Terraform y un único proveedor en todo el
# árbol infra/terraform:
#   - Terraform >= 1.6 (check blocks, preconditions y startswith usados en los
#     módulos) y < 2.0 (promesa de compatibilidad v1.x).
#   - Provider AWS hashicorp/aws ~> 6.72 (la versión exacta queda en
#     .terraform.lock.hcl al primer init).
#
# Este root NO declara bloque backend "s3": usa el backend local por defecto
# (ver README.md: no puede guardar su estado en el bucket que aún no existe).
# =============================================================================
terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }
}
