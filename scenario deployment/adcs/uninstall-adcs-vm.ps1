<#
.SYNOPSIS
    Removes the ADCS VM and all its resources for the selected HSM platform.

.DESCRIPTION
    Deletes the resource group created by deploy-adcs-vm.ps1 for the ADCS
    (Active Directory Certificate Services) scenario VM.

    Reads the resource group name from the platform-specific ADCS parameters
    file so it always deletes the correct group.

    Supported platforms:
      - AzureCloudHSM      : Deletes CHSM-HSB-ADCS-VM resource group
      - AzureDedicatedHSM   : Deletes DHSM-HSB-ADCS-VM resource group

    The ADCS VM resource group contains the VM, NIC, NSG, and
    OS disk. Deleting the resource group removes everything inside it.

    This does NOT delete the base HSM deployment or Admin VM. Use
    uninstall-hsm.ps1 for that.

.PARAMETER Platform
    The HSM platform whose ADCS VM to remove (required).
    Valid values: AzureCloudHSM, AzureDedicatedHSM

.PARAMETER SubscriptionId
    The Azure subscription ID containing the ADCS VM resources (required).

.PARAMETER ParameterFile
    Path to the ADCS ARM parameters file (to read the resource group name).
    Defaults to adcs-vm-parameters-<platform>.json in the same directory.

.PARAMETER SkipConfirmation
    Skip the interactive confirmation prompt. Use for automation.

.PARAMETER VerboseOutput
    Show full error details including stack traces for debugging.

.EXAMPLE
    .\uninstall-adcs-vm.ps1 -Platform AzureCloudHSM -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    .\uninstall-adcs-vm.ps1 -Platform AzureDedicatedHSM -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -SkipConfirmation
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "HSM platform whose ADCS VM to remove.")]
    [ValidateSet("AzureCloudHSM", "AzureDedicatedHSM")]
    [string]$Platform,

    [Parameter(Mandatory = $true, HelpMessage = "Azure subscription ID containing the ADCS VM resources.")]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false, HelpMessage = "Path to ADCS ARM parameters file (to read resource group name).")]
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
    "AzureCloudHSM"     = @{ DisplayName = "Azure Cloud HSM";     Params = "adcs-vm-parameters-cloudhsm.json";      DefaultRG = "CHSM-HSB-ADCS-VM" }
    "AzureDedicatedHSM"  = @{ DisplayName = "Azure Dedicated HSM"; Params = "adcs-vm-parameters-dedicatedhsm.json";  DefaultRG = "DHSM-HSB-ADCS-VM" }
}

$platformInfo = $platformMap[$Platform]
$displayName = $platformInfo.DisplayName

# ------------------------------------------------------------------
# Resolve paths and read resource group name from parameters file
# ------------------------------------------------------------------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

if (-not $ParameterFile) {
    $ParameterFile = Join-Path $scriptDir $platformInfo.Params
}

$adcsResourceGroup = $null

if (Test-Path $ParameterFile) {
    try {
        $params = Get-Content $ParameterFile -Raw | ConvertFrom-Json
        if ($params.parameters.PSObject.Properties['adcsResourceGroupName']) {
            $adcsResourceGroup = $params.parameters.adcsResourceGroupName.value
        }
        Write-Host "Read resource group name from: $ParameterFile" -ForegroundColor Gray
    }
    catch {
        Write-Host "Warning: Could not parse $ParameterFile." -ForegroundColor Yellow
    }
}
else {
    Write-Host "Parameters file not found: $ParameterFile" -ForegroundColor Yellow
    Write-Host "Using default resource group name." -ForegroundColor Yellow
}

# Fallback to default if nothing was read
if (-not $adcsResourceGroup) {
    $adcsResourceGroup = $platformInfo.DefaultRG
    Write-Host "Using default resource group: $adcsResourceGroup" -ForegroundColor Yellow
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
Write-Host "  HSM Scenario Builder - ADCS VM Removal" -ForegroundColor Red
Write-Host "  Platform: $displayName" -ForegroundColor Red
Write-Host "================================================" -ForegroundColor Red
Write-Host ""
Write-Host "  Platform     : $displayName"
Write-Host "  Subscription : $SubscriptionId"
Write-Host ""
Write-Host "  The following resource group will be PERMANENTLY DELETED:" -ForegroundColor Yellow
Write-Host ""
Write-Host "    1. $adcsResourceGroup" -ForegroundColor Yellow
Write-Host ""
Write-Host "  This includes the ADCS VM, NIC, NSG, and OS disk." -ForegroundColor Yellow
Write-Host "  The base HSM deployment and Admin VM are NOT affected." -ForegroundColor Gray
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
Set-AzContext -SubscriptionId $SubscriptionId -WarningAction SilentlyContinue | Out-Null
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
# Delete resource group
# ------------------------------------------------------------------
Write-Host "Deleting resource group: $adcsResourceGroup" -ForegroundColor Yellow

$exists = Get-AzResourceGroup -Name $adcsResourceGroup -ErrorAction SilentlyContinue
if ($exists) {
    Write-Host "  Removing $adcsResourceGroup (this may take several minutes)..." -ForegroundColor Gray
    try {
        Remove-AzResourceGroup -Name $adcsResourceGroup -Force -ErrorAction Stop | Out-Null
        Write-Host "  $adcsResourceGroup deleted." -ForegroundColor Green
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
        exit 1
    }
}
else {
    Write-Host "  $adcsResourceGroup not found - nothing to delete." -ForegroundColor Gray
}

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host "  ADCS VM resources removed ($displayName)." -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
Write-Host ""
Write-Host "The base HSM deployment and Admin VM are still intact." -ForegroundColor Cyan
Write-Host "To remove those, run:" -ForegroundColor Cyan
Write-Host ""
Write-Host "  .\..\..\uninstallhsm\uninstall-hsm.ps1 -Platform $Platform -SubscriptionId `"$SubscriptionId`"" -ForegroundColor Gray
Write-Host ""
