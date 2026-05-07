<#
.SYNOPSIS
    Step 2 of 2: Configures ADCS as a Root CA or Issuing (Subordinate) CA
    using an HSM-backed Key Storage Provider (Azure Cloud HSM or Azure
    Dedicated HSM).

.DESCRIPTION
    ADCS Scenario — Step 2 of 2: Configure CA

    Automates the full ADCS CA configuration on a Windows Server VM
    that already has the HSM client/SDK installed.

    Supports both Root CA and Subordinate (Issuing) CA configurations.

    Supported platforms:
      - AzureCloudHSM     — Cavium Key Storage Provider (Marvell LiquidSecurity)
      - AzureDedicatedHSM — SafeNet Key Storage Provider (Thales Luna Network HSM)

    Root CA flow (StandaloneRootCA / EnterpriseRootCA):
      1. Validates prerequisites (OS, KSP registered, no existing CA)
      2. Creates C:\Windows\CAPolicy.inf
      3. Installs the ADCS Windows feature
      4. Configures Root CA (self-signed) via Install-AdcsCertificationAuthority
      5. Validates the CA is operational and keys are in the HSM
      6. Locks down registry settings and backs up the CA configuration

    Subordinate CA flow (StandaloneSubordinateCA / EnterpriseSubordinateCA):
      1-3. Same as Root CA
      4. Configures Subordinate CA — generates a CSR (.req file)
      5. Submits CSR to the parent Root CA and retrieves the signed certificate
      6. Installs the signed certificate and starts the CA service
      7. Validates the CA is operational with correct chain
      8. Locks down registry settings and backs up the CA configuration

    Workflow:
      Step 1 — deploy-adcs-vm.ps1    Deploy the ADCS VM
      Step 2 — configure-adcs.ps1    (this script) Configure CA with HSM KSP

    IMPORTANT: The HSM client/SDK must be installed BEFORE running this script.
      - Cloud HSM: Install the Azure Cloud HSM SDK (provides Cavium KSP)
      - Dedicated HSM: Install the Luna Client + register SafeNet KSP via KspConfig.exe

    For Subordinate CAs, the parent Root CA must be running and accessible.
    The -ParentCAConfig parameter specifies the Root CA to sign the subordinate
    certificate (format: "hostname\CAName").

    Run this script on the ADCS VM after:
      - Step 1: deploy-adcs-vm.ps1 has created the VM
      - HSM client/SDK has been installed on the VM
      - Verified: certutil -csplist shows the platform's KSP
      - (Enterprise only) The VM is domain-joined
      - (Subordinate only) Parent Root CA is operational and reachable

.PARAMETER Platform
    The HSM platform backing the ADCS deployment (default: AzureCloudHSM).
    Valid values: AzureCloudHSM, AzureDedicatedHSM
      AzureCloudHSM     — Uses Cavium Key Storage Provider (Marvell/Cloud HSM SDK)
      AzureDedicatedHSM — Uses SafeNet Key Storage Provider (Thales Luna Client)

.PARAMETER CACommonName
    The Common Name for the Root CA certificate (required).
    Example: "Contoso Root CA"
    For Root CA migrations, use a generational suffix to distinguish the new CA
    from the old (e.g., "Contoso Root CA-G2"). This prevents chain ambiguity when
    both roots coexist in trust stores during the pre-distribution window.
    See: https://aka.ms/adcs-migration for details.

.PARAMETER CAType
    The type of CA to configure (default: StandaloneRootCA).
    Valid values: StandaloneRootCA, EnterpriseRootCA, StandaloneSubordinateCA, EnterpriseSubordinateCA
    Use StandaloneRootCA for offline / air-gapped root CAs.
    Use EnterpriseRootCA for domain-joined root CAs with AD integration.
    Use StandaloneSubordinateCA for standalone issuing CAs signed by a root CA.
    Use EnterpriseSubordinateCA for domain-joined issuing CAs with AD integration.

.PARAMETER ParentCAConfig
    The parent CA configuration string for subordinate CA types (format: "hostname\CAName").
    Required when -CAType is StandaloneSubordinateCA or EnterpriseSubordinateCA.
    Example: "dhsm-adcs-vm\HSB-RootCA"
    The parent CA must be running and reachable from this server.

.PARAMETER OutputRequestFile
    Override the CSR output path for subordinate CA configuration.
    Default: C:\<CACommonName>.req
    Only used with subordinate CA types.

.PARAMETER KeyAlgorithm
    Key algorithm for the CA certificate (default: RSA).
    Valid values: RSA, ECDSA_P256, ECDSA_P384, ECDSA_P521
    Each appears as a separate provider in the ADCS configuration wizard.
    The KSP name depends on the -Platform parameter:
      Cloud HSM:     "RSA#Cavium Key Storage Provider"
      Dedicated HSM: "RSA#SafeNet Key Storage Provider"
    Valid algorithms and key lengths:
      RSA         — key lengths: 2048, 3072, 4096
      ECDSA_P256  — key length: 256 (fixed)
      ECDSA_P384  — key length: 384 (fixed)
      ECDSA_P521  — key length: 521 (fixed)

.PARAMETER KeyLength
    Key length in bits (default: 2048).
    RSA valid values: 2048, 3072, 4096
    ECDSA curves: automatically set to the curve's native size (256, 384, or 521).
    Any manual override is ignored for ECDSA algorithms.

.PARAMETER HashAlgorithm
    Hash algorithm for the CA certificate (default: SHA256).
    Valid values: SHA256, SHA384, SHA512

.PARAMETER ValidityYears
    Validity period of the Root CA certificate in years (default: 20).

.PARAMETER CADistinguishedNameSuffix
    Optional suffix appended to the CA subject name.
    Example: "O=Contoso,C=US"
    If provided, the full subject becomes: CN=<CACommonName>,<suffix>

.PARAMETER CRLPeriod
    CRL publication period unit (default: Weeks).
    Valid values: Hours, Days, Weeks, Months, Years

.PARAMETER CRLPeriodUnits
    Number of CRL period units (default: 1).

.PARAMETER CRLDeltaPeriod
    Delta CRL publication period unit (default: Days).
    Set to "Days" with 0 units to disable Delta CRLs (recommended for root CAs).
    Valid values: Hours, Days

.PARAMETER CRLDeltaPeriodUnits
    Number of Delta CRL period units (default: 0 = disabled).

.PARAMETER CRLOverlapPeriod
    CRL overlap period unit (default: Hours).

.PARAMETER CRLOverlapUnits
    Number of CRL overlap period units (default: 0).

.PARAMETER CRLDeltaOverlapPeriod
    Delta CRL overlap period unit (default: Minutes).

.PARAMETER CRLDeltaOverlapUnits
    Number of Delta CRL overlap period units (default: 0).

.PARAMETER IssuedCertValidityYears
    Default validity period for certificates issued BY this CA (default: 1).
    This is separate from the CA certificate's own validity (-ValidityYears).
    Maps to registry: CA\ValidityPeriodUnits

.PARAMETER PathLength
    Basic Constraints path length for the Root CA (default: None).
    Controls how many levels of subordinate CAs can exist below this root.
    "None" = no restriction. 0 = only end-entity certs below this CA.
    1 = one level of sub-CA allowed, etc.

.PARAMETER DisableBackup
    Skip the post-configuration CA backup step.

.PARAMETER DatabaseDirectory
    Path for the CA database (default: C:\Windows\system32\CertLog).

.PARAMETER LogDirectory
    Path for the CA log files (default: C:\Windows\system32\CertLog).

.PARAMETER OverwriteExisting
    Overwrite any existing CA configuration and keys. Use with caution.

.PARAMETER CACredential
    PSCredential for the account to configure the CA.
    Example: chsm-adcs-vm\chsmVMAdmin
    If omitted, runs under the current user context (must be local admin).
    Usage: $cred = Get-Credential; .\configure-adcs.ps1 -CACredential $cred ...

.PARAMETER AllowAdminInteraction
    Enable "Allow administrator interaction when the private key is accessed
    by the CA". Default: $false (disabled).
    Maps to registry: CA\CSP\Interactive

    WARNING: Setting this to $true (Interactive=1) causes the HSM KSP to pop
    a GUI dialog during every signing operation. This HANGS any headless
    session (certsvc running as SYSTEM, az vm run-command, RDP-less operation).
    Both Cavium KSP (Cloud HSM) and SafeNet KSP (Dedicated HSM) authenticate
    via stored credentials (environment variables and cached slot credentials
    respectively) and do NOT need interactive prompts.

.PARAMETER SkipConfirmation
    Skip the interactive confirmation prompt before configuring.

.EXAMPLE
    .\configure-adcs.ps1 -CACommonName "HSB-RootCA"

.EXAMPLE
    .\configure-adcs.ps1 -CACommonName "HSB-RootCA" -Platform AzureCloudHSM -KeyAlgorithm RSA -KeyLength 2048

.EXAMPLE
    .\configure-adcs.ps1 -CACommonName "HSB-RootCA" -Platform AzureDedicatedHSM

.EXAMPLE
    .\configure-adcs.ps1 -CACommonName "HSB-RootCA" -Platform AzureDedicatedHSM -KeyAlgorithm RSA -KeyLength 4096

.EXAMPLE
    .\configure-adcs.ps1 -CACommonName "HSB-RootCA" -KeyAlgorithm ECDSA_P256

.EXAMPLE
    .\configure-adcs.ps1 -CACommonName "HSB-RootCA" -KeyAlgorithm ECDSA_P384

.EXAMPLE
    .\configure-adcs.ps1 -CACommonName "HSB-RootCA" -KeyAlgorithm ECDSA_P521

.EXAMPLE
    $cred = Get-Credential "chsm-adcs-vm\chsmVMAdmin"
    .\configure-adcs.ps1 -CACommonName "HSB-RootCA" -CACredential $cred

.EXAMPLE
    .\configure-adcs.ps1 -CACommonName "HSB-RootCA" -CAType EnterpriseRootCA -KeyLength 4096

.EXAMPLE
    .\configure-adcs.ps1 -CACommonName "HSB-RootCA" -CADistinguishedNameSuffix "O=Contoso,C=US" -ValidityYears 25

.EXAMPLE
    .\configure-adcs.ps1 -CACommonName "HSB-RootCA" -SkipConfirmation

.EXAMPLE
    # Root CA migration: use a generational suffix (-G2) so the new root is
    # distinguishable from the old during the pre-distribution coexistence window.
    .\configure-adcs.ps1 -CACommonName "HSB-RootCA-G2" -Platform AzureCloudHSM -OverwriteExisting

.EXAMPLE
    # Standalone Subordinate (Issuing) CA signed by a Standalone Root CA
    .\configure-adcs.ps1 -CACommonName "HSB-IssuingCA" -CAType StandaloneSubordinateCA `
        -ParentCAConfig "dhsm-adcs-vm\HSB-RootCA" -Platform AzureDedicatedHSM

.EXAMPLE
    # Enterprise Subordinate (Issuing) CA with custom CSR output path
    .\configure-adcs.ps1 -CACommonName "HSB-IssuingCA" -CAType EnterpriseSubordinateCA `
        -ParentCAConfig "dhsm-adcs-vm\HSB-RootCA" -Platform AzureDedicatedHSM `
        -OutputRequestFile "C:\temp\HSB-IssuingCA.req"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Common Name for the Root CA certificate.")]
    [ValidateNotNullOrEmpty()]
    [string]$CACommonName,

    [Parameter(Mandatory = $false, HelpMessage = "HSM platform: AzureCloudHSM (Cavium KSP) or AzureDedicatedHSM (SafeNet KSP).")]
    [ValidateSet("AzureCloudHSM", "AzureDedicatedHSM")]
    [string]$Platform = "AzureCloudHSM",

    [Parameter(Mandatory = $false, HelpMessage = "Type of CA (StandaloneRootCA, EnterpriseRootCA, StandaloneSubordinateCA, or EnterpriseSubordinateCA).")]
    [ValidateSet("StandaloneRootCA", "EnterpriseRootCA", "StandaloneSubordinateCA", "EnterpriseSubordinateCA")]
    [string]$CAType = "StandaloneRootCA",

    [Parameter(Mandatory = $false, HelpMessage = "Parent CA config string for subordinate CAs (format: 'hostname\CAName'). Required for subordinate CA types.")]
    [string]$ParentCAConfig,

    [Parameter(Mandatory = $false, HelpMessage = "Override the CSR output path for subordinate CA configuration.")]
    [string]$OutputRequestFile,

    [Parameter(Mandatory = $false, HelpMessage = "Key algorithm (RSA, ECDSA_P256, ECDSA_P384, or ECDSA_P521).")]
    [ValidateSet("RSA", "ECDSA_P256", "ECDSA_P384", "ECDSA_P521")]
    [string]$KeyAlgorithm = "RSA",

    [Parameter(Mandatory = $false, HelpMessage = "Key length in bits (RSA: 2048/3072/4096, ECDSA: auto-set to curve size).")]
    [ValidateSet(256, 384, 521, 2048, 3072, 4096)]
    [int]$KeyLength = 2048,

    [Parameter(Mandatory = $false, HelpMessage = "Hash algorithm for the CA certificate.")]
    [ValidateSet("SHA256", "SHA384", "SHA512")]
    [string]$HashAlgorithm = "SHA256",

    [Parameter(Mandatory = $false, HelpMessage = "Validity period in years for the Root CA certificate.")]
    [ValidateRange(1, 50)]
    [int]$ValidityYears = 20,

    [Parameter(Mandatory = $false, HelpMessage = "Distinguished name suffix (e.g., 'O=Contoso,C=US').")]
    [string]$CADistinguishedNameSuffix,

    [Parameter(Mandatory = $false, HelpMessage = "CRL publication period unit.")]
    [ValidateSet("Hours", "Days", "Weeks", "Months", "Years")]
    [string]$CRLPeriod = "Weeks",

    [Parameter(Mandatory = $false, HelpMessage = "Number of CRL period units.")]
    [ValidateRange(1, 365)]
    [int]$CRLPeriodUnits = 1,

    [Parameter(Mandatory = $false, HelpMessage = "Delta CRL publication period unit.")]
    [ValidateSet("Hours", "Days")]
    [string]$CRLDeltaPeriod = "Days",

    [Parameter(Mandatory = $false, HelpMessage = "Number of Delta CRL period units (0 = disabled).")]
    [ValidateRange(0, 365)]
    [int]$CRLDeltaPeriodUnits = 0,

    [Parameter(Mandatory = $false, HelpMessage = "CRL overlap period unit.")]
    [ValidateSet("Hours", "Days", "Weeks", "Months")]
    [string]$CRLOverlapPeriod = "Hours",

    [Parameter(Mandatory = $false, HelpMessage = "Number of CRL overlap period units.")]
    [ValidateRange(0, 365)]
    [int]$CRLOverlapUnits = 0,

    [Parameter(Mandatory = $false, HelpMessage = "Delta CRL overlap period unit.")]
    [ValidateSet("Minutes", "Hours", "Days")]
    [string]$CRLDeltaOverlapPeriod = "Minutes",

    [Parameter(Mandatory = $false, HelpMessage = "Number of Delta CRL overlap period units.")]
    [ValidateRange(0, 365)]
    [int]$CRLDeltaOverlapUnits = 0,

    [Parameter(Mandatory = $false, HelpMessage = "Default validity period for certs issued by this CA (years).")]
    [ValidateRange(1, 50)]
    [int]$IssuedCertValidityYears = 1,

    [Parameter(Mandatory = $false, HelpMessage = "Basic Constraints path length (None = no restriction).")]
    [string]$PathLength = "None",

    [Parameter(Mandatory = $false, HelpMessage = "Skip the post-configuration CA backup.")]
    [switch]$DisableBackup,

    [Parameter(Mandatory = $false, HelpMessage = "Path for the CA database.")]
    [string]$DatabaseDirectory = "C:\Windows\system32\CertLog",

    [Parameter(Mandatory = $false, HelpMessage = "Path for the CA log files.")]
    [string]$LogDirectory = "C:\Windows\system32\CertLog",

    [Parameter(Mandatory = $false, HelpMessage = "Overwrite existing CA configuration and keys.")]
    [switch]$OverwriteExisting,

    [Parameter(Mandatory = $false, HelpMessage = "PSCredential for the CA configuration account (e.g. chsm-adcs-vm\chsmVMAdmin).")]
    [System.Management.Automation.PSCredential]$CACredential,

    [Parameter(Mandatory = $false, HelpMessage = "Azure Cloud HSM Crypto User username (e.g., 'cu1'). Sets azcloudhsm_username system environment variable.")]
    [string]$HsmUsername,

    [Parameter(Mandatory = $false, HelpMessage = "Azure Cloud HSM Crypto User password (e.g., 'user1234'). Combined with HsmUsername to set azcloudhsm_password as 'username:password'.")]
    [SecureString]$HsmPassword,

    [Parameter(Mandatory = $false, HelpMessage = "Allow admin interaction when private key is accessed by the CA. WARNING: enabling this hangs headless sessions.")]
    [bool]$AllowAdminInteraction = $false,

    [Parameter(Mandatory = $false, HelpMessage = "Skip confirmation prompt.")]
    [switch]$SkipConfirmation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ═══════════════════════════════════════════════════════════════════════
# Constants & Key Algorithm Resolution
# ═══════════════════════════════════════════════════════════════════════
# Platform-specific KSP names
$KSPNames = @{
    "AzureCloudHSM"     = "Cavium Key Storage Provider"
    "AzureDedicatedHSM" = "SafeNet Key Storage Provider"
}
$KSPBase     = $KSPNames[$Platform]
$KSPProvider = "$KeyAlgorithm#$KSPBase"   # e.g. "RSA#SafeNet Key Storage Provider"
$isCloudHSM  = ($Platform -eq "AzureCloudHSM")

# CA type classification
$isSubordinate = ($CAType -match 'Subordinate')
$isRootCA      = -not $isSubordinate
$isEnterprise  = ($CAType -match 'Enterprise')
$caTypeLabel   = if ($isSubordinate) { "Issuing (Subordinate) CA" } else { "Root CA" }
$totalSteps    = if ($isSubordinate) { 8 } else { 6 }

# Validate subordinate CA requirements
if ($isSubordinate) {
    if ([string]::IsNullOrWhiteSpace($ParentCAConfig)) {
        Write-Host ""
        Write-Host "  ERROR: -ParentCAConfig is required for subordinate CA types." -ForegroundColor Red
        Write-Host "  Specify the parent Root CA in the format: hostname\CAName" -ForegroundColor Yellow
        Write-Host "  Example: -ParentCAConfig `"dhsm-adcs-vm\HSB-RootCA`"" -ForegroundColor Gray
        Write-Host ""
        exit 1
    }
    if (-not $OutputRequestFile) {
        $OutputRequestFile = "C:\$CACommonName.req"
    }
}

# Auto-set key length for ECDSA curves (fixed to the curve's native size)
$ecdsaKeySizes = @{
    "ECDSA_P256" = 256
    "ECDSA_P384" = 384
    "ECDSA_P521" = 521
}
if ($ecdsaKeySizes.ContainsKey($KeyAlgorithm)) {
    $expectedSize = $ecdsaKeySizes[$KeyAlgorithm]
    if ($KeyLength -ne $expectedSize) {
        Write-Host "  [INFO] $KeyAlgorithm requires key length $expectedSize. Overriding from $KeyLength." -ForegroundColor Yellow
    }
    $KeyLength = $expectedSize
}

# ═══════════════════════════════════════════════════════════════════════
# Banner
# ═══════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  ADCS Scenario -- Step 2 of 2: Configure $caTypeLabel" -ForegroundColor Cyan
Write-Host "  Platform : $Platform"                                -ForegroundColor Cyan
Write-Host "  Provider : $KSPProvider"                             -ForegroundColor Cyan
Write-Host "  Algorithm: $KeyAlgorithm ($KeyLength-bit)"           -ForegroundColor Cyan
Write-Host "  CA Type  : $CAType"                                  -ForegroundColor Cyan
if ($isSubordinate) {
Write-Host "  Parent CA: $ParentCAConfig"                          -ForegroundColor Cyan
}
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════
# Helper: Check result
# ═══════════════════════════════════════════════════════════════════════
$checks = @()
$allPassed = $true

function Add-CheckResult {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $script:checks += [PSCustomObject]@{
        Check  = $Name
        Status = if ($Passed) { "PASS" } else { "FAIL" }
        Detail = $Detail
    }
    if (-not $Passed) { $script:allPassed = $false }
    $color = if ($Passed) { "Green" } else { "Red" }
    $icon  = if ($Passed) { "[PASS]" } else { "[FAIL]" }
    Write-Host "  $icon $Name" -ForegroundColor $color
    if ($Detail) {
        Write-Host "        $Detail" -ForegroundColor Gray
    }
}

# ═══════════════════════════════════════════════════════════════════════
# Cloud HSM Environment Variables (AzureCloudHSM only)
# ═══════════════════════════════════════════════════════════════════════
# The Cavium KSP requires two system environment variables to authenticate
# to Azure Cloud HSM. These must be set BEFORE the KSP can operate.
# SafeNet KSP (Dedicated HSM) does NOT use environment variables — it
# authenticates via slot registration in KspConfig.exe.
#   azcloudhsm_username — Crypto User name (e.g. "cu1")
#   azcloudhsm_password — Crypto User credentials (e.g. "cu1:user1234")

if ($isCloudHSM) {

$existingHsmUser = [System.Environment]::GetEnvironmentVariable('azcloudhsm_username', 'Machine')
$existingHsmPass = [System.Environment]::GetEnvironmentVariable('azcloudhsm_password', 'Machine')

if ($HsmUsername -and $HsmPassword) {
    # Set from parameters — compose azcloudhsm_password as "username:password"
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($HsmPassword)
    )
    $hsmPasswordValue = "${HsmUsername}:${plainPassword}"
    [System.Environment]::SetEnvironmentVariable('azcloudhsm_username', $HsmUsername, 'Machine')
    [System.Environment]::SetEnvironmentVariable('azcloudhsm_password', $hsmPasswordValue, 'Machine')
    # Also set for current process so KSP works immediately
    $env:azcloudhsm_username = $HsmUsername
    $env:azcloudhsm_password = $hsmPasswordValue
    $plainPassword = $null
    $hsmPasswordValue = $null
    Write-Host "  [PASS] Cloud HSM credentials set as system environment variables" -ForegroundColor Green
    Write-Host "         azcloudhsm_username = $HsmUsername" -ForegroundColor Gray
    Write-Host "         azcloudhsm_password = ${HsmUsername}:********" -ForegroundColor Gray
} elseif ($existingHsmUser -and $existingHsmPass) {
    # Already set — use existing
    $env:azcloudhsm_username = $existingHsmUser
    $env:azcloudhsm_password = $existingHsmPass
    Write-Host "  [INFO] Using existing Cloud HSM credentials from system environment variables" -ForegroundColor Gray
    Write-Host "         azcloudhsm_username = $existingHsmUser" -ForegroundColor Gray
} else {
    # Not provided and not set — prompt
    Write-Host "" -ForegroundColor White
    Write-Host "  The Cavium KSP requires Cloud HSM Crypto User credentials." -ForegroundColor Yellow
    Write-Host "  These are set as system environment variables:" -ForegroundColor Yellow
    Write-Host "    azcloudhsm_username - Crypto User name (e.g. 'cu1')" -ForegroundColor Gray
    Write-Host "    azcloudhsm_password - username:password format (e.g. 'cu1:user1234')" -ForegroundColor Gray
    Write-Host ""
    $HsmUsername = Read-Host -Prompt "  Cloud HSM username (e.g. cu1)"
    $HsmPassword = Read-Host -AsSecureString -Prompt "  Cloud HSM password (e.g. user1234)"
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($HsmPassword)
    )
    if ([string]::IsNullOrWhiteSpace($HsmUsername) -or [string]::IsNullOrWhiteSpace($plainPassword)) {
        Write-Host "  [FAIL] Cloud HSM credentials are required." -ForegroundColor Red
        Write-Host "         Pass -HsmUsername and -HsmPassword, or set the environment variables manually:" -ForegroundColor Yellow
        Write-Host "           setx /m azcloudhsm_username cu1" -ForegroundColor Gray
        Write-Host "           setx /m azcloudhsm_password cu1:user1234" -ForegroundColor Gray
        exit 1
    }
    $hsmPasswordValue = "${HsmUsername}:${plainPassword}"
    [System.Environment]::SetEnvironmentVariable('azcloudhsm_username', $HsmUsername, 'Machine')
    [System.Environment]::SetEnvironmentVariable('azcloudhsm_password', $hsmPasswordValue, 'Machine')
    $env:azcloudhsm_username = $HsmUsername
    $env:azcloudhsm_password = $hsmPasswordValue
    $plainPassword = $null
    $hsmPasswordValue = $null
    Write-Host "  [PASS] Cloud HSM credentials set as system environment variables" -ForegroundColor Green
}

} else {
    # AzureDedicatedHSM — no environment variables needed
    Write-Host "  [INFO] Dedicated HSM: SafeNet KSP authenticates via registered slot (no env vars needed)" -ForegroundColor Gray
}
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════
# STEP 1 : Prerequisites Validation
# ═══════════════════════════════════════════════════════════════════════
Write-Host "[STEP 1/$totalSteps] Validating prerequisites..." -ForegroundColor White
Write-Host ""

# --- Check 1: Running as Administrator ---
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
Add-CheckResult -Name "Running as Administrator" -Passed $isAdmin `
    -Detail $(if ($isAdmin) { "Elevated session confirmed" } else { "This script MUST be run as Administrator" })

if (-not $isAdmin) {
    Write-Host ""
    Write-Host "  ERROR: Please re-run this script from an elevated PowerShell session." -ForegroundColor Red
    Write-Host "         Right-click PowerShell > Run as Administrator" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# --- Check 2: Windows Server OS ---
$os = Get-CimInstance -ClassName Win32_OperatingSystem
$isServer = $os.ProductType -eq 3  # 3 = Server
$osCaption = $os.Caption
Add-CheckResult -Name "Windows Server OS" -Passed $isServer `
    -Detail $osCaption

# --- Checks 3-5: Platform-specific HSM prerequisites ---
if ($isCloudHSM) {
    # --- Check 3: Cloud HSM SDK path and configuration file ---
    # The CNG/KSP provider requires azcloudhsm_application.cfg to be reachable.
    # Adding the SDK directories to the system PATH ensures any application
    # (certutil, certsvc, ADCS) can find the config file and utilities.
    $sdkBasePath   = "C:\Program Files\Microsoft Azure Cloud HSM Client SDK"
    $sdkUtilPath   = "C:\Program Files\Microsoft Azure Cloud HSM Client SDK\utils\azcloudhsm_util"
    $cfgFilePath   = Join-Path $sdkUtilPath "azcloudhsm_application.cfg"

    $cfgExists = Test-Path $cfgFilePath
    Add-CheckResult -Name "Cloud HSM Config File" -Passed $cfgExists `
        -Detail $(if ($cfgExists) { "Found: $cfgFilePath" } else { "NOT FOUND: $cfgFilePath - verify Cloud HSM SDK installation" })

    if ($cfgExists) {
        # Safely append SDK paths to the system PATH if not already present
        $currentPath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
        $pathsToAdd = @($sdkBasePath, $sdkUtilPath)
        $pathUpdated = $false
        foreach ($p in $pathsToAdd) {
            if ($currentPath -notlike "*$p*") {
                $currentPath = "$currentPath;$p"
                $pathUpdated = $true
            }
        }
        if ($pathUpdated) {
            [System.Environment]::SetEnvironmentVariable('Path', $currentPath, 'Machine')
            # Also update current process PATH
            $env:Path = $currentPath
            Add-CheckResult -Name "Cloud HSM SDK in PATH" -Passed $true `
                -Detail "Added SDK directories to system PATH"
        } else {
            Add-CheckResult -Name "Cloud HSM SDK in PATH" -Passed $true `
                -Detail "SDK directories already in system PATH"
        }
    } else {
        Write-Host ""
        Write-Host "  ERROR: azcloudhsm_application.cfg not found." -ForegroundColor Red
        Write-Host "  The Azure Cloud HSM SDK must be installed BEFORE configuring ADCS." -ForegroundColor Yellow
        Write-Host "  Expected location: $cfgFilePath" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  Install the SDK from:" -ForegroundColor Gray
        Write-Host "  https://github.com/microsoft/MicrosoftAzureCloudHSM/tree/main/OnboardingGuides" -ForegroundColor Cyan
        Write-Host ""
        exit 1
    }

    # --- Check 4: Cloud HSM Client Service (azcloudhsm_client) ---
    # The MSI installs azcloudhsm_client as an automatic service but leaves it stopped.
    # The KSP depends on this service being running to communicate with the HSM.
    # Must be running BEFORE certutil -csplist, otherwise:
    #   "Failed to connect socket IP 127.0.0.1 Error:10061"
    $clientSvc = Get-Service -Name 'azcloudhsm_client' -ErrorAction SilentlyContinue
    if ($clientSvc) {
        if ($clientSvc.Status -ne 'Running') {
            Write-Host "  [INFO] Starting azcloudhsm_client service..." -ForegroundColor Gray
            try {
                Start-Service -Name 'azcloudhsm_client' -ErrorAction Stop
                Start-Sleep -Seconds 3
                $clientSvc = Get-Service -Name 'azcloudhsm_client'
            } catch {
                Add-CheckResult -Name "Cloud HSM Client Service" -Passed $false `
                    -Detail "Failed to start azcloudhsm_client: $($_.Exception.Message)"
            }
        }
        $svcRunning = ($clientSvc.Status -eq 'Running')
        Add-CheckResult -Name "Cloud HSM Client Service" -Passed $svcRunning `
            -Detail $(if ($svcRunning) { "azcloudhsm_client is running" } else { "azcloudhsm_client status: $($clientSvc.Status) - start manually: Start-Service azcloudhsm_client" })

        if (-not $svcRunning) {
            Write-Host ""
            Write-Host "  ERROR: The Cloud HSM client service must be running for the KSP to operate." -ForegroundColor Red
            Write-Host "  Try: Start-Service azcloudhsm_client" -ForegroundColor Yellow
            Write-Host ""
            exit 1
        }
    } else {
        Add-CheckResult -Name "Cloud HSM Client Service" -Passed $false `
            -Detail "azcloudhsm_client service not found - verify Cloud HSM SDK installation"
        exit 1
    }

} else {
    # --- AzureDedicatedHSM: Check Luna Client installation ---
    # SafeNet KSP is registered via KspConfig.exe during Luna Client setup.
    # No background service is needed — NTLS connectivity is via Chrystoki.conf.
    $lunaClientPath = "C:\Program Files\SafeNet\LunaClient"
    $lunaKspPath    = Join-Path $lunaClientPath "KSP"
    $kspConfigExe   = Join-Path $lunaKspPath "KspConfig.exe"
    $crystokiPath   = Join-Path $lunaClientPath "crystoki.ini"

    $lunaInstalled = Test-Path $lunaClientPath
    Add-CheckResult -Name "Luna Client Installed" -Passed $lunaInstalled `
        -Detail $(if ($lunaInstalled) { "Found: $lunaClientPath" } else { "NOT FOUND: $lunaClientPath - install Thales Luna Client first" })

    if (-not $lunaInstalled) {
        Write-Host ""
        Write-Host "  ERROR: Thales Luna Client not found." -ForegroundColor Red
        Write-Host "  Install the Luna Client and register the SafeNet KSP via KspConfig.exe" -ForegroundColor Yellow
        Write-Host "  before running this script." -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }

    $crystokiExists = Test-Path $crystokiPath
    Add-CheckResult -Name "Luna crystoki.ini" -Passed $crystokiExists `
        -Detail $(if ($crystokiExists) { "Found: $crystokiPath" } else { "NOT FOUND: $crystokiPath - Luna Client may not be properly configured" })

    # Check NTLS client private key has SYSTEM read access (required for CertSvc)
    $ntlsKeyPath = Join-Path $lunaClientPath "cert\client"
    $ntlsKeys = Get-ChildItem $ntlsKeyPath -Filter "*Key.pem" -ErrorAction SilentlyContinue
    if ($ntlsKeys) {
        foreach ($keyFile in $ntlsKeys) {
            $acl = Get-Acl $keyFile.FullName
            $systemAccess = $acl.Access | Where-Object { $_.IdentityReference -match "SYSTEM" }
            if (-not $systemAccess) {
                Write-Host "  [WARN] NTLS private key '$($keyFile.Name)' is not readable by SYSTEM" -ForegroundColor Yellow
                Write-Host "        Granting SYSTEM read access (required for CertSvc)..." -ForegroundColor Yellow
                icacls $keyFile.FullName /grant "NT AUTHORITY\SYSTEM:(R)" 2>&1 | Out-Null
                Write-Host "  [PASS] SYSTEM read access granted to $($keyFile.Name)" -ForegroundColor Green
            } else {
                Write-Host "  [PASS] NTLS private key readable by SYSTEM" -ForegroundColor Green
                Write-Host "        $($keyFile.Name) ACL verified" -ForegroundColor Gray
            }
        }
    }
}

# --- Check 5: HSM Key Storage Provider registered ---
# Run certutil -csplist to confirm the platform's KSP is available.
$kspFound = $false
$kspDetail = ""
try {
    $cspOutput = certutil -csplist 2>&1
    $cspText = $cspOutput -join "`n"
    if ($cspText -match [regex]::Escape($KSPBase)) {
        $kspFound = $true
        $kspDetail = "$KSPBase found - will use: $KSPProvider"
    } else {
        if ($isCloudHSM) {
            $kspDetail = "$KSPBase not found. Install Azure Cloud HSM SDK first."
        } else {
            $kspDetail = "$KSPBase not found. Register SafeNet KSP via KspConfig.exe first."
        }
    }
} catch {
    $kspDetail = "certutil -csplist failed: $($_.Exception.Message)"
}
Add-CheckResult -Name "$KSPBase Registered" -Passed $kspFound -Detail $kspDetail

if (-not $kspFound) {
    Write-Host ""
    Write-Host "  ERROR: $KSPBase is not registered." -ForegroundColor Red
    if ($isCloudHSM) {
        Write-Host "  The Azure Cloud HSM SDK must be installed BEFORE configuring ADCS." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Install the SDK from:" -ForegroundColor Gray
        Write-Host "  https://github.com/microsoft/MicrosoftAzureCloudHSM/tree/main/OnboardingGuides" -ForegroundColor Cyan
    } else {
        Write-Host "  Register the SafeNet KSP using KspConfig.exe from the Luna Client KSP directory." -ForegroundColor Yellow
        Write-Host "  1. Run KspConfig.exe → Register Or View Security Library → register cryptoki.dll" -ForegroundColor Gray
        Write-Host "  2. Register HSM Slots for Domain\\User and NT AUTHORITY\\SYSTEM" -ForegroundColor Gray
    }
    Write-Host ""
    exit 1
}

# --- Check 6: Enterprise CA requires domain membership ---
if ($isEnterprise) {
    $isDomainJoined = $false
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem
        $isDomainJoined = ($cs.PartOfDomain -eq $true)
        Add-CheckResult -Name "Domain Membership" -Passed $isDomainJoined `
            -Detail $(if ($isDomainJoined) { "Domain: $($cs.Domain)" } else { "Enterprise CA requires domain membership" })

        if (-not $isDomainJoined) {
            Write-Host ""
            Write-Host "  ERROR: $CAType requires a domain-joined server." -ForegroundColor Red
            Write-Host "  Either join the domain first, or use a Standalone CA type." -ForegroundColor Yellow
            Write-Host ""
            exit 1
        }
    } catch {
        Add-CheckResult -Name "Domain Membership" -Passed $false -Detail "Could not check domain status"
    }
}

# --- Check 7: No existing CA configured (unless -OverwriteExisting) ---
$existingCA = $false
try {
    $caInfo = certutil -cainfo name 2>&1
    $caInfoText = $caInfo -join "`n"
    if ($LASTEXITCODE -eq 0 -and $caInfoText -notmatch 'error|not found') {
        $existingCA = $true
    }
} catch {
    # No CA configured — this is the expected state
}

if ($existingCA -and -not $OverwriteExisting) {
    Write-Host ""
    Write-Host "  [WARN] An existing CA configuration was detected on this server." -ForegroundColor Yellow
    Write-Host "         Use -OverwriteExisting to replace it, or remove the existing CA first." -ForegroundColor Yellow
    Write-Host ""
    Add-CheckResult -Name "No Existing CA" -Passed $false `
        -Detail "Existing CA found. Use -OverwriteExisting to replace."
    exit 1
} elseif ($existingCA -and $OverwriteExisting) {
    Add-CheckResult -Name "Existing CA (will overwrite)" -Passed $true `
        -Detail "Existing CA detected - will be overwritten per -OverwriteExisting"
} else {
    Add-CheckResult -Name "No Existing CA" -Passed $true `
        -Detail "No pre-existing CA configuration found"
}

# --- Prereq gate ---
if (-not $allPassed) {
    Write-Host ""
    Write-Host "  Prerequisites FAILED. Resolve the issues above before continuing." -ForegroundColor Red
    Write-Host ""
    exit 1
}

Write-Host ""
Write-Host "  All prerequisites passed." -ForegroundColor Green
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════
# Confirmation
# ═══════════════════════════════════════════════════════════════════════
$subjectLine = "CN=$CACommonName"
if ($CADistinguishedNameSuffix) {
    $subjectLine += ",$CADistinguishedNameSuffix"
}

Write-Host "  ┌──────────────────────────────────────────────────────┐" -ForegroundColor White
Write-Host "  │  $caTypeLabel Configuration Summary" -ForegroundColor White
Write-Host "  ├──────────────────────────────────────────────────────┤" -ForegroundColor White
Write-Host "  │  CA Common Name : $CACommonName" -ForegroundColor White
Write-Host "  │  Subject        : $subjectLine" -ForegroundColor White
Write-Host "  │  CA Type        : $CAType" -ForegroundColor White
if ($isSubordinate) {
Write-Host "  │  Parent CA      : $ParentCAConfig" -ForegroundColor White
Write-Host "  │  CSR Output     : $OutputRequestFile" -ForegroundColor White
}
Write-Host "  │  Key Algorithm : $KeyAlgorithm" -ForegroundColor White
Write-Host "  │  Key Provider   : $KSPProvider" -ForegroundColor White
Write-Host "  │  Key Length     : $KeyLength bits" -ForegroundColor White
Write-Host "  │  Hash Algorithm : $HashAlgorithm" -ForegroundColor White
if ($isRootCA) {
Write-Host "  │  Validity       : $ValidityYears years (CA cert)" -ForegroundColor White
}
Write-Host "  │  Issued Cert    : $IssuedCertValidityYears years (certs issued by this CA)" -ForegroundColor White
Write-Host "  │  New Key        : Yes (create new key pair in HSM)" -ForegroundColor White
Write-Host "  │  Admin Interact : $(if ($AllowAdminInteraction) { 'Enabled' } else { 'Disabled' })" -ForegroundColor White
Write-Host "  │  Credential    : $(if ($CACredential) { $CACredential.UserName } else { '(current user)' })" -ForegroundColor White
Write-Host "  │  CRL Period     : $CRLPeriodUnits $CRLPeriod" -ForegroundColor White
Write-Host "  │  CRL Overlap    : $CRLOverlapUnits $CRLOverlapPeriod" -ForegroundColor White
Write-Host "  │  Delta CRL     : $(if ($CRLDeltaPeriodUnits -eq 0) { 'Disabled' } else { "$CRLDeltaPeriodUnits $CRLDeltaPeriod" })" -ForegroundColor White
Write-Host "  │  Path Length   : $PathLength" -ForegroundColor White
Write-Host "  │  CAPolicy.inf  : C:\Windows\CAPolicy.inf" -ForegroundColor White
Write-Host "  │  Database       : $DatabaseDirectory" -ForegroundColor White
Write-Host "  └──────────────────────────────────────────────────────┘" -ForegroundColor White
Write-Host ""

if (-not $SkipConfirmation) {
    $confirm = Read-Host "  Proceed with $caTypeLabel configuration? (yes/no)"
    if ($confirm -ne 'yes') {
        Write-Host ""
        Write-Host "  Aborted. No changes were made." -ForegroundColor Yellow
        Write-Host ""
        exit 0
    }
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════
# STEP 2 of 6 : Create CAPolicy.inf
# ═══════════════════════════════════════════════════════════════════════
Write-Host "[STEP 2/$totalSteps] Creating C:\Windows\CAPolicy.inf..." -ForegroundColor White
Write-Host ""
Write-Host "  This file MUST exist before ADCS role configuration." -ForegroundColor Gray
Write-Host "  It controls CA extensions, CRL settings, and policy constraints." -ForegroundColor Gray
Write-Host ""

$caPolicyPath = "C:\Windows\CAPolicy.inf"

# Check if one already exists
if (Test-Path $caPolicyPath) {
    $existingContent = Get-Content $caPolicyPath -Raw
    Write-Host "  [WARN] Existing CAPolicy.inf found at $caPolicyPath" -ForegroundColor Yellow
    if (-not $OverwriteExisting) {
        Write-Host "         Using existing file. Pass -OverwriteExisting to replace it." -ForegroundColor Yellow
        Write-Host ""
    } else {
        $backupPath = "$caPolicyPath.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -Path $caPolicyPath -Destination $backupPath -Force
        Write-Host "         Backed up to: $backupPath" -ForegroundColor Gray
    }
}

# Build the CAPolicy.inf content
# PathLength handling: "None" = omit constraint, numeric = set it
$pathLengthLine = ""
if ($PathLength -ne "None") {
    $pathLengthLine = "PathLength = $PathLength"
}

if ($isSubordinate) {
    # Subordinate CA: no self-signed validity, path length typically 0
    $caPolicyContent = @"
; ==========================================================================
; CAPolicy.inf - Subordinate (Issuing) CA Policy File
; Generated by configure-adcs.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
;
; This file is read by Install-AdcsCertificationAuthority during CA setup.
; It MUST exist at C:\Windows\CAPolicy.inf BEFORE the CA is configured.
; ==========================================================================

[Version]
Signature = "`$Windows NT`$"

[certsrv_server]
; --- Crypto Provider ---
RenewalKeyLength = $KeyLength
HashAlgorithm    = $HashAlgorithm
CNGHashAlgorithm = $HashAlgorithm
CNGPublicKeyAlgorithm = $KeyAlgorithm

; --- CRL Settings ---
CRLPeriod        = $CRLPeriod
CRLPeriodUnits   = $CRLPeriodUnits
CRLDeltaPeriod   = $CRLDeltaPeriod
CRLDeltaPeriodUnits = $CRLDeltaPeriodUnits
CRLOverlapPeriod = $CRLOverlapPeriod
CRLOverlapUnits  = $CRLOverlapUnits

; --- Disable discrete signatures (use PKCS) ---
AlternateSignatureAlgorithm = 0

[BasicConstraintsExtension]
Critical = Yes
$pathLengthLine

[Extensions]
; Key Usage: Digital Signature, Certificate Signing, CRL Signing
2.5.29.15 = AwIBhg==
Critical  = 2.5.29.15

"@
} else {
    # Root CA: includes self-signed validity period
    $caPolicyContent = @"
; ==========================================================================
; CAPolicy.inf - Root CA Policy File
; Generated by configure-adcs.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
;
; This file is read by Install-AdcsCertificationAuthority during CA setup.
; It MUST exist at C:\Windows\CAPolicy.inf BEFORE the CA is configured.
; ==========================================================================

[Version]
Signature = "`$Windows NT`$"

[certsrv_server]
; --- Crypto Provider ---
RenewalKeyLength = $KeyLength
HashAlgorithm    = $HashAlgorithm
CNGHashAlgorithm = $HashAlgorithm
CNGPublicKeyAlgorithm = $KeyAlgorithm

; --- CRL Settings ---
CRLPeriod        = $CRLPeriod
CRLPeriodUnits   = $CRLPeriodUnits
CRLDeltaPeriod   = $CRLDeltaPeriod
CRLDeltaPeriodUnits = $CRLDeltaPeriodUnits
CRLOverlapPeriod = $CRLOverlapPeriod
CRLOverlapUnits  = $CRLOverlapUnits

; --- Validity issued to subordinate CAs ---
ValidityPeriod      = Years
ValidityPeriodUnits = $ValidityYears

; --- Disable discrete signatures (use PKCS) ---
AlternateSignatureAlgorithm = 0

[BasicConstraintsExtension]
Critical = Yes
$pathLengthLine

[Extensions]
; Key Usage: Digital Signature, Certificate Signing, CRL Signing
2.5.29.15 = AwIBhg==
Critical  = 2.5.29.15

"@
}

# Write (or overwrite) the CAPolicy.inf
if (-not (Test-Path $caPolicyPath) -or $OverwriteExisting) {
    $caPolicyContent | Out-File -FilePath $caPolicyPath -Encoding ASCII -Force
    Write-Host "  [PASS] CAPolicy.inf created at $caPolicyPath" -ForegroundColor Green
} else {
    Write-Host "  [PASS] Using existing CAPolicy.inf" -ForegroundColor Green
}

# Display the content
Write-Host ""
Write-Host "  Contents:" -ForegroundColor Gray
(Get-Content $caPolicyPath) | ForEach-Object {
    Write-Host "    $_" -ForegroundColor DarkGray
}
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════
# STEP 3 of 6 : Install ADCS Windows Feature
# ═══════════════════════════════════════════════════════════════════════
Write-Host "[STEP 3/$totalSteps] Installing ADCS Windows feature..." -ForegroundColor White
Write-Host ""

$adcsFeature = Get-WindowsFeature -Name ADCS-Cert-Authority -ErrorAction SilentlyContinue

if ($adcsFeature.Installed) {
    Write-Host "  ADCS-Cert-Authority feature is already installed." -ForegroundColor Green
} else {
    Write-Host "  Installing ADCS-Cert-Authority with management tools..." -ForegroundColor Gray
    try {
        $installResult = Install-WindowsFeature -Name ADCS-Cert-Authority -IncludeManagementTools -ErrorAction Stop
        if ($installResult.Success) {
            Write-Host "  [PASS] ADCS feature installed successfully." -ForegroundColor Green
            if ($installResult.RestartNeeded -eq 'Yes') {
                Write-Host ""
                Write-Host "  WARNING: A restart is required before configuring the CA." -ForegroundColor Red
                Write-Host "  Restart the server and re-run this script." -ForegroundColor Yellow
                Write-Host ""
                exit 0
            }
        } else {
            Write-Host "  [FAIL] ADCS feature installation failed." -ForegroundColor Red
            Write-Host "  Exit code: $($installResult.ExitCode)" -ForegroundColor Red
            exit 1
        }
    } catch {
        Write-Host "  [FAIL] Error installing ADCS feature: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# Also install ADCS web enrollment and online responder if Enterprise CA
if ($isEnterprise) {
    $webEnroll = Get-WindowsFeature -Name ADCS-Web-Enrollment -ErrorAction SilentlyContinue
    if (-not $webEnroll.Installed) {
        Write-Host "  Installing ADCS-Web-Enrollment for Enterprise CA..." -ForegroundColor Gray
        Install-WindowsFeature -Name ADCS-Web-Enrollment -ErrorAction SilentlyContinue | Out-Null
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════════
# STEP 4 of 6 : Configure Root CA with HSM KSP
# ═══════════════════════════════════════════════════════════════════════
Write-Host "[STEP 4/$totalSteps] Configuring $caTypeLabel with $KSPBase..." -ForegroundColor White
Write-Host ""
if ($isSubordinate) {
    Write-Host "  This will generate the CA key pair inside the HSM" -ForegroundColor Gray
    Write-Host "  and create a Certificate Signing Request (CSR)." -ForegroundColor Gray
} else {
    Write-Host "  This will generate the CA key pair inside the HSM" -ForegroundColor Gray
    Write-Host "  and create the self-signed Root CA certificate." -ForegroundColor Gray
}
Write-Host ""

# Build the Install-AdcsCertificationAuthority parameters
$caParams = @{
    CAType             = $CAType
    CryptoProviderName = $KSPProvider      # e.g. "RSA#SafeNet Key Storage Provider"
    KeyLength          = $KeyLength
    HashAlgorithmName  = $HashAlgorithm
    CACommonName       = $CACommonName
    DatabaseDirectory  = $DatabaseDirectory
    LogDirectory       = $LogDirectory
    Force              = $true
}

# Root CA needs ValidityPeriod (self-signed); Subordinate CA gets it from the parent
if ($isRootCA) {
    $caParams["ValidityPeriod"]      = "Years"
    $caParams["ValidityPeriodUnits"] = $ValidityYears
}

# Subordinate CA: specify the CSR output file
if ($isSubordinate) {
    $caParams["OutputCertRequestFile"] = $OutputRequestFile
}

# Add optional DN suffix
if ($CADistinguishedNameSuffix) {
    $caParams["CADistinguishedNameSuffix"] = $CADistinguishedNameSuffix
}

# Add credential if provided (e.g. chsm-adcs-vm\chsmVMAdmin)
if ($CACredential) {
    $caParams["Credential"] = $CACredential
}

# Handle overwrite
if ($OverwriteExisting) {
    $caParams["OverwriteExistingKey"]      = $true
    $caParams["OverwriteExistingDatabase"] = $true
    $caParams["OverwriteExistingCAinDS"]   = $true
}

Write-Host "  Creating NEW key pair in $Platform HSM..." -ForegroundColor White
Write-Host "  Running Install-AdcsCertificationAuthority..." -ForegroundColor White
Write-Host "    -CAType             : $CAType" -ForegroundColor Gray
Write-Host "    -CryptoProviderName : $KSPProvider" -ForegroundColor Gray
Write-Host "    -KeyAlgorithm       : $KeyAlgorithm" -ForegroundColor Gray
Write-Host "    -KeyLength          : $KeyLength" -ForegroundColor Gray
Write-Host "    -HashAlgorithmName  : $HashAlgorithm" -ForegroundColor Gray
if ($isRootCA) {
    Write-Host "    -ValidityPeriod     : $ValidityYears Years" -ForegroundColor Gray
}
if ($isSubordinate) {
    Write-Host "    -OutputCertRequest  : $OutputRequestFile" -ForegroundColor Gray
    Write-Host "    -ParentCA           : $ParentCAConfig" -ForegroundColor Gray
}
Write-Host "    -CACommonName       : $CACommonName" -ForegroundColor Gray
if ($CACredential) {
    Write-Host "    -Credential         : $($CACredential.UserName)" -ForegroundColor Gray
}
if ($CADistinguishedNameSuffix) {
    Write-Host "    -CADNSuffix         : $CADistinguishedNameSuffix" -ForegroundColor Gray
}
Write-Host ""

try {
    $configResult = Install-AdcsCertificationAuthority @caParams -ErrorAction Stop
    if ($isSubordinate) {
        Write-Host "  [PASS] Subordinate CA configured — CSR generated." -ForegroundColor Green
        Write-Host "         CSR file: $OutputRequestFile" -ForegroundColor Gray
    } else {
        Write-Host "  [PASS] Root CA configured successfully." -ForegroundColor Green
    }
    Write-Host ""
} catch {
    $errMsg = $_.Exception.Message

    # Check for common error: "The Certification Authority is already installed"
    if ($errMsg -match 'already installed|already configured') {
        Write-Host "  [WARN] CA is already configured on this server." -ForegroundColor Yellow
        Write-Host "  Use -OverwriteExisting to replace the existing configuration." -ForegroundColor Yellow
    } else {
        Write-Host "  [FAIL] CA configuration failed:" -ForegroundColor Red
        Write-Host "         $errMsg" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Common causes:" -ForegroundColor Yellow
        Write-Host "    - HSM SDK/client not installed or not connected" -ForegroundColor Gray
        Write-Host "    - $KSPBase cannot reach the HSM partition" -ForegroundColor Gray
        Write-Host "    - Insufficient permissions (run as Administrator)" -ForegroundColor Gray
        Write-Host "    - ADCS feature needs a reboot after installation" -ForegroundColor Gray
        if ($isSubordinate) {
            Write-Host "    - Parent CA ($ParentCAConfig) not reachable or not running" -ForegroundColor Gray
        }
    }
    Write-Host ""
    exit 1
}

# ═══════════════════════════════════════════════════════════════════════
# STEP 5 & 6 (Subordinate only): Submit CSR and Install Certificate
# ═══════════════════════════════════════════════════════════════════════
if ($isSubordinate) {

    # --- STEP 5: Submit CSR to the Parent Root CA ---
    Write-Host ""
    Write-Host "[STEP 5/$totalSteps] Submitting CSR to parent CA ($ParentCAConfig)..." -ForegroundColor White
    Write-Host ""

    # Verify CSR file exists
    if (-not (Test-Path $OutputRequestFile)) {
        Write-Host "  [FAIL] CSR file not found: $OutputRequestFile" -ForegroundColor Red
        Write-Host "  Install-AdcsCertificationAuthority should have created this file." -ForegroundColor Yellow
        exit 1
    }

    Write-Host "  CSR file: $OutputRequestFile ($(( Get-Item $OutputRequestFile ).Length) bytes)" -ForegroundColor Gray
    Write-Host "  Submitting to: $ParentCAConfig" -ForegroundColor Gray
    Write-Host ""

    $signedCertPath = "C:\$CACommonName.cer"
    $certChainPath  = "C:\$CACommonName.p7b"

    try {
        # certreq -submit sends the CSR to the parent CA and retrieves the signed cert.
        # For a Standalone Root CA, the request may be auto-issued or may pend for admin approval.
        # -config specifies the parent CA, -attrib provides the certificate template.
        $submitOutput = certreq -submit -config "$ParentCAConfig" "$OutputRequestFile" "$signedCertPath" "$certChainPath" 2>&1
        $submitExitCode = $LASTEXITCODE
        $submitText = $submitOutput -join "`n"

        if ($submitExitCode -eq 0 -and (Test-Path $signedCertPath)) {
            Write-Host "  [PASS] Certificate signed by parent CA." -ForegroundColor Green
            Write-Host "         Signed cert : $signedCertPath" -ForegroundColor Gray
            Write-Host "         Cert chain  : $certChainPath" -ForegroundColor Gray
        } elseif ($submitText -match 'pending|taken under submission') {
            # Request is pending admin approval on the parent CA
            # Extract the Request ID for manual approval
            $requestId = ""
            if ($submitText -match 'RequestId:\s*(\d+)') {
                $requestId = $Matches[1]
            } elseif ($submitText -match 'request\s+Id\s+is\s+(\d+)') {
                $requestId = $Matches[1]
            }

            Write-Host "  [PEND] Certificate request is PENDING approval on the parent CA." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  The parent Standalone Root CA requires manual approval." -ForegroundColor Yellow
            Write-Host "  On the ROOT CA server ($($ParentCAConfig.Split('\')[0])):" -ForegroundColor White
            Write-Host ""
            if ($requestId) {
                Write-Host "    certutil -resubmit $requestId" -ForegroundColor Cyan
            } else {
                Write-Host "    1. Open certsrv.msc → Pending Requests" -ForegroundColor Gray
                Write-Host "    2. Right-click the request → All Tasks → Issue" -ForegroundColor Gray
            }
            Write-Host ""
            Write-Host "  After issuing, retrieve the certificate on THIS server:" -ForegroundColor White
            Write-Host ""
            if ($requestId) {
                Write-Host "    certreq -retrieve -config `"$ParentCAConfig`" $requestId `"$signedCertPath`"" -ForegroundColor Cyan
            } else {
                Write-Host "    certreq -retrieve -config `"$ParentCAConfig`" <RequestId> `"$signedCertPath`"" -ForegroundColor Cyan
            }
            Write-Host ""
            Write-Host "  Then install the certificate:" -ForegroundColor White
            Write-Host "    certutil -installCert `"$signedCertPath`"" -ForegroundColor Cyan
            Write-Host "    Start-Service certsvc" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "  ────────────────────────────────────────────────────" -ForegroundColor Gray
            Write-Host "  Subordinate CA configuration PAUSED — waiting for Root CA approval." -ForegroundColor Yellow
            Write-Host "  Re-run this script with -OverwriteExisting after installing the cert," -ForegroundColor Yellow
            Write-Host "  or complete the remaining steps manually." -ForegroundColor Yellow
            Write-Host "  ────────────────────────────────────────────────────" -ForegroundColor Gray
            Write-Host ""
            exit 0
        } else {
            Write-Host "  [FAIL] CSR submission failed:" -ForegroundColor Red
            Write-Host "         $submitText" -ForegroundColor Red
            Write-Host ""
            Write-Host "  Common causes:" -ForegroundColor Yellow
            Write-Host "    - Parent CA ($ParentCAConfig) is not running" -ForegroundColor Gray
            Write-Host "    - Parent CA hostname not resolvable from this server" -ForegroundColor Gray
            Write-Host "    - RPC/DCOM connectivity blocked between servers" -ForegroundColor Gray
            Write-Host "    - Parent CA has insufficient validity remaining" -ForegroundColor Gray
            Write-Host ""
            exit 1
        }
    } catch {
        Write-Host "  [FAIL] CSR submission error: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    # --- STEP 6: Install the signed certificate ---
    Write-Host ""
    Write-Host "[STEP 6/$totalSteps] Installing signed certificate..." -ForegroundColor White
    Write-Host ""

    try {
        $installOutput = certutil -installCert "$signedCertPath" 2>&1
        $installExitCode = $LASTEXITCODE
        $installText = $installOutput -join "`n"

        if ($installExitCode -eq 0) {
            Write-Host "  [PASS] Signed certificate installed successfully." -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] Certificate installation failed:" -ForegroundColor Red
            Write-Host "         $installText" -ForegroundColor Red
            Write-Host ""
            Write-Host "  Troubleshooting:" -ForegroundColor Yellow
            Write-Host "    - Ensure the Root CA certificate is in the Trusted Root store" -ForegroundColor Gray
            Write-Host "    - Verify the signed cert matches the pending CSR" -ForegroundColor Gray
            Write-Host "    - Check: certutil -dump `"$signedCertPath`"" -ForegroundColor Gray
            exit 1
        }
    } catch {
        Write-Host "  [FAIL] Certificate installation error: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    # Start the CA service — it cannot start until the cert is installed
    Write-Host ""
    Write-Host "  Starting Certificate Services..." -ForegroundColor Gray
    try {
        Start-Service certsvc -ErrorAction Stop
        Start-Sleep -Seconds 3
        $svc = Get-Service -Name certsvc
        if ($svc.Status -eq 'Running') {
            Write-Host "  [PASS] certsvc is running." -ForegroundColor Green
        } else {
            Write-Host "  [WARN] certsvc status: $($svc.Status)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  [WARN] Could not start certsvc: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  The service may start after a reboot." -ForegroundColor Gray
    }
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════
# Validation Step : Post-Configuration Validation
# ═══════════════════════════════════════════════════════════════════════
$validationStep = if ($isSubordinate) { 7 } else { 5 }
Write-Host "[STEP $validationStep/$totalSteps] Validating $caTypeLabel configuration..." -ForegroundColor White
Write-Host ""

$postChecks = @()
$postAllPassed = $true

function Add-PostCheck {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $script:postChecks += [PSCustomObject]@{
        Check  = $Name
        Status = if ($Passed) { "PASS" } else { "FAIL" }
        Detail = $Detail
    }
    if (-not $Passed) { $script:postAllPassed = $false }
    $color = if ($Passed) { "Green" } else { "Red" }
    $icon  = if ($Passed) { "[PASS]" } else { "[FAIL]" }
    Write-Host "  $icon $Name" -ForegroundColor $color
    if ($Detail) {
        Write-Host "        $Detail" -ForegroundColor Gray
    }
}

# --- Post-Check 1: Certificate Services is running ---
try {
    $svc = Get-Service -Name certsvc -ErrorAction Stop
    Add-PostCheck -Name "Certificate Services Running" -Passed ($svc.Status -eq 'Running') `
        -Detail "certsvc status: $($svc.Status)"

    if ($svc.Status -ne 'Running') {
        Write-Host "  Starting certsvc..." -ForegroundColor Gray
        Start-Service certsvc -ErrorAction Stop
        Start-Sleep -Seconds 3
        $svc = Get-Service -Name certsvc -ErrorAction Stop
        Write-Host "  certsvc status: $($svc.Status)" -ForegroundColor $(if ($svc.Status -eq 'Running') { "Green" } else { "Red" })
    }
} catch {
    Add-PostCheck -Name "Certificate Services Running" -Passed $false `
        -Detail "certsvc not found or failed to start: $($_.Exception.Message)"
}

# --- Post-Check 2: CA certificate exists ---
# The cert store may not be fully ready immediately after Install-AdcsCertificationAuthority.
# Retry up to 3 times with a short delay to handle this timing window.
$caCertSubject = ""
try {
    $caCertPath = Join-Path $env:TEMP "RootCA-verify.cer"
    $exportExitCode = 1
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Remove-Item $caCertPath -Force -ErrorAction SilentlyContinue
        $exportResult = certutil -ca.cert "`"$caCertPath`"" 2>&1
        $exportExitCode = $LASTEXITCODE
        if ($exportExitCode -eq 0 -and (Test-Path $caCertPath)) { break }
        if ($attempt -lt 3) {
            Write-Host "  [INFO] CA cert export attempt $attempt failed, retrying in 5 seconds..." -ForegroundColor Gray
            Start-Sleep -Seconds 5
        }
    }

    if ($exportExitCode -eq 0 -and (Test-Path $caCertPath)) {
        $dumpOutput = certutil -dump $caCertPath 2>&1
        $dumpText = $dumpOutput -join "`n"

        if ($dumpText -match 'Subject:\s*\r?\n\s*(.+)') {
            $caCertSubject = $Matches[1].Trim()
        }

        $isSelfSigned = $false
        if ($dumpText -match 'Issuer:\s*\r?\n\s*(.+)') {
            $issuer = $Matches[1].Trim()
            $isSelfSigned = ($issuer -eq $caCertSubject)
        }

        Add-PostCheck -Name "CA Certificate Exists" -Passed $true `
            -Detail "Subject: $caCertSubject"

        if ($isSubordinate) {
            # Subordinate: issuer must differ from subject (signed by parent)
            Add-PostCheck -Name "Signed by Parent CA" -Passed (-not $isSelfSigned) `
                -Detail $(if (-not $isSelfSigned) { "Issuer: $issuer (parent-signed)" } else { "ERROR: Certificate is self-signed — expected parent-signed" })
        } else {
            Add-PostCheck -Name "Self-Signed Root" -Passed $isSelfSigned `
                -Detail $(if ($isSelfSigned) { "Confirmed self-signed root CA" } else { "Issuer does not match subject" })
        }

        # Cleanup
        Remove-Item $caCertPath -Force -ErrorAction SilentlyContinue
    } else {
        Add-PostCheck -Name "CA Certificate Exists" -Passed $false -Detail "Could not export CA certificate"
    }
} catch {
    Add-PostCheck -Name "CA Certificate Exists" -Passed $false -Detail $_.Exception.Message
}

# --- Post-Check 3: CA is using the expected HSM KSP ---
try {
    $cspOutput = certutil -getreg CA\CSP 2>&1
    $cspText = $cspOutput -join "`n"
    $usingExpectedKSP = $cspText -match [regex]::Escape($KSPBase)

    Add-PostCheck -Name "CA Uses $KSPBase" -Passed $usingExpectedKSP `
        -Detail $(if ($usingExpectedKSP) { "Confirmed: $KSPBase" } else { "CA is NOT using $KSPBase" })
} catch {
    Add-PostCheck -Name "CA Uses $KSPBase" -Passed $false -Detail $_.Exception.Message
}

# --- Post-Check 4: Private key verification ---
try {
    $verifyOutput = certutil -verifykeys 2>&1
    $verifyExitCode = $LASTEXITCODE
    $verifyText = $verifyOutput -join "`n"

    $keysOk = ($verifyExitCode -eq 0) -or ($verifyText -match 'PASS|succeeded|verified')
    Add-PostCheck -Name "Private Key Verified" -Passed $keysOk `
        -Detail $(if ($keysOk) { "CA private key verified in HSM" } else { "Key verification failed" })
} catch {
    Add-PostCheck -Name "Private Key Verified" -Passed $false -Detail $_.Exception.Message
}

# --- Post-Check 5: CRL publication ---
try {
    $crlOutput = certutil -CRL 2>&1
    $crlExitCode = $LASTEXITCODE
    Add-PostCheck -Name "CRL Published" -Passed ($crlExitCode -eq 0) `
        -Detail $(if ($crlExitCode -eq 0) { "Initial CRL published successfully" } else { "CRL publication failed" })
} catch {
    Add-PostCheck -Name "CRL Published" -Passed $false -Detail $_.Exception.Message
}

# --- Post-Check 6: CAPolicy.inf exists and was applied ---
try {
    $infExists = Test-Path "C:\Windows\CAPolicy.inf"
    Add-PostCheck -Name "CAPolicy.inf Present" -Passed $infExists `
        -Detail $(if ($infExists) { "C:\Windows\CAPolicy.inf confirmed" } else { "CAPolicy.inf missing - CA may not have correct policy settings" })

    if ($infExists) {
        $infContent = Get-Content "C:\Windows\CAPolicy.inf" -Raw
        $infHasServerSection = $infContent -match 'certsrv_server'
        Add-PostCheck -Name "CAPolicy.inf Valid" -Passed $infHasServerSection `
            -Detail $(if ($infHasServerSection) { "Contains [certsrv_server] section" } else { "Missing expected sections" })
    }
} catch {
    Add-PostCheck -Name "CAPolicy.inf Present" -Passed $false -Detail $_.Exception.Message
}

# ═══════════════════════════════════════════════════════════════════════
# Configure CRL settings
# ═══════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "  Configuring CRL publication settings..." -ForegroundColor Gray
try {
    certutil -setreg CA\CRLPeriod $CRLPeriod 2>&1 | Out-Null
    certutil -setreg CA\CRLPeriodUnits $CRLPeriodUnits 2>&1 | Out-Null
    certutil -setreg CA\CRLDeltaPeriod $CRLDeltaPeriod 2>&1 | Out-Null
    certutil -setreg CA\CRLDeltaPeriodUnits $CRLDeltaPeriodUnits 2>&1 | Out-Null
    certutil -setreg CA\CRLOverlapPeriod $CRLOverlapPeriod 2>&1 | Out-Null
    certutil -setreg CA\CRLOverlapUnits $CRLOverlapUnits 2>&1 | Out-Null
    certutil -setreg CA\CRLDeltaOverlapPeriod $CRLDeltaOverlapPeriod 2>&1 | Out-Null
    certutil -setreg CA\CRLDeltaOverlapUnits $CRLDeltaOverlapUnits 2>&1 | Out-Null
    Write-Host "  CRL period         : $CRLPeriodUnits $CRLPeriod" -ForegroundColor Gray
    Write-Host "  CRL overlap        : $CRLOverlapUnits $CRLOverlapPeriod" -ForegroundColor Gray
    Write-Host "  Delta CRL          : $(if ($CRLDeltaPeriodUnits -eq 0) { 'Disabled' } else { "$CRLDeltaPeriodUnits $CRLDeltaPeriod" })" -ForegroundColor Gray
    Write-Host "  Delta CRL overlap  : $CRLDeltaOverlapUnits $CRLDeltaOverlapPeriod" -ForegroundColor Gray

    # Set issued certificate validity (separate from the CA cert's own validity)
    certutil -setreg CA\ValidityPeriod "Years" 2>&1 | Out-Null
    certutil -setreg CA\ValidityPeriodUnits $IssuedCertValidityYears 2>&1 | Out-Null
    Write-Host "  Issued cert validity: $IssuedCertValidityYears Years" -ForegroundColor Gray

    # Force UTF8 encoding (ForceTeletex = 0x12 = TELETEX_AUTO + TELETEX_UTF8)
    certutil -setreg CA\ForceTeletex 18 2>&1 | Out-Null
    Write-Host "  ForceTeletex       : 0x12 (AUTO + UTF8)" -ForegroundColor Gray

    # Restart certsvc to apply CRL settings
    Restart-Service certsvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Write-Host "  [PASS] CRL and CA settings applied, certsvc restarted." -ForegroundColor Green
} catch {
    Write-Host "  [WARN] CRL settings could not be applied: $($_.Exception.Message)" -ForegroundColor Yellow
}

# ═══════════════════════════════════════════════════════════════════════
# Lockdown Step : Registry lockdown & Backup
# ═══════════════════════════════════════════════════════════════════════
Write-Host ""
$lockdownStep = if ($isSubordinate) { 8 } else { 6 }
Write-Host "[STEP $lockdownStep/$totalSteps] Registry lockdown and CA backup..." -ForegroundColor White
Write-Host ""

# --- 6a: HSM private key interaction mode ---
# Interactive=1 causes the HSM KSP to pop a GUI dialog during every signing
# operation. This HANGS certsvc (runs as SYSTEM in session 0 with no desktop),
# az vm run-command, and any headless/automated workflow.
# Both KSPs authenticate via stored credentials:
#   - Cavium KSP (Cloud HSM): azcloudhsm_username / azcloudhsm_password env vars
#   - SafeNet KSP (Dedicated HSM): cached slot credentials via kspcmd
# Interactive=0 is the correct setting for BOTH platforms.
try {
    if ($AllowAdminInteraction) {
        certutil -setreg CA\CSP\Interactive 1 2>&1 | Out-Null
        Write-Host "  [WARN] Admin interaction ENABLED (CA\CSP\Interactive = 1)" -ForegroundColor Yellow
        Write-Host "        WARNING: This will cause GUI prompts during signing operations." -ForegroundColor Yellow
        Write-Host "        CertSvc and headless sessions (az vm run-command) will HANG." -ForegroundColor Yellow
        Write-Host "        Only enable this for interactive debugging from a desktop session." -ForegroundColor Yellow
    } else {
        certutil -setreg CA\CSP\Interactive 0 2>&1 | Out-Null
        Write-Host "  [PASS] Admin interaction disabled (CA\CSP\Interactive = 0)" -ForegroundColor Green
        if ($isCloudHSM) {
            Write-Host "        Cavium KSP authenticates via azcloudhsm_username/password env vars" -ForegroundColor Gray
        } else {
            Write-Host "        SafeNet KSP uses cached slot credentials (kspcmd)" -ForegroundColor Gray
        }
    }
} catch {
    Write-Host "  [WARN] Could not set admin interaction: $($_.Exception.Message)" -ForegroundColor Yellow
}

# --- 6b: Enable full CA auditing ---
try {
    certutil -setreg CA\AuditFilter 127 2>&1 | Out-Null
    Write-Host "  [PASS] CA audit filter set to 127 (full auditing)" -ForegroundColor Green
} catch {
    Write-Host "  [WARN] Could not set audit filter: $($_.Exception.Message)" -ForegroundColor Yellow
}

# --- 6c: Set InterfaceFlags for security hardening ---
# Matches real ADCS config: 0x641 (1601)
#   IF_LOCKICERTREQUEST (0x1)          — Lock down ICertRequest interface
#   IF_NOREMOTEICERTADMINBACKUP (0x40) — Prevent remote CA backup
#   IF_ENFORCEENCRYPTICERTREQUEST (0x200) — Enforce encryption on cert requests
#   IF_ENFORCEENCRYPTICERTADMIN (0x400)   — Enforce encryption on admin interface
try {
    certutil -setreg CA\InterfaceFlags +IF_LOCKICERTREQUEST 2>&1 | Out-Null
    certutil -setreg CA\InterfaceFlags +IF_NOREMOTEICERTADMINBACKUP 2>&1 | Out-Null
    certutil -setreg CA\InterfaceFlags +IF_ENFORCEENCRYPTICERTREQUEST 2>&1 | Out-Null
    certutil -setreg CA\InterfaceFlags +IF_ENFORCEENCRYPTICERTADMIN 2>&1 | Out-Null
    Write-Host "  [PASS] InterfaceFlags hardened (0x641: lock requests, no remote backup, enforce encryption)" -ForegroundColor Green
} catch {
    Write-Host "  [WARN] Could not set InterfaceFlags: $($_.Exception.Message)" -ForegroundColor Yellow
}

# --- 6d: Ensure CRLEditFlags has EDITF_ENABLEAKIKEYID ---
# This enables the Authority Key Identifier extension in CRLs
try {
    certutil -setreg CA\CRLEditFlags +EDITF_ENABLEAKIKEYID 2>&1 | Out-Null
    Write-Host "  [PASS] CRLEditFlags: EDITF_ENABLEAKIKEYID enabled" -ForegroundColor Green
} catch {
    Write-Host "  [WARN] Could not set CRLEditFlags: $($_.Exception.Message)" -ForegroundColor Yellow
}

# --- 6e: Restart certsvc to apply registry changes ---
try {
    Restart-Service certsvc -Force -ErrorAction Stop
    Start-Sleep -Seconds 3
    Write-Host "  [PASS] Certificate Services restarted with hardened settings" -ForegroundColor Green
} catch {
    Write-Host "  [WARN] Could not restart certsvc: $($_.Exception.Message)" -ForegroundColor Yellow
}

# --- 6f: Backup CA configuration ---
if (-not $DisableBackup) {
    $backupTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir = "C:\CABackup\$CACommonName-$backupTimestamp"
    Write-Host ""
    Write-Host "  Backing up CA to: $backupDir" -ForegroundColor Gray

    try {
        if (-not (Test-Path $backupDir)) {
            New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
        }

        # Backup CA database only — private key lives in the HSM and cannot
        # be exported via certutil -backup (which hangs waiting for HSM
        # interactive approval on Cloud HSM / Cavium KSP or Dedicated HSM / SafeNet KSP).
        $dbBackupResult = certutil -backupDB $backupDir 2>&1
        $dbBackupExitCode = $LASTEXITCODE

        if ($dbBackupExitCode -eq 0) {
            Write-Host "  [PASS] CA database backed up successfully" -ForegroundColor Green
            Write-Host "         (Private key is HSM-resident - not included in backup)" -ForegroundColor Gray
        } else {
            Write-Host "  [WARN] Database backup returned code $dbBackupExitCode" -ForegroundColor Yellow
            Write-Host "         Back up manually: certutil -backupDB C:\CABackup" -ForegroundColor Gray
        }

        # Also copy CAPolicy.inf to backup
        if (Test-Path "C:\Windows\CAPolicy.inf") {
            Copy-Item -Path "C:\Windows\CAPolicy.inf" -Destination "$backupDir\CAPolicy.inf" -Force
            Write-Host "  [PASS] CAPolicy.inf copied to backup directory" -ForegroundColor Green
        }

        # Export CA certificate to backup
        $backupCertPath = Join-Path $backupDir "$CACommonName.cer"
        certutil -ca.cert "`"$backupCertPath`"" 2>&1 | Out-Null
        if (Test-Path $backupCertPath) {
            Write-Host "  [PASS] CA certificate exported to backup directory" -ForegroundColor Green
        }
    } catch {
        Write-Host "  [WARN] Backup error: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "         Back up manually: certutil -backup C:\CABackup" -ForegroundColor Gray
    }
} else {
    Write-Host "  [SKIP] Backup disabled via -DisableBackup" -ForegroundColor Yellow
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "======================================================" -ForegroundColor $(if ($postAllPassed) { "Green" } else { "Yellow" })
if ($postAllPassed) {
    if ($isSubordinate) {
        Write-Host "  Subordinate (Issuing) CA Configuration Succeeded" -ForegroundColor Green
    } else {
        Write-Host "  Step 2 Complete: Root CA Configuration Succeeded" -ForegroundColor Green
    }
} else {
    if ($isSubordinate) {
        Write-Host "  Subordinate (Issuing) CA Configured (with warnings)" -ForegroundColor Yellow
    } else {
        Write-Host "  Step 2: Root CA Configured (with warnings)" -ForegroundColor Yellow
    }
}
Write-Host "======================================================" -ForegroundColor $(if ($postAllPassed) { "Green" } else { "Yellow" })
Write-Host ""
Write-Host "  CA Common Name  : $CACommonName" -ForegroundColor White
Write-Host "  Subject         : $caCertSubject" -ForegroundColor White
Write-Host "  CA Type         : $CAType" -ForegroundColor White
if ($isSubordinate) {
    Write-Host "  Parent CA       : $ParentCAConfig" -ForegroundColor White
}
Write-Host "  Key Algorithm   : $KeyAlgorithm" -ForegroundColor White
Write-Host "  Key Provider    : $KSPProvider" -ForegroundColor White
Write-Host "  Key Length      : $KeyLength bits" -ForegroundColor White
Write-Host "  Hash Algorithm  : $HashAlgorithm" -ForegroundColor White
if ($isRootCA) {
    Write-Host "  Validity        : $ValidityYears years" -ForegroundColor White
}
Write-Host ""

Write-Host "  Validation Results:" -ForegroundColor White
foreach ($c in $postChecks) {
    $color = if ($c.Status -eq "PASS") { "Green" } else { "Red" }
    Write-Host "    $($c.Status)  $($c.Check)" -ForegroundColor $color
}

Write-Host ""
Write-Host "  The $caTypeLabel is now operational with keys stored in $Platform HSM ($KSPBase)." -ForegroundColor Green
Write-Host ""
Write-Host "  ────────────────────────────────────────────────────" -ForegroundColor Gray
if ($isSubordinate) {
    Write-Host "  Issuing CA Configuration Complete" -ForegroundColor Green
} else {
    Write-Host "  ADCS Scenario Complete (Step 1 + Step 2)" -ForegroundColor Green
}
Write-Host "  ────────────────────────────────────────────────────" -ForegroundColor Gray
Write-Host ""
Write-Host "  Verify with:" -ForegroundColor Gray
Write-Host "    certutil -ca.cert CA.cer          # Export CA certificate" -ForegroundColor Gray
Write-Host "    certutil -dump CA.cer             # View certificate details" -ForegroundColor Gray
Write-Host "    certutil -getreg CA\CSP           # Confirm $KSPBase" -ForegroundColor Gray
Write-Host "    certutil -verifykeys              # Verify HSM key binding" -ForegroundColor Gray
Write-Host ""

if ($isSubordinate) {
    Write-Host "  Next Steps for Subordinate (Issuing) CA:" -ForegroundColor Yellow
    Write-Host "    1. Verify certificate chain: certutil -verify -urlfetch CA.cer" -ForegroundColor White
    Write-Host "    2. Publish CRL: certutil -CRL" -ForegroundColor White
    Write-Host "    3. Test certificate issuance from this CA" -ForegroundColor White
    Write-Host "    4. For migration testing: compare key operations between DHSM and CHSM ICA" -ForegroundColor White
    Write-Host ""
} elseif ($CAType -eq "StandaloneRootCA") {
    Write-Host "  Next Steps for Standalone Root CA:" -ForegroundColor Yellow
    Write-Host "    1. Export the Root CA certificate for distribution" -ForegroundColor White
    Write-Host "    2. Configure subordinate/issuing CAs to chain to this root" -ForegroundColor White
    Write-Host "    3. If this will be an offline root, harden and disconnect from network" -ForegroundColor White
    Write-Host ""
} elseif ($CAType -eq "EnterpriseRootCA") {
    Write-Host "  Next Steps for Enterprise Root CA:" -ForegroundColor Yellow
    Write-Host "    1. Root CA certificate is auto-published to AD" -ForegroundColor White
    Write-Host "    2. Configure certificate templates as needed" -ForegroundColor White
    Write-Host "    3. Configure subordinate/issuing CAs if using a two-tier hierarchy" -ForegroundColor White
    Write-Host ""
}
