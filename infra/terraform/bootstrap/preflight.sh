#!/usr/bin/env bash
# ==============================================================================
# Preflight de la HU 1 (Terraform) para CircleGuard.
#
#   ./infra/terraform/bootstrap/preflight.sh
#
# Comprueba, ANTES del primer plan/apply, que el repositorio y la cuenta AWS
# cumplen los supuestos del diseño: red existente, AMI fijada, key pairs,
# instancia DevOps + registro Nexus, cuota de vCPU, ausencia de colisiones de
# nombres e identidad/permisos del operador.
#
# SOLO LECTURA (restricción de la HU 1):
#   - AWS CLI: únicamente describe/list/get/sts/simulate.
#   - Local:  únicamente lectura de archivos y comprobaciones de existencia.
#   - NO ejecuta Terraform ni crea/modifica/elimina recursos.
#
# Códigos de salida: 0 = sin FAIL (se permiten WARN), 1 = hay al menos un FAIL.
# Estilo alineado con scripts/check-infrastructure.sh.
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SHARED_FILE="${TF_DIR}/shared/main.tf"
GITIGNORE_FILE="$(cd "${TF_DIR}/../.." && pwd)/.gitignore"

# --- Supuestos del diseño (deben coincidir con shared/main.tf y el diseño) ---
EXPECTED_ACCOUNT_ID="718875641310"
AWS_REGION="us-east-1"
EXPECTED_VPC_NAME="circleguard-vpc"
EXPECTED_VPC_CIDR="10.20.0.0/16"
EXPECTED_RT_NAME="circleguard-public-rt"
EXPECTED_SUBNETS="cg-dev-subnet cg-stage-subnet cg-prod-subnet cg-devops-subnet"
EXPECTED_KEY_PAIRS="cg-dev-key cg-stage-key cg-prod-key"
NEW_NODES=4                 # 1 dev + 1 stage + 2 prod
VCPUS_PER_NODE_DEFAULT=2    # m7i-flex.large = 2 vCPU

PASS_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0
pass() { echo "[PASS] $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
warn() { echo "[WARN] $*"; WARN_COUNT=$((WARN_COUNT + 1)); }
fail() { echo "[FAIL] $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
section() { echo; echo "--- $* ---"; }

tf_local() { # tf_local <nombre_de_variable>  -> lee 'nombre = "valor"' de shared/main.tf
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${SHARED_FILE}" | head -1
}

vcpu_of() { # vcpu_of <tipo> -> vCPUs del tipo (con fallback por quirk de la API)
    case "$1" in
        "") echo "${VCPUS_PER_NODE_DEFAULT}" ;;
        m7i-flex.large) echo 2 ;;  # describe-instance-types devuelve VcpuInfo nulo en flex
        *)
            local v
            v=$(aws ec2 describe-instance-types --instance-types "$1" \
                --query 'InstanceTypes[0].VcpuInfo.DefaultVCpus' --output text 2>/dev/null)
            if [[ "$v" =~ ^[0-9]+$ ]]; then echo "$v"; else echo ""; fi
            ;;
    esac
}

echo "========================================"
echo "  CIRCLEGUARD HU 1 · PREFLIGHT (SOLO LECTURA)"
echo "========================================"

# 1) Herramientas locales ------------------------------------------------------
section "Herramientas locales"
if command -v aws >/dev/null 2>&1; then
    pass "AWS CLI: $(aws --version 2>&1 | awk '{print $1, $2}')"
else
    fail "AWS CLI no está instalado (requerido para todas las comprobaciones)"
fi

if command -v terraform >/dev/null 2>&1; then
    TF_VERSION=$(terraform version 2>/dev/null | head -1 | sed 's/^Terraform v//')
    pass "Terraform instalado: v${TF_VERSION}"
else
    # No instala nada este script: la instalación requiere permisos del usuario.
    warn "Terraform no está instalado (requiere instalación manual)"
fi

if command -v curl >/dev/null 2>&1; then
    pass "curl disponible (comprobación del registro Nexus)"
else
    warn "curl no disponible: se omite la comprobación HTTP del registro"
fi

# 2) Constantes del repositorio ------------------------------------------------
section "Constantes en infra/terraform/shared/main.tf"
if [[ ! -f "${SHARED_FILE}" ]]; then
    fail "No existe ${SHARED_FILE} (bloque B1 incompleto)"
else
    AMI_ID=$(tf_local ami_id)
    AMI_NAME=$(tf_local ami_name)
    INSTANCE_TYPE=$(tf_local instance_type)
    K3S_VERSION=$(tf_local k3s_version)
    PARAM_NAME=$(tf_local token_parameter_name)
    for pair in "ami_id:${AMI_ID}" "ami_name:${AMI_NAME}" "instance_type:${INSTANCE_TYPE}" \
                "k3s_version:${K3S_VERSION}" "token_parameter_name:${PARAM_NAME}"; do
        name="${pair%%:*}"; value="${pair#*:}"
        if [[ -n "${value}" ]]; then
            pass "${name} = ${value}"
        else
            fail "${name} vacío o ilegible en shared/main.tf"
        fi
    done
fi

if [[ -f "${GITIGNORE_FILE}" ]] && grep -qE '^\*\.tfstate$' "${GITIGNORE_FILE}"; then
    pass ".gitignore contiene reglas de Terraform (*.tfstate)"
else
    warn ".gitignore sin reglas de Terraform (deben agregarse antes del primer plan)"
fi

# 3) Identidad de la cuenta ----------------------------------------------------
section "Identidad AWS"
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)
CALLER_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
if [[ -z "${CALLER_ACCOUNT}" ]]; then
    fail "No hay credenciales AWS válidas (sts get-caller-identity falló)"
elif [[ "${CALLER_ACCOUNT}" == "${EXPECTED_ACCOUNT_ID}" ]]; then
    pass "Cuenta ${CALLER_ACCOUNT} (esperada ${EXPECTED_ACCOUNT_ID})"
    echo "       identidad: ${CALLER_ARN}"
else
    fail "Cuenta ${CALLER_ACCOUNT} distinta de la esperada ${EXPECTED_ACCOUNT_ID}"
fi

# 4) AMI fijada ---------------------------------------------------------------
section "AMI fijada"
if [[ -n "${AMI_ID:-}" ]]; then
    IMG=$(aws ec2 describe-images --region "${AWS_REGION}" --image-ids "${AMI_ID}" \
        --query 'Images[0].[Name,State,Architecture,RootDeviceType]' --output text 2>/dev/null)
    if [[ -z "${IMG}" || "${IMG}" == "None" ]]; then
        fail "La AMI ${AMI_ID} no existe en ${AWS_REGION}"
    else
        IMG_NAME=$(echo "${IMG}" | cut -f1)
        IMG_STATE=$(echo "${IMG}" | cut -f2)
        IMG_ARCH=$(echo "${IMG}" | cut -f3)
        if [[ "${IMG_STATE}" == "available" && "${IMG_ARCH}" == "x86_64" ]]; then
            pass "AMI ${AMI_ID}: state=${IMG_STATE}, arch=${IMG_ARCH}"
        else
            fail "AMI ${AMI_ID}: state=${IMG_STATE}, arch=${IMG_ARCH}"
        fi
        if [[ "${IMG_NAME}" == "${AMI_NAME}" ]]; then
            pass "Nombre coincide con shared/main.tf"
        else
            warn "Nombre distinto del declarado: '${IMG_NAME}' vs '${AMI_NAME}'"
        fi
    fi
fi

# 5) Red existente (solo lectura: futuros data sources) ------------------------
section "Red existente (data sources previstos)"
VPC_ID=$(aws ec2 describe-vpcs --region "${AWS_REGION}" \
    --filters "Name=tag:Name,Values=${EXPECTED_VPC_NAME}" \
    --query 'Vpcs[0].[VpcId,CidrBlock]' --output text 2>/dev/null)
if [[ -n "${VPC_ID}" && "${VPC_ID}" != "None" ]]; then
    VPC_ID_ONLY=$(echo "${VPC_ID}" | cut -f1)
    VPC_CIDR=$(echo "${VPC_ID}" | cut -f2)
    if [[ "${VPC_CIDR}" == "${EXPECTED_VPC_CIDR}" ]]; then
        pass "VPC ${VPC_ID_ONLY} (${VPC_CIDR})"
    else
        warn "VPC ${VPC_ID_ONLY} con CIDR ${VPC_CIDR} (esperado ${EXPECTED_VPC_CIDR})"
    fi
else
    fail "No se encontró la VPC '${EXPECTED_VPC_NAME}' en ${AWS_REGION}"
    VPC_ID_ONLY=""
fi

if [[ -n "${VPC_ID_ONLY}" ]]; then
    SUBNET_IDS=$(aws ec2 describe-subnets --region "${AWS_REGION}" \
        --filters "Name=vpc-id,Values=${VPC_ID_ONLY}" \
        --query 'Subnets[].[SubnetId,CidrBlock,AvailabilityZone,MapPublicIpOnLaunch]' --output text 2>/dev/null)
    MISSING=0
    for name in ${EXPECTED_SUBNETS}; do
        if echo "${SUBNET_IDS}" | grep -q .; then
            ROW=$(aws ec2 describe-subnets --region "${AWS_REGION}" \
                --filters "Name=tag:Name,Values=${name}" \
                --query 'Subnets[0].[SubnetId,AvailabilityZone]' --output text 2>/dev/null)
            if [[ -n "${ROW}" && "${ROW}" != "None" ]]; then
                pass "Subred ${name}: $(echo "${ROW}" | cut -f1) ($(echo "${ROW}" | cut -f2))"
            else
                fail "Falta la subred '${name}'"
                MISSING=1
            fi
        fi
    done
    if [[ "${MISSING}" -eq 0 ]]; then
        AZS=$(echo "${SUBNET_IDS}" | cut -f3 | sort -u | tr '\n' ' ')
        warn "Todas las subredes usan: ${AZS}(limitación de una sola AZ en el diseño)"
    fi
fi

RT_ID=$(aws ec2 describe-route-tables --region "${AWS_REGION}" \
    --filters "Name=tag:Name,Values=${EXPECTED_RT_NAME}" \
    --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
if [[ -n "${RT_ID}" && "${RT_ID}" != "None" ]]; then
    IGW_RT=$(aws ec2 describe-route-tables --region "${AWS_REGION}" \
        --route-table-ids "${RT_ID}" \
        --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId' --output text 2>/dev/null)
    if [[ "${IGW_RT}" == igw-* ]]; then
        pass "Tabla de rutas ${RT_ID} con salida a ${IGW_RT}"
    else
        fail "La tabla ${RT_ID} no tiene ruta 0.0.0.0/0 hacia un Internet Gateway"
    fi
else
    fail "No se encontró la tabla de rutas '${EXPECTED_RT_NAME}'"
fi

if [[ -n "${VPC_ID_ONLY}" ]]; then
    IGW_ID=$(aws ec2 describe-internet-gateways --region "${AWS_REGION}" \
        --filters "Name=attachment.vpc-id,Values=${VPC_ID_ONLY}" \
        --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null)
    if [[ -n "${IGW_ID}" && "${IGW_ID}" != "None" ]]; then
        pass "Internet Gateway ${IGW_ID} adjunto a la VPC"
    else
        fail "La VPC no tiene Internet Gateway adjunto"
    fi
fi

# 6) Infraestructura DevOps y registro Nexus (no se modifica en la HU 1) -------
section "Infraestructura DevOps existente (solo lectura)"
DEVOPS=$(aws ec2 describe-instances --region "${AWS_REGION}" \
    --filters "Name=tag:Name,Values=cg-devops" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].[InstanceId,PublicIpAddress,PrivateIpAddress]' --output text 2>/dev/null)
if [[ -n "${DEVOPS}" && "${DEVOPS}" != "None" ]]; then
    DEVOPS_ID=$(echo "${DEVOPS}" | cut -f1)
    DEVOPS_PUB=$(echo "${DEVOPS}" | cut -f2)
    DEVOPS_PRIV=$(echo "${DEVOPS}" | cut -f3)
    pass "cg-devops ${DEVOPS_ID} en ejecución (${DEVOPS_PRIV} / ${DEVOPS_PUB})"
else
    fail "La instancia cg-devops no está en ejecución"
    DEVOPS_PUB=""
fi

SG_DEVOPS=$(aws ec2 describe-security-groups --region "${AWS_REGION}" \
    --filters "Name=group-name,Values=cg-devops-sg" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
if [[ -n "${SG_DEVOPS}" && "${SG_DEVOPS}" != "None" ]]; then
    pass "Security Group cg-devops-sg = ${SG_DEVOPS} (origen de las reglas SSH/kubectl de los nodos)"
else
    fail "No existe el Security Group cg-devops-sg"
fi

if [[ -n "${DEVOPS_PUB}" ]] && command -v curl >/dev/null 2>&1; then
    HTTP_CODE=$(curl -s -o /dev/null -m 6 -w '%{http_code}' "http://${DEVOPS_PUB}:8082/v2/" 2>/dev/null)
    case "${HTTP_CODE}" in
        200|401|403) pass "Registro Nexus responde en ${DEVOPS_PUB}:8082 (HTTP ${HTTP_CODE})" ;;
        *) warn "Registro Nexus no responde en ${DEVOPS_PUB}:8082 (HTTP ${HTTP_CODE:-000})" ;;
    esac
fi

OLD_RUNNING=$(aws ec2 describe-instances --region "${AWS_REGION}" \
    --filters "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | wc -w)
pass "${OLD_RUNNING} instancias en ejecución existentes (la HU 1 no las modifica ni las detiene)"

# 7) Key pairs reutilizados ----------------------------------------------------
section "Key pairs existentes (reutilizados por los nodos nuevos)"
for kp in ${EXPECTED_KEY_PAIRS}; do
    FOUND=$(aws ec2 describe-key-pairs --region "${AWS_REGION}" \
        --filters "Name=key-name,Values=${kp}" \
        --query 'KeyPairs[0].KeyName' --output text 2>/dev/null)
    if [[ -n "${FOUND}" && "${FOUND}" != "None" ]]; then
        pass "Key pair ${kp}"
    else
        fail "Falta el key pair '${kp}'"
    fi
done

# 8) Cuota de vCPU ------------------------------------------------------------
section "Cuota de vCPU (On-Demand Standard)"
QUOTA=$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
    --region "${AWS_REGION}" --query 'Quota.Value' --output text 2>/dev/null)
USED_VCPUS=0
INSTANCE_ROWS=$(aws ec2 describe-instances --region "${AWS_REGION}" \
    --filters "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].[InstanceId,InstanceType]' --output text 2>/dev/null)
if [[ -n "${INSTANCE_ROWS}" ]]; then
    while IFS=$'\t' read -r iid itype; do
        [[ -z "${iid}" ]] && continue
        v=$(vcpu_of "${itype}")
        if [[ -n "${v}" ]]; then
            USED_VCPUS=$((USED_VCPUS + v))
        else
            warn "No se pudo determinar vCPUs del tipo ${itype} (${iid})"
        fi
    done <<< "${INSTANCE_ROWS}"
fi

NODE_VCPUS=$(vcpu_of "${INSTANCE_TYPE:-}")
NODE_VCPUS="${NODE_VCPUS:-${VCPUS_PER_NODE_DEFAULT}}"
NEEDED=$((NEW_NODES * NODE_VCPUS))

if [[ -n "${QUOTA}" && "${QUOTA}" != "None" ]]; then
    QUOTA_INT=${QUOTA%.*}
    FREE=$((QUOTA_INT - USED_VCPUS))
    pass "Cuota=${QUOTA_INT} vCPU · en uso=${USED_VCPUS} · libres=${FREE} · necesarios=${NEEDED}"
    if [[ "${FREE}" -lt "${NEEDED}" ]]; then
        fail "Cuota insuficiente: faltan $((NEEDED - FREE)) vCPU (solicitar aumento antes del apply)"
    elif [[ "${FREE}" -eq "${NEEDED}" ]]; then
        warn "La cuota cubre lo necesario exactamente (sin margen tras el apply)"
    fi
else
    warn "No se pudo leer la cuota L-1216C47A (service-quotas)"
fi

# 9) Ausencia de colisiones (nombres que creará la HU 1) -----------------------
section "Ausencia de colisiones con recursos futuros de la HU 1"
COLL_INSTANCES=$(aws ec2 describe-instances --region "${AWS_REGION}" \
    --filters "Name=tag:Name,Values=cg-k3s-*" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | wc -w)
COLL_SGS=$(aws ec2 describe-security-groups --region "${AWS_REGION}" \
    --filters "Name=group-name,Values=cg-k3s-*" \
    --query 'SecurityGroups[].GroupId' --output text 2>/dev/null | wc -w)
COLL_ROLES=$(aws iam list-roles --query 'Roles[].RoleName' --output text 2>/dev/null \
    | tr '\t' '\n' | grep -cE '^(cg-k3s-|cg-dlm-)' || true)
COLL_PROFILES=$(aws iam list-instance-profiles --query 'InstanceProfiles[].InstanceProfileName' \
    --output text 2>/dev/null | tr '\t' '\n' | grep -cE '^cg-k3s-' || true)
COLL_DLM=$(aws dlm get-lifecycle-policies --region "${AWS_REGION}" \
    --query 'Policies[].PolicyId' --output text 2>/dev/null | wc -w)
COLL_PARAM=$(aws ssm describe-parameters --region "${AWS_REGION}" \
    --filters "Name=name,Values=${PARAM_NAME:-/circleguard/k3s/prod-join-token}" \
    --query 'Parameters[].Name' --output text 2>/dev/null | wc -w)

if [[ "${COLL_INSTANCES}" -eq 0 && "${COLL_SGS}" -eq 0 ]]; then
    pass "Sin instancias ni Security Groups con prefijo cg-k3s-*"
else
    warn "Ya existen recursos cg-k3s-* (instancias=${COLL_INSTANCES}, SGs=${COLL_SGS}): ¿re-ejecución?"
fi
if [[ "${COLL_ROLES}" -eq 0 && "${COLL_PROFILES}" -eq 0 ]]; then
    pass "Sin roles ni instance profiles cg-k3s-*/cg-dlm-*"
else
    warn "Ya existen roles/profiles de la HU 1 (roles=${COLL_ROLES}, profiles=${COLL_PROFILES})"
fi
if [[ "${COLL_DLM}" -eq 0 ]]; then
    pass "Sin políticas DLM en la región"
else
    warn "Ya existen ${COLL_DLM} políticas DLM"
fi
if [[ "${COLL_PARAM}" -eq 0 ]]; then
    pass "Sin parámetro ${PARAM_NAME:-/circleguard/k3s/prod-join-token} en Parameter Store"
else
    warn "El parámetro del token ya existe (posible rebuild o re-ejecución)"
fi

# 10) Permisos del operador (simulación, solo lectura) --------------------------
section "Permisos IAM del operador (simulate-principal-policy)"
CALLER_SOURCE_ARN="${CALLER_ARN}"
if [[ "${CALLER_ARN}" == *":assumed-role/"* ]]; then
    ROLE_NAME=$(echo "${CALLER_ARN}" | sed -E 's#.*:assumed-role/([^/]+)/.*#\1#')
    CALLER_SOURCE_ARN="arn:aws:iam::${EXPECTED_ACCOUNT_ID}:role/${ROLE_NAME}"
fi
SIMULATION=$(aws iam simulate-principal-policy \
    --policy-source-arn "${CALLER_SOURCE_ARN}" \
    --action-names ec2:CreateSecurityGroup ec2:AuthorizeSecurityGroupIngress \
        ec2:AuthorizeSecurityGroupEgress ec2:CreateVpcSecurityGroupIngressRule \
        ec2:CreateVpcSecurityGroupEgressRule ec2:RunInstances ec2:CreateTags \
        iam:PassRole dlm:CreateLifecyclePolicy \
    --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text 2>/dev/null)
if [[ -z "${SIMULATION}" ]]; then
    warn "Simulación no disponible para ${CALLER_SOURCE_ARN} (se omite esta comprobación)"
else
    DENIED=0
    while IFS=$'\t' read -r action decision; do
        [[ -z "${action}" ]] && continue
        if [[ "${decision}" == "allowed" ]]; then
            pass "${action} → allowed"
        else
            fail "${action} → ${decision}"
            DENIED=1
        fi
    done <<< "${SIMULATION}"
    [[ "${DENIED}" -eq 0 ]] || true
fi

# Resumen ---------------------------------------------------------------------
echo
echo "========================================"
echo "              RESUMEN"
echo "========================================"
echo "PASS: ${PASS_COUNT}   WARN: ${WARN_COUNT}   FAIL: ${FAIL_COUNT}"
echo "Región: ${AWS_REGION} · Cuenta: ${EXPECTED_ACCOUNT_ID}"
echo "Completado: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "========================================"
echo "Este script es de solo lectura: no modifica infraestructura."

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    exit 1
fi
exit 0
