#!/usr/bin/env bash
#
# uninstall-hsm.sh - Universal HSM Scenario Builder resource removal script
#
# Removes all resource groups created by the HSM Scenario Builder deployment
# for the selected platform.
#
# Usage:
#   ./uninstall-hsm.sh --platform azurecloudhsm --subscription-id <SUBSCRIPTION_ID>
#   ./uninstall-hsm.sh --platform azurekeyvault --subscription-id <SUBSCRIPTION_ID> --yes
#   ./uninstall-hsm.sh --platform azuremanagedhsm --subscription-id <SUBSCRIPTION_ID>
#
set -euo pipefail

# ------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../deployhsm" && pwd)"
SUBSCRIPTION_ID=""
PLATFORM=""
PARAMETER_FILE=""
SKIP_CONFIRM=false
VERBOSE=false

# ------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------
print_usage() {
    echo ""
    echo "Usage: $0 --platform <PLATFORM> --subscription-id <SUBSCRIPTION_ID> [OPTIONS]"
    echo ""
    echo "Required:"
    echo "  --platform, -t          HSM platform: azurecloudhsm, azuredededicatedhsm, azurekeyvault, azuremanagedhsm, azurepaymentshsm"
    echo "  --subscription-id, -s   Azure subscription ID"
    echo ""
    echo "Optional:"
    echo "  --parameter-file, -p    Path to ARM parameters file (reads RG names)"
    echo "  --yes, -y               Skip confirmation prompt"
    echo "  --verbose, -v           Show full error details for debugging"
    echo "  --help, -h              Show this help message"
    echo ""
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform|-t)
            PLATFORM="$(echo "$2" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
        --subscription-id|-s)
            SUBSCRIPTION_ID="$2"; shift 2 ;;
        --parameter-file|-p)
            PARAMETER_FILE="$2"; shift 2 ;;
        --yes|-y)
            SKIP_CONFIRM=true; shift ;;
        --verbose|-v)
            VERBOSE=true; shift ;;
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
        PLATFORM_DIR="${DEPLOY_DIR}/azurecloudhsm"
        PARAMS_NAME="cloudhsm-parameters.json"
        DEFAULT_RGS=("CHSM-HSB-ADMINVM-RG" "CHSM-HSB-CLIENT-RG" "CHSM-HSB-HSM-RG" "CHSM-HSB-LOGS-RG" "CHSM-HSB-CERT-RG")
        ;;
    azuredededicatedhsm)
        DISPLAY_NAME="Azure Dedicated HSM"
        PLATFORM_DIR="${DEPLOY_DIR}/azuredededicatedhsm"
        PARAMS_NAME="dedicatedhsm-parameters.json"
        DEFAULT_RGS=("DHSM-HSB-ADMINVM-RG" "DHSM-HSB-CLIENT-RG" "DHSM-HSB-HSM-RG")
        ;;
    azurekeyvault)
        DISPLAY_NAME="Azure Key Vault"
        PLATFORM_DIR="${DEPLOY_DIR}/azurekeyvault"
        PARAMS_NAME="keyvault-parameters.json"
        DEFAULT_RGS=("AKV-HSB-ADMINVM-RG" "AKV-HSB-CLIENT-RG" "AKV-HSB-HSM-RG" "AKV-HSB-LOGS-RG")
        ;;
    azuremanagedhsm)
        DISPLAY_NAME="Azure Managed HSM"
        PLATFORM_DIR="${DEPLOY_DIR}/azuremanagedhsm"
        PARAMS_NAME="managedhsm-parameters.json"
        DEFAULT_RGS=("MHSM-HSB-ADMINVM-RG" "MHSM-HSB-CLIENT-RG" "MHSM-HSB-HSM-RG" "MHSM-HSB-LOGS-RG")
        ;;
    azurepaymentshsm)
        DISPLAY_NAME="Azure Payment HSM"
        PLATFORM_DIR="${DEPLOY_DIR}/azurepaymentshsm"
        PARAMS_NAME="paymentshsm-parameters.json"
        DEFAULT_RGS=("PHSM-HSB-ADMINVM-RG" "PHSM-HSB-CLIENT-RG" "PHSM-HSB-HSM-RG")
        ;;
    *)
        echo "Error: --platform is required. Valid values: azurecloudhsm, azuredededicatedhsm, azurekeyvault, azuremanagedhsm, azurepaymentshsm"
        print_usage
        exit 1
        ;;
esac

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

if ! command -v az &> /dev/null; then
    echo "Error: Azure CLI (az) is not installed."
    echo "Install: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi

# ------------------------------------------------------------------
# Read resource group names from parameters file
# ------------------------------------------------------------------
RESOURCE_GROUPS=()

if [[ -f "${PARAMETER_FILE}" ]]; then
    # Helper to read a parameter value using python3 or jq
    read_param() {
        local param_name="$1"
        python3 -c "
import json
with open('${PARAMETER_FILE}') as f:
    p = json.load(f)
v = p.get('parameters', {}).get('${param_name}', {}).get('value', '')
if v: print(v)
" 2>/dev/null || jq -r ".parameters.${param_name}.value // empty" "${PARAMETER_FILE}" 2>/dev/null || echo ""
    }

    # Try standard parameter names.
    # Admin VM RG first: its NIC references the client VNet subnet (cross-RG dependency).
    # Logs RG last: preserves diagnostic data longest.
    for param in adminVmResourceGroupName clientResourceGroupName serverResourceGroupName resourceGroupName logsResourceGroupName certResourceGroupName; do
        val=$(read_param "${param}")
        if [[ -n "${val}" ]]; then
            RESOURCE_GROUPS+=("${val}")
        fi
    done

    if [[ ${#RESOURCE_GROUPS[@]} -gt 0 ]]; then
        echo "Read resource group names from: ${PARAMETER_FILE}"
    fi
else
    echo "Warning: Parameters file not found: ${PARAMETER_FILE}"
fi

# Fallback to defaults if nothing was read
if [[ ${#RESOURCE_GROUPS[@]} -eq 0 ]]; then
    RESOURCE_GROUPS=("${DEFAULT_RGS[@]}")
    echo "Using default resource group names for ${DISPLAY_NAME}."
fi

# ------------------------------------------------------------------
# Display plan and confirm
# ------------------------------------------------------------------
echo ""
echo "================================================"
echo "  HSM Scenario Builder - ${DISPLAY_NAME} Removal"
echo "================================================"
echo ""
echo "  Platform     : ${DISPLAY_NAME}"
echo "  Subscription : ${SUBSCRIPTION_ID}"
echo ""
echo "  The following resource groups will be PERMANENTLY DELETED:"
echo ""

INDEX=1
for rg in "${RESOURCE_GROUPS[@]}"; do
    echo "    ${INDEX}. ${rg}"
    INDEX=$((INDEX + 1))
done

echo ""
echo "  This action CANNOT be undone."
echo ""

if [[ "${SKIP_CONFIRM}" != true ]]; then
    read -rp "Type 'DELETE' to confirm and proceed: " CONFIRM
    if [[ "${CONFIRM}" != "DELETE" ]]; then
        echo "Aborted. No resources were deleted."
        exit 0
    fi
    echo ""
fi

# ------------------------------------------------------------------
# Login and set subscription
# ------------------------------------------------------------------
echo "Checking Azure CLI login..."
if ! az account show &> /dev/null; then
    echo "Not logged in. Launching az login..."
    az login
fi

echo "Setting subscription..."
az account set --subscription "${SUBSCRIPTION_ID}"
echo "Active subscription: $(az account show --query name -o tsv) (${SUBSCRIPTION_ID})"
echo ""

# ------------------------------------------------------------------
# Delete resource groups
# ------------------------------------------------------------------
TOTAL=${#RESOURCE_GROUPS[@]}
STEP=1

for rg in "${RESOURCE_GROUPS[@]}"; do
    echo "[Step ${STEP}/${TOTAL}] Deleting resource group: ${rg}"

    if az group show --name "${rg}" &> /dev/null; then
        echo "  Removing ${rg} (this may take several minutes)..."
        DELETE_OUTPUT=$(az group delete --name "${rg}" --yes 2>&1)
        DELETE_RC=$?
        if [[ ${DELETE_RC} -eq 0 ]]; then
            echo "  ${rg} deleted."
        elif echo "${DELETE_OUTPUT}" | grep -qi 'unauthorized\|401'; then
            echo "  az group delete : Operation returned an invalid status code 'Unauthorized'"
            echo "  StatusCode: 401"
            echo "  ReasonPhrase: 401 Unauthorized - Azure session token expired. Re-run to retry."
        elif echo "${DELETE_OUTPUT}" | grep -qi 'conflict\|409'; then
            echo "  az group delete : Operation returned status code 'Conflict'"
            echo "  StatusCode: 409"
            echo "  ReasonPhrase: 409 Conflict - a resource in another group still references this group. Re-run to retry."
        else
            echo "  az group delete failed: ${DELETE_OUTPUT}"
            echo "  Re-run to retry."
        fi
        if [[ "${VERBOSE}" == true ]]; then
            echo ""
            echo "  --- Verbose Error Detail ---"
            echo "  Exit Code : ${DELETE_RC}"
            echo "  Output    :"
            echo "${DELETE_OUTPUT}" | sed 's/^/    /'
            echo "  --- End Verbose Detail ---"
        fi
    else
        echo "  ${rg} not found - skipping."
    fi

    if [[ ${STEP} -lt ${TOTAL} ]]; then echo ""; fi
    STEP=$((STEP + 1))
done

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
echo ""
echo "================================================"
echo "  All ${DISPLAY_NAME} resources have been removed."
echo "================================================"
echo ""
echo "If you deployed any additional resources in separate resource groups,"
echo "delete those manually:"
echo ""
echo "  az group delete --name '<resource-group-name>' --yes"
echo ""
