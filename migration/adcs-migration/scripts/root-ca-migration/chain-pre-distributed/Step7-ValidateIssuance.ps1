<#
.SYNOPSIS
    Step 7: Cross-validate certificate issuance from the new Root CA.

.DESCRIPTION
    Issues a test certificate from the new Root CA using COM-based submission
    (the same pattern proven in manual migration testing), then validates the
    certificate chain on both the local machine and optionally a remote target.

    The COM-based approach bypasses certreq's interactive prompts and works
    reliably in headless sessions (az vm run-command, scheduled tasks, etc.).

    Flow:
    1. Generate PKCS10 CSR via certreq -new -f
    2. Submit via COM CertificateAuthority.Request with Submit(0x100)
    3. Approve via COM CertificateAuthority.Admin.ResubmitRequest
    4. Retrieve signed cert via COM RetrievePending + GetCertificate(0)
    5. Validate chain on local machine
    6. Export test cert for remote validation

    RUN ON: NEW ADCS Server (after Steps 3-6)

.PARAMETER TestSubject
    Subject name for the test certificate. Defaults to "CN=RootCA-CrossVal-Test".

.PARAMETER OutputDir
    Directory to save test artifacts. Defaults to a timestamped subfolder.

.PARAMETER KeyLength
    Key length for the test certificate. Defaults to 2048.

.EXAMPLE
    .\Step7-CrossValidate.ps1

.EXAMPLE
    .\Step7-CrossValidate.ps1 -TestSubject "CN=MigrationTest-$(Get-Date -Format yyyyMMdd)"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TestSubject = "CN=RootCA-CrossVal-Test",

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
Write-Host "  Root CA Migration - Step 7: Cross-Validate Issuance" -ForegroundColor Cyan
Write-Host "  Run on: NEW ADCS Server (after Steps 3-6)" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# -- Output directory --------------------------------------------------------
if (-not $OutputDir) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputDir = Join-Path $env:USERPROFILE "rootca-migration-step7-$timestamp"
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

# -- Pre-check: certsvc running ----------------------------------------------
Write-Host "[1/7] Verifying Certificate Services..." -ForegroundColor White

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

# -- Step 2: Generate test CSR -----------------------------------------------
Write-Host ""
Write-Host "[2/7] Generating test CSR (PKCS10)..." -ForegroundColor White

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

# -- Step 3: Submit via COM with Disposition flags ----------------------------
Write-Host ""
Write-Host "[3/7] Submitting CSR to CA via COM (Submit 0x100)..." -ForegroundColor White

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

    # -- Step 4: Approve pending request via COM Admin -------------------------
    Write-Host ""
    Write-Host "[4/7] Approving pending request via COM Admin..." -ForegroundColor White

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
Write-Host "[5/7] Retrieving signed certificate..." -ForegroundColor White

# GetCertificate(0) = CR_OUT_BASE64 (with headers)
$certPem = $certRequest.GetCertificate(0)
$certFile = Join-Path $OutputDir "crossval-test.cer"

# Extract base64 between headers
$b64Match = [regex]::Match($certPem, '-----BEGIN CERTIFICATE-----\s*([\s\S]+?)\s*-----END CERTIFICATE-----')
if ($b64Match.Success) {
    $b64Clean = $b64Match.Groups[1].Value -replace '\s', ''
    $certBytes = [Convert]::FromBase64String($b64Clean)
    [IO.File]::WriteAllBytes($certFile, $certBytes)
} else {
    # Try saving PEM directly and import
    $certPem | Out-File -FilePath $certFile -Encoding ASCII
}

if (Test-Path $certFile) {
    Add-CheckResult -Name "Certificate Retrieved" -Passed $true -Detail "Saved to: $certFile"
} else {
    Add-CheckResult -Name "Certificate Retrieved" -Passed $false -Detail "Failed to save certificate"
    exit 1
}

# -- Step 6: Validate certificate chain on local machine ----------------------
Write-Host ""
Write-Host "[6/7] Validating certificate chain on local machine..." -ForegroundColor White

$testCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certFile)

Write-Host "       Test Cert Subject:  $($testCert.Subject)" -ForegroundColor White
Write-Host "       Test Cert Issuer:   $($testCert.Issuer)" -ForegroundColor White
Write-Host "       Test Cert Serial:   $($testCert.SerialNumber)" -ForegroundColor Gray
Write-Host "       Test Cert Thumb:    $($testCert.Thumbprint)" -ForegroundColor Gray
Write-Host ""

# .NET chain validation
$chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
$chain.ChainPolicy.RevocationMode = 'NoCheck'
$chainResult = $chain.Build($testCert)

$chainLength = $chain.ChainElements.Count
$chainStatusInfo = ($chain.ChainStatus | ForEach-Object { $_.StatusInformation.Trim() }) -join "; "

Write-Host "       Chain length: $chainLength" -ForegroundColor Gray
if ($chainLength -gt 0) {
    for ($i = 0; $i -lt $chainLength; $i++) {
        $elem = $chain.ChainElements[$i]
        $depth = if ($i -eq 0) { "Leaf" } elseif ($i -eq $chainLength - 1) { "Root" } else { "ICA" }
        Write-Host "       [$depth] $($elem.Certificate.Subject)" -ForegroundColor Gray
    }
}

Add-CheckResult -Name "Chain Validation (Local)" -Passed $chainResult `
    -Detail $(if ($chainResult) { "Chain builds to trusted root ($chainLength elements)" } else { "Chain failed: $chainStatusInfo" })

# Also run certutil -verify for independent confirmation
$verifyOutput = certutil -verify $certFile 2>&1
$verifyText = $verifyOutput -join "`n"
$certutilOk = $verifyText -match 'completed successfully'

$verifyFile = Join-Path $OutputDir "crossval-chain-verify.txt"
$verifyOutput | Out-File -FilePath $verifyFile -Encoding UTF8

Add-CheckResult -Name "certutil -verify" -Passed $certutilOk `
    -Detail $(if ($certutilOk) { "certutil chain verification passed" } else { "certutil chain verification failed (see $verifyFile)" })

# -- Step 7: Export artifacts for remote validation ---------------------------
Write-Host ""
Write-Host "[7/7] Exporting artifacts for remote cross-validation..." -ForegroundColor White

# Export test cert as base64 for transfer to other machines
$testB64 = [Convert]::ToBase64String($testCert.RawData)
$testB64File = Join-Path $OutputDir "crossval-test.b64"
$testB64 | Out-File -FilePath $testB64File -Encoding ASCII

# Also export the root CA cert
$rootCert = $null
foreach ($cert in (Get-ChildItem Cert:\LocalMachine\My)) {
    if ($cert.Subject -notmatch [regex]::Escape($activeCA)) { continue }
    foreach ($ext in $cert.Extensions) {
        if ($ext.Oid.FriendlyName -eq 'Basic Constraints') {
            $rootCert = $cert
            break
        }
    }
    if ($rootCert) { break }
}

if ($rootCert) {
    $rootB64File = Join-Path $OutputDir "root-ca.b64"
    $rootB64 = [Convert]::ToBase64String($rootCert.RawData)
    $rootB64 | Out-File -FilePath $rootB64File -Encoding ASCII
    Write-Host "       Root CA cert exported: $rootB64File" -ForegroundColor Green
}

Write-Host "       Test cert exported:   $testB64File" -ForegroundColor Green

# Generate remote validation script
$remoteScript = Join-Path $OutputDir "Validate-Remote.ps1"
$remoteContent = @"

# Remote Cross-Validation Script
# Run on the OLD ADCS server (or any target machine) to verify the test cert
# issued by the new Root CA chains correctly on that machine.

Write-Host ""
Write-Host "Cross-Validation: Verifying test cert from new Root CA" -ForegroundColor Cyan
Write-Host "Machine: `$env:COMPUTERNAME" -ForegroundColor Gray
Write-Host ""

# Test cert issued by new CA (base64-encoded DER)
`$testCertB64 = "$testB64"

# Decode and import
`$testCertBytes = [Convert]::FromBase64String(`$testCertB64)
`$testCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,`$testCertBytes)

Write-Host "Test Cert Subject: `$(`$testCert.Subject)" -ForegroundColor White
Write-Host "Test Cert Issuer:  `$(`$testCert.Issuer)" -ForegroundColor White
Write-Host ""

# Build chain
`$chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
`$chain.ChainPolicy.RevocationMode = 'NoCheck'
`$result = `$chain.Build(`$testCert)

Write-Host "Chain Result: `$result" -ForegroundColor `$(if (`$result) { 'Green' } else { 'Red' })
Write-Host "Chain Length: `$(`$chain.ChainElements.Count)" -ForegroundColor Gray

for (`$i = 0; `$i -lt `$chain.ChainElements.Count; `$i++) {
    `$elem = `$chain.ChainElements[`$i]
    Write-Host "  [`$i] `$(`$elem.Certificate.Subject)" -ForegroundColor Gray
}

if (`$result) {
    Write-Host ""
    Write-Host "[PASS] Test cert chains to trusted root on `$env:COMPUTERNAME" -ForegroundColor Green
} else {
    `$status = (`$chain.ChainStatus | ForEach-Object { `$_.StatusInformation.Trim() }) -join "; "
    Write-Host ""
    Write-Host "[FAIL] Chain validation failed: `$status" -ForegroundColor Red
}
"@
$remoteContent | Out-File -FilePath $remoteScript -Encoding ASCII
Write-Host "       Remote validation script: $remoteScript" -ForegroundColor Green

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
    Write-Host "  The new Root CA successfully issued and signed a test" -ForegroundColor Green
    Write-Host "  certificate, and the chain validates on this machine." -ForegroundColor Green
    Write-Host ""
    Write-Host "  Output files:" -ForegroundColor White
    Write-Host "    - $certFile (test certificate)" -ForegroundColor Gray
    Write-Host "    - $testB64File (base64 for transfer)" -ForegroundColor Gray
    Write-Host "    - $remoteScript (run on other machines)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  NEXT: Copy Validate-Remote.ps1 to the OLD ADCS server" -ForegroundColor Yellow
    Write-Host "        and other target machines to confirm the test" -ForegroundColor Yellow
    Write-Host "        certificate chains correctly everywhere." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "        When all remote validations pass, run" -ForegroundColor Yellow
    Write-Host "        Step8-DecommissionChecks.ps1 on the OLD server" -ForegroundColor Yellow
    Write-Host "        to assess decommission readiness." -ForegroundColor Yellow
} else {
    Write-Host "  ACTION: Resolve the failed checks before proceeding." -ForegroundColor Red
    Write-Host "  Common causes:" -ForegroundColor Yellow
    Write-Host "    - New root not in trust store (run Step 6)" -ForegroundColor Gray
    Write-Host "    - certsvc not running (start with Start-Service certsvc)" -ForegroundColor Gray
    Write-Host "    - Interactive=1 causing HSM prompts (certutil -setreg CA\\CSP\\Interactive 0)" -ForegroundColor Gray
}
Write-Host ""
