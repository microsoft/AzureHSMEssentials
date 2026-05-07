# =============================================================================
# activate-mhsm.ps1
# =============================================================================
# Activates an Azure Managed HSM by generating RSA Security Officer key pairs
# and downloading the security domain. Must be run from a machine that has
# network access to the Managed HSM (e.g., the admin VM via private endpoint,
# or any machine if public access is enabled).
#
# Usage:
#   .\activate-mhsm.ps1 -HsmName <MHSM_NAME> [-Quorum <N>] [-KeyCount <N>] [-OutputDir <DIR>]
#
# Examples:
#   .\activate-mhsm.ps1 -HsmName mhsm-abc123def
#   .\activate-mhsm.ps1 -HsmName mhsm-abc123def -Quorum 3 -KeyCount 5
#   .\activate-mhsm.ps1 -HsmName mhsm-abc123def -OutputDir C:\secure\mhsm-certs
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Name of the Azure Managed HSM to activate (short name, not FQDN)")]
    [string]$HsmName,

    [Parameter(HelpMessage = "Minimum keys needed to recover security domain (default: 2)")]
    [int]$Quorum = 2,

    [Parameter(HelpMessage = "Number of RSA key pairs to generate (default: 3, minimum: 3)")]
    [int]$KeyCount = 3,

    [Parameter(HelpMessage = "Directory to store certs and security domain")]
    [string]$OutputDir = ""
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------
# Validate parameters
# ------------------------------------------------------------------
if ($KeyCount -lt 3) {
    Write-Error "KeyCount must be at least 3 (Azure requires minimum 3 Security Officer keys)."
    exit 1
}

if ($Quorum -lt 2) {
    Write-Error "Quorum must be at least 2."
    exit 1
}

if ($Quorum -gt $KeyCount) {
    Write-Error "Quorum ($Quorum) cannot exceed KeyCount ($KeyCount)."
    exit 1
}

# Default output directory
if ([string]::IsNullOrEmpty($OutputDir)) {
    $OutputDir = Join-Path $HOME "mhsm-security-domain\$HsmName"
}

# ------------------------------------------------------------------
# Banner
# ------------------------------------------------------------------
Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  Managed HSM Security Domain Activation" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  HSM Name     : $HsmName" -ForegroundColor White
Write-Host "  Key Count    : $KeyCount" -ForegroundColor White
Write-Host "  Quorum       : $Quorum of $KeyCount" -ForegroundColor White
Write-Host "  Output Dir   : $OutputDir" -ForegroundColor White
Write-Host ""

# ------------------------------------------------------------------
# Check prerequisites
# ------------------------------------------------------------------

# Check openssl
$opensslCmd = Get-Command openssl -ErrorAction SilentlyContinue
if (-not $opensslCmd) {
    Write-Host "Error: openssl is not found in PATH." -ForegroundColor Red
    Write-Host ""
    Write-Host "Install options:" -ForegroundColor Yellow
    Write-Host "  - Git for Windows includes openssl (add Git\usr\bin to PATH)" -ForegroundColor Gray
    Write-Host "  - winget install ShiningLight.OpenSSL.Light" -ForegroundColor Gray
    Write-Host "  - choco install openssl" -ForegroundColor Gray
    exit 1
}

# Check az CLI
$azCmd = Get-Command az -ErrorAction SilentlyContinue
if (-not $azCmd) {
    Write-Host "Error: Azure CLI (az) is not installed." -ForegroundColor Red
    Write-Host "Install: winget install Microsoft.AzureCLI" -ForegroundColor Yellow
    exit 1
}

# Check az login
try {
    $null = az account show 2>$null
    if ($LASTEXITCODE -ne 0) { throw }
}
catch {
    Write-Host "Not logged in to Azure CLI. Launching login..." -ForegroundColor Yellow
    az login
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Azure login failed."
        exit 1
    }
}

# ------------------------------------------------------------------
# Verify the HSM exists and is reachable
# ------------------------------------------------------------------
Write-Host "Verifying Managed HSM is reachable..." -ForegroundColor White

$hsmStatus = $null
try {
    $hsmStatus = az keyvault show --hsm-name $HsmName --query "properties.statusMessage" -o tsv 2>$null
    if ($LASTEXITCODE -ne 0) { $hsmStatus = $null }
}
catch {
    $hsmStatus = $null
}

if (-not $hsmStatus) {
    Write-Host "" 
    Write-Host "Error: Cannot reach Managed HSM '$HsmName'." -ForegroundColor Red
    Write-Host ""
    Write-Host "If using a private endpoint, ensure you are running this script" -ForegroundColor Yellow
    Write-Host "from a machine connected to the HSM's virtual network (e.g., the admin VM)." -ForegroundColor Yellow
    exit 1
}

$provisioningState = az keyvault show --hsm-name $HsmName --query "properties.provisioningState" -o tsv 2>$null
Write-Host "  Provisioning State: $provisioningState" -ForegroundColor White

# Check if already activated
$securityDomainState = az keyvault show --hsm-name $HsmName --query "properties.securityDomainProperties.activationStatus" -o tsv 2>$null
if ($securityDomainState -eq 'Active') {
    Write-Host "" 
    Write-Host "  This Managed HSM is already ACTIVATED." -ForegroundColor Green
    Write-Host "  Security domain has already been downloaded." -ForegroundColor Green
    Write-Host "  No action needed." -ForegroundColor Green
    exit 0
}

Write-Host "  Security Domain : $securityDomainState (not yet activated)" -ForegroundColor Yellow
Write-Host ""

# ------------------------------------------------------------------
# Create output directory
# ------------------------------------------------------------------
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
Write-Host "Output directory: $OutputDir" -ForegroundColor White
Write-Host ""

# ------------------------------------------------------------------
# Step 1: Generate RSA key pairs
# ------------------------------------------------------------------
Write-Host "Step 1/3: Generating $KeyCount RSA Security Officer key pairs..." -ForegroundColor Cyan
Write-Host ""

$certFiles = @()
for ($i = 0; $i -lt $KeyCount; $i++) {
    $keyFile  = Join-Path $OutputDir "sd_key_$i.key"
    $certFile = Join-Path $OutputDir "sd_cert_$i.cer"

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $opensslOutput = & openssl req -newkey rsa:2048 -nodes `
        -keyout $keyFile `
        -x509 -days 365 `
        -out $certFile `
        -subj "/CN=MHSM Security Domain $i" 2>&1
    $opensslExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP

    if ($opensslExit -ne 0) {
        Write-Host ($opensslOutput | Out-String) -ForegroundColor Red
        Write-Error "Failed to generate key pair $i. Check that openssl is working correctly."
        exit 1
    }

    $certFiles += $certFile
    Write-Host "  [$i] $certFile (private key: $keyFile)" -ForegroundColor White
}

Write-Host ""
Write-Host "  All $KeyCount key pairs generated." -ForegroundColor Green
Write-Host ""

# ------------------------------------------------------------------
# Step 2: Download security domain
# ------------------------------------------------------------------
$sdFile = Join-Path $OutputDir "$HsmName-security-domain.json"

Write-Host "Step 2/3: Downloading security domain (this activates the HSM)..." -ForegroundColor Cyan
Write-Host "  This may take 1-2 minutes..." -ForegroundColor Gray
Write-Host ""

# Build the az command arguments
$azArgs = @(
    'keyvault', 'security-domain', 'download',
    '--hsm-name', $HsmName,
    '--sd-wrapping-keys'
)
$azArgs += $certFiles
$azArgs += @('--sd-quorum', $Quorum, '--security-domain-file', $sdFile)

& az @azArgs

if ($LASTEXITCODE -ne 0) {
    Write-Error "Security domain download failed. Check the error above."
    exit 1
}

Write-Host ""
Write-Host "  Security domain downloaded: $sdFile" -ForegroundColor Green
Write-Host ""

# ------------------------------------------------------------------
# Step 3: Verify activation
# ------------------------------------------------------------------
Write-Host "Step 3/3: Verifying activation..." -ForegroundColor Cyan

$activationStatus = az keyvault show --hsm-name $HsmName --query "properties.securityDomainProperties.activationStatus" -o tsv 2>$null

if ($activationStatus -eq 'Active') {
    Write-Host "  Managed HSM is now ACTIVE and operational." -ForegroundColor Green
} else {
    Write-Host "  Activation status: $activationStatus" -ForegroundColor Yellow
    Write-Host "  The HSM may take a moment to fully activate. Re-check with:" -ForegroundColor Yellow
    Write-Host "    az keyvault show --hsm-name $HsmName --query properties.securityDomainProperties.activationStatus" -ForegroundColor Gray
}

# ------------------------------------------------------------------
# Summary and security warnings
# ------------------------------------------------------------------
Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  Security Domain Activation Complete" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  HSM Name       : $HsmName" -ForegroundColor White
Write-Host "  Status         : $activationStatus" -ForegroundColor White
Write-Host "  Quorum         : $Quorum of $KeyCount" -ForegroundColor White
Write-Host "  Security Domain: $sdFile" -ForegroundColor White
Write-Host ""
Write-Host "  Files saved to: $OutputDir\" -ForegroundColor White
Get-ChildItem $OutputDir | Format-Table Name, Length, LastWriteTime -AutoSize
Write-Host ""
Write-Host "  ==============================================" -ForegroundColor Red
Write-Host "  CRITICAL SECURITY WARNINGS" -ForegroundColor Red
Write-Host "  ==============================================" -ForegroundColor Red
Write-Host ""
Write-Host "  1. BACK UP these files to secure offline storage IMMEDIATELY:" -ForegroundColor Yellow
Write-Host "     - $sdFile" -ForegroundColor White
for ($i = 0; $i -lt $KeyCount; $i++) {
    Write-Host "     - $(Join-Path $OutputDir "sd_key_$i.key")" -ForegroundColor White
}
Write-Host ""
Write-Host "  2. Distribute private keys to different Security Officers." -ForegroundColor Yellow
Write-Host "     No single person should hold all $KeyCount keys." -ForegroundColor White
Write-Host ""
Write-Host "  3. If you lose the security domain file AND $Quorum+ private keys," -ForegroundColor Yellow
Write-Host "     the HSM data is UNRECOVERABLE." -ForegroundColor Red
Write-Host ""
Write-Host "  4. After backing up, consider removing private keys from this machine:" -ForegroundColor Yellow
Write-Host "     Remove-Item `"$OutputDir\sd_key_*.key`"" -ForegroundColor Gray
Write-Host ""
Write-Host "  5. The security domain file is encrypted with your $KeyCount public keys." -ForegroundColor Yellow
Write-Host "     You need at least $Quorum of the $KeyCount private keys to restore it." -ForegroundColor White
Write-Host ""
