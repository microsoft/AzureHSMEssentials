#!/usr/bin/env bash
# =============================================================================
# activate-mhsm.sh
# =============================================================================
# Activates an Azure Managed HSM by generating RSA Security Officer key pairs
# and downloading the security domain. Must be run from the admin VM (which has
# private endpoint access to the Managed HSM).
#
# Usage:
#   ./activate-mhsm.sh --hsm-name <MHSM_NAME> [--quorum <N>] [--key-count <N>] [--output-dir <DIR>]
#
# Examples:
#   ./activate-mhsm.sh --hsm-name mhsm-abc123def
#   ./activate-mhsm.sh --hsm-name mhsm-abc123def --quorum 3 --key-count 5
#   ./activate-mhsm.sh --hsm-name mhsm-abc123def --output-dir /secure/mhsm-certs
# =============================================================================

set -euo pipefail

# ------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------
HSM_NAME=""
QUORUM=2
KEY_COUNT=3
OUTPUT_DIR=""

# ------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------
print_usage() {
    echo "Usage: $0 --hsm-name <MHSM_NAME> [options]"
    echo ""
    echo "Required:"
    echo "  --hsm-name, -n        Name of the Azure Managed HSM to activate"
    echo ""
    echo "Optional:"
    echo "  --quorum, -q          Minimum keys needed to recover security domain (default: 2)"
    echo "  --key-count, -k       Number of RSA key pairs to generate (default: 3, min: 3)"
    echo "  --output-dir, -o      Directory to store certs and security domain (default: ~/mhsm-security-domain/<hsm-name>)"
    echo "  --help, -h            Show this help message"
}

# ------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hsm-name|-n)    HSM_NAME="$2"; shift 2 ;;
        --quorum|-q)      QUORUM="$2"; shift 2 ;;
        --key-count|-k)   KEY_COUNT="$2"; shift 2 ;;
        --output-dir|-o)  OUTPUT_DIR="$2"; shift 2 ;;
        --help|-h)        print_usage; exit 0 ;;
        *) echo "Unknown option: $1"; print_usage; exit 1 ;;
    esac
done

# ------------------------------------------------------------------
# Validate
# ------------------------------------------------------------------
if [[ -z "${HSM_NAME}" ]]; then
    echo "Error: --hsm-name is required."
    echo ""
    print_usage
    exit 1
fi

if [[ "${KEY_COUNT}" -lt 3 ]]; then
    echo "Error: --key-count must be at least 3 (Azure requires minimum 3 Security Officer keys)."
    exit 1
fi

if [[ "${QUORUM}" -lt 2 ]]; then
    echo "Error: --quorum must be at least 2."
    exit 1
fi

if [[ "${QUORUM}" -gt "${KEY_COUNT}" ]]; then
    echo "Error: --quorum (${QUORUM}) cannot exceed --key-count (${KEY_COUNT})."
    exit 1
fi

# Default output directory
if [[ -z "${OUTPUT_DIR}" ]]; then
    OUTPUT_DIR="${HOME}/mhsm-security-domain/${HSM_NAME}"
fi

# ------------------------------------------------------------------
# Check prerequisites
# ------------------------------------------------------------------
echo ""
echo "================================================"
echo "  Managed HSM Security Domain Activation"
echo "================================================"
echo ""
echo "  HSM Name     : ${HSM_NAME}"
echo "  Key Count    : ${KEY_COUNT}"
echo "  Quorum       : ${QUORUM} of ${KEY_COUNT}"
echo "  Output Dir   : ${OUTPUT_DIR}"
echo ""

# Check openssl
if ! command -v openssl &> /dev/null; then
    echo "Error: openssl is not installed. Install it with: sudo apt-get install openssl"
    exit 1
fi

# Check az CLI
if ! command -v az &> /dev/null; then
    echo "Error: Azure CLI (az) is not installed."
    echo "Install: curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"
    exit 1
fi

# Check az login
if ! az account show &> /dev/null; then
    echo "Not logged in to Azure CLI. Launching login..."
    az login
fi

# Verify the HSM exists and is reachable
echo "Verifying Managed HSM is reachable..."
HSM_STATUS=$(az keyvault show --hsm-name "${HSM_NAME}" --query "properties.statusMessage" -o tsv 2>/dev/null || echo "UNREACHABLE")
if [[ "${HSM_STATUS}" == "UNREACHABLE" ]]; then
    echo ""
    echo "Error: Cannot reach Managed HSM '${HSM_NAME}'."
    echo ""
    echo "If using a private endpoint, ensure you are running this script"
    echo "from the admin VM connected to the HSM's virtual network."
    exit 1
fi

PROVISIONING_STATE=$(az keyvault show --hsm-name "${HSM_NAME}" --query "properties.provisioningState" -o tsv 2>/dev/null || echo "Unknown")
echo "  Provisioning State: ${PROVISIONING_STATE}"

# Check if already activated
SECURITY_DOMAIN_STATE=$(az keyvault show --hsm-name "${HSM_NAME}" --query "properties.securityDomainProperties.activationStatus" -o tsv 2>/dev/null || echo "Unknown")
if [[ "${SECURITY_DOMAIN_STATE}" == "Active" ]]; then
    echo ""
    echo "  This Managed HSM is already ACTIVATED."
    echo "  Security domain has already been downloaded."
    echo "  No action needed."
    exit 0
fi

echo "  Security Domain : ${SECURITY_DOMAIN_STATE} (not yet activated)"
echo ""

# ------------------------------------------------------------------
# Create output directory
# ------------------------------------------------------------------
mkdir -p "${OUTPUT_DIR}"
echo "Created output directory: ${OUTPUT_DIR}"
echo ""

# ------------------------------------------------------------------
# Step 1: Generate RSA key pairs
# ------------------------------------------------------------------
echo "Step 1/${KEY_COUNT}: Generating ${KEY_COUNT} RSA Security Officer key pairs..."
echo ""

CERT_FILES=()
for i in $(seq 0 $((KEY_COUNT - 1))); do
    KEY_FILE="${OUTPUT_DIR}/sd_key_${i}.key"
    CERT_FILE="${OUTPUT_DIR}/sd_cert_${i}.cer"

    openssl req -newkey rsa:2048 -nodes \
        -keyout "${KEY_FILE}" \
        -x509 -days 365 \
        -out "${CERT_FILE}" \
        -subj "/CN=MHSM Security Domain ${i}" \
        2>/dev/null

    chmod 600 "${KEY_FILE}"
    CERT_FILES+=("${CERT_FILE}")
    echo "  [${i}] ${CERT_FILE} (private key: ${KEY_FILE})"
done

echo ""
echo "  All ${KEY_COUNT} key pairs generated."
echo ""

# ------------------------------------------------------------------
# Step 2: Download security domain
# ------------------------------------------------------------------
SD_FILE="${OUTPUT_DIR}/${HSM_NAME}-security-domain.json"

echo "Step 2/3: Downloading security domain (this activates the HSM)..."
echo "  This may take 1-2 minutes..."
echo ""

# Build the --sd-wrapping-keys argument
SD_KEYS_ARG=""
for cert in "${CERT_FILES[@]}"; do
    SD_KEYS_ARG="${SD_KEYS_ARG} ${cert}"
done

az keyvault security-domain download \
    --hsm-name "${HSM_NAME}" \
    --sd-wrapping-keys ${SD_KEYS_ARG} \
    --sd-quorum "${QUORUM}" \
    --security-domain-file "${SD_FILE}"

echo ""
echo "  Security domain downloaded: ${SD_FILE}"
echo ""

# ------------------------------------------------------------------
# Step 3: Verify activation
# ------------------------------------------------------------------
echo "Step 3/3: Verifying activation..."

ACTIVATION_STATUS=$(az keyvault show --hsm-name "${HSM_NAME}" --query "properties.securityDomainProperties.activationStatus" -o tsv 2>/dev/null || echo "Unknown")

if [[ "${ACTIVATION_STATUS}" == "Active" ]]; then
    echo "  Managed HSM is now ACTIVE and operational."
else
    echo "  Activation status: ${ACTIVATION_STATUS}"
    echo "  The HSM may take a moment to fully activate. Re-check with:"
    echo "    az keyvault show --hsm-name ${HSM_NAME} --query properties.securityDomainProperties.activationStatus"
fi

# ------------------------------------------------------------------
# Summary and security warnings
# ------------------------------------------------------------------
echo ""
echo "================================================"
echo "  Security Domain Activation Complete"
echo "================================================"
echo ""
echo "  HSM Name       : ${HSM_NAME}"
echo "  Status         : ${ACTIVATION_STATUS}"
echo "  Quorum         : ${QUORUM} of ${KEY_COUNT}"
echo "  Security Domain: ${SD_FILE}"
echo ""
echo "  Files saved to: ${OUTPUT_DIR}/"
ls -la "${OUTPUT_DIR}/"
echo ""
echo "  =============================================="
echo "  CRITICAL SECURITY WARNINGS"
echo "  =============================================="
echo ""
echo "  1. BACK UP these files to secure offline storage IMMEDIATELY:"
echo "     - ${SD_FILE}"
for i in $(seq 0 $((KEY_COUNT - 1))); do
    echo "     - ${OUTPUT_DIR}/sd_key_${i}.key"
done
echo ""
echo "  2. Distribute private keys to different Security Officers."
echo "     No single person should hold all ${KEY_COUNT} keys."
echo ""
echo "  3. If you lose the security domain file AND ${QUORUM}+ private keys,"
echo "     the HSM data is UNRECOVERABLE."
echo ""
echo "  4. After backing up, consider removing private keys from this VM:"
echo "     rm ${OUTPUT_DIR}/sd_key_*.key"
echo ""
echo "  5. The security domain file is encrypted with your ${KEY_COUNT} public keys."
echo "     You need at least ${QUORUM} of the ${KEY_COUNT} private keys to restore it."
echo ""
