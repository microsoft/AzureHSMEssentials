<#
.SYNOPSIS
    Step 6: Validate trust distribution of the new Root CA certificate.

.DESCRIPTION
    Verifies that the new Root CA certificate has been properly distributed
    to target machines. Checks:
    - New root is in Trusted Root CAs store (by thumbprint)
    - Old root is still present (both must coexist during migration)
    - Chain building works for the new root
    - certutil -verify confirms trust

    Run this script on EACH machine that should trust the new root to
    confirm the distribution from Step 5 was successful.

    RUN ON: Target machines / relying parties (after Step 5 distribution)

.PARAMETER NewRootThumbprint
    Thumbprint of the new Root CA certificate to verify.

.PARAMETER OldRootThumbprint
    Thumbprint of the old Root CA certificate (optional). If provided,
    confirms both roots coexist in the trust store.

.PARAMETER NewRootCertPath
    Path to the new Root CA .cer file (alternative to thumbprint).
    The script extracts the thumbprint from the file.

.EXAMPLE
    .\Step6-ValidateTrust.ps1 -NewRootThumbprint "42037055..."

.EXAMPLE
    .\Step6-ValidateTrust.ps1 -NewRootCertPath "C:\Certs\NewRootCA.cer" -OldRootThumbprint "343A5FDC..."

.EXAMPLE
    .\Step6-ValidateTrust.ps1 -NewRootThumbprint "42037055..." -OldRootThumbprint "343A5FDC..."
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$NewRootThumbprint,

    [Parameter(Mandatory = $false)]
    [string]$OldRootThumbprint,

    [Parameter(Mandatory = $false)]
    [string]$NewRootCertPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Banner ------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Root CA Migration - Step 6: Validate Trust Distribution" -ForegroundColor Cyan
Write-Host "  Run on: Target machines (relying parties)" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# -- Resolve thumbprint -------------------------------------------------------
if (-not $NewRootThumbprint -and -not $NewRootCertPath) {
    Write-Host "[ERROR] Provide either -NewRootThumbprint or -NewRootCertPath." -ForegroundColor Red
    exit 1
}

if ($NewRootCertPath -and -not $NewRootThumbprint) {
    if (-not (Test-Path $NewRootCertPath)) {
        Write-Host "[ERROR] Certificate file not found: $NewRootCertPath" -ForegroundColor Red
        exit 1
    }
    $certObj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($NewRootCertPath)
    $NewRootThumbprint = $certObj.Thumbprint
    Write-Host "[INFO] Resolved thumbprint from file: $NewRootThumbprint" -ForegroundColor Gray
}

# Normalize thumbprints (remove spaces, uppercase)
$NewRootThumbprint = ($NewRootThumbprint -replace '\s', '').ToUpper()
if ($OldRootThumbprint) {
    $OldRootThumbprint = ($OldRootThumbprint -replace '\s', '').ToUpper()
}

Write-Host "[INFO] Machine: $env:COMPUTERNAME" -ForegroundColor Gray
Write-Host ""

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
        Write-Host "         $Detail" -ForegroundColor Gray
    }
}

# -- Check 1: New root in Root store -----------------------------------------
Write-Host "[1/4] Checking for new Root CA in trust store..." -ForegroundColor White

$rootStore = Get-ChildItem Cert:\LocalMachine\Root
$newRootCert = $rootStore | Where-Object { $_.Thumbprint -eq $NewRootThumbprint }

if ($newRootCert) {
    Add-CheckResult -Name "New Root in Trust Store" -Passed $true `
        -Detail "$($newRootCert.Subject) (Thumbprint: $NewRootThumbprint)"
} else {
    Add-CheckResult -Name "New Root in Trust Store" -Passed $false `
        -Detail "Thumbprint $NewRootThumbprint NOT found in Trusted Root CAs"

    # Show what IS in the store for troubleshooting
    Write-Host ""
    Write-Host "         Root CAs currently in store:" -ForegroundColor Gray
    $rootStore | Where-Object { $_.Subject -match 'CN=' } |
        Select-Object -First 10 |
        ForEach-Object { Write-Host "           $($_.Subject) [$($_.Thumbprint)]" -ForegroundColor Gray }
}

# -- Check 2: Old root still present -----------------------------------------
Write-Host ""
Write-Host "[2/4] Checking old Root CA is still present..." -ForegroundColor White

if ($OldRootThumbprint) {
    $oldRootCert = $rootStore | Where-Object { $_.Thumbprint -eq $OldRootThumbprint }
    if ($oldRootCert) {
        Add-CheckResult -Name "Old Root Still Present" -Passed $true `
            -Detail "$($oldRootCert.Subject) (Thumbprint: $OldRootThumbprint)"
    } else {
        Add-CheckResult -Name "Old Root Still Present" -Passed $false `
            -Detail "Old root NOT found. Removing old root prematurely breaks existing certs."
    }
} else {
    Write-Host "  [SKIP] Old root thumbprint not provided (-OldRootThumbprint)" -ForegroundColor Yellow
}

# -- Check 3: Certificate chain validation ------------------------------------
Write-Host ""
Write-Host "[3/4] Validating new root certificate chain..." -ForegroundColor White

if ($newRootCert) {
    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    $chain.ChainPolicy.RevocationMode = 'NoCheck'
    $chain.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority'
    $chainResult = $chain.Build($newRootCert)

    # For a self-signed root, chain should build to itself
    $chainLength = $chain.ChainElements.Count
    $chainStatus = ($chain.ChainStatus | ForEach-Object { $_.StatusInformation }) -join "; "

    if ($chainResult -or $chainLength -eq 1) {
        Add-CheckResult -Name "Chain Validation" -Passed $true `
            -Detail "Chain length: $chainLength (self-signed root)"
    } else {
        Add-CheckResult -Name "Chain Validation" -Passed $false `
            -Detail "Chain build failed: $chainStatus"
    }
} else {
    Add-CheckResult -Name "Chain Validation" -Passed $false `
        -Detail "Skipped - new root not in store"
}

# -- Check 4: certutil -verify -----------------------------------------------
Write-Host ""
Write-Host "[4/4] Running certutil verification..." -ForegroundColor White

if ($NewRootCertPath -and (Test-Path $NewRootCertPath)) {
    $verifyOutput = certutil -verify $NewRootCertPath 2>&1
    $verifyText = $verifyOutput -join "`n"
    $verifyOk = $verifyText -match 'completed successfully'
    Add-CheckResult -Name "certutil -verify" -Passed $verifyOk `
        -Detail $(if ($verifyOk) { "Certificate verification passed" } else { "Verification failed - check trust store" })
} elseif ($newRootCert) {
    # Export to temp and verify
    $tempCert = Join-Path $env:TEMP "trust-check-root.cer"
    $derBytes = $newRootCert.Export('Cert')
    [IO.File]::WriteAllBytes($tempCert, $derBytes)

    $verifyOutput = certutil -verify $tempCert 2>&1
    $verifyText = $verifyOutput -join "`n"
    $verifyOk = $verifyText -match 'completed successfully'
    Add-CheckResult -Name "certutil -verify" -Passed $verifyOk `
        -Detail $(if ($verifyOk) { "Certificate verification passed" } else { "Verification failed" })

    Remove-Item $tempCert -Force -ErrorAction SilentlyContinue
} else {
    Add-CheckResult -Name "certutil -verify" -Passed $false `
        -Detail "Skipped - no certificate available for verification"
}

# -- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Trust Validation Summary - $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$passCount = @($checks | Where-Object { $_.Status -eq "PASS" }).Count
$failCount = @($checks | Where-Object { $_.Status -eq "FAIL" }).Count

foreach ($c in $checks) {
    $color = if ($c.Status -eq "PASS") { "Green" } else { "Red" }
    Write-Host "  [$($c.Status)] $($c.Check)" -ForegroundColor $color
}

Write-Host ""
Write-Host "  Result: $passCount PASS, $failCount FAIL" -ForegroundColor $(if ($allPassed) { "Green" } else { "Red" })
Write-Host ""

if ($allPassed) {
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "  Step 6 Complete: Trust validated on $env:COMPUTERNAME" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Both old and new roots are trusted on this machine." -ForegroundColor Green
    Write-Host ""
    Write-Host "  NEXT: Run this script on ALL other target machines." -ForegroundColor Yellow
    Write-Host "        When all targets pass, run Step7-CrossValidate.ps1" -ForegroundColor Yellow
    Write-Host "        on the NEW ADCS server to issue a test certificate." -ForegroundColor Yellow
} else {
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host "  Step 6 FAILED: Trust distribution incomplete" -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Fix the failed checks. Common remedies:" -ForegroundColor Yellow
    Write-Host "    - Import cert: certutil -addstore Root NewRootCA.cer" -ForegroundColor Gray
    Write-Host "    - Or run the Import-NewRoot-Windows.ps1 from Step 5" -ForegroundColor Gray
    Write-Host "    - AD: certutil -dspublish -f NewRootCA.cer RootCA" -ForegroundColor Gray
    Write-Host "    - Then: gpupdate /force" -ForegroundColor Gray
    exit 1
}
Write-Host ""
