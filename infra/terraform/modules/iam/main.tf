# =============================================================================
# Módulo: iam (HU 1)
#
# Crea roles e instance profiles NUEVOS, con nombres por ambiente (patrones
# definidos en el diseño) para que los tres estados Terraform jamás compitan
# por el mismo recurso IAM:
#
#   cg-k3s-<env>-server-role  / cg-k3s-<env>-server-profile   (siempre)
#   cg-k3s-prod-agent-role    / cg-k3s-prod-agent-profile     (solo prod)
#   cg-dlm-<env>-role                                           (snapshots)
#
# Mínimo privilegio:
#   - Roles de nodo: unicamente AmazonSSMManagedInstanceCore (Session Manager
#     como acceso preferido; el SSH desde cg-devops es la vía auxiliar).
#   - Parameter Store EXCLUSIVO de PROD: el server escribe el token de union
#     (ssm:PutParameter) y el agent lo lee (ssm:GetParameter), ambos sobre el
#     ARN EXACTO del parametro. DEV y STAGE no reciben ningun permiso sobre
#     Parameter Store (una validacion lo bloquea si alguien lo intenta).
#   - Sin permisos KMS: la clave aws/ssm es administrada por AWS y su politica
#     ya solo autoriza uso via SSM dentro de la cuenta (decision B). Si el
#     primer arranque reportara AccessDenied de KMS, se agregarian permisos
#     kms acotados a esa clave (contingencia documentada).
#   - NADA de AdministratorAccess y NO se modifica el rol existente
#     CircleGuard-EC2-SSM-Role (queda intacto).
#
# Rol DLM (verificado con la documentacion oficial de AWS EBS/DLM):
#   - Trust: dlm.amazonaws.com con aws:SourceAccount y aws:SourceArn
#     (ArnLike con policy/* porque el rol se crea antes que la politica de
#     ciclo de vida), tal como recomiendan las docs anti confused-deputy.
#     Si DLM no emitiera esas claves y los snapshots no corrieran, el
#     fallback es retirar el bloque Condition (decision reversible).
#   - Politica adjunta: AWSDataLifecycleManagerServiceRole (SNAPSHOT de
#     volumenes). NO usar AWSDataLifecycleManagerServiceRoleForAMIManagement
#     (esa es la politica de administracion de AMI).
# =============================================================================

data "aws_caller_identity" "current" {}

locals {
  is_prod = var.env == "prod"

  # Roles de nodo del ambiente: server siempre; agent solo en prod.
  node_roles = local.is_prod ? ["server", "agent"] : ["server"]

  # ARN EXACTO del unico parametro Parameter Store de la HU 1 (solo prod).
  # Formato verificado de forma empirica con un parametro publico de AWS:
  #   nombre   /aws/service/ami-...
  #   arn      arn:aws:ssm:us-east-1::parameter/aws/service/ami-...
  # es decir, el ARN es "parameter" + el nombre tal cual (que ya incluye la
  # barra inicial) => un unico slash.
  token_parameter_arn = var.token_parameter_name == null ? null : format(
    "arn:aws:ssm:%s:%s:parameter%s",
    var.region,
    data.aws_caller_identity.current.account_id,
    var.token_parameter_name,
  )
}

# ------------------------------------------------------------ Roles de nodos --

resource "aws_iam_role" "node" {
  for_each = toset(local.node_roles)

  name        = "${var.name_prefix}-${var.env}-${each.key}-role"
  description = "CircleGuard HU1: nodo k3s ${each.key} del ambiente ${var.env}. Acceso operativo por SSM Session Manager."
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, {
    Environment = var.env
    Role        = "k3s-${each.key}"
  })

  lifecycle {
    precondition {
      condition     = local.is_prod || var.token_parameter_name == null
      error_message = "token_parameter_name solo aplica en prod: DEV y STAGE no reciben permisos de Parameter Store."
    }
  }
}

resource "aws_iam_role_policy_attachment" "node_ssm_core" {
  for_each   = aws_iam_role.node
  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "node" {
  for_each = aws_iam_role.node

  name = "${var.name_prefix}-${var.env}-${each.key}-profile"
  role = each.value.name

  tags = merge(var.tags, {
    Environment = var.env
    Role        = "k3s-${each.key}"
  })
}

# ------------------------------------- Token de union de PROD (Parameter Store)

# Unico rol con permiso de ESCRITURA sobre el parametro (ARN exacto).
resource "aws_iam_role_policy" "prod_server_token_put" {
  count = local.is_prod ? 1 : 0

  name = "${var.name_prefix}-prod-server-token-put"
  role = aws_iam_role.node["server"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "PutJoinTokenOnly"
      Effect   = "Allow"
      Action   = ["ssm:PutParameter"]
      Resource = local.token_parameter_arn == null ? [] : [local.token_parameter_arn]
    }]
  })

  lifecycle {
    precondition {
      condition     = var.token_parameter_name != null
      error_message = "prod requiere token_parameter_name (module.shared.token_parameter_name) para que el server publique el token de union."
    }
  }
}

# Unico rol con permiso de LECTURA sobre el parametro (ARN exacto).
resource "aws_iam_role_policy" "prod_agent_token_get" {
  count = local.is_prod ? 1 : 0

  name = "${var.name_prefix}-prod-agent-token-get"
  role = aws_iam_role.node["agent"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "GetJoinTokenOnly"
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = local.token_parameter_arn == null ? [] : [local.token_parameter_arn]
    }]
  })

  lifecycle {
    precondition {
      condition     = var.token_parameter_name != null
      error_message = "prod requiere token_parameter_name (module.shared.token_parameter_name) para que el agent lea el token de union."
    }
  }
}

# ------------------------------------------------------------- Rol DLM --------

resource "aws_iam_role" "dlm" {
  name        = "cg-dlm-${var.env}-role"
  description = "CircleGuard HU1: rol de ejecucion de DLM para snapshots EBS del ambiente ${var.env}."
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:dlm:${var.region}:${data.aws_caller_identity.current.account_id}:policy/*" }
      }
    }]
  })

  tags = merge(var.tags, {
    Environment = var.env
    Component   = "dlm-snapshots"
  })
}

resource "aws_iam_role_policy_attachment" "dlm_snapshots" {
  role = aws_iam_role.dlm.name

  # Politica CORRECTA para politicas de SNAPSHOT de volumenes
  # (resource_types = ["VOLUME"], EBS_SNAPSHOT_MANAGEMENT).
  # NO usar AWSDataLifecycleManagerServiceRoleForAMIManagement (es la de AMI).
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}
