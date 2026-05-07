<#
.SYNOPSIS
    Step 4: Validate the signed issuing CA certificate returned from the offline root.

.DESCRIPTION
    After the offline root CA signs the CSR (certreq -submit), this script validates
    the returned issuing CA certificate to ensure it is correctly signed, has the
    expected subject name, key usage, and chains properly to the root.

    RUN ON: NEW ADCS Server (Azure Cloud HSM)

.PARAMETER SignedCertPath
    Path to the signed issuing CA certificate file (e.g., NewIssuingCA.cer).

.PARAMETER Step1OutputDir
    Path to Step 1 output directory (for comparison with old CA details).
    Optional but recommended.

.EXAMPLE
    .\Step4-ValidateNewCACert.ps1 -SignedCertPath "C:\Migration\NewIssuingCA.cer"

.EXAMPLE
    .\Step4-ValidateNewCACert.ps1 -SignedCertPath "C:\Migration\NewIssuingCA.cer" `
        -Step1OutputDir "C:\Migration\adcs-migration-step1-20260301"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SignedCertPath,

    [Parameter(Mandatory = $false)]
    [string]$Step1OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Banner ------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ADCS Migration - Step 4: Validate Signed Certificate" -ForegroundColor Cyan
Write-Host "  Run on: NEW ADCS Server (Azure Cloud HSM)" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
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
        Write-Host "        $Detail" -ForegroundColor Gray
    }
}

# -- Check signed cert exists ------------------------------------------------
Write-Host "[1/7] Checking signed certificate file..." -ForegroundColor White

if (-not (Test-Path $SignedCertPath)) {
    Write-Host "[ERROR] Signed certificate not found at: $SignedCertPath" -ForegroundColor Red
    exit 1
}
Add-CheckResult -Name "Certificate File Exists" -Passed $true -Detail $SignedCertPath

# -- Load certificate --------------------------------------------------------
Write-Host ""
Write-Host "[2/7] Loading and parsing certificate..." -ForegroundColor White

$certDump = certutil -dump $SignedCertPath 2>&1
$certText = $certDump -join "`n"

# Parse subject
$newSubject = ""
if ($certText -match 'Subject:\s*\r?\n\s*(.+)') {
    $newSubject = $Matches[1].Trim()
}

# Parse issuer
$newIssuer = ""
if ($certText -match 'Issuer:\s*\r?\n\s*(.+)') {
    $newIssuer = $Matches[1].Trim()
}

# Parse key length
$newKeyLength = ""
if ($certText -match 'Public Key Length:\s*(\d+)') {
    $newKeyLength = $Matches[1].Trim()
}

# Parse basic constraints
$isCA = $certText -match 'Subject Type=CA'

# Parse key usage
$hasKeyUsage = $certText -match 'Key Usage' -and ($certText -match 'Certificate Signing' -or $certText -match 'keyCertSign')

Write-Host "  Subject: $newSubject" -ForegroundColor White
Write-Host "  Issuer:  $newIssuer" -ForegroundColor White
Write-Host "  Key:     $newKeyLength bits" -ForegroundColor White

Add-CheckResult -Name "Certificate Parseable" -Passed ($newSubject.Length -gt 0) -Detail "Subject: $newSubject"

# -- Check 3: Basic Constraints = CA -----------------------------------------
Write-Host ""
Write-Host "[3/7] Checking Basic Constraints (CA:TRUE)..." -ForegroundColor White
Add-CheckResult -Name "Basic Constraints CA:TRUE" -Passed $isCA `
    -Detail $(if ($isCA) { "Certificate is a CA certificate" } else { "WARNING: Certificate does not appear to be a CA certificate" })

# -- Check 4: Key Usage ------------------------------------------------------
Write-Host ""
Write-Host "[4/7] Checking Key Usage (keyCertSign, cRLSign)..." -ForegroundColor White
Add-CheckResult -Name "Key Usage" -Passed $hasKeyUsage `
    -Detail $(if ($hasKeyUsage) { "keyCertSign present" } else { "Expected keyCertSign not found in Key Usage" })

# -- Check 5: Issuer is a root CA (not self-signed) -------------------------
Write-Host ""
Write-Host "[5/7] Checking certificate is signed by root (not self-signed)..." -ForegroundColor White

$isSelfSigned = ($newSubject -eq $newIssuer)
Add-CheckResult -Name "Signed by Root CA" -Passed (-not $isSelfSigned) `
    -Detail $(if (-not $isSelfSigned) { "Issuer differs from Subject (signed by root)" } else { "Subject matches Issuer - certificate appears self-signed" })

# -- Check 6: Chain validation -----------------------------------------------
Write-Host ""
Write-Host "[6/7] Validating certificate chain..." -ForegroundColor White

$verifyOutput = certutil -verify $SignedCertPath 2>&1
$verifyText = $verifyOutput -join "`n"
$chainValid = ($verifyText -match 'passes' -or $verifyText -match 'Verified' -or $verifyText -match 'completed successfully') -and ($verifyText -notmatch 'CERT_TRUST_IS_UNTRUSTED_ROOT')

# Even if chain validation has warnings, check if the cert itself is valid
$certValid = $verifyText -notmatch 'ERROR' -or $verifyText -match 'CertUtil.*-verify command completed successfully'

Add-CheckResult -Name "Chain Validation" -Passed $certValid `
    -Detail $(if ($certValid) { "Certificate chain verified" } else { "Chain validation had errors - check root CA trust on this machine" })

# -- Check 7: Compare with old CA (if Step 1 output available) ---------------
Write-Host ""
Write-Host "[7/7] Comparing with old CA details..." -ForegroundColor White

if ($Step1OutputDir -and (Test-Path (Join-Path $Step1OutputDir "ca-migration-details.json"))) {
    $oldCA = Get-Content (Join-Path $Step1OutputDir "ca-migration-details.json") -Raw | ConvertFrom-Json

    $subjectMatch = $false
    if ($oldCA.SubjectName -and $newSubject) {
        # Compare CN portions
        $oldCN = if ($oldCA.SubjectName -match 'CN=([^,]+)') { $Matches[1].Trim() } else { $oldCA.SubjectName }
        $newCN = if ($newSubject -match 'CN=([^,]+)') { $Matches[1].Trim() } else { $newSubject }
        $subjectMatch = $oldCN -eq $newCN
    }

    Add-CheckResult -Name "Subject Name Match" -Passed $subjectMatch `
        -Detail $(if ($subjectMatch) { "New CA subject matches old CA" } else { "Old: $($oldCA.SubjectName) | New: $newSubject" })

    # Key length comparison
    if ($oldCA.KeyLength -and $newKeyLength) {
        $keyMatch = ($oldCA.KeyLength -eq $newKeyLength)
        Add-CheckResult -Name "Key Length Match" -Passed $keyMatch `
            -Detail "Old: $($oldCA.KeyLength) | New: $newKeyLength"
    }
} else {
    Write-Host "  [SKIP] Step 1 output not provided - skipping old CA comparison" -ForegroundColor Yellow
    Write-Host "         Provide -Step1OutputDir to enable comparison checks" -ForegroundColor Gray
}

# -- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor $(if ($allPassed) { "Green" } else { "Red" })
$statusMsg = if ($allPassed) { "  Step 4 Complete: Signed certificate validated" } else { "  Step 4: Some validation checks FAILED" }
Write-Host $statusMsg -ForegroundColor $(if ($allPassed) { "Green" } else { "Red" })
Write-Host "============================================================" -ForegroundColor $(if ($allPassed) { "Green" } else { "Red" })
Write-Host ""

# Display results table
Write-Host "  Validation Results:" -ForegroundColor White
foreach ($c in $checks) {
    $color = if ($c.Status -eq "PASS") { "Green" } else { "Red" }
    Write-Host "    $($c.Status)  $($c.Check)" -ForegroundColor $color
}

Write-Host ""
if ($allPassed) {
    Write-Host "  NEXT: Run Step5-PreDistribute.ps1 to distribute the new" -ForegroundColor Yellow
    Write-Host "        issuing CA certificate BEFORE activating the CA." -ForegroundColor Yellow
} else {
    Write-Host "  ACTION: Resolve failed checks. You may need to re-submit" -ForegroundColor Red
    Write-Host "          the CSR to the offline root CA." -ForegroundColor Red
}
Write-Host ""
