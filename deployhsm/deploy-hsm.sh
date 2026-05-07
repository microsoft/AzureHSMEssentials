#!/usr/bin/env bash
#
# deploy-hsm.sh - Universal HSM Scenario Builder deployment script
#
# Deploys infrastructure for Azure Cloud HSM, Azure Key Vault,
# or Azure Managed HSM using the corresponding ARM template.
#
# Usage:
#   ./deploy-hsm.sh --platform azurecloudhsm --subscription-id <SUBSCRIPTION_ID>
#   ./deploy-hsm.sh --platform azurekeyvault --subscription-id <SUBSCRIPTION_ID>
#   ./deploy-hsm.sh --platform azuremanagedhsm --subscription-id <SUBSCRIPTION_ID> --location "East US"
#
set -euo pipefail

# ------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBSCRIPTION_ID=""
LOCATION=""
PLATFORM=""
PARAMETER_FILE=""
ADMIN_PASSWORD_OR_KEY=""
ADMIN_USERNAME=""
AUTH_TYPE=""
INITIAL_ADMIN_IDS=""
ENABLE_CERT_STORAGE=false

# ------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------
print_usage() {
    echo ""
    echo "Usage: $0 --platform <PLATFORM> --subscription-id <SUBSCRIPTION_ID> [OPTIONS]"
    echo ""
    echo "Required:"
    echo "  --platform, -t          HSM platform: azurecloudhsm, azuredededicatedhsm, azurekeyvault, azuremanagedhsm, azurepaymentshsm"
    echo "  --subscription-id, -s   Azure subscription ID to deploy into"
    echo ""
    echo "Optional:"
    echo "  --location, -l              Azure region override (default: from parameters file)"
    echo "  --parameter-file, -p        Path to ARM parameters file (default: auto-detected)"
    echo "  --admin-password-or-key     SSH public key or password for admin VM (if omitted, no VM deployed)"
    echo "  --admin-username            Admin username for the VM (default: azureuser)"
    echo "  --auth-type                 Authentication type: sshPublicKey or password (default: sshPublicKey)"
    echo "  --initial-admin-ids         Comma-separated Entra ID object IDs for Managed HSM initial admins"
    echo "  --enable-cert-storage       Deploy certificate object storage (Blob + Managed Identity + RBAC). Cloud HSM only."
    echo "  --help, -h                  Show this help message"
    echo ""
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform|-t)
            PLATFORM="$(echo "$2" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
        --subscription-id|-s)
            SUBSCRIPTION_ID="$2"; shift 2 ;;
        --location|-l)
            LOCATION="$2"; shift 2 ;;
        --parameter-file|-p)
            PARAMETER_FILE="$2"; shift 2 ;;
        --admin-password-or-key)
            ADMIN_PASSWORD_OR_KEY="$2"; shift 2 ;;
        --admin-username)
            ADMIN_USERNAME="$2"; shift 2 ;;
        --auth-type)
            AUTH_TYPE="$2"; shift 2 ;;
        --initial-admin-ids)
            INITIAL_ADMIN_IDS="$2"; shift 2 ;;
        --enable-cert-storage)
            ENABLE_CERT_STORAGE=true; shift ;;
        --help|-h)
            print_usage; exit 0 ;;
        *)
            echo "Unknown option: $1"; print_usage; exit 1 ;;
    esac
done

# ------------------------------------------------------------------
# Validate platform
# ------------------------------------------------------------------
case "${PLATFORM}" in
    azurecloudhsm)
        DISPLAY_NAME="Azure Cloud HSM"
        DEPLOY_PREFIX="chsm"
        PLATFORM_DIR="${SCRIPT_DIR}/azurecloudhsm"
        TEMPLATE_NAME="cloudhsm-deploy.json"
        PARAMS_NAME="cloudhsm-parameters.json"
        ;;
    azuredededicatedhsm)
        DISPLAY_NAME="Azure Dedicated HSM"
        DEPLOY_PREFIX="dhsm"
        PLATFORM_DIR="${SCRIPT_DIR}/azuredededicatedhsm"
        TEMPLATE_NAME="dedicatedhsm-deploy.json"
        PARAMS_NAME="dedicatedhsm-parameters.json"
        ;;
    azurekeyvault)
        DISPLAY_NAME="Azure Key Vault"
        DEPLOY_PREFIX="akv"
        PLATFORM_DIR="${SCRIPT_DIR}/azurekeyvault"
        TEMPLATE_NAME="keyvault-deploy.json"
        PARAMS_NAME="keyvault-parameters.json"
        ;;
    azuremanagedhsm)
        DISPLAY_NAME="Azure Managed HSM"
        DEPLOY_PREFIX="mhsm"
        PLATFORM_DIR="${SCRIPT_DIR}/azuremanagedhsm"
        TEMPLATE_NAME="managedhsm-deploy.json"
        PARAMS_NAME="managedhsm-parameters.json"
        ;;
    azurepaymentshsm)
        DISPLAY_NAME="Azure Payment HSM"
        DEPLOY_PREFIX="phsm"
        PLATFORM_DIR="${SCRIPT_DIR}/azurepaymentshsm"
        TEMPLATE_NAME="paymentshsm-deploy.json"
        PARAMS_NAME="paymentshsm-parameters.json"
        ;;
    *)
        echo "Error: --platform is required. Valid values: azurecloudhsm, azuredededicatedhsm, azurekeyvault, azuremanagedhsm, azurepaymentshsm"
        print_usage
        exit 1
        ;;
esac

TEMPLATE_FILE="${PLATFORM_DIR}/${TEMPLATE_NAME}"

if [[ -z "${PARAMETER_FILE}" ]]; then
    PARAMETER_FILE="${PLATFORM_DIR}/${PARAMS_NAME}"
fi

# ------------------------------------------------------------------
# Validate inputs
# ------------------------------------------------------------------
if [[ -z "${SUBSCRIPTION_ID}" ]]; then
    echo "Error: --subscription-id is required."
    print_usage
    exit 1
fi

if [[ ! -d "${PLATFORM_DIR}" ]]; then
    echo "Error: Platform folder not found: ${PLATFORM_DIR}"
    exit 1
fi

if [[ ! -f "${TEMPLATE_FILE}" ]]; then
    echo "Error: ARM template not found: ${TEMPLATE_FILE}"
    exit 1
fi

if [[ ! -f "${PARAMETER_FILE}" ]]; then
    echo "Error: Parameters file not found: ${PARAMETER_FILE}"
    exit 1
fi

# Read location from parameters file if not overridden
if [[ -z "${LOCATION}" ]]; then
    LOCATION=$(python3 -c "
import json, sys
with open('${PARAMETER_FILE}') as f:
    params = json.load(f)
print(params['parameters']['location']['value'])
" 2>/dev/null || echo "")

    if [[ -z "${LOCATION}" ]]; then
        # Fallback: try jq
        LOCATION=$(jq -r '.parameters.location.value' "${PARAMETER_FILE}" 2>/dev/null || echo "")
    fi

    if [[ -z "${LOCATION}" ]]; then
        echo "Error: Could not read location from ${PARAMETER_FILE}. Provide --location."
        exit 1
    fi
fi

# Check Azure CLI is installed
if ! command -v az &> /dev/null; then
    echo "Error: Azure CLI (az) is not installed."
    echo "Install: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi

# ------------------------------------------------------------------
# Deploy
# ------------------------------------------------------------------
DEPLOYMENT_NAME="${DEPLOY_PREFIX}-deploy-$(date +%Y%m%d-%H%M%S)"

echo ""
echo "================================================"
echo "  HSM Scenario Builder - ${DISPLAY_NAME} Deployment"
echo "================================================"
echo ""
echo "  Platform     : ${DISPLAY_NAME}"
echo "  Subscription : ${SUBSCRIPTION_ID}"
echo "  Location     : ${LOCATION}"
echo "  Template     : ${TEMPLATE_FILE}"
echo "  Parameters   : ${PARAMETER_FILE}"
echo "  Deployment   : ${DEPLOYMENT_NAME}"
if [[ -n "${ADMIN_PASSWORD_OR_KEY}" ]]; then
    echo "  Admin VM     : Enabled (credential provided)"
else
    echo "  Admin VM     : Skipped (no --admin-password-or-key)"
fi
if [[ "${ENABLE_CERT_STORAGE}" == true ]]; then
    echo "  Cert Storage : Enabled (Blob + Managed Identity + RBAC)"
else
    echo "  Cert Storage : Skipped (no --enable-cert-storage)"
fi
echo ""

# ------------------------------------------------------------------
# Step tracking
# ------------------------------------------------------------------
TOTAL_STEPS=2
CURRENT_STEP=0

# ------------------------------------------------------------------
# Step 1: Authenticate and set subscription
# ------------------------------------------------------------------
CURRENT_STEP=$((CURRENT_STEP + 1))
echo "Step ${CURRENT_STEP}/${TOTAL_STEPS}: Authenticating and setting subscription context..."
echo ""

if ! az account show &> /dev/null; then
    echo "  Not logged in. Launching az login..."
    az login
fi

az account set --subscription "${SUBSCRIPTION_ID}"
echo "  Active subscription: $(az account show --query name -o tsv) (${SUBSCRIPTION_ID})"
echo "  Step ${CURRENT_STEP}/${TOTAL_STEPS} complete."

# ------------------------------------------------------------------
# Step 2: Deploy infrastructure (ARM template)
# ------------------------------------------------------------------
CURRENT_STEP=$((CURRENT_STEP + 1))
echo ""
echo "Step ${CURRENT_STEP}/${TOTAL_STEPS}: Deploying ${DISPLAY_NAME} infrastructure..."
echo "  Deployment: ${DEPLOYMENT_NAME}"
echo "  This may take 10-20 minutes..."
echo ""

# Build the base deployment command
DEPLOY_CMD=(az deployment sub create \
    --name "${DEPLOYMENT_NAME}" \
    --location "${LOCATION}" \
    --template-file "${TEMPLATE_FILE}" \
    --parameters "${PARAMETER_FILE}")

# Add VM authentication parameters when provided
if [[ -n "${ADMIN_PASSWORD_OR_KEY}" ]]; then
    DEPLOY_CMD+=(--parameters "adminPasswordOrKey=${ADMIN_PASSWORD_OR_KEY}")
    if [[ -n "${ADMIN_USERNAME}" ]]; then
        DEPLOY_CMD+=(--parameters "adminUsername=${ADMIN_USERNAME}")
    fi
    if [[ -n "${AUTH_TYPE}" ]]; then
        DEPLOY_CMD+=(--parameters "authenticationType=${AUTH_TYPE}")
    fi
fi

# Add Managed HSM initial admin object IDs when provided
if [[ "${PLATFORM}" == "azuremanagedhsm" && -n "${INITIAL_ADMIN_IDS}" ]]; then
    # Convert comma-separated string to JSON array for ARM
    IDS_JSON=$(echo "${INITIAL_ADMIN_IDS}" | python3 -c "
import sys, json
ids = [x.strip() for x in sys.stdin.read().strip().split(',') if x.strip()]
print(json.dumps(ids))
" 2>/dev/null || echo "")
    if [[ -n "${IDS_JSON}" && "${IDS_JSON}" != "[]" ]]; then
        DEPLOY_CMD+=(--parameters "initialAdminObjectIds=${IDS_JSON}")
    fi
fi

# Add certificate storage flag when enabled (Cloud HSM only)
if [[ "${ENABLE_CERT_STORAGE}" == true ]]; then
    if [[ "${PLATFORM}" != "azurecloudhsm" ]]; then
        echo "  WARNING: --enable-cert-storage is only supported for azurecloudhsm. Ignoring."
    else
        DEPLOY_CMD+=(--parameters enableCertificateStorage=true)
    fi
fi

DEPLOY_CMD+=(--output table)

if "${DEPLOY_CMD[@]}"; then

    echo ""
    echo "================================================"
    echo "  Deployment Succeeded - ${DISPLAY_NAME}"
    echo "================================================"
    echo ""

    # Print outputs
    echo "Deployment outputs:"
    az deployment sub show \
        --name "${DEPLOYMENT_NAME}" \
        --query "properties.outputs" \
        --output table 2>/dev/null || true

    # Display diagnostic logging info
    SA_NAME=$(az deployment sub show --name "${DEPLOYMENT_NAME}" --query "properties.outputs.storageAccountName.value" -o tsv 2>/dev/null || echo "")
    LA_NAME=$(az deployment sub show --name "${DEPLOYMENT_NAME}" --query "properties.outputs.logAnalyticsWorkspaceName.value" -o tsv 2>/dev/null || echo "")
    if [[ -n "${SA_NAME}" || -n "${LA_NAME}" ]]; then
        echo ""
        echo "  Diagnostic Logging:"
        [[ -n "${SA_NAME}" ]] && echo "    Storage Account    : ${SA_NAME}"
        [[ -n "${LA_NAME}" ]] && echo "    Log Analytics      : ${LA_NAME}"
    fi

    # Display certificate object storage info (if enabled)
    CERT_URL=$(az deployment sub show --name "${DEPLOYMENT_NAME}" --query "properties.outputs.certContainerUrl.value" -o tsv 2>/dev/null || echo "")
    CERT_CLIENT_ID=$(az deployment sub show --name "${DEPLOYMENT_NAME}" --query "properties.outputs.certManagedIdentityClientId.value" -o tsv 2>/dev/null || echo "")
    CERT_SA=$(az deployment sub show --name "${DEPLOYMENT_NAME}" --query "properties.outputs.certStorageAccountName.value" -o tsv 2>/dev/null || echo "")
    CERT_ID_NAME=$(az deployment sub show --name "${DEPLOYMENT_NAME}" --query "properties.outputs.certManagedIdentityName.value" -o tsv 2>/dev/null || echo "")
    if [[ -n "${CERT_URL}" || -n "${CERT_CLIENT_ID}" ]]; then
        echo ""
        echo "  Certificate Object Storage:"
        [[ -n "${CERT_SA}" ]]        && echo "    Storage Account    : ${CERT_SA}"
        [[ -n "${CERT_URL}" ]]       && echo "    Container URL      : ${CERT_URL}"
        [[ -n "${CERT_ID_NAME}" ]]   && echo "    Managed Identity   : ${CERT_ID_NAME}"
        [[ -n "${CERT_CLIENT_ID}" ]] && echo "    MI Client ID       : ${CERT_CLIENT_ID}"
        echo ""
        echo "  Update azcloudhsm_application.cfg on the Admin VM with the Container URL"
        echo "  and Managed Identity Client ID listed above to enable PKCS#11 certificate"
        echo "  object storage."
    fi

    echo ""
    echo "Deployment complete. Your ${DISPLAY_NAME} environment is ready for testing."
    echo "See the platform README under deployhsm/ for post-deployment steps."
    echo ""
    echo "  Step ${CURRENT_STEP}/${TOTAL_STEPS} complete."
else
    echo ""
    echo "================================================"
    echo "  Deployment Failed - ${DISPLAY_NAME}"
    echo "================================================"
    echo ""
    echo "Check the deployment in the Azure Portal:"
    echo "  Subscriptions > ${SUBSCRIPTION_ID} > Deployments > ${DEPLOYMENT_NAME}"
    exit 1
fi
