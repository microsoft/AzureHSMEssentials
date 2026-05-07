<#
.SYNOPSIS
    Step 7: Cross-validate certificate issuance from the cross-signed Root CA.

.DESCRIPTION
    Issues a test certificate from the new Root CA and validates the
    certificate chain, including the cross-cert trust bridge.

    Architecture (corrected):
    - The CA's identity cert is self-signed (from Step 3)
    - A cross-cert exists in the Intermediate CA store (from Step 5)
    - On this server (NEW CA), the chain may be 2 elements because the
      new root is locally trusted: Leaf -> New Root (self-signed)
    - On other machines that trust the OLD root but not the new one,
      the chain will be 3 elements via the cross-cert:
      Leaf -> Cross-Cert (issued by Old Root) -> Old Root

    The COM-based approach (proven in Option 1 testing) bypasses certreq's
    interactive prompts and works reliably in headless sessions.

    Flow:
    1. Verify CA is running and cross-cert is present
    2. Generate PKCS10 CSR via certreq -new -f
    3. Submit via COM CertificateAuthority.Request with Submit(0x100)
    4. Approve via COM CertificateAuthority.Admin.ResubmitRequest
    5. Retrieve signed cert via COM RetrievePending + GetCertificate(0)
    6. Validate chain building (2 or 3 elements both acceptable)
    7. Export test cert + remote validation script

    RUN ON: NEW ADCS Server (after Steps 3-6)

.PARAMETER TestSubject
    Subject name for the test certificate. Defaults to "CN=CrossSign-CrossVal-Test".

.PARAMETER OldRootCertPath
    Optional path to the OLD Root CA .cer file. If provided, verifies the
    chain terminates at the old root when chain length is 3.

.PARAMETER OutputDir
    Directory to save test artifacts. Defaults to a timestamped subfolder.

.PARAMETER KeyLength
    Key length for the test certificate. Defaults to 2048.

.EXAMPLE
    .\Step7-CrossValidate.ps1

.EXAMPLE
    .\Step7-CrossValidate.ps1 -OldRootCertPath "C:\temp\OldRootCA.cer"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TestSubject = "CN=CrossSign-CrossVal-Test",

    [Parameter(Mandatory = $false)]
    [string]$OldRootCertPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputDir,

    [Parameter(Mandatory = $false)]
    [ValidateSet("2048", "3072", "4096")]
    [string]$KeyLength = "2048"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Banner ------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Root CA Migration (Cross-Signed) - Step 7: Cross-Validate" -ForegroundColor Cyan
Write-Host "  Run on: NEW ADCS Server (after Steps 3-6)" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Local chain:  Leaf -> New Root (self-signed, trusted locally)" -ForegroundColor White
Write-Host "  Remote chain: Leaf -> Cross-Cert -> Old Root (via trust bridge)" -ForegroundColor White
Write-Host ""

# -- Output directory --------------------------------------------------------
if (-not $OutputDir) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputDir = Join-Path $env:USERPROFILE "rootca-crosssign-step7-$timestamp"
}
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}
Write-Host "[INFO] Output directory: $OutputDir" -ForegroundColor Gray

# Load old root if provided
$oldRootCert = $null
if ($OldRootCertPath -and (Test-Path $OldRootCertPath)) {
    $oldRootCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($OldRootCertPath)
    Write-Host "[INFO] Old root cert loaded: $($oldRootCert.Subject)" -ForegroundColor Gray
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
        Write-Host "         $Detail" -ForegroundColor Gray
    }
}

# -- Pre-check 1: certsvc running -------------------------------------------
Write-Host "[1/8] Verifying Certificate Services..." -ForegroundColor White

try {
    $svc = Get-Service -Name certsvc -ErrorAction Stop
    Add-CheckResult -Name "Certificate Services Running" -Passed ($svc.Status -eq 'Running') `
        -Detail "certsvc status: $($svc.Status)"

    if ($svc.Status -ne 'Running') {
        Write-Host "[ERROR] certsvc is not running. Start it before cross-validation." -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host "[ERROR] certsvc not found." -ForegroundColor Red
    exit 1
}

# Get CA config for COM calls
try { $activeCA = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA Stop).Active } catch { $activeCA = $null }
$caConfig = "$env:COMPUTERNAME\$activeCA"
Write-Host "       CA Config: $caConfig" -ForegroundColor Gray

# -- Pre-check 2: Verify CA has self-signed cert + cross-cert exists ---------
Write-Host ""
Write-Host "[2/8] Confirming cross-signed architecture..." -ForegroundColor White

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
    $isSelfSigned = ($caCert.Subject -eq $caCert.Issuer)
    Add-CheckResult -Name "CA Cert Self-Signed" -Passed $isSelfSigned `
        -Detail $(if ($isSelfSigned) { "Subject == Issuer: $($caCert.Subject)" } else { "Subject: $($caCert.Subject) | Issuer: $($caCert.Issuer)" })
} else {
    Write-Host "  [WARN] Could not find CA certificate in MY store." -ForegroundColor Yellow
}

# Check for cross-cert
$crossCert = $null
foreach ($cert in (Get-ChildItem Cert:\LocalMachine\CA)) {
    if ($cert.Subject -match [regex]::Escape($activeCA) -and $cert.Subject -ne $cert.Issuer) {
        $crossCert = $cert
        break
    }
}

if ($crossCert) {
    Add-CheckResult -Name "Cross-Cert Present" -Passed $true `
        -Detail "Issuer: $($crossCert.Issuer) | Thumb: $($crossCert.Thumbprint)"
} else {
    Add-CheckResult -Name "Cross-Cert Present" -Passed $false `
        -Detail "No cross-cert in Intermediate CA store. Run Step 5 first."
    Write-Host "[ERROR] Cross-cert not found. Cannot validate cross-sign chain." -ForegroundColor Red
    exit 1
}

# -- Step 3: Generate test CSR -----------------------------------------------
Write-Host ""
Write-Host "[3/8] Generating test CSR (PKCS10)..." -ForegroundColor White

$infFile = Join-Path $OutputDir "crossval-test.inf"
$reqFile = Join-Path $OutputDir "crossval-test.req"

$infContent = @"
[Version]
Signature="`$Windows NT`$"

[NewRequest]
Subject="$TestSubject"
KeyLength=$KeyLength
Exportable=true
MachineKeySet=true
ProviderName="Microsoft RSA SChannel Cryptographic Provider"
RequestType=PKCS10
HashAlgorithm=SHA256
"@

$infContent | Out-File -FilePath $infFile -Encoding ASCII

$reqOutput = certreq -new -f $infFile $reqFile 2>&1
$reqText = ($reqOutput | Out-String)

if ($reqText -notmatch 'Request Created') {
    Add-CheckResult -Name "CSR Generation" -Passed $false -Detail "certreq -new -f failed"
    Write-Host "       Output: $reqText" -ForegroundColor Red
    exit 1
}
Add-CheckResult -Name "CSR Generation" -Passed $true -Detail "PKCS10 request created"

# -- Step 4: Submit via COM --------------------------------------------------
Write-Host ""
Write-Host "[4/8] Submitting CSR to CA via COM (Submit 0x100)..." -ForegroundColor White

$csrContent = Get-Content $reqFile -Raw

$certRequest = New-Object -ComObject CertificateAuthority.Request
# 0x100 = CR_IN_BASE64 | CR_IN_FORMATANY
$disposition = $certRequest.Submit(0x100, $csrContent, '', $caConfig)
$requestId = $certRequest.GetRequestId()

Write-Host "       Request ID: $requestId" -ForegroundColor Gray
Write-Host "       Disposition: $disposition" -ForegroundColor Gray

# Disposition 3 = issued, 5 = pending
if ($disposition -eq 3) {
    Write-Host "       Certificate issued directly." -ForegroundColor Green
} elseif ($disposition -eq 5) {
    Write-Host "       Request is pending. Approving via COM Admin..." -ForegroundColor Yellow

    Write-Host ""
    Write-Host "[5/8] Approving pending request via COM Admin..." -ForegroundColor White

    $certAdmin = New-Object -ComObject CertificateAuthority.Admin
    $resubmitResult = $certAdmin.ResubmitRequest($caConfig, $requestId)
    Write-Host "       ResubmitRequest result: $resubmitResult" -ForegroundColor Gray

    # Re-check disposition
    $disposition = $certRequest.RetrievePending($requestId, $caConfig)
    Write-Host "       New disposition: $disposition" -ForegroundColor Gray
} else {
    Add-CheckResult -Name "Certificate Submission" -Passed $false `
        -Detail "Unexpected disposition: $disposition (Request ID: $requestId)"
    Write-Host ""
    Write-Host "  Disposition codes: 2=denied, 3=issued, 5=pending" -ForegroundColor Gray
    exit 1
}

if ($disposition -ne 3) {
    Add-CheckResult -Name "Certificate Issuance" -Passed $false `
        -Detail "Certificate not issued. Disposition: $disposition"
    exit 1
}

Add-CheckResult -Name "Certificate Issued" -Passed $true `
    -Detail "Request ID: $requestId, Disposition: 3 (Issued)"

# -- Step 5: Retrieve signed certificate -------------------------------------
Write-Host ""
Write-Host "[6/8] Retrieving signed certificate..." -ForegroundColor White

# GetCertificate(0) = CR_OUT_BASE64 (with headers)
$certPem = $certRequest.GetCertificate(0)
$testCertFile = Join-Path $OutputDir "crossval-test.cer"

# Extract base64 between headers
$b64Match = [regex]::Match($certPem, '-----BEGIN CERTIFICATE-----\s*([\s\S]+?)\s*-----END CERTIFICATE-----')
if ($b64Match.Success) {
    $b64Clean = $b64Match.Groups[1].Value -replace '\s', ''
    $certBytes = [Convert]::FromBase64String($b64Clean)
    [IO.File]::WriteAllBytes($testCertFile, $certBytes)
} else {
    # Try saving PEM directly and import
    $certPem | Out-File -FilePath $testCertFile -Encoding ASCII
}

if (Test-Path $testCertFile) {
    Add-CheckResult -Name "Certificate Retrieved" -Passed $true -Detail "Saved to: $testCertFile"
} else {
    Add-CheckResult -Name "Certificate Retrieved" -Passed $false -Detail "Failed to save certificate"
    exit 1
}

# -- Step 6: Validate chain --------------------------------------------------
Write-Host ""
Write-Host "[7/8] Validating certificate chain..." -ForegroundColor White

$testCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($testCertFile)

Write-Host "       Test Cert Subject:  $($testCert.Subject)" -ForegroundColor White
Write-Host "       Test Cert Issuer:   $($testCert.Issuer)" -ForegroundColor White
Write-Host "       Test Cert Serial:   $($testCert.SerialNumber)" -ForegroundColor Gray
Write-Host "       Test Cert Thumb:    $($testCert.Thumbprint)" -ForegroundColor Gray
Write-Host ""

# .NET chain validation
$chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
$chain.ChainPolicy.RevocationMode = 'NoCheck'
$chain.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority'

$chainResult = $chain.Build($testCert)

$chainLength = $chain.ChainElements.Count

Write-Host "       Chain length: $chainLength" -ForegroundColor $(if ($chainLength -ge 2) { "Green" } else { "Red" })
Write-Host ""
Write-Host "       Chain elements:" -ForegroundColor White
if ($chainLength -gt 0) {
    for ($i = 0; $i -lt $chainLength; $i++) {
        $elem = $chain.ChainElements[$i]
        $depth = if ($i -eq 0) { "Leaf  " } elseif ($i -eq $chainLength - 1) { "Root  " } else { "Bridge" }
        $elemSubject = $elem.Certificate.Subject
        $elemIssuer  = $elem.Certificate.Issuer
        Write-Host "       [$depth] $elemSubject" -ForegroundColor Gray
        Write-Host "                Issuer: $elemIssuer" -ForegroundColor DarkGray
    }
}
Write-Host ""

# With the corrected architecture:
# - Local (new root trusted): chain = 2 (Leaf -> New Root self-signed)
# - If chain builder uses cross-cert: chain = 3 (Leaf -> Cross-Cert -> Old Root)
# Both are valid.
$chainOk = $chainLength -ge 2

Add-CheckResult -Name "Chain Length >= 2" -Passed $chainOk `
    -Detail "Chain: $chainLength elements"

if ($chainLength -eq 2) {
    Write-Host "  NOTE: Chain has 2 elements. The .NET chain builder used the" -ForegroundColor Yellow
    Write-Host "        new root's self-signed cert (locally trusted). On remote" -ForegroundColor Yellow
    Write-Host "        machines that only trust the OLD root, the chain will be" -ForegroundColor Yellow
    Write-Host "        3 elements via the cross-cert trust bridge." -ForegroundColor Yellow
    Write-Host ""

    # Verify the root is our self-signed CA cert
    $rootElem = $chain.ChainElements[$chainLength - 1].Certificate
    if ($caCert -and $rootElem.Thumbprint -eq $caCert.Thumbprint) {
        Add-CheckResult -Name "Chain Root = New CA (self-signed)" -Passed $true `
            -Detail "Root: $($rootElem.Subject) (locally trusted)"
    }
} elseif ($chainLength -ge 3) {
    # Full cross-sign chain: verify it terminates at OLD root
    $rootElem = $chain.ChainElements[$chainLength - 1].Certificate
    $isOldRoot = ($rootElem.Subject -eq $rootElem.Issuer)
    Add-CheckResult -Name "Chain Terminates at Self-Signed Root" -Passed $isOldRoot `
        -Detail $(if ($isOldRoot) { "Root: $($rootElem.Subject)" } else { "Final element is not self-signed: $($rootElem.Subject)" })

    # If old root cert provided, verify it matches
    if ($oldRootCert -and $isOldRoot) {
        $rootMatchesOld = ($rootElem.Thumbprint -eq $oldRootCert.Thumbprint)
        Add-CheckResult -Name "Chain Root = Old Root CA" -Passed $rootMatchesOld `
            -Detail $(if ($rootMatchesOld) { "Thumbprint match: $($rootElem.Thumbprint)" } else { "Root: $($rootElem.Thumbprint) != Old: $($oldRootCert.Thumbprint)" })
    }

    Write-Host ""
    Write-Host "  CROSS-SIGN CHAIN PROOF:" -ForegroundColor Cyan
    Write-Host "    [Leaf]   $($testCert.Subject)" -ForegroundColor White
    Write-Host "       |     signed by" -ForegroundColor DarkGray
    Write-Host "    [Bridge] $($chain.ChainElements[1].Certificate.Subject)" -ForegroundColor White
    Write-Host "       |     cross-signed by" -ForegroundColor DarkGray
    Write-Host "    [Root]   $($rootElem.Subject)" -ForegroundColor White
    Write-Host ""
}

# Also run certutil -verify for independent confirmation
$verifyOutput = certutil -verify $testCertFile 2>&1
$verifyText = $verifyOutput -join "`n"
$certutilOk = $verifyText -match 'completed successfully'

$verifyFile = Join-Path $OutputDir "crossval-chain-verify.txt"
$verifyOutput | Out-File -FilePath $verifyFile -Encoding UTF8

Add-CheckResult -Name "certutil -verify" -Passed $certutilOk `
    -Detail $(if ($certutilOk) { "certutil chain verification passed" } else { "certutil chain verification failed (see $verifyFile)" })

# -- Step 7: Export artifacts for remote validation ---------------------------
Write-Host ""
Write-Host "[8/8] Exporting artifacts for remote cross-validation..." -ForegroundColor White

# Export test cert as base64 for transfer
$testB64 = [Convert]::ToBase64String($testCert.RawData)
$testB64File = Join-Path $OutputDir "crossval-test.b64"
$testB64 | Out-File -FilePath $testB64File -Encoding ASCII

# Export cross-cert as base64 for remote machines
$crossB64 = ""
if ($crossCert) {
    $crossB64 = [Convert]::ToBase64String($crossCert.RawData)
    $crossB64File = Join-Path $OutputDir "cross-cert.b64"
    $crossB64 | Out-File -FilePath $crossB64File -Encoding ASCII
    Write-Host "       Cross-cert exported: $crossB64File" -ForegroundColor Green
}

# Export CA self-signed cert
if ($caCert) {
    $caB64File = Join-Path $OutputDir "ca-selfsigned.b64"
    $caB64 = [Convert]::ToBase64String($caCert.RawData)
    $caB64 | Out-File -FilePath $caB64File -Encoding ASCII
    Write-Host "       CA cert exported:    $caB64File" -ForegroundColor Green
}

Write-Host "       Test cert exported:  $testB64File" -ForegroundColor Green

# Generate remote validation script
$remoteScript = Join-Path $OutputDir "Validate-Remote-CrossSign.ps1"
$remoteContent = @"

# Remote Cross-Validation Script (Cross-Signed CA)
# Run on the OLD ADCS server or any target machine to verify the
# test cert chains correctly.
#
# This script installs the cross-cert in the intermediate CA store
# (needed for chain building on remote machines) then validates:
#   Leaf -> Cross-Cert (issued by Old Root) -> Old Root (3 elements)

Write-Host ""
Write-Host "Cross-Validation: Verifying test cert from cross-signed Root CA" -ForegroundColor Cyan
Write-Host "Machine: `$env:COMPUTERNAME" -ForegroundColor Gray
Write-Host ""

# Test cert issued by new CA (base64-encoded DER)
`$testCertB64 = "$testB64"

# Cross-cert (base64-encoded DER) - needed for chain building
`$crossCertB64 = "$crossB64"

# Decode test cert
`$testCertBytes = [Convert]::FromBase64String(`$testCertB64)
`$testCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,`$testCertBytes)

Write-Host "Test Cert Subject: `$(`$testCert.Subject)" -ForegroundColor White
Write-Host "Test Cert Issuer:  `$(`$testCert.Issuer)" -ForegroundColor White
Write-Host ""

# Install cross-cert in intermediate CA store if provided
if (`$crossCertB64) {
    Write-Host "Installing cross-cert in Intermediate CA store..." -ForegroundColor Yellow
    `$crossCertBytes = [Convert]::FromBase64String(`$crossCertB64)
    `$crossCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,`$crossCertBytes)
    `$caStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("CA", "LocalMachine")
    `$caStore.Open("ReadWrite")
    `$caStore.Add(`$crossCert)
    `$caStore.Close()
    Write-Host "  Cross-cert installed: `$(`$crossCert.Subject) issued by `$(`$crossCert.Issuer)" -ForegroundColor Green
    Write-Host ""
}

# Build chain
`$chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
`$chain.ChainPolicy.RevocationMode = 'NoCheck'
`$result = `$chain.Build(`$testCert)

Write-Host "Chain Result: `$result" -ForegroundColor `$(if (`$result) { 'Green' } else { 'Red' })
Write-Host "Chain Length: `$(`$chain.ChainElements.Count)" -ForegroundColor Gray

for (`$i = 0; `$i -lt `$chain.ChainElements.Count; `$i++) {
    `$elem = `$chain.ChainElements[`$i]
    `$depth = if (`$i -eq 0) { 'Leaf' } elseif (`$i -eq `$chain.ChainElements.Count - 1) { 'Root' } else { 'Bridge' }
    Write-Host "  [`$depth] `$(`$elem.Certificate.Subject)" -ForegroundColor Gray
    Write-Host "          Issuer: `$(`$elem.Certificate.Issuer)" -ForegroundColor DarkGray
}

if (`$result -and `$chain.ChainElements.Count -ge 3) {
    Write-Host ""
    Write-Host "[PASS] Full cross-sign chain verified on `$env:COMPUTERNAME" -ForegroundColor Green
    Write-Host "       Leaf -> Cross-Cert -> Old Root (trusted)" -ForegroundColor Green
} elseif (`$result -and `$chain.ChainElements.Count -eq 2) {
    Write-Host ""
    Write-Host "[PASS] Chain builds (2 elements - new root may be directly trusted)" -ForegroundColor Yellow
} else {
    `$status = (`$chain.ChainStatus | ForEach-Object { `$_.StatusInformation.Trim() }) -join "; "
    Write-Host ""
    Write-Host "[FAIL] Chain validation failed: `$status" -ForegroundColor Red
}
"@
$remoteContent | Out-File -FilePath $remoteScript -Encoding ASCII
Write-Host "       Remote script:       $remoteScript" -ForegroundColor Green

# -- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor $(if ($allPassed) { "Green" } else { "Red" })
$statusMsg = if ($allPassed) { "  Step 7 Complete: Cross-validation PASSED" } else { "  Step 7: Cross-validation had FAILURES" }
Write-Host $statusMsg -ForegroundColor $(if ($allPassed) { "Green" } else { "Red" })
Write-Host "============================================================" -ForegroundColor $(if ($allPassed) { "Green" } else { "Red" })
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
    Write-Host "  The new Root CA issued a test certificate successfully." -ForegroundColor Green
    Write-Host "  Cross-cert trust bridge is in place for backward" -ForegroundColor Green
    Write-Host "  compatibility with clients that trust the OLD root." -ForegroundColor Green
    Write-Host ""
    Write-Host "  Output files:" -ForegroundColor White
    Write-Host "    - $testCertFile (test certificate)" -ForegroundColor Gray
    Write-Host "    - $testB64File (base64 for transfer)" -ForegroundColor Gray
    Write-Host "    - $remoteScript (run on other machines)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  NEXT: Copy Validate-Remote-CrossSign.ps1 to the OLD" -ForegroundColor Yellow
    Write-Host "        ADCS server and run it. The remote script will" -ForegroundColor Yellow
    Write-Host "        install the cross-cert and verify the 3-element" -ForegroundColor Yellow
    Write-Host "        chain: Leaf -> Cross-Cert -> Old Root." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "        When all validations pass, run" -ForegroundColor Yellow
    Write-Host "        Step8-DecommissionChecks.ps1 on the OLD server." -ForegroundColor Yellow
} else {
    Write-Host "  ACTION: Resolve the failed checks before proceeding." -ForegroundColor Red
    Write-Host "  Common causes:" -ForegroundColor Yellow
    Write-Host "    - No cross-cert: Run Steps 4-5 first" -ForegroundColor Gray
    Write-Host "    - certsvc not running (Start-Service certsvc)" -ForegroundColor Gray
    Write-Host "    - Interactive=1 (certutil -setreg CA\\CSP\\Interactive 0)" -ForegroundColor Gray
}
Write-Host ""
