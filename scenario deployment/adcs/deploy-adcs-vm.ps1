<#
.SYNOPSIS
    Step 1 of 2: Deploys a Windows Server 2022 VM for the ADCS scenario on
    Azure Cloud HSM or Azure Dedicated HSM.

.DESCRIPTION
    ADCS Scenario — Step 1 of 2: Deploy ADCS VM

    Creates a Windows Server 2022 Datacenter Gen2 VM in its own resource group,
    connected to the existing HSM platform VNet and subnet so it can communicate
    with the Admin VM. Authentication is username/password.

    After the VM is online, install the Azure Cloud HSM SDK (Cavium CNG/KSP)
    and then run Step 2 (configure-adcs.ps1) to configure the Root CA.

    Workflow:
      Step 1 — deploy-adcs-vm.ps1    (this script) Deploy the ADCS VM
      Step 2 — configure-adcs.ps1     Configure Root CA with Cavium KSP

    Supported platforms:
      - AzureCloudHSM     : Deploys into the Cloud HSM VNet  (CHSM-HSB-ADCS-VM)
      - AzureDedicatedHSM : Deploys into the Dedicated HSM VNet (DHSM-HSB-ADCS-VM)

    Prerequisites:
      - The HSM platform base deployment must already exist (VNet, subnet, Admin VM).
      - Az PowerShell module must be installed and authenticated.

.PARAMETER Platform
    The HSM platform whose VNet the ADCS VM will join (required).
    Valid values: AzureCloudHSM, AzureDedicatedHSM

.PARAMETER SubscriptionId
    The Azure subscription ID (required).

.PARAMETER Location
    Azure region override. If not specified, uses the value from the parameters file.

.PARAMETER AdminPassword
    Password for the VM admin account. If not provided, you will be prompted.

.PARAMETER AdminUsername
    Admin username (default: azureuser, matching the Admin VM).

.PARAMETER ParameterFile
    Path to the ARM parameters file. Defaults to the platform-specific
    parameters file (e.g., adcs-vm-parameters-cloudhsm.json).

.EXAMPLE
    .\deploy-adcs-vm.ps1 -Platform AzureCloudHSM -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    .\deploy-adcs-vm.ps1 -Platform AzureDedicatedHSM -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    .\deploy-adcs-vm.ps1 -Platform AzureCloudHSM -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -Location "East US" -AdminUsername "myadmin"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "HSM platform whose VNet the ADCS VM will join.")]
    [ValidateSet("AzureCloudHSM", "AzureDedicatedHSM")]
    [string]$Platform,

    [Parameter(Mandatory = $true, HelpMessage = "Azure subscription ID to deploy into.")]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false, HelpMessage = "Azure region override (e.g., 'UK West', 'East US').")]
    [string]$Location,

    [Parameter(Mandatory = $false, HelpMessage = "Admin password for the ADCS VM.")]
    [SecureString]$AdminPassword,

    [Parameter(Mandatory = $false, HelpMessage = "Admin username for the ADCS VM (default: azureuser).")]
    [string]$AdminUsername,

    [Parameter(Mandatory = $false, HelpMessage = "Path to the ARM parameters file.")]
    [string]$ParameterFile
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------
# Platform mapping
# ------------------------------------------------------------------
$platformMap = @{
    "AzureCloudHSM"     = @{ DisplayName = "Azure Cloud HSM";     Params = "adcs-vm-parameters-cloudhsm-rca.json" }
    "AzureDedicatedHSM"  = @{ DisplayName = "Azure Dedicated HSM"; Params = "adcs-vm-parameters-dedicatedhsm-rca.json" }
}

$platformInfo = $platformMap[$Platform]
$displayName = $platformInfo.DisplayName

# ------------------------------------------------------------------
# Banner
# ------------------------------------------------------------------
Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  ADCS Scenario — Step 1 of 2: Deploy ADCS VM"         -ForegroundColor Cyan
Write-Host "  Platform : $displayName"                             -ForegroundColor Cyan
Write-Host "  VM Image : Windows Server 2022 Datacenter Gen2"     -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""

# ------------------------------------------------------------------
# Resolve paths
# ------------------------------------------------------------------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$templateFile = Join-Path $scriptDir "adcs-vm-deploy.json"

if (-not $ParameterFile) {
    $ParameterFile = Join-Path $scriptDir $platformInfo.Params
}

if (-not (Test-Path $templateFile)) {
    Write-Error "ARM template not found: $templateFile"
    exit 1
}
if (-not (Test-Path $ParameterFile)) {
    Write-Error "Parameters file not found: $ParameterFile"
    exit 1
}

Write-Host "[INFO] Template file  : $templateFile" -ForegroundColor Gray
Write-Host "[INFO] Parameters file: $ParameterFile" -ForegroundColor Gray

# ------------------------------------------------------------------
# Read parameters file for defaults
# ------------------------------------------------------------------
$paramContent = Get-Content -Path $ParameterFile -Raw | ConvertFrom-Json
$paramValues = $paramContent.parameters

# Resolve location — track whether user explicitly provided it
$locationOverride = $PSBoundParameters.ContainsKey('Location')
if (-not $Location) {
    $Location = $paramValues.location.value
    Write-Host "[INFO] Using location from parameters file: $Location" -ForegroundColor Gray
}

# ------------------------------------------------------------------
# Prompt for password if not supplied
# ------------------------------------------------------------------
if (-not $AdminPassword) {
    Write-Host ""
    Write-Host "[INPUT] Create a new admin password for the ADCS VM." -ForegroundColor Yellow
    Write-Host "        (Tip: use a strong password with 12+ characters, mixed case, numbers, and symbols.)" -ForegroundColor Yellow
    $AdminPassword = Read-Host -AsSecureString -Prompt "Admin password"
    Write-Host ""
}

# Validate password is not empty
$plainCheck = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword)
)
if ([string]::IsNullOrWhiteSpace($plainCheck)) {
    Write-Error "Admin password cannot be empty."
    exit 1
}
# Clear plaintext from memory
$plainCheck = $null

# ------------------------------------------------------------------
# Build deployment parameter overrides
# ------------------------------------------------------------------
$deployParams = @{
    "adminPassword" = $AdminPassword
}

if ($AdminUsername) {
    $deployParams["adminUsername"] = $AdminUsername
}

# Only override location if the user explicitly passed -Location
if ($locationOverride) {
    $deployParams["location"] = $Location
}

# ------------------------------------------------------------------
# Set subscription context
# ------------------------------------------------------------------
Write-Host "[STEP 1/3] Setting Azure subscription context..." -ForegroundColor White
Set-AzContext -SubscriptionId $SubscriptionId -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
Write-Host "  Subscription: $SubscriptionId" -ForegroundColor Green

# Pre-import Az modules to suppress the "unapproved verbs" warning during auto-load.
# WarningPreference wrapper is needed because -DisableNameChecking does not propagate
# to nested modules (e.g. Microsoft.Azure.PowerShell.Cmdlets.Network inside Az.Network).
$savedWarningPref = $WarningPreference
$WarningPreference = 'SilentlyContinue'
Import-Module Az.Resources -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module Az.Network  -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module Az.Compute  -DisableNameChecking -ErrorAction SilentlyContinue
$WarningPreference = $savedWarningPref

# ------------------------------------------------------------------
# Pre-flight: verify the HSM platform VNet exists
# ------------------------------------------------------------------
$vnetRg     = $paramValues.existingVnetResourceGroupName.value
$vnetName   = $paramValues.existingVnetName.value
$subnetName = $paramValues.existingSubnetName.value

Write-Host "[PRE-FLIGHT] Checking for existing VNet '$vnetName' in '$vnetRg'..." -ForegroundColor White

$vnetExists = $false
try {
    $rg = Get-AzResourceGroup -Name $vnetRg -ErrorAction Stop -WarningAction SilentlyContinue
    $vnet = Get-AzVirtualNetwork -ResourceGroupName $vnetRg -Name $vnetName -ErrorAction Stop -WarningAction SilentlyContinue
    $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $subnetName }
    if ($subnet) {
        $vnetExists = $true
        Write-Host "  VNet '$vnetName' and subnet '$subnetName' found." -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "  ERROR: Subnet '$subnetName' not found in VNet '$vnetName'." -ForegroundColor Red
    }
} catch {
    # Resource group or VNet doesn't exist
}

if (-not $vnetExists) {
    Write-Host ""
    Write-Host "======================================================" -ForegroundColor Red
    Write-Host "  PREREQUISITE NOT MET" -ForegroundColor Red
    Write-Host "======================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "  $displayName must be deployed before running this script." -ForegroundColor Yellow
    Write-Host "  The ADCS VM requires the existing VNet and subnet created" -ForegroundColor Yellow
    Write-Host "  by the $displayName base deployment." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Deploy $displayName first:" -ForegroundColor White
    Write-Host "    .\deployhsm\deploy-hsm.ps1 -Platform $Platform -SubscriptionId `"$SubscriptionId`"" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Then re-run this script." -ForegroundColor White
    Write-Host ""
    exit 1
}

# ------------------------------------------------------------------
# Validate the template
# ------------------------------------------------------------------
Write-Host "[STEP 2/3] Validating ARM template..." -ForegroundColor White

$deploymentName = "adcs-vm-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

try {
    $validation = Test-AzSubscriptionDeployment `
        -Name $deploymentName `
        -Location $Location `
        -TemplateFile $templateFile `
        -TemplateParameterFile $ParameterFile `
        @deployParams `
        -ErrorAction Stop

    if ($validation.Count -gt 0) {
        Write-Host "  Validation warnings:" -ForegroundColor Yellow
        $validation | ForEach-Object { Write-Host "    - $($_.Message)" -ForegroundColor Yellow }
    } else {
        Write-Host "  Validation passed." -ForegroundColor Green
    }
} catch {
    Write-Error "Template validation failed: $_"
    exit 1
}

# ------------------------------------------------------------------
# Deploy
# ------------------------------------------------------------------
Write-Host "[STEP 3/3] Deploying ADCS VM ($displayName)..." -ForegroundColor White
Write-Host "  Deployment name: $deploymentName" -ForegroundColor Gray
Write-Host "  This may take 5-10 minutes..." -ForegroundColor Gray
Write-Host ""

try {
    $result = New-AzSubscriptionDeployment `
        -Name $deploymentName `
        -Location $Location `
        -TemplateFile $templateFile `
        -TemplateParameterFile $ParameterFile `
        @deployParams `
        -ErrorAction Stop

    Write-Host ""
    Write-Host "======================================================" -ForegroundColor Green
    Write-Host "  Step 1 Complete: ADCS VM Deployed ($displayName)" -ForegroundColor Green
    Write-Host "======================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Resource Group  : $($result.Outputs.adcsResourceGroupName.Value)" -ForegroundColor White
    Write-Host "  VM Name         : $($result.Outputs.vmName.Value)" -ForegroundColor White
    Write-Host "  Private IP      : $($result.Outputs.privateIpAddress.Value)" -ForegroundColor White
    Write-Host "  Public IP       : $($result.Outputs.publicIpAddress.Value)" -ForegroundColor White
    $resolvedUser = if ($AdminUsername) { $AdminUsername } else { $paramValues.adminUsername.value }
    Write-Host "  Admin Username  : $resolvedUser" -ForegroundColor White
    Write-Host "  RDP (Public)    : mstsc /v:$($result.Outputs.publicIpAddress.Value)" -ForegroundColor White
    Write-Host "  RDP (VPN)       : mstsc /v:$($result.Outputs.privateIpAddress.Value)" -ForegroundColor White
    Write-Host ""
    Write-Host "  The ADCS VM is on the same VNet/subnet as the $displayName Admin VM." -ForegroundColor Gray
    Write-Host ""
    Write-Host "  ────────────────────────────────────────────────────" -ForegroundColor Yellow
    Write-Host "  NEXT — Step 2 of 2: Configure Root CA" -ForegroundColor Yellow
    Write-Host "  ────────────────────────────────────────────────────" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Before running Step 2:" -ForegroundColor White
    Write-Host "    1. RDP into the ADCS VM" -ForegroundColor White
    if ($Platform -eq 'AzureCloudHSM') {
        Write-Host "    2. Install the Azure Cloud HSM SDK (Cavium CNG/KSP)" -ForegroundColor White
        Write-Host "    3. Verify: certutil -csplist | findstr Cavium" -ForegroundColor White
        Write-Host "" -ForegroundColor White
        Write-Host "  NOTE: Cloud HSM Crypto User credentials are required." -ForegroundColor Yellow
        Write-Host "        The configure script will prompt for them, or pass them directly:" -ForegroundColor Yellow
        Write-Host "          -HsmUsername `"cu1`" -HsmPassword (ConvertTo-SecureString `"user1234`" -AsPlainText -Force)" -ForegroundColor Gray
    } else {
        Write-Host "    2. Install the Thales Luna Appliance Software (Luna CNG/KSP)" -ForegroundColor White
        Write-Host "    3. Verify: certutil -csplist | findstr Luna" -ForegroundColor White
    }
    Write-Host ""
    Write-Host "  Then run on the ADCS VM:" -ForegroundColor White
    if ($Platform -eq 'AzureCloudHSM') {
        Write-Host "    .\configure-adcs.ps1 -CACommonName `"HSB-RootCA`" -HsmUsername `"cu1`" -HsmPassword (ConvertTo-SecureString `"user1234`" -AsPlainText -Force)" -ForegroundColor Cyan
    } else {
        Write-Host "    .\configure-adcs.ps1 -CACommonName `"HSB-RootCA`"" -ForegroundColor Cyan
    }
    Write-Host ""

} catch {
    $errMsg = $_.Exception.Message
    if ($errMsg -match 'InvalidResourceReference' -or $errMsg -match 'referenced by resource.*was not found') {
        Write-Host ""
        Write-Host "======================================================" -ForegroundColor Red
        Write-Host "  DEPLOYMENT FAILED - MISSING PREREQUISITE" -ForegroundColor Red
        Write-Host "======================================================" -ForegroundColor Red
        Write-Host ""
        Write-Host "  $displayName must be deployed before running this script." -ForegroundColor Yellow
        Write-Host "  The ADCS VM requires the existing VNet and subnet created" -ForegroundColor Yellow
        Write-Host "  by the $displayName base deployment." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Deploy $displayName first:" -ForegroundColor White
        Write-Host "    .\deployhsm\deploy-hsm.ps1 -Platform $Platform -SubscriptionId `"$SubscriptionId`"" -ForegroundColor Cyan
        Write-Host ""
    } else {
        Write-Error "Deployment failed: $errMsg"
    }
    exit 1
}
