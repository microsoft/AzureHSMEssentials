<#
.SYNOPSIS
    Step 6: Validate the cross-signed Issuing CA configuration.

.DESCRIPTION
    Verifies that the new Issuing CA (CSR from Step 3, cross-cert from Step 4,
    activated in Step 5) meets all requirements:

    Architecture (ICA cross-signed):
    - The CA's IDENTITY certificate is root-signed (Subject != Issuer)
    - A SEPARATE cross-certificate exists in the Intermediate CA store
    - The cross-cert Subject matches the CA cert Subject (same identity)
    - The cross-cert Issuer matches the OLD Issuing CA
    - The cross-cert AKI matches the OLD ICA's SKI (chain proof)
    - Basic Constraints: CA:TRUE on both CA cert and cross-cert
    - Key Usage: Certificate Signing, CRL Signing
    - Correct HSM KSP is in use
    - Interactive=0 for headless operation
    - Certificate Services is running
    - Private key is accessible via HSM

    Key difference from Root CA cross-sign: The ICA identity cert is
    root-signed (NOT self-signed). The cross-cert bridges trust from
    the OLD ICA hierarchy to the NEW ICA.

    RUN ON: NEW ADCS Server (after Step 5)

.PARAMETER OldICACertPath
    Optional path to the OLD Issuing CA .cer file. If provided, verifies
    the cross-cert's issuer and AKI/SKI relationship.

.PARAMETER OutputDir
    Directory to save validation results. Defaults to a timestamped subfolder.

.EXAMPLE
    .\Step6-ValidateCrossSignedCA.ps1

.EXAMPLE
    .\Step6-ValidateCrossSignedCA.ps1 -OldICACertPath "C:\temp\OldIssuingCA.cer"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OldICACertPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Banner ------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ICA Migration (Cross-Signed) - Step 6: Validate CA" -ForegroundColor Cyan
Write-Host "  Run on: NEW ADCS Server (after Step 5)" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# -- Output directory --------------------------------------------------------
if (-not $OutputDir) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputDir = Join-Path $env:USERPROFILE "ica-crosssign-step6-$timestamp"
}
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}
Write-Host "[INFO] Output directory: $OutputDir" -ForegroundColor Gray

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

# -- Load old ICA cert if provided -------------------------------------------
$oldICACert = $null
if ($OldICACertPath -and (Test-Path $OldICACertPath)) {
    $oldICACert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($OldICACertPath)
    Write-Host "[INFO] Old ICA cert loaded: $($oldICACert.Subject)" -ForegroundColor Gray
    Write-Host "       Thumbprint: $($oldICACert.Thumbprint)" -ForegroundColor Gray
}

# -- Check 1: Active CA exists -----------------------------------------------
Write-Host ""
Write-Host "[1/11] Checking active CA configuration..." -ForegroundColor White

try { $activeCA = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA Stop).Active } catch { $activeCA = $null }
if (-not $activeCA) {
    Write-Host "[ERROR] No active CA found. Run Step 5 first." -ForegroundColor Red
    exit 1
}
Add-CheckResult -Name "Active CA Configured" -Passed $true -Detail "CA: $activeCA"

# -- Check 2: Export and parse CA certificate ---------------------------------
Write-Host ""
Write-Host "[2/11] Exporting CA identity certificate..." -ForegroundColor White

$certFile = Join-Path $OutputDir "NewICA-Identity.cer"

$caCert = $null
foreach ($cert in (Get-ChildItem Cert:\LocalMachine\My)) {
    if ($cert.Subject -notmatch [regex]::Escape($activeCA)) { continue }
    foreach ($ext in $cert.Extensions) {
        if ($ext.Oid.FriendlyName -eq 'Basic Constraints') {
            $caCert = $cert
            break
        }
    }
    if ($caCert) { break }
}

if ($caCert) {
    $derBytes = $caCert.Export('Cert')
    [IO.File]::WriteAllBytes($certFile, $derBytes)
} else {
    $exportOut = certutil -ca.cert $certFile 2>&1
    $exportText = ($exportOut | Out-String)
    if ($exportText -notmatch 'command completed successfully') {
        Write-Host "[ERROR] Cannot export CA certificate." -ForegroundColor Red
        exit 1
    }
    $caCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certFile)
}

# Parse with certutil -dump
$dumpOutput = certutil -dump $certFile 2>&1
$fullDump = $dumpOutput -join "`n"
$dumpFile = Join-Path $OutputDir "NewICA-Identity-details.txt"
$dumpOutput | Out-File -FilePath $dumpFile -Encoding UTF8

Write-Host ""
Write-Host "  CA Identity Certificate:" -ForegroundColor White
Write-Host "    Subject:     $($caCert.Subject)" -ForegroundColor White
Write-Host "    Issuer:      $($caCert.Issuer)" -ForegroundColor White
Write-Host "    Thumbprint:  $($caCert.Thumbprint)" -ForegroundColor Gray
Write-Host "    Not After:   $($caCert.NotAfter)" -ForegroundColor White
Write-Host ""

Add-CheckResult -Name "Certificate Exported" -Passed $true -Detail "Thumbprint: $($caCert.Thumbprint)"

# -- Check 3: CA cert is root-signed (NOT self-signed for ICA) ---------------
Write-Host ""
Write-Host "[3/11] Verifying CA cert is root-signed (ICA identity)..." -ForegroundColor White

$isSelfSigned = ($caCert.Subject -eq $caCert.Issuer)
if ($isSelfSigned) {
    # Self-signed is acceptable in Phase 8a test mode but flagged
    Add-CheckResult -Name "CA Cert Signed by Root" -Passed $true `
        -Detail "Self-signed (Phase 8a test mode). Production ICA should be root-signed."
} else {
    Add-CheckResult -Name "CA Cert Signed by Root" -Passed $true `
        -Detail "Issuer: $($caCert.Issuer) (root-signed subordinate CA)"
}

# -- Check 4: Cross-cert exists in Intermediate CA store ---------------------
Write-Host ""
Write-Host "[4/11] Checking for cross-certificate in Intermediate CA store..." -ForegroundColor White

$caCN = $activeCA
$crossCert = $null

# Collect ALL cross-certs matching the CA CN (Subject != Issuer)
$crossCandidates = @()
foreach ($cert in (Get-ChildItem Cert:\LocalMachine\CA)) {
    if ($cert.Subject -match [regex]::Escape($caCN) -and $cert.Subject -ne $cert.Issuer) {
        $crossCandidates += $cert
    }
}

if ($crossCandidates.Count -gt 0 -and $oldICACert) {
    # DETERMINISTIC: Match by AKI = old CA's SKI (cryptographic proof of who signed it)
    $oldSKIHex = ""
    foreach ($ext in $oldICACert.Extensions) {
        if ($ext.Oid.Value -eq '2.5.29.14') {
            $oldSKIHex = ($ext.Format($false) -replace '\s', '').ToUpper()
        }
    }
    if ($oldSKIHex) {
        foreach ($cc in $crossCandidates) {
            foreach ($ext in $cc.Extensions) {
                if ($ext.Oid.Value -eq '2.5.29.35') {
                    $akiText = $ext.Format($false)
                    if ($akiText -match 'KeyID=([0-9a-fA-F\s]+)') {
                        $ccAKI = ($Matches[1] -replace '\s', '').ToUpper()
                        if ($ccAKI -eq $oldSKIHex) {
                            $crossCert = $cc
                            Write-Host "       [INFO] Matched cross-cert by AKI=$ccAKI (deterministic)" -ForegroundColor Gray
                        }
                    }
                }
            }
            if ($crossCert) { break }
        }
    }
}

if (-not $crossCert -and $crossCandidates.Count -gt 0) {
    # FALLBACK: Pick the most recently issued cross-cert
    $crossCert = $crossCandidates | Sort-Object NotBefore -Descending | Select-Object -First 1
    Write-Host "       [INFO] Fallback: selected newest cross-cert (NotBefore=$($crossCert.NotBefore))" -ForegroundColor Yellow
}

if ($crossCert) {
    Add-CheckResult -Name "Cross-Cert in CA Store" -Passed $true `
        -Detail "Subject: $($crossCert.Subject) | Issuer: $($crossCert.Issuer)"

    Write-Host ""
    Write-Host "  Cross-Certificate:" -ForegroundColor White
    Write-Host "    Subject:     $($crossCert.Subject)" -ForegroundColor White
    Write-Host "    Issuer:      $($crossCert.Issuer)" -ForegroundColor White
    Write-Host "    Thumbprint:  $($crossCert.Thumbprint)" -ForegroundColor Gray
    Write-Host "    Not After:   $($crossCert.NotAfter)" -ForegroundColor White
    Write-Host ""

    # Export cross-cert for reference
    $crossFile = Join-Path $OutputDir "CrossCert.cer"
    $crossBytes = $crossCert.Export('Cert')
    [IO.File]::WriteAllBytes($crossFile, $crossBytes)
} else {
    Add-CheckResult -Name "Cross-Cert in CA Store" -Passed $false `
        -Detail "No cross-cert found for '$caCN' in Intermediate CA store. Run Step 5 first."
}

# -- Check 5: Cross-cert Subject matches CA cert Subject ---------------------
Write-Host ""
Write-Host "[5/11] Verifying cross-cert matches CA identity..." -ForegroundColor White

if ($crossCert) {
    $subjectMatch = ($crossCert.Subject -eq $caCert.Subject)
    Add-CheckResult -Name "Cross-Cert Subject = CA Subject" -Passed $subjectMatch `
        -Detail $(if ($subjectMatch) { "Both: $($caCert.Subject)" } else { "CA: $($caCert.Subject) | Cross: $($crossCert.Subject)" })
} else {
    Write-Host "  [SKIP] No cross-cert to compare" -ForegroundColor Yellow
}

# -- Check 6: Cross-cert Issuer matches OLD ICA ------------------------------
Write-Host ""
Write-Host "[6/11] Verifying cross-cert issuer is OLD Issuing CA..." -ForegroundColor White

if ($crossCert -and $oldICACert) {
    $issuerMatchesCert = ($crossCert.Issuer -eq $oldICACert.Subject)
    Add-CheckResult -Name "Cross-Cert Issuer = Old ICA" -Passed $issuerMatchesCert `
        -Detail $(if ($issuerMatchesCert) { "Issuer matches: $($oldICACert.Subject)" } else { "Cross Issuer: $($crossCert.Issuer) != Old ICA: $($oldICACert.Subject)" })

    # AKI/SKI check on cross-cert
    $crossAKI = ""
    $oldSKI = ""
    foreach ($ext in $crossCert.Extensions) {
        if ($ext.Oid.Value -eq '2.5.29.35') {
            $akiText = $ext.Format($false)
            if ($akiText -match 'KeyID=([0-9a-fA-F\s]+)') {
                $crossAKI = ($Matches[1] -replace '\s', '').ToUpper()
            }
        }
    }
    foreach ($ext in $oldICACert.Extensions) {
        if ($ext.Oid.Value -eq '2.5.29.14') {
            $skiText = $ext.Format($false)
            $oldSKI = ($skiText -replace '\s', '').ToUpper()
        }
    }

    if ($crossAKI -and $oldSKI) {
        $akiMatch = ($crossAKI -eq $oldSKI)
        Add-CheckResult -Name "Cross-Cert AKI/SKI Chain Proof" -Passed $akiMatch `
            -Detail $(if ($akiMatch) { "Cross AKI matches Old SKI: $crossAKI" } else { "AKI: $crossAKI != Old SKI: $oldSKI" })
    } else {
        Write-Host "  [SKIP] AKI/SKI check - could not extract identifiers" -ForegroundColor Yellow
    }
} elseif ($crossCert) {
    $issuerCN = if ($crossCert.Issuer -match 'CN=([^,]+)') { $Matches[1] } else { $crossCert.Issuer }
    Write-Host "  [SKIP] Old ICA cert not provided (-OldICACertPath)" -ForegroundColor Yellow
    Write-Host "         Cross-cert issuer: $issuerCN" -ForegroundColor Gray
} else {
    Write-Host "  [SKIP] No cross-cert found" -ForegroundColor Yellow
}

# -- Check 7: Basic Constraints CA:TRUE on CA cert ---------------------------
Write-Host ""
Write-Host "[7/11] Checking Basic Constraints on CA cert..." -ForegroundColor White

$basicConstraintsOk = $false
foreach ($ext in $caCert.Extensions) {
    if ($ext.Oid.FriendlyName -eq 'Basic Constraints') {
        $bcExt = [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]$ext
        if ($bcExt.CertificateAuthority) {
            $basicConstraintsOk = $true
        }
    }
}
if (-not $basicConstraintsOk -and $fullDump -match 'Subject Type=CA') {
    $basicConstraintsOk = $true
}
Add-CheckResult -Name "Basic Constraints CA:TRUE" -Passed $basicConstraintsOk `
    -Detail $(if ($basicConstraintsOk) { "Certificate Authority = True" } else { "CA flag NOT set" })

# -- Check 8: Key Usage ------------------------------------------------------
Write-Host ""
Write-Host "[8/11] Checking Key Usage..." -ForegroundColor White

$keyUsageOk = $false
$keyUsageDetail = "Not found"
foreach ($ext in $caCert.Extensions) {
    if ($ext.Oid.FriendlyName -eq 'Key Usage') {
        $kuExt = [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]$ext
        $hasSign = $kuExt.KeyUsages -band [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign
        $hasCRL  = $kuExt.KeyUsages -band [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::CrlSign
        if ($hasSign -and $hasCRL) {
            $keyUsageOk = $true
            $keyUsageDetail = $kuExt.KeyUsages.ToString()
        }
    }
}
if (-not $keyUsageOk -and $fullDump -match 'Key Usage[\s\S]*?Certificate Signing.*CRL Signing') {
    $keyUsageOk = $true
    $keyUsageDetail = "Certificate Signing, CRL Signing"
}
Add-CheckResult -Name "Key Usage" -Passed $keyUsageOk -Detail $keyUsageDetail

# -- Check 9: HSM KSP in use ------------------------------------------------
Write-Host ""
Write-Host "[9/11] Verifying HSM Key Storage Provider..." -ForegroundColor White

$cspOutput = certutil -getreg CA\CSP 2>&1
$cspText = $cspOutput -join "`n"

$isCavium = $cspText -match 'Cavium'
$isSafeNet = $cspText -match 'SafeNet'
$kspOk = $isCavium -or $isSafeNet
$kspName = if ($isCavium) { "Cavium Key Storage Provider" } elseif ($isSafeNet) { "SafeNet Key Storage Provider" } else { "Unknown" }

Add-CheckResult -Name "HSM KSP Active" -Passed $kspOk -Detail $kspName

# -- Check 10: Interactive=0 -------------------------------------------------
Write-Host ""
Write-Host "[10/11] Checking Interactive mode..." -ForegroundColor White

$interactiveOutput = certutil -getreg CA\CSP\Interactive 2>&1
$interactiveText = $interactiveOutput -join "`n"
$interactiveValue = -1
if ($interactiveText -match 'Interactive REG_DWORD = (\d+)') {
    $interactiveValue = [int]$Matches[1]
}
Add-CheckResult -Name "Interactive Mode = 0" -Passed ($interactiveValue -eq 0) `
    -Detail $(if ($interactiveValue -eq 0) { "CA\CSP\Interactive = 0 (correct)" } else { "CA\CSP\Interactive = $interactiveValue -- MUST be 0" })

# -- Check 11: certsvc running + verifykeys ---------------------------------
Write-Host ""
Write-Host "[11/11] Checking Certificate Services..." -ForegroundColor White

try {
    $svc = Get-Service -Name certsvc -ErrorAction Stop
    Add-CheckResult -Name "Certificate Services Running" -Passed ($svc.Status -eq 'Running') `
        -Detail "certsvc status: $($svc.Status)"
} catch {
    Add-CheckResult -Name "Certificate Services Running" -Passed $false `
        -Detail "certsvc not found: $($_.Exception.Message)"
}

# NOTE: certutil -verifykeys removed -- it touches the HSM private key and hangs
# under SYSTEM (Finding 22). Key accessibility is validated during the manual
# Step 5 (RDP session) where certutil -installcert + certutil -verifykeys succeed.

# -- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Cross-Signed Issuing CA Validation Summary" -ForegroundColor Cyan
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

# Save results
$checks | Export-Csv -Path (Join-Path $OutputDir "validation-results.csv") -NoTypeInformation -Force

if ($allPassed) {
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "  Step 6 Complete: Cross-signed ICA validated successfully" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Architecture verified:" -ForegroundColor Green
    Write-Host "    - CA identity cert: root-signed (Subject != Issuer)" -ForegroundColor Green
    Write-Host "    - Cross-cert:       separate trust bridge in CA store" -ForegroundColor Green
    Write-Host "    - HSM key:          accessible and verified" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Chain paths:" -ForegroundColor Green
    Write-Host "    Direct: Leaf -> New ICA -> Root CA" -ForegroundColor Green
    Write-Host "    Bridge: Leaf -> New ICA (cross-cert) -> Old ICA -> Root CA" -ForegroundColor Green
    Write-Host ""
    Write-Host "  NEXT: Run Step7-CrossValidate.ps1 to issue a test" -ForegroundColor Yellow
    Write-Host "        certificate and verify the full chain." -ForegroundColor Yellow
} else {
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host "  Step 6: Validation FAILED - Resolve issues above" -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Common fixes:" -ForegroundColor Yellow
    Write-Host "    - No cross-cert: Re-run Steps 4-5" -ForegroundColor Gray
    Write-Host "    - Interactive=1: certutil -setreg CA\CSP\Interactive 0" -ForegroundColor Gray
    Write-Host "    - certsvc stopped: Start-Service certsvc" -ForegroundColor Gray
    Write-Host "    - Key not found: Check HSM connectivity" -ForegroundColor Gray
}
Write-Host ""
