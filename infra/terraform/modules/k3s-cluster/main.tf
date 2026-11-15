# =============================================================================
# Módulo: k3s-cluster (HU 1)
#
# Crea las CUATRO instancias EC2 de los tres clústeres k3s independientes
# (decisión aprobada) y su bootstrap mediante cloud-init:
#   dev    -> 1 server     stage -> 1 server     prod -> 1 server + 1 agent
#
# Conserva: m7i-flex.large (decisión establecida), AMI/versión/usuario de
# shared, subnets y VPC existentes (B2, solo lectura), Security Groups de B3,
# instance profiles de B3, key pairs existentes por ambiente, IMDSv2, sin EIP,
# monitoring=false, sin tocar ni reemplazar las instancias existentes.
#
# EBS: por nodo solo el volumen RAÍZ (decisión aprobada), gp3 CIFRADO,
# DEV/STAGE 40 GB y PROD 50 GB según var.root_volume_size, con
# delete_on_termination=true y los tags que selecciona modules/storage (DLM).
#
# Bootstrap (templates/*.tftpl): instala la versión de k3s FIJADA (sin latest)
# y, en PROD, publica/lee el token de unión en Parameter Store sin exponerlo:
# el valor nunca aparece en user_data, variables, outputs, estado de Terraform,
# argumentos de procesos ni logs (ver tratamiento en las plantillas).
# AWS CLI v2 solo se instala/descarga donde Parameter Store es necesario.
# =============================================================================

locals {
  server_name = "${var.name_prefix}-${var.env}-server"
  agent_name  = "${var.name_prefix}-${var.env}-agent"

  # Tags del volumen raíz: deben CONTENER el target_tags de modules/storage
  # (Project, Environment, DailySnapshot) para que DLM lo seleccione.
  # "Project" se garantiza aunque var.tags no lo traiga (corrección revisión B4).
  root_volume_tags = merge(var.tags, {
    Project       = lookup(var.tags, "Project", "circleguard")
    Environment   = var.env
    DailySnapshot = "true"
  })

  # Campos de plantilla comunes a server y agent (sin secretos).
  template_common = {
    env                  = var.env
    region               = var.region
    k3s_version          = var.k3s_version
    registry_endpoint    = var.registry_endpoint
    registry_scheme      = var.registry_scheme
    # Vacío fuera de prod: el server omite la publicación del token y, con él,
    # cualquier interacción (o instalación) de AWS CLI en dev/stage.
    token_parameter_name = var.token_parameter_name == null ? "" : var.token_parameter_name
    awscli_version       = var.awscli_version
    awscli_sha256        = var.awscli_sha256
  }
}

resource "aws_instance" "server" {
  ami           = var.ami_id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id

  vpc_security_group_ids = [var.server_sg_id]
  key_name               = var.key_name

  # El proveedor AWS declara este argumento como "Specified as the name of the
  # Instance Profile" (string), no como bloque.
  iam_instance_profile = var.server_profile_name

  # IP pública explícita: obligatorio porque cg-stage-subnet tiene
  # MapPublicIpOnLaunch=false (verificado en B2). Solo para salida y entrada
  # aprobada; la exposición la gobiernan los Security Groups de B3.
  associate_public_ip_address = true
  monitoring                  = false # sin detailed monitoring (decisión aprobada)

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 obligatorio, consistente con lo existente
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true # EBS gp3 cifrado (aprobado; la cuenta no tiene cifrado por defecto)
    delete_on_termination = true
    tags                  = merge(local.root_volume_tags, { Name = "${local.server_name}-root" })
  }

  user_data = templatefile("${path.module}/templates/server-cloud-init.yaml.tftpl", merge(local.template_common, {
    node_name = local.server_name
  }))

  tags = merge(var.tags, {
    Name        = local.server_name
    Environment = var.env
    Role        = "k3s-server"
  })

  # Sin user_data_replace_on_change: un cambio de plantilla no recrea el nodo
  # por defecto; la reconstrucción del bootstrap es explícita (documentado).
}

resource "aws_instance" "agent" {
  count = var.agent_count # 0 en dev/stage; 1 en prod

  ami           = var.ami_id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id

  vpc_security_group_ids = [var.agent_sg_id]
  key_name               = var.key_name

  # Verificado: el argumento admite el nombre del instance profile como string.
  iam_instance_profile = var.agent_profile_name

  associate_public_ip_address = true
  monitoring                  = false

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true
    tags                  = merge(local.root_volume_tags, { Name = "${local.agent_name}-root" })
  }

  # Referencia al server: crea la dependencia implícita de Terraform (el
  # server arranca primero) y entrega la IP privada del API al agent.
  user_data = templatefile("${path.module}/templates/agent-cloud-init.yaml.tftpl", merge(local.template_common, {
    node_name         = local.agent_name
    server_private_ip = aws_instance.server.private_ip
  }))

  tags = merge(var.tags, {
    Name        = local.agent_name
    Environment = var.env
    Role        = "k3s-agent"
  })

  lifecycle {
    precondition {
      condition     = var.token_parameter_name != null && var.agent_sg_id != null && var.agent_profile_name != null
      error_message = "el agente PROD requiere token_parameter_name (shared), agent_sg_id (security) y agent_profile_name (iam): revisa el cableado del ambiente en B5."
    }
  }
}
