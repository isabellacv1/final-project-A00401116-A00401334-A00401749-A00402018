#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/infrastructure.env"

# Load local configuration
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[ERROR] Configuration file not found: $CONFIG_FILE"
    echo "Copy infrastructure.env.example to infrastructure.env and configure it."
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Validate dependencies
for command in aws curl; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "[ERROR] Required command not found: $command"
        exit 1
    fi
done

# Validate required configuration
REQUIRED_VARS=(
    AWS_REGION
    EC2_DEVOPS
    EC2_SONARQUBE
    EC2_DEV
    EC2_STAGE
    EC2_PROD
    JENKINS_URL
    NEXUS_URL
    SONARQUBE_URL
)

for variable in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!variable:-}" ]]; then
        echo "[ERROR] Missing configuration: $variable"
        exit 1
    fi
done

FAILED_CHECKS=0

print_header() {
    echo
    echo "========================================"
    echo "       CIRCLEGUARD INFRASTRUCTURE"
    echo "========================================"
    echo
}

check_instance() {
    local name="$1"
    local instance_id="$2"
    local state
    local system_status="N/A"
    local instance_status="N/A"

    echo -n "[EC2] $name ($instance_id): "

    state=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null) || {
            echo "ERROR - Unable to retrieve instance"
            ((FAILED_CHECKS++))
            return
        }

    if [[ -z "$state" || "$state" == "None" ]]; then
        echo "NOT FOUND"
        ((FAILED_CHECKS++))
        return
    fi

    if [[ "$state" != "running" ]]; then
        echo "$state"
        ((FAILED_CHECKS++))
        return
    fi

    local status
    status=$(aws ec2 describe-instance-status \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id" \
        --query 'InstanceStatuses[0].[SystemStatus.Status,InstanceStatus.Status]' \
        --output text 2>/dev/null) || status=""

    if [[ -n "$status" && "$status" != "None	None" ]]; then
        read -r system_status instance_status <<< "$status"
    fi

    if [[ "$system_status" == "ok" && "$instance_status" == "ok" ]]; then
        echo "RUNNING | System: OK | Instance: OK"
    else
        echo "RUNNING | System: ${system_status} | Instance: ${instance_status}"
        ((FAILED_CHECKS++))
    fi
}

check_service() {
    local name="$1"
    local url="$2"
    local response

    echo -n "[SERVICE] $name: "

    response=$(curl -L -sS -o /dev/null \
        --max-time 10 \
        -w "%{http_code}" \
        "$url" 2>/dev/null) || response="000"

    if [[ "$response" =~ ^2[0-9][0-9]$ ]]; then
        echo "AVAILABLE (HTTP $response)"
    else
        echo "UNAVAILABLE (HTTP $response)"
        ((FAILED_CHECKS++))
    fi
}

check_sonarqube() {
    local response

    echo -n "[SERVICE] SonarQube: "

    response=$(curl -L -fsS --max-time 10 "$SONARQUBE_URL" 2>/dev/null) || {
        echo "UNAVAILABLE"
        ((FAILED_CHECKS++))
        return
    }

    if grep -Eq '"status"[[:space:]]*:[[:space:]]*"UP"' <<< "$response"; then
        echo "AVAILABLE (UP)"
    else
        echo "NOT READY (API did not report UP)"
        ((FAILED_CHECKS++))
    fi
}

print_header

echo "AWS ACCOUNT"
if aws sts get-caller-identity --query 'Account' --output text --region "$AWS_REGION" >/dev/null 2>&1; then
    ACCOUNT_ID=$(aws sts get-caller-identity \
        --query 'Account' --output text --region "$AWS_REGION")
    echo "Authenticated account: $ACCOUNT_ID"
else
    echo "[ERROR] AWS authentication failed. Check your AWS credentials."
    exit 1
fi

echo
echo "EC2 INSTANCES"
check_instance "cg-devops" "$EC2_DEVOPS"
check_instance "cg-sonarqube" "$EC2_SONARQUBE"
check_instance "cg-dev" "$EC2_DEV"
check_instance "cg-stage" "$EC2_STAGE"
check_instance "cg-prod" "$EC2_PROD"

echo
echo "APPLICATION SERVICES"
check_service "Jenkins" "$JENKINS_URL"
check_service "Nexus" "$NEXUS_URL"
check_sonarqube

echo
echo "========================================"
echo "             SUMMARY"
echo "========================================"

if [[ "$FAILED_CHECKS" -eq 0 ]]; then
    echo "All validations passed."
else
    echo "$FAILED_CHECKS validation(s) reported an issue."
fi

echo "Completed at: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "========================================"

# A failed check reports a non-zero exit code.
# The script never modifies infrastructure.
if [[ "$FAILED_CHECKS" -gt 0 ]]; then
    exit 1
fi

exit 0
