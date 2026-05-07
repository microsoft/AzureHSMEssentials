<#
.SYNOPSIS
    Deploys HSM Scenario Builder infrastructure for Azure Cloud HSM, Azure Dedicated HSM,
    Azure Key Vault, Azure Managed HSM, or Azure Payment HSM.

.DESCRIPTION
    Universal deployment script that provisions the selected HSM platform using
    the corresponding ARM template under the deployhsm/<platform> subfolder.

    Supported platforms:
      - AzureCloudHSM      : Cloud HSM cluster with private endpoint and networking
      - AzureDedicatedHSM   : Dedicated HSM (Thales SafeNet Luna A790) with VNet injection
      - AzureKeyVault       : Key Vault with networking and diagnostics
      - AzureManagedHSM     : Managed HSM with private endpoint and networking
      - AzurePaymentHSM     : Payment HSM (Thales payShield 10K) with VNet injection

.PARAMETER Platform
    The HSM platform to deploy (required).
    Valid values: AzureCloudHSM, AzureDedicatedHSM, AzureKeyVault, AzureManagedHSM, AzurePaymentHSM

.PARAMETER SubscriptionId
    The Azure subscription ID to deploy into (required).

.PARAMETER Location
    Azure region override. If not specified, uses the value from the parameters file.

.PARAMETER ParameterFile
    Path to the ARM parameters file. Defaults to the platform-specific
    parameters file in the selected platform subfolder (e.g., cloudhsm-parameters.json).

.EXAMPLE
    .\deploy-hsm.ps1 -Platform AzureCloudHSM -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    .\deploy-hsm.ps1 -Platform AzureManagedHSM -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -Location "East US"

.EXAMPLE
    .\deploy-hsm.ps1 -Platform AzureKeyVault -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    .\deploy-hsm.ps1 -Platform AzureCloudHSM -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -AdminPasswordOrKey (Read-Host -AsSecureString -Prompt "Admin password") -AdminUsername "myadmin" -AuthenticationType password

.EXAMPLE
    .\deploy-hsm.ps1 -Platform AzureCloudHSM -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -EnableVpnGateway

.EXAMPLE
    .\deploy-hsm.ps1 -Platform AzureCloudHSM -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -ResourceTags @{'EnableHsmAuditPolicy'='true'}
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "HSM platform to deploy.")]
    [ValidateSet("AzureCloudHSM", "AzureDedicatedHSM", "AzureKeyVault", "AzureManagedHSM", "AzurePaymentHSM")]
    [string]$Platform,

    [Parameter(Mandatory = $true, HelpMessage = "Azure subscription ID to deploy into.")]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false, HelpMessage = "Azure region override (e.g., 'UK West', 'East US').")]
    [string]$Location,

    [Parameter(Mandatory = $false, HelpMessage = "Path to the ARM parameters file.")]
    [string]$ParameterFile,

    [Parameter(Mandatory = $false, HelpMessage = "SSH public key or password for the admin VM. If omitted, no admin VM is deployed.")]
    [SecureString]$AdminPasswordOrKey,

    [Parameter(Mandatory = $false, HelpMessage = "Admin username for the VM (default: azureuser).")]
    [string]$AdminUsername,

    [Parameter(Mandatory = $false, HelpMessage = "VM authentication type: sshPublicKey or password.")]
    [ValidateSet("sshPublicKey", "password")]
    [string]$AuthenticationType,

    [Parameter(Mandatory = $false, HelpMessage = "Comma-separated Entra ID object IDs for Managed HSM initial administrators (required for AzureManagedHSM).")]
    [string]$InitialAdminObjectIds,

    [Parameter(Mandatory = $false, HelpMessage = "Deploy a Point-to-Site VPN Gateway into the client VNet for remote access.")]
    [switch]$EnableVpnGateway,

    [Parameter(Mandatory = $false, HelpMessage = "Deploy certificate object storage (Blob Storage, Managed Identity, RBAC) for PKCS#11 applications. Cloud HSM only.")]
    [switch]$EnableCertificateStorage,

    [Parameter(Mandatory = $false, HelpMessage = "CIDR address pool for VPN clients (default: 192.168.100.0/24).")]
    [string]$VpnClientAddressPool = '192.168.100.0/24',

    [Parameter(Mandatory = $false, HelpMessage = "Hashtable of resource tags to apply to the Cloud HSM cluster (e.g., @{'EnableHsmAuditPolicy'='true'}).")]
    [hashtable]$ResourceTags,

    [Parameter(Mandatory = $false, HelpMessage = "VM size override (default: Standard_D2s_v3). Use when the default SKU is unavailable in the target region.")]
    [string]$VmSize = 'Standard_D2s_v3',

    [Parameter(Mandatory = $false, HelpMessage = "Azure region override for the Cloud HSM cluster (e.g., 'centraluseuap'). Defaults to the main location.")]
    [string]$HsmLocation
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------
# Platform display names and subfolder mapping
# ------------------------------------------------------------------
$platformMap = @{
    "AzureCloudHSM"     = @{ Folder = "azurecloudhsm";      DisplayName = "Azure Cloud HSM";      DeployPrefix = "chsm"; DefaultUser = "chsmVMAdmin"; VpnGwName = "chsm-vpn-gateway"; GwSubnet = "10.0.255.0/26";  Template = "cloudhsm-deploy.json";      Params = "cloudhsm-parameters.json" }
    "AzureDedicatedHSM"  = @{ Folder = "azuredededicatedhsm"; DisplayName = "Azure Dedicated HSM";  DeployPrefix = "dhsm"; DefaultUser = "dhsmVMAdmin"; VpnGwName = "dhsm-vpn-gateway"; GwSubnet = "10.3.255.0/26";  Template = "dedicatedhsm-deploy.json";  Params = "dedicatedhsm-parameters.json" }
    "AzureKeyVault"      = @{ Folder = "azurekeyvault";      DisplayName = "Azure Key Vault";      DeployPrefix = "akv";  DefaultUser = "akvVMAdmin";  VpnGwName = "akv-vpn-gateway";  GwSubnet = "10.2.255.0/26";  Template = "keyvault-deploy.json";      Params = "keyvault-parameters.json" }
    "AzureManagedHSM"    = @{ Folder = "azuremanagedhsm";    DisplayName = "Azure Managed HSM";    DeployPrefix = "mhsm"; DefaultUser = "mhsmVMAdmin"; VpnGwName = "mhsm-vpn-gateway"; GwSubnet = "10.1.255.0/26";  Template = "managedhsm-deploy.json";    Params = "managedhsm-parameters.json" }
    "AzurePaymentHSM"    = @{ Folder = "azurepaymentshsm";   DisplayName = "Azure Payment HSM";    DeployPrefix = "phsm"; DefaultUser = "phsmVMAdmin"; VpnGwName = "phsm-vpn-gateway"; GwSubnet = "10.4.255.0/26";  Template = "paymentshsm-deploy.json";   Params = "paymentshsm-parameters.json" }
}

$platformInfo = $platformMap[$Platform]
$displayName = $platformInfo.DisplayName
$deployPrefix = $platformInfo.DeployPrefix
$defaultUser = $platformInfo.DefaultUser

# ------------------------------------------------------------------
# Resolve paths
# ------------------------------------------------------------------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$platformDir = Join-Path $scriptDir $platformInfo.Folder
$templateFile = Join-Path $platformDir $platformInfo.Template

if (-not $ParameterFile) {
    $ParameterFile = Join-Path $platformDir $platformInfo.Params
}

if (-not (Test-Path $platformDir)) {
    Write-Error "Platform folder not found: $platformDir"
    exit 1
}
if (-not (Test-Path $templateFile)) {
    Write-Error "ARM template not found: $templateFile"
    exit 1
}
if (-not (Test-Path $ParameterFile)) {
    Write-Error "Parameters file not found: $ParameterFile"
    exit 1
}

# ------------------------------------------------------------------
# Read location from parameters file if not overridden
# ------------------------------------------------------------------
$locationOverridden = $PSBoundParameters.ContainsKey('Location')
if (-not $Location) {
    $params = Get-Content $ParameterFile -Raw | ConvertFrom-Json
    $Location = $params.parameters.location.value
    if (-not $Location) {
        Write-Error "No location specified. Provide -Location or set it in $ParameterFile."
        exit 1
    }
}

# ------------------------------------------------------------------
# Ensure Az module is available
# ------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Host "Az PowerShell module not found. Install with: Install-Module -Name Az -Scope CurrentUser" -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------
# Connect and set subscription
# ------------------------------------------------------------------
Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  HSM Scenario Builder - $displayName Deployment" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Platform     : $displayName"
Write-Host "Subscription : $SubscriptionId"
Write-Host "Location     : $Location"
Write-Host "Template     : $templateFile"
Write-Host "Parameters   : $ParameterFile"
$deployVm = $PSBoundParameters.ContainsKey('AdminPasswordOrKey')
if ($deployVm) {
    Write-Host "Admin VM     : Enabled (credential provided)"
} else {
    Write-Host "Admin VM     : Skipped (no -AdminPasswordOrKey)"
}
if ($Platform -eq 'AzureManagedHSM') {
    if ($InitialAdminObjectIds) {
        Write-Host "MHSM Admins  : $InitialAdminObjectIds"
    } else {
        Write-Host "MHSM Admins  : (from parameters file)"
    }
}
if ($EnableVpnGateway) {
    Write-Host "VPN Gateway  : Enabled (P2S with OpenVPN)"
    Write-Host "VPN Pool     : $VpnClientAddressPool"
} else {
    Write-Host "VPN Gateway  : Skipped (no -EnableVpnGateway)"
}
if ($Platform -eq 'AzureCloudHSM') {
    if ($EnableCertificateStorage) {
        Write-Host "Cert Storage : Enabled (Blob + Managed Identity + RBAC)"
    } else {
        Write-Host "Cert Storage : Skipped (no -EnableCertificateStorage)"
    }
    if ($ResourceTags) {
        Write-Host "Resource Tags: $($ResourceTags.Keys -join ', ')"
    }
    if ($HsmLocation) {
        Write-Host "HSM Location : $HsmLocation"
    }
}
if ($PSBoundParameters.ContainsKey('VmSize') -and $VmSize -ne 'Standard_D2s_v3') {
    Write-Host "VM Size      : $VmSize (override)"
}
Write-Host ""

# ------------------------------------------------------------------
# Step tracking
# ------------------------------------------------------------------
$totalSteps = 2  # Always: Auth + Infrastructure
if ($deployVm)        { $totalSteps++ }  # Optional: Admin VM
if ($EnableVpnGateway) { $totalSteps++ }  # Optional: VPN Gateway
$currentStep = 0

# ------------------------------------------------------------------
# Step 1: Authenticate and set subscription
# ------------------------------------------------------------------
$currentStep++
Write-Host "Step ${currentStep}/${totalSteps}: Authenticating and setting subscription context..." -ForegroundColor Cyan
Write-Host ""

$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Write-Host "  Not logged in to Azure. Launching login..." -ForegroundColor Yellow
    Connect-AzAccount -ErrorAction Stop
}

try {
    Set-AzContext -SubscriptionId $SubscriptionId -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
}
catch {
    Write-Host "  Session expired or subscription not accessible. Re-authenticating..." -ForegroundColor Yellow
    Connect-AzAccount -Subscription $SubscriptionId -ErrorAction Stop
    Set-AzContext -SubscriptionId $SubscriptionId -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
}
Write-Host "  Active subscription: $((Get-AzContext).Subscription.Name) ($SubscriptionId)" -ForegroundColor Green

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
# Pre-flight: check for resource groups still being deleted
# ------------------------------------------------------------------
# After an uninstall, Azure may still be deprovisioning resource groups.
# Deploying into a group that is mid-deletion will fail with
# ResourceGroupBeingDeleted.  We detect this and wait automatically.
$rgParamKeys = @('clientResourceGroupName', 'serverResourceGroupName', 'adminVmResourceGroupName', 'logsResourceGroupName', 'certResourceGroupName')
$paramJson = Get-Content $ParameterFile -Raw | ConvertFrom-Json
$targetRGs = @()
foreach ($key in $rgParamKeys) {
    if ($paramJson.parameters.PSObject.Properties[$key]) {
        $targetRGs += $paramJson.parameters.$key.value
    }
}

if ($targetRGs.Count -gt 0) {
    $maxWaitSeconds = 300   # 5 minutes
    $pollInterval   = 15    # seconds between checks
    $elapsed        = 0
    $deletingRGs    = @()

    # Initial check
    foreach ($rgName in $targetRGs) {
        $rg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
        if ($rg -and $rg.ProvisioningState -eq 'Deleting') {
            $deletingRGs += $rgName
        }
    }

    if ($deletingRGs.Count -gt 0) {
        Write-Host ""
        Write-Host "  Waiting for resource group cleanup to finish..." -ForegroundColor Yellow
        Write-Host "  The following groups are still being deleted from a previous uninstall:" -ForegroundColor Yellow
        foreach ($rgName in $deletingRGs) {
            Write-Host "    - $rgName" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "  Will retry every ${pollInterval}s for up to ${maxWaitSeconds}s." -ForegroundColor Gray

        while ($deletingRGs.Count -gt 0 -and $elapsed -lt $maxWaitSeconds) {
            Start-Sleep -Seconds $pollInterval
            $elapsed += $pollInterval
            $stillDeleting = @()
            foreach ($rgName in $deletingRGs) {
                $rg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
                if ($rg -and $rg.ProvisioningState -eq 'Deleting') {
                    $stillDeleting += $rgName
                }
            }
            $deletingRGs = $stillDeleting
            if ($deletingRGs.Count -gt 0) {
                $remaining = $maxWaitSeconds - $elapsed
                Write-Host "  Still waiting... ${elapsed}s elapsed, ${remaining}s remaining ($($deletingRGs.Count) group(s) pending)" -ForegroundColor Gray
            }
        }

        if ($deletingRGs.Count -gt 0) {
            Write-Host ""
            Write-Host "================================================" -ForegroundColor Red
            Write-Host "  DEPLOYMENT BLOCKED" -ForegroundColor Red
            Write-Host "================================================" -ForegroundColor Red
            Write-Host ""
            Write-Host "  The following resource groups are still being deleted after ${maxWaitSeconds}s:" -ForegroundColor Red
            foreach ($rgName in $deletingRGs) {
                Write-Host "    - $rgName" -ForegroundColor Red
            }
            Write-Host ""
            Write-Host "  Azure is still deprovisioning resources from a previous uninstall." -ForegroundColor Yellow
            Write-Host "  Please wait a few more minutes and try again." -ForegroundColor Yellow
            Write-Host ""
            exit 1
        }

        Write-Host "  All resource groups cleared. Proceeding with deployment." -ForegroundColor Green
        Write-Host ""
    }
}

Write-Host "  Step ${currentStep}/${totalSteps} complete." -ForegroundColor Green

# ------------------------------------------------------------------
# Step 2: Deploy infrastructure (ARM template)
# ------------------------------------------------------------------
$currentStep++
$deploymentName = "$deployPrefix-deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$mainDeploySucceeded = $false
$mainDeployPartial   = $false   # Resources exist but private endpoint re-apply failed

Write-Host ""
Write-Host "Step ${currentStep}/${totalSteps}: Deploying $displayName infrastructure..." -ForegroundColor Cyan
Write-Host "  Deployment: $deploymentName" -ForegroundColor Yellow
Write-Host "  This may take 10-20 minutes..." -ForegroundColor Yellow
Write-Host ""

try {
    # Build deployment parameters - use splatting so we can conditionally
    # add VM authentication parameters without changing the base call.
    #
    # When -Location is explicitly provided, we must read the parameter file
    # into a hashtable and override the location value, because the cmdlet's
    # own -Location parameter (subscription deployment metadata) collides
    # with the ARM template's 'location' parameter.
    # NOTE: When using TemplateParameterObject, ALL template param overrides
    # must go into the $templateParams hashtable (not $deployParams), because
    # dynamic template parameters cannot be mixed with -TemplateParameterObject.
    if ($locationOverridden) {
        $paramFileJson = Get-Content $ParameterFile -Raw | ConvertFrom-Json
        $templateParams = @{}
        foreach ($p in $paramFileJson.parameters.PSObject.Properties) {
            $templateParams[$p.Name] = $p.Value.value
        }
        $templateParams['location'] = $Location

        $deployParams = @{
            Name                    = $deploymentName
            Location                = $Location
            TemplateFile            = $templateFile
            TemplateParameterObject = $templateParams
            ErrorAction             = 'Stop'
            Verbose                 = $true
        }
    } else {
        $templateParams = $null
        $deployParams = @{
            Name                  = $deploymentName
            Location              = $Location
            TemplateFile          = $templateFile
            TemplateParameterFile = $ParameterFile
            ErrorAction           = 'Stop'
            Verbose               = $true
        }
    }

    # Helper: add a template parameter override to the correct target.
    # When using TemplateParameterObject, overrides go into $templateParams.
    # When using TemplateParameterFile, overrides go into $deployParams as dynamic params.
    function Add-TemplateParam([string]$Name, $Value) {
        if ($templateParams) { $templateParams[$Name] = $Value }
        else                 { $deployParams[$Name]   = $Value }
    }

    # Add VM authentication parameters when provided
    if ($deployVm) {
        Add-TemplateParam 'adminPasswordOrKey' $AdminPasswordOrKey
        if ($AdminUsername)        { Add-TemplateParam 'adminUsername'       $AdminUsername }
        if ($AuthenticationType)   { Add-TemplateParam 'authenticationType'  $AuthenticationType }
    }

    # Add Managed HSM initial admin object IDs when provided
    if ($Platform -eq 'AzureManagedHSM' -and $InitialAdminObjectIds) {
        $idsArray = @($InitialAdminObjectIds -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($idsArray.Count -eq 0) {
            throw 'AzureManagedHSM requires at least one Entra ID object ID in -InitialAdminObjectIds.'
        }
        Add-TemplateParam 'initialAdminObjectIds' $idsArray
    }

    # Add certificate storage flag when enabled (Cloud HSM only)
    if ($EnableCertificateStorage) {
        if ($Platform -ne 'AzureCloudHSM') {
            Write-Host "  WARNING: -EnableCertificateStorage is only supported for AzureCloudHSM. Ignoring." -ForegroundColor Yellow
        } else {
            Add-TemplateParam 'enableCertificateStorage' $true
        }
    }

    # Add resource tags when provided (Cloud HSM only)
    if ($ResourceTags) {
        if ($Platform -ne 'AzureCloudHSM') {
            Write-Host "  WARNING: -ResourceTags is only supported for AzureCloudHSM. Ignoring." -ForegroundColor Yellow
        } else {
            Add-TemplateParam 'resourceTags' $ResourceTags
        }
    }

    # Override VM size when explicitly provided
    if ($PSBoundParameters.ContainsKey('VmSize')) {
        Add-TemplateParam 'vmSize' $VmSize
    }

    # Override HSM cluster location when provided (Cloud HSM only)
    if ($HsmLocation) {
        if ($Platform -ne 'AzureCloudHSM') {
            Write-Host "  WARNING: -HsmLocation is only supported for AzureCloudHSM. Ignoring." -ForegroundColor Yellow
        } else {
            Add-TemplateParam 'hsmLocation' $HsmLocation
        }
    }

    $result = New-AzSubscriptionDeployment @deployParams

    # Double-check provisioning state even if no exception was thrown
    if ($result.ProvisioningState -ne 'Succeeded') {
        throw "Deployment finished with state: $($result.ProvisioningState)"
    }

    Write-Host ""
    Write-Host "================================================" -ForegroundColor Green
    Write-Host "  Deployment Succeeded - $displayName" -ForegroundColor Green
    Write-Host "================================================" -ForegroundColor Green
    Write-Host ""

    # Display all deployment outputs (skip keys shown in dedicated sections below)
    $skipKeys = @('adminVmName', 'storageAccountName', 'logAnalyticsWorkspaceName')
    if ($result.Outputs -and $result.Outputs.Count -gt 0) {
        foreach ($key in $result.Outputs.Keys) {
            if ($skipKeys -contains $key) { continue }
            $label = $key.PadRight(22)
            $value = $result.Outputs[$key].Value
            Write-Host "  $label : $value"
        }
        Write-Host ""
    }

    # ------------------------------------------------------------------
    # Platform-specific post-deployment info
    # ------------------------------------------------------------------
    if ($Platform -eq "AzureCloudHSM") {
        # Display private endpoint FQDN details by querying the DNS zone group
        $peName = $result.Outputs.privateEndpointName.Value
        $clientRgName = $result.Outputs.clientResourceGroupName.Value
        if ($peName -and $clientRgName) {
            try {
                $dnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $clientRgName -PrivateEndpointName $peName -ErrorAction Stop -WarningAction SilentlyContinue
                $recordSets = $dnsZoneGroup.PrivateDnsZoneConfigs[0].RecordSets
                if ($recordSets -and $recordSets.Count -gt 0) {
                    Write-Host "  Private Endpoint DNS Configuration:" -ForegroundColor Cyan
                    $hsmIndex = 1
                    foreach ($record in $recordSets) {
                        $fqdn = $record.Fqdn
                        $ips = ($record.IpAddresses -join ', ')
                        if ($fqdn) {
                            Write-Host "    HSM${hsmIndex} : [$ips] -> $fqdn"
                            $hsmIndex++
                        }
                    }
                    Write-Host ""
                }
            }
            catch {
                Write-Host "  (Could not retrieve DNS configuration for private endpoint.)" -ForegroundColor Yellow
            }
        }

        # Display diagnostic logging info
        $saName  = if ($result.Outputs.storageAccountName)    { $result.Outputs.storageAccountName.Value }    else { $null }
        $laName  = if ($result.Outputs.logAnalyticsWorkspaceName) { $result.Outputs.logAnalyticsWorkspaceName.Value } else { $null }
        if ($saName -or $laName) {
            Write-Host "  Diagnostic Logging:" -ForegroundColor Cyan
            if ($saName) { Write-Host "    Storage Account    : $saName" }
            if ($laName) { Write-Host "    Log Analytics      : $laName" }
            Write-Host ""
        }

        Write-Host '  NOTE: Download and install the latest Azure Cloud HSM SDK from GitHub on your Admin VM,' -ForegroundColor Yellow
        Write-Host '        then update the hostname entry in the azcloudhsm_resource.cfg file to the FQDN' -ForegroundColor Yellow
        Write-Host '        of HSM1 listed above and complete remaining steps in the Cloud HSM Onboarding Guide.' -ForegroundColor Yellow

        # Display certificate object storage info (if enabled)
        $certContainerUrl = if ($result.Outputs.certContainerUrl) { $result.Outputs.certContainerUrl.Value } else { $null }
        $certClientId     = if ($result.Outputs.certManagedIdentityClientId) { $result.Outputs.certManagedIdentityClientId.Value } else { $null }
        $certSaName       = if ($result.Outputs.certStorageAccountName) { $result.Outputs.certStorageAccountName.Value } else { $null }
        $certIdName       = if ($result.Outputs.certManagedIdentityName) { $result.Outputs.certManagedIdentityName.Value } else { $null }
        if ($certContainerUrl -or $certClientId) {
            Write-Host ''
            Write-Host '  Certificate Object Storage:' -ForegroundColor Cyan
            if ($certSaName)       { Write-Host "    Storage Account    : $certSaName" }
            if ($certContainerUrl) { Write-Host "    Container URL      : $certContainerUrl" }
            if ($certIdName)       { Write-Host "    Managed Identity   : $certIdName" }
            if ($certClientId)     { Write-Host "    MI Client ID       : $certClientId" }
            Write-Host ''
            Write-Host '  Update azcloudhsm_application.cfg on the Admin VM with the Container URL' -ForegroundColor Yellow
            Write-Host '  and Managed Identity Client ID listed above to enable PKCS#11 certificate' -ForegroundColor Yellow
            Write-Host '  object storage.' -ForegroundColor Yellow
        }
    }

    if ($Platform -eq "AzureManagedHSM") {
        # Display Managed HSM URI
        $hsmUri = $result.Outputs.managedHsmUri.Value
        if ($hsmUri) {
            Write-Host "  Managed HSM URI: $hsmUri" -ForegroundColor Cyan
            Write-Host ""
        }

        # Display private endpoint FQDN details (if private endpoint was deployed)
        $peName = if ($result.Outputs.privateEndpointName) { $result.Outputs.privateEndpointName.Value } else { $null }
        $clientRgName = $result.Outputs.clientResourceGroupName.Value
        if ($peName -and $clientRgName) {
            try {
                $dnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $clientRgName -PrivateEndpointName $peName -ErrorAction Stop -WarningAction SilentlyContinue
                $recordSets = $dnsZoneGroup.PrivateDnsZoneConfigs[0].RecordSets
                if ($recordSets -and $recordSets.Count -gt 0) {
                    Write-Host "  Private Endpoint DNS Configuration:" -ForegroundColor Cyan
                    foreach ($record in $recordSets) {
                        $fqdn = $record.Fqdn
                        $ips = ($record.IpAddresses -join ', ')
                        if ($fqdn) {
                            Write-Host "    [$ips] -> $fqdn"
                        }
                    }
                    Write-Host ""
                }
            }
            catch {
                Write-Host "  (Could not retrieve DNS configuration for private endpoint.)" -ForegroundColor Yellow
            }
        }

        # Display diagnostic logging info
        $saName  = if ($result.Outputs.storageAccountName)    { $result.Outputs.storageAccountName.Value }    else { $null }
        $laName  = if ($result.Outputs.logAnalyticsWorkspaceName) { $result.Outputs.logAnalyticsWorkspaceName.Value } else { $null }
        if ($saName -or $laName) {
            Write-Host "  Diagnostic Logging:" -ForegroundColor Cyan
            if ($saName) { Write-Host "    Storage Account    : $saName" }
            if ($laName) { Write-Host "    Log Analytics      : $laName" }
            Write-Host ""
        }

        Write-Host '  NOTE: Azure Managed HSM uses Entra ID RBAC-only authentication.' -ForegroundColor Yellow
        Write-Host '        Assign additional roles via: az keyvault role assignment create --hsm-name <name> ...' -ForegroundColor Yellow
        Write-Host '        The HSM must be activated with security domain download before use.' -ForegroundColor Yellow
    }

    if ($Platform -eq "AzureDedicatedHSM") {
        # Display Dedicated HSM resource info
        $hsmName = if ($result.Outputs.dedicatedHsmName) { $result.Outputs.dedicatedHsmName.Value } else { $null }
        $hsmSku  = if ($result.Outputs.dedicatedHsmSku)  { $result.Outputs.dedicatedHsmSku.Value }  else { $null }
        if ($hsmName) {
            Write-Host "  Dedicated HSM Name: $hsmName" -ForegroundColor Cyan
        }
        if ($hsmSku) {
            Write-Host "  SKU               : $hsmSku" -ForegroundColor Cyan
        }
        Write-Host ""

        # Display ExpressRoute Gateway info
        $erGw = if ($result.Outputs.erGatewayName) { $result.Outputs.erGatewayName.Value } else { $null }
        if ($erGw) {
            Write-Host "  ExpressRoute Gateway: $erGw" -ForegroundColor Cyan
            Write-Host ""
        }

        Write-Host '  NOTE: Azure Dedicated HSM uses Thales SafeNet Luna Network HSM A790.' -ForegroundColor Yellow
        Write-Host '        This is a bare-metal device -- Azure Monitor/Log Analytics is NOT supported.' -ForegroundColor Yellow
        Write-Host '        Configure logging via the Luna client tools (syslog, SNMP).' -ForegroundColor Yellow
        Write-Host '        The HSM is accessed via its private IP on the delegated hsmSubnet.' -ForegroundColor Yellow
        Write-Host '        The ERGW must exist so the service can create a VNIC for HSM connectivity.' -ForegroundColor Yellow
    }

    if ($Platform -eq "AzureKeyVault") {
        # Display Key Vault URI and SKU
        $kvUri = $result.Outputs.keyVaultUri.Value
        $kvSku = $result.Outputs.skuName.Value
        if ($kvUri) {
            Write-Host "  Key Vault URI: $kvUri" -ForegroundColor Cyan
        }
        if ($kvSku) {
            Write-Host "  SKU          : $kvSku ($(if ($kvSku -eq 'premium') { 'HSM-backed keys' } else { 'software-protected keys' }))" -ForegroundColor Cyan
        }
        Write-Host ""

        # Display private endpoint FQDN details (if private endpoint was deployed)
        $peName = if ($result.Outputs.privateEndpointName) { $result.Outputs.privateEndpointName.Value } else { $null }
        $clientRgName = $result.Outputs.clientResourceGroupName.Value
        if ($peName -and $clientRgName) {
            try {
                $dnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $clientRgName -PrivateEndpointName $peName -ErrorAction Stop -WarningAction SilentlyContinue
                $recordSets = $dnsZoneGroup.PrivateDnsZoneConfigs[0].RecordSets
                if ($recordSets -and $recordSets.Count -gt 0) {
                    Write-Host "  Private Endpoint DNS Configuration:" -ForegroundColor Cyan
                    foreach ($record in $recordSets) {
                        $fqdn = $record.Fqdn
                        $ips = ($record.IpAddresses -join ', ')
                        if ($fqdn) {
                            Write-Host "    [$ips] -> $fqdn"
                        }
                    }
                    Write-Host ""
                }
            }
            catch {
                Write-Host "  (Could not retrieve DNS configuration for private endpoint.)" -ForegroundColor Yellow
            }
        }

        # Display diagnostic logging info
        $saName  = if ($result.Outputs.storageAccountName)    { $result.Outputs.storageAccountName.Value }    else { $null }
        $laName  = if ($result.Outputs.logAnalyticsWorkspaceName) { $result.Outputs.logAnalyticsWorkspaceName.Value } else { $null }
        if ($saName -or $laName) {
            Write-Host "  Diagnostic Logging:" -ForegroundColor Cyan
            if ($saName) { Write-Host "    Storage Account    : $saName" }
            if ($laName) { Write-Host "    Log Analytics      : $laName" }
            Write-Host ""
        }

        Write-Host '  NOTE: Azure Key Vault uses Entra ID RBAC-only authentication.' -ForegroundColor Yellow
        Write-Host '        Assign roles via: az role assignment create --role "Key Vault Crypto Officer" ...' -ForegroundColor Yellow
    }

    if ($Platform -eq "AzurePaymentHSM") {
        # Display Payment HSM resource info
        $hsmName = if ($result.Outputs.paymentHsmName) { $result.Outputs.paymentHsmName.Value } else { $null }
        if ($hsmName) {
            Write-Host "  Payment HSM Name: $hsmName" -ForegroundColor Cyan
            Write-Host ""
        }

        Write-Host '  NOTE: Azure Payment HSM uses Thales payShield 10K for payment processing.' -ForegroundColor Yellow
        Write-Host '        This is a bare-metal device -- Azure Monitor/Log Analytics is NOT supported.' -ForegroundColor Yellow
        Write-Host '        Configure logging via the payShield Manager console.' -ForegroundColor Yellow
        Write-Host '        The HSM has separate data (hsmSubnet) and management (hsmMgmtSubnet) interfaces.' -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Deployment complete. Your $displayName environment is ready for testing." -ForegroundColor Cyan
    Write-Host "See the platform README under deployhsm/ for post-deployment steps." -ForegroundColor Cyan

    $mainDeploySucceeded = $true
    Write-Host ""
    Write-Host "  Step ${currentStep}/${totalSteps} complete." -ForegroundColor Green
}
catch {
    $errMsg = $_.Exception.Message

    # Friendly message for resource groups still being deleted from a previous uninstall
    if ($errMsg -match 'ResourceGroupBeingDeleted' -or $errMsg -match 'deprovisioning state') {
        Write-Host ""
        Write-Host "================================================" -ForegroundColor Red
        Write-Host "  DEPLOYMENT BLOCKED - Resource Group Still Deleting" -ForegroundColor Red
        Write-Host "================================================" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Azure is still removing resource groups from a previous uninstall." -ForegroundColor Yellow
        Write-Host "  This usually takes 2-5 minutes after an uninstall completes." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Wait a few minutes and re-run:" -ForegroundColor Cyan
        Write-Host "    .\deploy-hsm.ps1 -Platform $Platform -SubscriptionId `"$SubscriptionId`" ..." -ForegroundColor Gray
        Write-Host ""
        exit 1
    }

    # Private endpoint already exists - resources are deployed, just the PE
    # re-apply failed.  Mark as partial so VPN Gateway can still proceed.
    if ($errMsg -match 'CannotChangePrivateLinkConnection') {
        $mainDeployPartial = $true
        Write-Host ""
        Write-Host "================================================" -ForegroundColor Yellow
        Write-Host "  Deployment Partially Succeeded - $displayName" -ForegroundColor Yellow
        Write-Host "================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Core resources are already deployed. The private endpoint connection" -ForegroundColor Yellow
        Write-Host "  cannot be re-applied because it already exists. This is expected" -ForegroundColor Yellow
        Write-Host "  when re-running the deployment on an existing environment." -ForegroundColor Yellow
        Write-Host ""
    } else {
        Write-Host ""
        Write-Host "================================================" -ForegroundColor Red
        Write-Host "  Deployment Failed - $displayName" -ForegroundColor Red
        Write-Host "================================================" -ForegroundColor Red
        Write-Host ""
        Write-Host $errMsg -ForegroundColor Red
        Write-Host ""
        Write-Host "Check the deployment in the Azure Portal:" -ForegroundColor Yellow
        Write-Host ('  Subscriptions > ' + $SubscriptionId + ' > Deployments > ' + $deploymentName) -ForegroundColor Yellow
        exit 1
    }
}

# ------------------------------------------------------------------
# Step N: Validate Admin VM deployment (optional)
# ------------------------------------------------------------------
if ($deployVm -and ($mainDeploySucceeded -or $mainDeployPartial)) {
    $currentStep++
    Write-Host ""
    Write-Host "Step ${currentStep}/${totalSteps}: Validating Admin VM deployment..." -ForegroundColor Cyan
    Write-Host ""

    $adminVmDeployed = $false
    $vmRg = $null
    $vmNameOut = $null

    # Get VM details from deployment outputs (available when main deployment succeeded)
    if ($mainDeploySucceeded -and $result.Outputs.adminVmResourceGroupName -and $result.Outputs.adminVmName) {
        $vmRg = $result.Outputs.adminVmResourceGroupName.Value
        $vmNameOut = $result.Outputs.adminVmName.Value
    }

    if ($vmRg -and $vmNameOut) {
        try {
            $nicName = "${vmNameOut}-nic"
            $nic = Get-AzNetworkInterface -ResourceGroupName $vmRg -Name $nicName -ErrorAction Stop -WarningAction SilentlyContinue
            $privateIp = $nic.IpConfigurations[0].PrivateIpAddress
            $publicIp = $null
            $pipRef = $nic.IpConfigurations[0].PublicIpAddress
            if ($pipRef) {
                $pipResource = Get-AzPublicIpAddress -ResourceGroupName $vmRg -Name "${vmNameOut}-pip" -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                if ($pipResource) { $publicIp = $pipResource.IpAddress }
            }
            $connectIp = if ($publicIp -and $publicIp -ne 'Not Assigned') { $publicIp } else { $privateIp }
            $user = if ($AdminUsername) { $AdminUsername } else { $defaultUser }
            $authType = if ($AuthenticationType) { $AuthenticationType } else { 'sshPublicKey' }

            Write-Host "  ================================================" -ForegroundColor Green
            Write-Host "  Admin VM Deployed Successfully" -ForegroundColor Green
            Write-Host "  ================================================" -ForegroundColor Green
            Write-Host ""
            Write-Host "  Name            : $vmNameOut" -ForegroundColor White
            Write-Host "  Resource Group  : $vmRg" -ForegroundColor White
            Write-Host "  Private IP      : $privateIp" -ForegroundColor White
            if ($publicIp -and $publicIp -ne 'Not Assigned') {
                Write-Host "  Public IP       : $publicIp" -ForegroundColor White
            }
            Write-Host ""
            if ($authType -eq 'sshPublicKey') {
                Write-Host "  Connect: ssh ${user}@${connectIp}" -ForegroundColor Yellow
            } else {
                Write-Host "  Connect (SSH): ssh ${user}@${connectIp}" -ForegroundColor Yellow
                Write-Host "  Connect (RDP): mstsc /v:${connectIp}" -ForegroundColor Yellow
                Write-Host "  Username      : $user" -ForegroundColor Yellow
            }
            Write-Host ""
            $adminVmDeployed = $true
            Write-Host "  Step ${currentStep}/${totalSteps} complete." -ForegroundColor Green
        }
        catch {
            Write-Host "  ================================================" -ForegroundColor Red
            Write-Host "  Admin VM Validation Failed" -ForegroundColor Red
            Write-Host "  ================================================" -ForegroundColor Red
            Write-Host ""
            Write-Host "  Could not retrieve Admin VM network details." -ForegroundColor Yellow
            Write-Host "  VM Name: $vmNameOut  |  RG: $vmRg" -ForegroundColor Yellow
            Write-Host "  Check the Azure Portal for the VM status." -ForegroundColor Yellow
            Write-Host ""
        }
    } else {
        Write-Host "  ================================================" -ForegroundColor Red
        Write-Host "  Admin VM Not Found" -ForegroundColor Red
        Write-Host "  ================================================" -ForegroundColor Red
        Write-Host ""
        Write-Host "  The Admin VM was requested but could not be found in deployment outputs." -ForegroundColor Yellow
        Write-Host "  The infrastructure deployment may have failed before creating the VM." -ForegroundColor Yellow
        Write-Host "  Check the deployment in the Azure Portal for details." -ForegroundColor Yellow
        Write-Host ""
    }
}

# ------------------------------------------------------------------
# Step N: Deploy Point-to-Site VPN Gateway (optional, always last)
# ------------------------------------------------------------------
if ($EnableVpnGateway -and ($mainDeploySucceeded -or $mainDeployPartial)) {
    $currentStep++
    Write-Host ""
    Write-Host "Step ${currentStep}/${totalSteps}: Deploying P2S VPN Gateway..." -ForegroundColor Cyan
    Write-Host ""

    $vpnGwName    = $platformInfo.VpnGwName
    $gwSubnet     = $platformInfo.GwSubnet
    $vpnTemplate  = Join-Path $scriptDir "vpngateway\P2S VPN Gateway\vpngw-deploy.json"
    $clientRgName = $paramJson.parameters.clientResourceGroupName.value
    $vnetName     = $paramJson.parameters.vnetName.value

    if (-not (Test-Path $vpnTemplate)) {
        Write-Host "VPN Gateway ARM template not found: $vpnTemplate" -ForegroundColor Red
        Write-Host "Skipping VPN Gateway deployment." -ForegroundColor Yellow
    } else {
        # For Dedicated HSM the GatewaySubnet already exists (ExpressRoute).
        # The VPN template will update it to add the VPN Gateway alongside.
        $vpnDeployName = "$deployPrefix-vpngw-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

        Write-Host "  VPN Gateway    : $vpnGwName" -ForegroundColor White
        Write-Host "  GatewaySubnet  : $gwSubnet" -ForegroundColor White
        Write-Host "  Client Pool    : $VpnClientAddressPool" -ForegroundColor White
        Write-Host "  Target RG      : $clientRgName" -ForegroundColor White
        Write-Host "  Target VNet    : $vnetName" -ForegroundColor White
        Write-Host ""
        Write-Host "  VPN Gateway provisioning typically takes 20-45 minutes." -ForegroundColor Yellow
        Write-Host "  Please be patient..." -ForegroundColor Yellow
        Write-Host ""

        # ---- Pre-create GatewaySubnet via PowerShell (avoids ARM subnet-reset issues) ----
        $existingGwSubnet = Get-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' `
            -VirtualNetwork (Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $clientRgName) `
            -ErrorAction SilentlyContinue
        if ($existingGwSubnet) {
            Write-Host "  GatewaySubnet already exists ($($existingGwSubnet.AddressPrefix)) - skipping creation." -ForegroundColor Yellow
        } else {
            Write-Host "  Creating GatewaySubnet ($gwSubnet) on $vnetName..." -ForegroundColor White
            $vnetObj = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $clientRgName
            Add-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -AddressPrefix $gwSubnet -VirtualNetwork $vnetObj | Out-Null
            $vnetObj | Set-AzVirtualNetwork | Out-Null
            Write-Host "  GatewaySubnet created." -ForegroundColor Green
        }
        Write-Host ""

        # ---- Pre-flight: clean up orphaned non-zonal PIP from a prior failed deployment ----
        $pipName = "${vpnGwName}-pip"
        $existingPip = Get-AzPublicIpAddress -ResourceGroupName $clientRgName -Name $pipName -ErrorAction SilentlyContinue
        if ($existingPip -and $existingPip.Zones.Count -eq 0) {
            # Check the PIP is not attached to a working gateway
            $existingGw = Get-AzVirtualNetworkGateway -ResourceGroupName $clientRgName -Name $vpnGwName -ErrorAction SilentlyContinue
            if (-not $existingGw) {
                Write-Host "  Removing orphaned non-zonal public IP '$pipName' from a previous failed deployment..." -ForegroundColor Yellow
                Remove-AzPublicIpAddress -ResourceGroupName $clientRgName -Name $pipName -Force
                Write-Host "  Removed. Will be recreated with zone redundancy." -ForegroundColor Green
                Write-Host ""
            }
        }

        try {
            # Auto-detect availability zone support for the target region
            $azProvider = Get-AzResourceProvider -ProviderNamespace Microsoft.Network -ErrorAction SilentlyContinue
            $pipType = $azProvider.ResourceTypes | Where-Object { $_.ResourceTypeName -eq 'publicIPAddresses' }
            $regionSupportsAZ = ($pipType.ZoneMappings | Where-Object { $_.Location -eq $Location }).Zones.Count -gt 0

            # Azure requires AZ SKUs for all new VPN Gateways; zones on the public IP are optional
            if ($regionSupportsAZ) {
                Write-Host "  Region '$Location' supports availability zones - deploying zone-redundant gateway." -ForegroundColor Green
            } else {
                Write-Host "  Region '$Location' does not support availability zones - deploying AZ SKU gateway without zonal public IP." -ForegroundColor Yellow
            }
            Write-Host ""

            $vpnResult = New-AzResourceGroupDeployment `
                -Name $vpnDeployName `
                -ResourceGroupName $clientRgName `
                -TemplateFile $vpnTemplate `
                -location $Location `
                -existingVnetName $vnetName `
                -vpnGatewayName $vpnGwName `
                -vpnClientAddressPool $VpnClientAddressPool `
                -enableAvailabilityZones $regionSupportsAZ `
                -ErrorAction Stop `
                -Verbose

            if ($vpnResult.ProvisioningState -eq 'Succeeded') {
                Write-Host ""
                Write-Host "================================================" -ForegroundColor Green
                Write-Host "  VPN Gateway Deployed Successfully" -ForegroundColor Green
                Write-Host "================================================" -ForegroundColor Green
                Write-Host ""
                Write-Host "  Gateway Name   : $vpnGwName" -ForegroundColor White
                Write-Host "  Public IP      : $($vpnResult.Outputs.vpnGatewayPublicIp.Value)" -ForegroundColor White
                Write-Host "  Client Pool    : $($vpnResult.Outputs.vpnClientAddressPool.Value)" -ForegroundColor White
                Write-Host ""
                Write-Host "  NEXT STEPS: Generate certificates and configure your VPN client:" -ForegroundColor Yellow
                Write-Host "    & `".\vpngateway\P2S VPN Gateway\setup-vpn-certs.ps1`" ``" -ForegroundColor Gray
                Write-Host "        -VpnGatewayName $vpnGwName ``" -ForegroundColor Gray
                Write-Host "        -ResourceGroupName $clientRgName" -ForegroundColor Gray
                Write-Host ""
                Write-Host "  Step ${currentStep}/${totalSteps} complete." -ForegroundColor Green
            } else {
                Write-Host "VPN Gateway deployment finished with state: $($vpnResult.ProvisioningState)" -ForegroundColor Red
            }
        }
        catch {
            Write-Host ""
            Write-Host "================================================" -ForegroundColor Red
            Write-Host "  VPN Gateway Deployment Failed" -ForegroundColor Red
            Write-Host "================================================" -ForegroundColor Red
            Write-Host ""
            Write-Host $_.Exception.Message -ForegroundColor Red
            Write-Host ""
            if ($mainDeploySucceeded) {
                Write-Host "  The main HSM deployment succeeded. You can retry the VPN Gateway" -ForegroundColor Yellow
            } else {
                Write-Host "  The main HSM resources already exist. You can retry the VPN Gateway" -ForegroundColor Yellow
            }
            Write-Host "  deployment separately or use the manual steps in the VPN README." -ForegroundColor Yellow
            Write-Host ""
        }
    }
}
