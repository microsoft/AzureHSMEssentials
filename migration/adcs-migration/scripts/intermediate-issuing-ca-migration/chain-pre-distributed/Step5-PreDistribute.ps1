<#
.SYNOPSIS
    Step 5: Pre-distribute the new issuing CA certificate (Critical Step).

.DESCRIPTION
    Publishes the new issuing CA certificate to Active Directory and generates
    a checklist of manual distribution targets. This step MUST be completed
    before activating the new CA (Step 6).

    RUN ON: NEW ADCS Server (Azure Cloud HSM) or Domain Controller

.PARAMETER SignedCertPath
    Path to the signed issuing CA certificate file (e.g., NewIssuingCA.cer).

.PARAMETER PublishToAD
    Publish the certificate to Active Directory via certutil -dspublish.
    Requires Enterprise Admin or equivalent permissions.

.PARAMETER SkipADPublish
    Skip the AD publishing step (useful for standalone CAs or manual publishing).

.EXAMPLE
    .\Step5-PreDistribute.ps1 -SignedCertPath "C:\Migration\NewIssuingCA.cer" -PublishToAD

.EXAMPLE
    .\Step5-PreDistribute.ps1 -SignedCertPath "C:\Migration\NewIssuingCA.cer" -SkipADPublish
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SignedCertPath,

    [Parameter(Mandatory = $false)]
    [switch]$PublishToAD,

    [Parameter(Mandatory = $false)]
    [switch]$SkipADPublish
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Banner ------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ADCS Migration - Step 5: Pre-Distribute New ICA Cert" -ForegroundColor Cyan
Write-Host "  Run on: NEW ADCS Server or Domain Controller" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  WARNING: This step MUST be completed before activating" -ForegroundColor Red
Write-Host "  the new CA. Incomplete distribution will cause trust" -ForegroundColor Red
Write-Host "  failures for clients." -ForegroundColor Red
Write-Host ""

# -- Validate input ----------------------------------------------------------
if (-not (Test-Path $SignedCertPath)) {
    Write-Host "[ERROR] Signed certificate not found at: $SignedCertPath" -ForegroundColor Red
    exit 1
}

# Load cert details for display
$certDump = certutil -dump $SignedCertPath 2>&1
$certText = $certDump -join "`n"
$certSubject = ""
if ($certText -match 'Subject:\s*\r?\n\s*(.+)') {
    $certSubject = $Matches[1].Trim()
}
Write-Host "[INFO] Certificate: $certSubject" -ForegroundColor Gray
Write-Host "[INFO] File: $SignedCertPath" -ForegroundColor Gray
Write-Host ""

# -- AD Publishing -----------------------------------------------------------
$adPublished = $false

if ($SkipADPublish) {
    Write-Host "[1/3] AD Publishing: SKIPPED (-SkipADPublish)" -ForegroundColor Yellow
} elseif ($PublishToAD) {
    Write-Host "[1/3] Publishing to Active Directory..." -ForegroundColor White

    # Publish as Sub CA (NTAuth + AIA)
    Write-Host "       Publishing as Sub CA (NTAuth store)..." -ForegroundColor Gray
    $ntauthResult = certutil -dspublish -f $SignedCertPath SubCA 2>&1
    $ntauthText = ($ntauthResult | Out-String)
    if ($ntauthText -match 'completed successfully') {
        Write-Host "       [PASS] Published to NTAuth store" -ForegroundColor Green
    } else {
        Write-Host "       [FAIL] NTAuth publish failed" -ForegroundColor Red
        $ntauthResult | ForEach-Object { Write-Host "         $_" -ForegroundColor Red }
    }

    # Also publish to the AIA container
    Write-Host "       Publishing to AIA container..." -ForegroundColor Gray
    $aiaResult = certutil -dspublish -f $SignedCertPath NTAuthCA 2>&1
    $aiaText = ($aiaResult | Out-String)
    if ($aiaText -match 'completed successfully') {
        Write-Host "       [PASS] Published to AIA" -ForegroundColor Green
        $adPublished = $true
    } else {
        Write-Host "       [WARN] AIA publish returned non-zero (may require Enterprise Admin)" -ForegroundColor Yellow
    }

    # Force Group Policy update to propagate
    Write-Host ""
    Write-Host "       Triggering Group Policy update..." -ForegroundColor Gray
    try {
        gpupdate /force 2>&1 | Out-Null
        Write-Host "       [PASS] Group Policy update triggered" -ForegroundColor Green
    } catch {
        Write-Host "       [WARN] gpupdate failed - run manually on domain controllers" -ForegroundColor Yellow
    }
} else {
    Write-Host "[1/3] AD Publishing: Not requested" -ForegroundColor Yellow
    Write-Host "       Use -PublishToAD to publish to Active Directory" -ForegroundColor Gray
    Write-Host "       Use -SkipADPublish to skip this step intentionally" -ForegroundColor Gray
}

# -- Verify AD publishing ----------------------------------------------------
Write-Host ""
Write-Host "[2/3] Checking AD trust store for new ICA certificate..." -ForegroundColor White

try {
    $viewStoreResult = certutil -viewstore -enterprise NTAuth 2>&1
    $viewStoreText = $viewStoreResult -join "`n"

    # Extract CN from subject for matching
    $searchCN = ""
    if ($certSubject -match 'CN=([^,]+)') {
        $searchCN = $Matches[1].Trim()
    }

    if ($searchCN -and $viewStoreText -match [regex]::Escape($searchCN)) {
        Write-Host "       [PASS] New ICA certificate found in NTAuth enterprise store" -ForegroundColor Green
    } else {
        Write-Host "       [WARN] New ICA certificate NOT yet visible in NTAuth store" -ForegroundColor Yellow
        Write-Host "              AD replication may take time, or publish was not performed" -ForegroundColor Gray
    }
} catch {
    Write-Host "       [SKIP] Could not query enterprise NTAuth store (may not be domain-joined)" -ForegroundColor Yellow
}

# -- Manual distribution checklist --------------------------------------------
Write-Host ""
Write-Host "[3/3] Manual Distribution Checklist" -ForegroundColor White
Write-Host ""
Write-Host "  The following systems MUST receive the new ICA certificate" -ForegroundColor Yellow
Write-Host "  BEFORE the new CA is activated (Step 6):" -ForegroundColor Yellow
Write-Host ""
Write-Host "  +----------------------------------------------------------+" -ForegroundColor White
Write-Host "  |  Distribution Target             | Status               |" -ForegroundColor White
Write-Host "  +----------------------------------------------------------+" -ForegroundColor White

$targets = @(
    @{ Name = "Active Directory (NTAuth/AIA)"; Auto = $adPublished },
    @{ Name = "RADIUS servers (NPS/ISE/ClearPass)"; Auto = $false },
    @{ Name = "Load balancers (TLS termination)"; Auto = $false },
    @{ Name = "Web Application Firewalls (WAF)"; Auto = $false },
    @{ Name = "TLS termination / reverse proxies"; Auto = $false },
    @{ Name = "Devices with pinned trust (IoT)"; Auto = $false },
    @{ Name = "802.1X authenticators"; Auto = $false },
    @{ Name = "VPN concentrators"; Auto = $false },
    @{ Name = "Certificate pinning configs"; Auto = $false }
)

foreach ($t in $targets) {
    $status = if ($t.Auto) { "DONE (automated)" } else { "[ ] MANUAL" }
    $color  = if ($t.Auto) { "Green" } else { "Yellow" }
    $padded = $t.Name.PadRight(36)
    Write-Host "  |  $padded| $status" -ForegroundColor $color
}

Write-Host "  +----------------------------------------------------------+" -ForegroundColor White
Write-Host ""
Write-Host "  Certificate file to distribute: $SignedCertPath" -ForegroundColor White

# -- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Step 5: Pre-Distribution In Progress" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  AD Published:       $(if ($adPublished) { 'Yes' } else { 'No / Not Requested' })" -ForegroundColor White
Write-Host "  Manual Targets:     Review checklist above" -ForegroundColor White
Write-Host ""
Write-Host "  CRITICAL: Do NOT proceed to Step 6 until ALL relying" -ForegroundColor Red
Write-Host "  parties have the new issuing CA certificate installed." -ForegroundColor Red
Write-Host ""
Write-Host "  NEXT: After confirming full distribution, run" -ForegroundColor Yellow
Write-Host "        Step6-ActivateNewCA.ps1 on the NEW ADCS server." -ForegroundColor Yellow
Write-Host ""
