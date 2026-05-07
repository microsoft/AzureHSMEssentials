<#
.SYNOPSIS
    Step 4: Validate the newly built Root CA certificate and configuration.

.DESCRIPTION
    Verifies that the new Root CA (built in Step 3) meets all requirements:
    - Certificate is self-signed (Subject == Issuer)
    - Basic Constraints: CA:TRUE
    - Key Usage: Certificate Signing, CRL Signing
    - Correct HSM KSP is in use
    - Interactive=0 for headless operation
    - Certificate Services is running
    - Private key is accessible via HSM (certutil -verifykeys)

    Optionally compares new CA details against Step 1 output to confirm
    key parameters match or exceed the old Root CA.

    RUN ON: NEW ADCS Server (after Step 3)

.PARAMETER Step1OutputDir
    Optional path to Step 1 output directory. If provided, compares the new
    CA configuration against the old Root CA details.

.PARAMETER OutputDir
    Directory to save validation results. Defaults to a timestamped subfolder.

.EXAMPLE
    .\Step4-ValidateNewCACert.ps1

.EXAMPLE
    .\Step4-ValidateNewCACert.ps1 -Step1OutputDir "C:\Migration\OldRoot"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Step1OutputDir,

    [Parameter(Mandatory = $false)]
    [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Banner ------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Root CA Migration - Step 4: Validate New Root CA" -ForegroundColor Cyan
Write-Host "  Run on: NEW ADCS Server (after Step 3)" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# -- Output directory --------------------------------------------------------
if (-not $OutputDir) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputDir = Join-Path $env:USERPROFILE "rootca-migration-step4-$timestamp"
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

# -- Check 1: Active CA exists -----------------------------------------------
Write-Host "[1/8] Checking active CA configuration..." -ForegroundColor White

try { $activeCA = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA Stop).Active } catch { $activeCA = $null }
if (-not $activeCA) {
    Write-Host "[ERROR] No active CA found. Run Step 3 first." -ForegroundColor Red
    exit 1
}
Add-CheckResult -Name "Active CA Configured" -Passed $true -Detail "CA: $activeCA"

# -- Check 2: Export and parse CA certificate ---------------------------------
Write-Host ""
Write-Host "[2/8] Exporting and parsing CA certificate..." -ForegroundColor White

$certFile = Join-Path $OutputDir "NewRootCA.cer"

# Export via PowerShell first
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
    # Fallback to certutil
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

$dumpFile = Join-Path $OutputDir "NewRootCA-details.txt"
$dumpOutput | Out-File -FilePath $dumpFile -Encoding UTF8

# Extract properties
$newSubject = ""
if ($fullDump -match 'Subject:\s*\r?\n\s*(.+)') { $newSubject = $Matches[1].Trim() }
$newIssuer = ""
if ($fullDump -match 'Issuer:\s*\r?\n\s*(.+)') { $newIssuer = $Matches[1].Trim() }
$newSerial = ""
if ($fullDump -match 'Serial Number:\s*\r?\n?\s*([0-9a-fA-F\s]+)') { $newSerial = ($Matches[1].Trim() -replace '\s+', '') }
$newNotBefore = ""
if ($fullDump -match 'NotBefore:\s*(.+)') { $newNotBefore = $Matches[1].Trim() }
$newNotAfter = ""
if ($fullDump -match 'NotAfter:\s*(.+)') { $newNotAfter = $Matches[1].Trim() }
$newKeyLength = ""
if ($fullDump -match 'Public Key Length:\s*(\d+)') { $newKeyLength = $Matches[1].Trim() }
$newThumbprint = $caCert.Thumbprint

Write-Host ""
Write-Host "  New Root CA Certificate:" -ForegroundColor White
Write-Host "    Subject:     $newSubject" -ForegroundColor White
Write-Host "    Issuer:      $newIssuer" -ForegroundColor White
Write-Host "    Serial:      $newSerial" -ForegroundColor Gray
Write-Host "    Thumbprint:  $newThumbprint" -ForegroundColor Gray
Write-Host "    Not Before:  $newNotBefore" -ForegroundColor White
Write-Host "    Not After:   $newNotAfter" -ForegroundColor White
Write-Host "    Key Length:  $newKeyLength" -ForegroundColor White
Write-Host ""

Add-CheckResult -Name "Certificate Exported" -Passed $true -Detail "Thumbprint: $newThumbprint"

# -- Check 3: Self-signed (Subject == Issuer) ---------------------------------
Write-Host ""
Write-Host "[3/8] Verifying certificate is self-signed..." -ForegroundColor White

$isSelfSigned = ($newSubject -eq $newIssuer)
Add-CheckResult -Name "Self-Signed Certificate" -Passed $isSelfSigned `
    -Detail $(if ($isSelfSigned) { "Subject and Issuer match: $newSubject" } else { "Subject: $newSubject differs from Issuer: $newIssuer" })

# -- Check 4: Basic Constraints CA:TRUE ---------------------------------------
Write-Host ""
Write-Host "[4/8] Checking Basic Constraints..." -ForegroundColor White

$basicConstraintsOk = $false
if ($fullDump -match 'Subject Type=CA') {
    $basicConstraintsOk = $true
}
# Also check via .NET
foreach ($ext in $caCert.Extensions) {
    if ($ext.Oid.FriendlyName -eq 'Basic Constraints') {
        $bcExt = [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]$ext
        if ($bcExt.CertificateAuthority) {
            $basicConstraintsOk = $true
        }
    }
}
Add-CheckResult -Name "Basic Constraints CA:TRUE" -Passed $basicConstraintsOk `
    -Detail $(if ($basicConstraintsOk) { "Certificate Authority = True" } else { "CA flag NOT set. This is not a CA certificate." })

# -- Check 5: Key Usage ------------------------------------------------------
Write-Host ""
Write-Host "[5/8] Checking Key Usage..." -ForegroundColor White

$keyUsageOk = $false
$keyUsageDetail = "Not found"
if ($fullDump -match 'Key Usage[\s\S]*?Certificate Signing.*CRL Signing') {
    $keyUsageOk = $true
    $keyUsageDetail = "Certificate Signing, CRL Signing"
}
# Also check via .NET
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
Add-CheckResult -Name "Key Usage" -Passed $keyUsageOk -Detail $keyUsageDetail

# -- Check 6: HSM KSP in use -------------------------------------------------
Write-Host ""
Write-Host "[6/8] Verifying HSM Key Storage Provider..." -ForegroundColor White

$cspOutput = certutil -getreg CA\CSP 2>&1
$cspText = $cspOutput -join "`n"

$isCavium = $cspText -match 'Cavium'
$isSafeNet = $cspText -match 'SafeNet'
$kspOk = $isCavium -or $isSafeNet
$kspName = if ($isCavium) { "Cavium Key Storage Provider" } elseif ($isSafeNet) { "SafeNet Key Storage Provider" } else { "Unknown" }

Add-CheckResult -Name "HSM KSP Active" -Passed $kspOk -Detail $kspName

# -- Check 7: Interactive=0 ---------------------------------------------------
Write-Host ""
Write-Host "[7/8] Checking Interactive mode..." -ForegroundColor White

$interactiveOutput = certutil -getreg CA\CSP\Interactive 2>&1
$interactiveText = $interactiveOutput -join "`n"
$interactiveValue = -1
if ($interactiveText -match 'Interactive REG_DWORD = (\d+)') {
    $interactiveValue = [int]$Matches[1]
}
Add-CheckResult -Name "Interactive Mode = 0" -Passed ($interactiveValue -eq 0) `
    -Detail $(if ($interactiveValue -eq 0) { "CA\CSP\Interactive = 0 (correct)" } else { "CA\CSP\Interactive = $interactiveValue -- MUST be 0" })

# -- Check 8: certsvc running + verifykeys ------------------------------------
Write-Host ""
Write-Host "[8/8] Checking Certificate Services and key accessibility..." -ForegroundColor White

try {
    $svc = Get-Service -Name certsvc -ErrorAction Stop
    Add-CheckResult -Name "Certificate Services Running" -Passed ($svc.Status -eq 'Running') `
        -Detail "certsvc status: $($svc.Status)"
} catch {
    Add-CheckResult -Name "Certificate Services Running" -Passed $false `
        -Detail "certsvc not found: $($_.Exception.Message)"
}

# Verify private key in HSM
Write-Host ""
$verifyKeysOutput = certutil -verifykeys 2>&1
$verifyKeysText = $verifyKeysOutput -join "`n"
$keysOk = ($verifyKeysText -match 'completed successfully') -or ($verifyKeysText -match 'PASS') -or ($verifyKeysText -match 'Signature test passed')
Add-CheckResult -Name "Private Key in HSM" -Passed $keysOk `
    -Detail $(if ($keysOk) { "certutil -verifykeys passed" } else { "Key verification failed - check HSM connectivity" })

# -- Optional: Compare with Step 1 -------------------------------------------
if ($Step1OutputDir) {
    $jsonFile = Join-Path $Step1OutputDir "rootca-migration-details.json"
    if (Test-Path $jsonFile) {
        Write-Host ""
        Write-Host "  --- Comparison with Old Root CA ---" -ForegroundColor Cyan
        $oldCA = Get-Content $jsonFile -Raw | ConvertFrom-Json

        $compares = @(
            @{ Field = "Key Length"; Old = $oldCA.KeyLength; New = $newKeyLength },
            @{ Field = "Subject";    Old = $oldCA.SubjectName; New = $newSubject }
        )

        foreach ($c in $compares) {
            $match = $c.Old -eq $c.New
            $tag = if ($match) { "SAME" } else { "DIFFERENT" }
            $color = if ($match) { "White" } else { "Yellow" }
            Write-Host "    $($c.Field): Old=$($c.Old) | New=$($c.New) [$tag]" -ForegroundColor $color
        }

        # Subject MUST be different for G2
        if ($oldCA.SubjectName -eq $newSubject) {
            Write-Host ""
            Write-Host "    [WARN] Subject name is IDENTICAL to old root." -ForegroundColor Red
            Write-Host "           This will cause chain ambiguity. Use a -G2 suffix." -ForegroundColor Red
        }
        Write-Host ""
    }
}

# -- Save validation results --------------------------------------------------
$resultsFile = Join-Path $OutputDir "validation-results.json"
$results = @{
    CAName      = $activeCA
    Subject     = $newSubject
    Issuer      = $newIssuer
    Serial      = $newSerial
    Thumbprint  = $newThumbprint
    NotBefore   = $newNotBefore
    NotAfter    = $newNotAfter
    KeyLength   = $newKeyLength
    SelfSigned  = $isSelfSigned
    KSP         = $kspName
    Interactive = $interactiveValue
    AllPassed   = $allPassed
}
$results | ConvertTo-Json -Depth 3 | Out-File -FilePath $resultsFile -Encoding UTF8

# -- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Validation Summary" -ForegroundColor Cyan
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
    Write-Host "  Step 4 Complete: New Root CA validated" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Output: $OutputDir" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  NEXT: Run Step5-PreDistribute.ps1 on this server" -ForegroundColor Yellow
    Write-Host "        to export the new root certificate for distribution" -ForegroundColor Yellow
    Write-Host "        to relying parties." -ForegroundColor Yellow
} else {
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host "  Step 4 INCOMPLETE: Fix failures before proceeding" -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    exit 1
}
Write-Host ""
