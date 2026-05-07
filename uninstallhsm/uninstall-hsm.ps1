<#
.SYNOPSIS
    Removes all HSM Scenario Builder resources for the selected platform.

.DESCRIPTION
    Universal uninstall script that deletes resource groups created by the
    corresponding ARM deployment for Azure Cloud HSM, Azure Dedicated HSM,
    Azure Key Vault, Azure Managed HSM, or Azure Payment HSM.

    Reads the resource group names from the platform's ARM parameters file
    so it always deletes the correct groups.

.PARAMETER Platform
    The HSM platform to uninstall (required).
    Valid values: AzureCloudHSM, AzureDedicatedHSM, AzureKeyVault, AzureManagedHSM, AzurePaymentHSM

.PARAMETER SubscriptionId
    The Azure subscription ID containing the resources (required).

.PARAMETER ParameterFile
    Path to the ARM parameters file to read resource group names from.
    Defaults to deployhsm/<platform>/<platform>-parameters.json.

.PARAMETER SkipConfirmation
    Skip the interactive confirmation prompt. Use for automation.

.PARAMETER Verbose
    Show full error details including stack traces for debugging.

.EXAMPLE
    .\uninstall-hsm.ps1 -Platform AzureCloudHSM -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    .\uninstall-hsm.ps1 -Platform AzureManagedHSM -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -SkipConfirmation
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "HSM platform to uninstall.")]
    [ValidateSet("AzureCloudHSM", "AzureDedicatedHSM", "AzureKeyVault", "AzureManagedHSM", "AzurePaymentHSM")]
    [string]$Platform,

    [Parameter(Mandatory = $true, HelpMessage = "Azure subscription ID containing the resources.")]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false, HelpMessage = "Path to ARM parameters file (to read resource group names).")]
    [string]$ParameterFile,

    [Parameter(Mandatory = $false, HelpMessage = "Skip confirmation prompt.")]
    [switch]$SkipConfirmation,

    [Parameter(Mandatory = $false, HelpMessage = "Show full error details for debugging.")]
    [switch]$VerboseOutput
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------
# Platform mapping
# ------------------------------------------------------------------
$platformMap = @{
    "AzureCloudHSM"     = @{ Folder = "azurecloudhsm";      DisplayName = "Azure Cloud HSM";     Params = "cloudhsm-parameters.json" }
    "AzureDedicatedHSM"  = @{ Folder = "azuredededicatedhsm"; DisplayName = "Azure Dedicated HSM"; Params = "dedicatedhsm-parameters.json" }
    "AzureKeyVault"      = @{ Folder = "azurekeyvault";      DisplayName = "Azure Key Vault";      Params = "keyvault-parameters.json" }
    "AzureManagedHSM"    = @{ Folder = "azuremanagedhsm";    DisplayName = "Azure Managed HSM";    Params = "managedhsm-parameters.json" }
    "AzurePaymentHSM"    = @{ Folder = "azurepaymentshsm";   DisplayName = "Azure Payment HSM";    Params = "paymentshsm-parameters.json" }
}

$platformInfo = $platformMap[$Platform]
$displayName = $platformInfo.DisplayName

# ------------------------------------------------------------------
# Resolve paths and read resource group names from parameters file
# ------------------------------------------------------------------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$deployDir = Join-Path (Split-Path -Parent $scriptDir) "deployhsm"

if (-not $ParameterFile) {
    $ParameterFile = Join-Path $deployDir "$($platformInfo.Folder)\$($platformInfo.Params)"
}

# Default resource group names (Cloud HSM defaults; other platforms will override)
$resourceGroups = @()

if (Test-Path $ParameterFile) {
    try {
        $params = Get-Content $ParameterFile -Raw | ConvertFrom-Json

        # Build list of resource groups from the parameters file.
        # Deletion order matters: admin VM RG first (its NIC references the
        # client VNet subnet), then client networking, then HSM cluster.
        if ($params.parameters.PSObject.Properties['adminVmResourceGroupName']) {
            $resourceGroups += $params.parameters.adminVmResourceGroupName.value
        }
        if ($params.parameters.PSObject.Properties['clientResourceGroupName']) {
            $resourceGroups += $params.parameters.clientResourceGroupName.value
        }
        if ($params.parameters.PSObject.Properties['serverResourceGroupName']) {
            $resourceGroups += $params.parameters.serverResourceGroupName.value
        }
        if ($params.parameters.PSObject.Properties['resourceGroupName']) {
            $resourceGroups += $params.parameters.resourceGroupName.value
        }
        if ($params.parameters.PSObject.Properties['logsResourceGroupName']) {
            $resourceGroups += $params.parameters.logsResourceGroupName.value
        }
        if ($params.parameters.PSObject.Properties['certResourceGroupName']) {
            $resourceGroups += $params.parameters.certResourceGroupName.value
        }

        Write-Host "Read resource group names from: $ParameterFile" -ForegroundColor Gray
    }
    catch {
        Write-Host "Warning: Could not parse $ParameterFile." -ForegroundColor Yellow
    }
}
else {
    Write-Host "Parameters file not found: $ParameterFile" -ForegroundColor Yellow
    Write-Host "Using default resource group names." -ForegroundColor Yellow
}

# Fallback defaults if nothing was read
if ($resourceGroups.Count -eq 0) {
    switch ($Platform) {
        "AzureCloudHSM"     { $resourceGroups = @("CHSM-HSB-ADMINVM-RG", "CHSM-HSB-CLIENT-RG", "CHSM-HSB-HSM-RG", "CHSM-HSB-LOGS-RG", "CHSM-HSB-CERT-RG") }
        "AzureDedicatedHSM"  { $resourceGroups = @("DHSM-HSB-ADMINVM-RG", "DHSM-HSB-CLIENT-RG", "DHSM-HSB-HSM-RG") }
        "AzureKeyVault"      { $resourceGroups = @("AKV-HSB-ADMINVM-RG", "AKV-HSB-CLIENT-RG", "AKV-HSB-HSM-RG", "AKV-HSB-LOGS-RG") }
        "AzureManagedHSM"    { $resourceGroups = @("MHSM-HSB-ADMINVM-RG", "MHSM-HSB-CLIENT-RG", "MHSM-HSB-HSM-RG", "MHSM-HSB-LOGS-RG") }
        "AzurePaymentHSM"    { $resourceGroups = @("PHSM-HSB-ADMINVM-RG", "PHSM-HSB-CLIENT-RG", "PHSM-HSB-HSM-RG") }
    }
    Write-Host "Using default resource group names for $displayName." -ForegroundColor Yellow
}

# ------------------------------------------------------------------
# Detect scenario resource groups (e.g. ADCS VM) that reference this
# platform's VNet.  They must be deleted BEFORE the client RG or the
# client RG deletion will fail with a 409 Conflict.
# ------------------------------------------------------------------
$scenarioRGMap = @{
    "AzureCloudHSM"     = @("CHSM-HSB-ADCS-VM")
    "AzureDedicatedHSM"  = @("DHSM-HSB-ADCS-VM")
}

if ($scenarioRGMap.ContainsKey($Platform)) {
    $scenarioRGs = $scenarioRGMap[$Platform]
    # Prepend scenario RGs before the main list so they are deleted first
    $prependList = @()
    foreach ($srg in $scenarioRGs) {
        if ($resourceGroups -notcontains $srg) {
            $prependList += $srg
        }
    }
    if ($prependList.Count -gt 0) {
        $resourceGroups = $prependList + $resourceGroups
        Write-Host "Detected scenario resource groups that depend on $displayName networking." -ForegroundColor Yellow
        Write-Host "They will be deleted first to avoid conflicts." -ForegroundColor Yellow
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
# Display plan and confirm
# ------------------------------------------------------------------
Write-Host ""
Write-Host "================================================" -ForegroundColor Red
Write-Host "  HSM Scenario Builder - $displayName Removal" -ForegroundColor Red
Write-Host "================================================" -ForegroundColor Red
Write-Host ""
Write-Host "  Platform     : $displayName"
Write-Host "  Subscription : $SubscriptionId"
Write-Host ""
Write-Host "  The following resource groups will be PERMANENTLY DELETED:" -ForegroundColor Yellow
Write-Host ""

$index = 1
foreach ($rg in $resourceGroups) {
    Write-Host "    $index. $rg" -ForegroundColor Yellow
    $index++
}

Write-Host ""
Write-Host "  This action CANNOT be undone." -ForegroundColor Red
Write-Host ""

if (-not $SkipConfirmation) {
    $confirm = Read-Host "Type 'DELETE' to confirm and proceed"
    if ($confirm -ne "DELETE") {
        Write-Host "Aborted. No resources were deleted." -ForegroundColor Green
        exit 0
    }
    Write-Host ""
}

# ------------------------------------------------------------------
# Connect and set subscription
# ------------------------------------------------------------------
$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Write-Host "Not logged in to Azure. Launching login..." -ForegroundColor Yellow
    Connect-AzAccount
}

Write-Host "Setting subscription context..." -ForegroundColor Yellow
try {
    Set-AzContext -SubscriptionId $SubscriptionId -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
} catch {
    Write-Host "Current session cannot access subscription $SubscriptionId. Re-authenticating..." -ForegroundColor Yellow
    Connect-AzAccount -SubscriptionId $SubscriptionId
    Set-AzContext -SubscriptionId $SubscriptionId -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
}
Write-Host "Active subscription: $((Get-AzContext).Subscription.Name) ($SubscriptionId)" -ForegroundColor Green
Write-Host ""

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
# Delete resource groups
# ------------------------------------------------------------------
$total = $resourceGroups.Count
$step = 1

foreach ($rg in $resourceGroups) {
    Write-Host "Step ${step}/${total}: Deleting resource group: $rg" -ForegroundColor Yellow

    $exists = Get-AzResourceGroup -Name $rg -ErrorAction SilentlyContinue
    if ($exists) {
        Write-Host "  Removing $rg (this may take several minutes)..." -ForegroundColor Gray
        try {
            Remove-AzResourceGroup -Name $rg -Force -ErrorAction Stop | Out-Null
            Write-Host "  $rg deleted." -ForegroundColor Green
        }
        catch {
            $msg = $_.Exception.Message
            if ($msg -match '401|Unauthorized') {
                Write-Host "  Remove-AzResourceGroup : Operation returned an invalid status code 'Unauthorized'" -ForegroundColor Red
                Write-Host "  StatusCode: 401" -ForegroundColor Red
                Write-Host "  ReasonPhrase: 401 Unauthorized - Azure session token expired. Re-run to retry." -ForegroundColor Red
            }
            elseif ($msg -match '409|Conflict') {
                Write-Host "  Remove-AzResourceGroup : Operation returned status code 'Conflict'" -ForegroundColor Red
                Write-Host "  StatusCode: 409" -ForegroundColor Red
                Write-Host "  ReasonPhrase: 409 Conflict - a resource in another group still references this group. Re-run to retry." -ForegroundColor Red
            }
            else {
                Write-Host "  Remove-AzResourceGroup failed: $msg" -ForegroundColor Red
                Write-Host "  Re-run to retry." -ForegroundColor Red
            }
            if ($VerboseOutput) {
                Write-Host "" -ForegroundColor DarkGray
                Write-Host "  --- Verbose Error Detail ---" -ForegroundColor DarkGray
                Write-Host "  Exception : $($_.Exception.GetType().FullName)" -ForegroundColor DarkGray
                Write-Host "  Message   : $msg" -ForegroundColor DarkGray
                if ($_.Exception.InnerException) {
                    Write-Host "  Inner     : $($_.Exception.InnerException.Message)" -ForegroundColor DarkGray
                }
                Write-Host "  Target    : $($_.TargetObject)" -ForegroundColor DarkGray
                Write-Host "  Stack     :" -ForegroundColor DarkGray
                Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
                Write-Host "  --- End Verbose Detail ---" -ForegroundColor DarkGray
            }
        }
    }
    else {
        Write-Host "  $rg not found - skipping." -ForegroundColor Gray
    }

    if ($step -lt $total) { Write-Host "" }
    $step++
}

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host "  All $displayName resources have been removed." -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
Write-Host ""
Write-Host "If you deployed any additional resources in separate resource groups," -ForegroundColor Cyan
Write-Host "delete those manually:" -ForegroundColor Cyan
Write-Host ""
Write-Host '  Remove-AzResourceGroup -Name "<resource-group-name>" -Force' -ForegroundColor Gray
Write-Host ""
