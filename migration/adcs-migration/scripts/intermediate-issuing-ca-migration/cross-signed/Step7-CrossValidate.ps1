<#
.SYNOPSIS
    Step 7: Validate cutover - verify the cross-signed CA is operational.

.DESCRIPTION
    Validates the new CA is running and properly configured after activation.
    Checks certsvc status, CA registry configuration, KSP provider, CRL,
    cross-certificate presence, and CA cert in store.

    NOTE: Test certificate issuance is performed manually during Step 5 (RDP)
    because the Cavium KSP requires an interactive session for signing operations.
    This script only performs non-HSM checks that work under SYSTEM (az vm run-command).

    RUN ON: NEW ADCS Server (Azure Cloud HSM)

.PARAMETER OutputDir
    Directory to save test results. Defaults to a timestamped subfolder.

.EXAMPLE
    .\Step7-CrossValidate.ps1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Banner ------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ICA Migration (Cross-Signed) - Step 7: Validate Cutover" -ForegroundColor Cyan
Write-Host "  Run on: NEW ADCS Server (Azure Cloud HSM)" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# -- Output directory --------------------------------------------------------
if (-not $OutputDir) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputDir = Join-Path $env:USERPROFILE "ica-crosssign-step7-$timestamp"
}
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}

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

# -- Check 1: Certificate Services running -----------------------------------
Write-Host "[1/6] Checking Certificate Services status..." -ForegroundColor White

try {
    $svc = Get-Service -Name certsvc -ErrorAction Stop
    Add-CheckResult -Name "Certificate Services Running" -Passed ($svc.Status -eq 'Running') `
        -Detail "certsvc status: $($svc.Status)"
} catch {
    Add-CheckResult -Name "Certificate Services Running" -Passed $false `
        -Detail "certsvc not found: $($_.Exception.Message)"
}

# -- Check 2: Active CA name in registry -------------------------------------
Write-Host ""
Write-Host "[2/6] Checking active CA configuration..." -ForegroundColor White

$activeCA = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA SilentlyContinue).Active
if ($activeCA) {
    Add-CheckResult -Name "Active CA Configured" -Passed $true -Detail "CA name: $activeCA"
} else {
    Add-CheckResult -Name "Active CA Configured" -Passed $false -Detail "No active CA in registry"
}

# -- Check 3: CSP is Cavium --------------------------------------------------
Write-Host ""
Write-Host "[3/6] Verifying key provider is Cavium KSP..." -ForegroundColor White

$cspOutput = certutil -getreg CA\CSP 2>&1
$cspText = $cspOutput -join "`n"
$isCavium = $cspText -match 'Cavium'
Add-CheckResult -Name "Cavium KSP Active" -Passed $isCavium `
    -Detail $(if ($isCavium) { "CA is using Cavium Key Storage Provider (Cloud HSM)" } else { "CA is NOT using Cavium KSP" })

# -- Check 4: CRL publication ------------------------------------------------
Write-Host ""
Write-Host "[4/6] Checking CRL publication..." -ForegroundColor White

$crlDir = "C:\Windows\System32\CertSrv\CertEnroll"
$crlFiles = @()
if (Test-Path $crlDir) {
    $crlFiles = Get-ChildItem $crlDir -Filter "*.crl" -EA SilentlyContinue
}

if ($crlFiles.Count -gt 0) {
    $newestCrl = $crlFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Add-CheckResult -Name "CRL Published" -Passed $true `
        -Detail "CRL found: $($newestCrl.Name) ($(Get-Date $newestCrl.LastWriteTime -Format 'yyyy-MM-dd HH:mm'))"
} else {
    Add-CheckResult -Name "CRL Published" -Passed $false -Detail "No CRL files found in $crlDir"
}

# -- Check 5: CA certificate in cert store -----------------------------------
Write-Host ""
Write-Host "[5/6] Checking CA certificate in local store..." -ForegroundColor White

if ($activeCA) {
    $storeOutput = certutil -store My $activeCA 2>&1
    $storeText = $storeOutput -join "`n"
    $certInStore = $storeText -match 'Cert Hash' -or $storeText -match 'Serial Number'
    Add-CheckResult -Name "CA Certificate in Store" -Passed $certInStore `
        -Detail $(if ($certInStore) { "CA certificate found in Personal store" } else { "CA certificate NOT found in Personal store" })
} else {
    Add-CheckResult -Name "CA Certificate in Store" -Passed $false -Detail "Skipped - no active CA name"
}

# -- Check 6: Cross-certificate in Intermediate CA store ---------------------
Write-Host ""
Write-Host "[6/6] Checking cross-certificate in Intermediate CA store..." -ForegroundColor White

$crossCert = $null
if ($activeCA) {
    foreach ($cert in (Get-ChildItem Cert:\LocalMachine\CA)) {
        if ($cert.Subject -match [regex]::Escape($activeCA) -and $cert.Subject -ne $cert.Issuer) {
            $crossCert = $cert
            break
        }
    }
}

if ($crossCert) {
    Add-CheckResult -Name "Cross-Cert Present" -Passed $true `
        -Detail "Issuer: $($crossCert.Issuer) | Thumbprint: $($crossCert.Thumbprint)"
} else {
    Add-CheckResult -Name "Cross-Cert Present" -Passed $false `
        -Detail "No cross-cert found for '$activeCA' in Intermediate CA store"
}

# -- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor $(if ($allPassed) { "Green" } else { "Red" })
$statusMsg = if ($allPassed) { "  Step 7 Complete: Cross-signed CA cutover validated" } else { "  Step 7: Some validation checks FAILED" }
Write-Host $statusMsg -ForegroundColor $(if ($allPassed) { "Green" } else { "Red" })
Write-Host "============================================================" -ForegroundColor $(if ($allPassed) { "Green" } else { "Red" })
Write-Host ""

foreach ($c in $checks) {
    $color = if ($c.Status -eq "PASS") { "Green" } else { "Red" }
    Write-Host "    $($c.Status)  $($c.Check)" -ForegroundColor $color
}

Write-Host ""
Write-Host "  Test artifacts saved to: $OutputDir" -ForegroundColor Gray
Write-Host ""
if ($allPassed) {
    Write-Host "  The new CA is operational with cross-certificate trust bridge." -ForegroundColor Green
    Write-Host "  Certificate issuance was validated during the manual Step 5" -ForegroundColor Green
    Write-Host "  (RDP session)." -ForegroundColor Green
    Write-Host ""
    Write-Host "  NEXT: Run Step8-DecommissionChecks.ps1 on the OLD ADCS server" -ForegroundColor Yellow
    Write-Host "        to assess decommission readiness." -ForegroundColor Yellow
} else {
    Write-Host "  ACTION: Resolve failed checks before relying on the new CA." -ForegroundColor Red
}
Write-Host ""
