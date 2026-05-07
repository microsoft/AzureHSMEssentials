<#
.SYNOPSIS
    Generates P2S VPN certificates and configures the VPN Gateway for certificate
    authentication.

.DESCRIPTION
    Post-deployment helper for HSM Scenario Builder VPN Gateway.
    Performs the following steps:

    1. Generates a self-signed root certificate (P2SRootCert) in CurrentUser\My
    2. Generates a client certificate (P2SChildCert) signed by the root cert
    3. Uploads the root certificate to the VPN Gateway
    4. Downloads the VPN client configuration package (OpenVPN)

    After running this script, import the VPN client config into the Azure VPN
    Client app and select the P2SChildCert when prompted for a certificate.

    Prerequisites:
      - The VPN Gateway must already be deployed (use deploy-hsm.ps1 -EnableVpnGateway).
      - Must be run on Windows (uses Windows certificate store).
      - Az PowerShell module must be installed and authenticated.

.PARAMETER VpnGatewayName
    Name of the VPN Gateway (e.g., chsm-vpn-gateway).

.PARAMETER ResourceGroupName
    Resource group containing the VPN Gateway (the client RG).

.PARAMETER SubscriptionId
    Azure subscription ID. If omitted, uses the current Az context.

.PARAMETER RootCertName
    Subject name for the root certificate (default: P2SRootCert).

.PARAMETER ClientCertName
    Subject name for the client certificate (default: P2SChildCert).

.PARAMETER RootCertValidMonths
    Validity period for the root cert in months (default: 24).

.PARAMETER ClientCertValidMonths
    Validity period for the client cert in months (default: 18).

.PARAMETER OutputDir
    Directory to save the VPN client configuration zip (default: user profile, e.g. C:\Users\<you>).

.PARAMETER SkipCertGeneration
    Skip certificate generation (use when certs already exist in the store).

.EXAMPLE
    .\setup-vpn-certs.ps1 -VpnGatewayName "chsm-vpn-gateway" -ResourceGroupName "CHSM-HSB-CLIENT-RG"

.EXAMPLE
    .\setup-vpn-certs.ps1 -VpnGatewayName "dhsm-vpn-gateway" -ResourceGroupName "DHSM-HSB-CLIENT-RG" -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    .\setup-vpn-certs.ps1 -VpnGatewayName "chsm-vpn-gateway" -ResourceGroupName "CHSM-HSB-CLIENT-RG" -SkipCertGeneration
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Name of the VPN Gateway.")]
    [string]$VpnGatewayName,

    [Parameter(Mandatory = $true, HelpMessage = "Resource group containing the VPN Gateway.")]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false, HelpMessage = "Azure subscription ID.")]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false, HelpMessage = "Subject name for the root certificate.")]
    [string]$RootCertName = 'P2SRootCert',

    [Parameter(Mandatory = $false, HelpMessage = "Subject name for the client certificate.")]
    [string]$ClientCertName = 'P2SChildCert',

    [Parameter(Mandatory = $false, HelpMessage = "Root cert validity in months.")]
    [int]$RootCertValidMonths = 24,

    [Parameter(Mandatory = $false, HelpMessage = "Client cert validity in months.")]
    [int]$ClientCertValidMonths = 18,

    [Parameter(Mandatory = $false, HelpMessage = "Directory to save the VPN client config zip.")]
    [string]$OutputDir = $env:USERPROFILE,

    [Parameter(Mandatory = $false, HelpMessage = "Skip certificate generation (use existing certs).")]
    [switch]$SkipCertGeneration
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  HSM Scenario Builder - VPN Certificate Setup" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

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
    Write-Host "Subscription: $SubscriptionId" -ForegroundColor Green
}
Write-Host "Gateway     : $VpnGatewayName" -ForegroundColor White
Write-Host "Resource Grp: $ResourceGroupName" -ForegroundColor White
Write-Host ""

# ------------------------------------------------------------------
# Verify the VPN Gateway exists
# ------------------------------------------------------------------
Write-Host "[STEP 1/4] Verifying VPN Gateway exists..." -ForegroundColor White
$gateway = Get-AzVirtualNetworkGateway -Name $VpnGatewayName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
Write-Host "  Found: $($gateway.Name) (SKU: $($gateway.Sku.Name))" -ForegroundColor Green
Write-Host ""

# ------------------------------------------------------------------
# Generate certificates
# ------------------------------------------------------------------
if (-not $SkipCertGeneration) {
    Write-Host "[STEP 2/4] Generating self-signed certificates..." -ForegroundColor White

    # Check for existing root cert
    $existingRoot = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq "CN=$RootCertName" }
    if ($existingRoot) {
        Write-Host "  Root cert 'CN=$RootCertName' already exists in CurrentUser\My." -ForegroundColor Yellow
        Write-Host "  Thumbprint: $($existingRoot.Thumbprint)" -ForegroundColor Yellow
        Write-Host "  Using existing certificate." -ForegroundColor Yellow
        $rootCert = $existingRoot | Select-Object -First 1
    } else {
        $rootParams = @{
            Type              = 'Custom'
            Subject           = "CN=$RootCertName"
            KeySpec           = 'Signature'
            KeyExportPolicy   = 'Exportable'
            KeyUsage          = 'CertSign'
            KeyUsageProperty  = 'Sign'
            KeyLength         = 2048
            HashAlgorithm     = 'sha256'
            NotAfter          = (Get-Date).AddMonths($RootCertValidMonths)
            CertStoreLocation = 'Cert:\CurrentUser\My'
        }
        $rootCert = New-SelfSignedCertificate @rootParams
        Write-Host "  Created root cert: CN=$RootCertName" -ForegroundColor Green
        Write-Host "  Thumbprint: $($rootCert.Thumbprint)" -ForegroundColor Green
        Write-Host "  Valid until: $($rootCert.NotAfter.ToString('yyyy-MM-dd'))" -ForegroundColor Green
    }

    # Check for existing client cert
    $existingChild = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq "CN=$ClientCertName" }
    if ($existingChild) {
        Write-Host "  Client cert 'CN=$ClientCertName' already exists in CurrentUser\My." -ForegroundColor Yellow
        Write-Host "  Thumbprint: $($existingChild.Thumbprint)" -ForegroundColor Yellow
        Write-Host "  Using existing certificate." -ForegroundColor Yellow
    } else {
        $childParams = @{
            Type              = 'Custom'
            Subject           = "CN=$ClientCertName"
            DnsName           = $ClientCertName
            KeySpec           = 'Signature'
            KeyExportPolicy   = 'Exportable'
            KeyLength         = 2048
            HashAlgorithm     = 'sha256'
            NotAfter          = (Get-Date).AddMonths($ClientCertValidMonths)
            CertStoreLocation = 'Cert:\CurrentUser\My'
            Signer            = $rootCert
            TextExtension     = @('2.5.29.37={text}1.3.6.1.5.5.7.3.2')
        }
        $childCert = New-SelfSignedCertificate @childParams
        Write-Host "  Created client cert: CN=$ClientCertName" -ForegroundColor Green
        Write-Host "  Thumbprint: $($childCert.Thumbprint)" -ForegroundColor Green
        Write-Host "  Valid until: $($childCert.NotAfter.ToString('yyyy-MM-dd'))" -ForegroundColor Green
    }
    Write-Host ""
} else {
    Write-Host "[STEP 2/4] Skipped certificate generation (-SkipCertGeneration)." -ForegroundColor Gray
    Write-Host ""
    $rootCert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq "CN=$RootCertName" } | Select-Object -First 1
    if (-not $rootCert) {
        Write-Host "  ERROR: Root cert 'CN=$RootCertName' not found in CurrentUser\My." -ForegroundColor Red
        Write-Host "  Run without -SkipCertGeneration to create it." -ForegroundColor Red
        exit 1
    }
}

# ------------------------------------------------------------------
# Upload root certificate to VPN Gateway
# ------------------------------------------------------------------
Write-Host "[STEP 3/4] Uploading root certificate to VPN Gateway..." -ForegroundColor White

$caBase64 = [System.Convert]::ToBase64String($rootCert.Export("Cert"))

# Check if already uploaded
$existingVpnCert = Get-AzVpnClientRootCertificate -VirtualNetworkGatewayName $VpnGatewayName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq $RootCertName }

if ($existingVpnCert) {
    Write-Host "  Root cert '$RootCertName' already uploaded to the gateway." -ForegroundColor Yellow
    Write-Host "  To replace it, remove the old one first via Azure Portal or PowerShell." -ForegroundColor Yellow
} else {
    Add-AzVpnClientRootCertificate `
        -VpnClientRootCertificateName $RootCertName `
        -VirtualNetworkGatewayname $VpnGatewayName `
        -ResourceGroupName $ResourceGroupName `
        -PublicCertData $caBase64

    Write-Host "  Root cert '$RootCertName' uploaded to gateway." -ForegroundColor Green
}
Write-Host ""

# ------------------------------------------------------------------
# Generate and download VPN client configuration
# ------------------------------------------------------------------
Write-Host "[STEP 4/4] Generating VPN client configuration..." -ForegroundColor White

$profile = New-AzVpnClientConfiguration `
    -Name $VpnGatewayName `
    -ResourceGroupName $ResourceGroupName `
    -AuthenticationMethod "EapTls"

$outputPath = Join-Path (Resolve-Path $OutputDir) "vpnclientconfiguration.zip"
Invoke-WebRequest $profile.VpnProfileSASUrl -OutFile $outputPath

Write-Host "  VPN client config saved to: $outputPath" -ForegroundColor Green
Write-Host ""

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
Write-Host "================================================" -ForegroundColor Green
Write-Host "  VPN Certificate Setup Complete" -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Certificates in CurrentUser\My:" -ForegroundColor Cyan
Write-Host "    Root cert   : CN=$RootCertName" -ForegroundColor White
Write-Host "    Client cert : CN=$ClientCertName" -ForegroundColor White
Write-Host ""
Write-Host "  NEXT STEPS:" -ForegroundColor Yellow
Write-Host "  1. Install the Azure VPN Client app (if not already installed)" -ForegroundColor White
Write-Host "     https://aka.ms/azvpnclientdownload" -ForegroundColor Gray
Write-Host ""
Write-Host "  2. Extract $outputPath" -ForegroundColor White
Write-Host ""
Write-Host "  3. Import the VPN profile into Azure VPN Client:" -ForegroundColor White
Write-Host "     - Open Azure VPN Client > Import > select azurevpnconfig.xml" -ForegroundColor Gray
Write-Host "     - For client certificate, select '$ClientCertName'" -ForegroundColor Gray
Write-Host ""
Write-Host "  4. Connect! Your VPN client will get an IP from the pool" -ForegroundColor White
Write-Host "     and have direct access to the HSM VNet." -ForegroundColor White
Write-Host ""
Write-Host "  Docs: https://learn.microsoft.com/en-us/azure/vpn-gateway/point-to-site-vpn-client-certificate-windows-azure-vpn-client" -ForegroundColor Gray
Write-Host ""
