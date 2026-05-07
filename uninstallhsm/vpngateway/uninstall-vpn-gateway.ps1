<#
.SYNOPSIS
    Removes the VPN Gateway and related resources from the HSM platform VNet.

.DESCRIPTION
    Deletes the VPN Gateway, its public IP, and optionally the GatewaySubnet
    from the client VNet. Also offers to remove P2S certificates from the
    local certificate store.

    This does NOT delete the base HSM deployment, Admin VM, or client VNet.
    It only removes the VPN Gateway components added by -EnableVpnGateway.

    Note: VPN Gateway deletion typically takes 15-30 minutes.

.PARAMETER VpnGatewayName
    Name of the VPN Gateway to remove (e.g., chsm-vpn-gateway).

.PARAMETER ResourceGroupName
    Resource group containing the VPN Gateway (the client RG).

.PARAMETER SubscriptionId
    Azure subscription ID. If omitted, uses the current Az context.

.PARAMETER RemoveLocalCerts
    Also remove P2SRootCert and P2SChildCert from the local certificate store.

.PARAMETER SkipConfirmation
    Skip the interactive confirmation prompt.

.PARAMETER VerboseOutput
    Show full error details and stack traces.

.EXAMPLE
    .\uninstall-vpn-gateway.ps1 -VpnGatewayName "chsm-vpn-gateway" -ResourceGroupName "CHSM-HSB-CLIENT-RG"

.EXAMPLE
    .\uninstall-vpn-gateway.ps1 -VpnGatewayName "dhsm-vpn-gateway" -ResourceGroupName "DHSM-HSB-CLIENT-RG" -RemoveLocalCerts -SkipConfirmation
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Name of the VPN Gateway to remove.")]
    [string]$VpnGatewayName,

    [Parameter(Mandatory = $true, HelpMessage = "Resource group containing the VPN Gateway.")]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false, HelpMessage = "Azure subscription ID.")]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false, HelpMessage = "Also remove P2S certs from local certificate store.")]
    [switch]$RemoveLocalCerts,

    [Parameter(Mandatory = $false, HelpMessage = "Skip confirmation prompt.")]
    [switch]$SkipConfirmation,

    [Parameter(Mandatory = $false, HelpMessage = "Show full error details for debugging.")]
    [switch]$VerboseOutput
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------
# Ensure Az module and connectivity
# ------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Host "Az PowerShell module not found. Install with: Install-Module -Name Az -Scope CurrentUser" -ForegroundColor Red
    exit 1
}

$savedWarningPref = $WarningPreference
$WarningPreference = 'SilentlyContinue'
Import-Module Az.Resources -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module Az.Network  -DisableNameChecking -ErrorAction SilentlyContinue
$WarningPreference = $savedWarningPref

$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Write-Host "Not logged in to Azure. Launching login..." -ForegroundColor Yellow
    Connect-AzAccount
}

if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId -WarningAction SilentlyContinue | Out-Null
}

# ------------------------------------------------------------------
# Check if gateway exists
# ------------------------------------------------------------------
$gateway = Get-AzVirtualNetworkGateway -Name $VpnGatewayName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $gateway) {
    Write-Host ""
    Write-Host "VPN Gateway '$VpnGatewayName' not found in '$ResourceGroupName'." -ForegroundColor Yellow
    Write-Host "Nothing to delete." -ForegroundColor Gray
    Write-Host ""
    exit 0
}

# Resolve the public IP name from the gateway config
$pipId = $gateway.IpConfigurations[0].PublicIpAddress.Id
$pipName = if ($pipId) { ($pipId -split '/')[-1] } else { $null }

# ------------------------------------------------------------------
# Display plan and confirm
# ------------------------------------------------------------------
Write-Host ""
Write-Host "================================================" -ForegroundColor Red
Write-Host "  HSM Scenario Builder - VPN Gateway Removal" -ForegroundColor Red
Write-Host "================================================" -ForegroundColor Red
Write-Host ""
Write-Host "  Gateway        : $VpnGatewayName"
Write-Host "  Resource Group : $ResourceGroupName"
if ($pipName) {
    Write-Host "  Public IP      : $pipName"
}
Write-Host ""
Write-Host "  The following resources will be deleted:" -ForegroundColor Yellow
Write-Host "    1. VPN Gateway: $VpnGatewayName" -ForegroundColor Yellow
if ($pipName) {
    Write-Host "    2. Public IP  : $pipName" -ForegroundColor Yellow
}
if ($RemoveLocalCerts) {
    Write-Host "    3. Local certs: P2SRootCert, P2SChildCert (from CurrentUser\My)" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  The VNet, subnets, HSM, and Admin VM are NOT affected." -ForegroundColor Gray
Write-Host "  Note: VPN Gateway deletion typically takes 15-30 minutes." -ForegroundColor Gray
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
# Delete VPN Gateway (this is the slow part)
# ------------------------------------------------------------------
Write-Host "Step 1: Deleting VPN Gateway '$VpnGatewayName' (this takes 15-30 minutes)..." -ForegroundColor Yellow
try {
    Remove-AzVirtualNetworkGateway -Name $VpnGatewayName -ResourceGroupName $ResourceGroupName -Force -ErrorAction Stop
    Write-Host "  VPN Gateway deleted." -ForegroundColor Green
}
catch {
    $msg = $_.Exception.Message
    Write-Host "  Failed to delete VPN Gateway: $msg" -ForegroundColor Red
    if ($VerboseOutput) {
        Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor DarkGray
    }
    exit 1
}

# ------------------------------------------------------------------
# Delete public IP
# ------------------------------------------------------------------
if ($pipName) {
    Write-Host ""
    Write-Host "Step 2: Deleting public IP '$pipName'..." -ForegroundColor Yellow
    try {
        Remove-AzPublicIpAddress -Name $pipName -ResourceGroupName $ResourceGroupName -Force -ErrorAction Stop
        Write-Host "  Public IP deleted." -ForegroundColor Green
    }
    catch {
        $msg = $_.Exception.Message
        Write-Host "  Failed to delete public IP (may already be gone): $msg" -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------------
# Remove local certificates
# ------------------------------------------------------------------
if ($RemoveLocalCerts) {
    Write-Host ""
    Write-Host "Step 3: Removing local VPN certificates..." -ForegroundColor Yellow

    $rootCerts = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq 'CN=P2SRootCert' }
    $childCerts = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq 'CN=P2SChildCert' }

    $removed = 0
    foreach ($cert in $rootCerts) {
        Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)" -ErrorAction SilentlyContinue
        $removed++
    }
    foreach ($cert in $childCerts) {
        Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)" -ErrorAction SilentlyContinue
        $removed++
    }
    Write-Host "  Removed $removed certificate(s) from CurrentUser\My." -ForegroundColor Green
}

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host "  VPN Gateway removed." -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
Write-Host ""
Write-Host "The GatewaySubnet remains in the VNet (empty, no cost)." -ForegroundColor Gray
Write-Host "To re-deploy the VPN Gateway later, re-run deploy-hsm.ps1 with -EnableVpnGateway." -ForegroundColor Cyan
Write-Host ""
