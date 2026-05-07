<#
.SYNOPSIS
    ADCS integration sanity check for HSM-backed Root CAs.

.DESCRIPTION
    Validates that ADCS is fully operational by generating a test certificate
    request, submitting it to the CA, issuing it, and verifying the issued
    certificate was signed with the HSM-backed key.

    Supports both Azure Cloud HSM (Cavium KSP) and Azure Dedicated HSM (SafeNet KSP).

    Steps performed:
      1. Generate a test INF file with the correct HSM provider
      2. Create a certificate signing request (CSR) via certreq
      3. Verify the CSR references the correct KSP
      4. Submit the CSR to the local CA
      5. Approve/issue the pending request
      6. Retrieve the issued certificate
      7. Verify the certificate details and provider
      8. Clean up test artifacts (optional)

.PARAMETER Platform
    The HSM platform: AzureCloudHSM (default) or AzureDedicatedHSM.

.PARAMETER CAName
    The CA name to submit requests to. If omitted, auto-detects the local CA.

.PARAMETER OutputDir
    Directory for test artifacts (default: C:\temp\adcs-sanity-check).

.PARAMETER SkipCleanup
    Keep test artifacts (INF, REQ, CER files) after the check.

.PARAMETER SubjectCN
    Common Name for the test certificate (default: "ADCS-Sanity-Test").

.EXAMPLE
    .\ADCS-Sanity-Check.ps1 -Platform AzureCloudHSM

.EXAMPLE
    .\ADCS-Sanity-Check.ps1 -Platform AzureDedicatedHSM -SkipCleanup

.EXAMPLE
    .\ADCS-Sanity-Check.ps1 -Platform AzureDedicatedHSM -SubjectCN "MyTestCert"
#>

[CmdletBinding()]
param(
    [ValidateSet("AzureCloudHSM", "AzureDedicatedHSM")]
    [string]$Platform = "AzureCloudHSM",

    [string]$CAName,

    [string]$OutputDir = "C:\temp\adcs-sanity-check",

    [switch]$SkipCleanup,

    [string]$SubjectCN = "ADCS-Sanity-Test"
)

# ── Platform provider map ──────────────────────────────────────────────────
$ProviderMap = @{
    "AzureCloudHSM" = @{
        ProviderName = "Cavium Key Storage Provider"
        ProviderType = 32
    }
    "AzureDedicatedHSM" = @{
        ProviderName = "SafeNet Key Storage Provider"
        ProviderType = 0
    }
}

$provider     = $ProviderMap[$Platform]
$providerName = $provider.ProviderName
$providerType = $provider.ProviderType

# ── Paths ──────────────────────────────────────────────────────────────────
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

$infFile  = Join-Path $OutputDir "sanity-request-$timestamp.inf"
$reqFile  = Join-Path $OutputDir "sanity-request-$timestamp.req"
$cerFile  = Join-Path $OutputDir "sanity-cert-$timestamp.cer"

$passed   = 0
$failed   = 0
$warnings = 0

function Write-Result {
    param([string]$Label, [string]$Status, [string]$Detail)
    switch ($Status) {
        "PASS" { Write-Host "  [PASS] $Label" -ForegroundColor Green; $script:passed++ }
        "FAIL" { Write-Host "  [FAIL] $Label" -ForegroundColor Red; $script:failed++ }
        "WARN" { Write-Host "  [WARN] $Label" -ForegroundColor Yellow; $script:warnings++ }
        "INFO" { Write-Host "  [INFO] $Label" -ForegroundColor Cyan }
    }
    if ($Detail) { Write-Host "        $Detail" -ForegroundColor Gray }
}

# ══════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "======================================================" -ForegroundColor White
Write-Host "  ADCS Sanity Check" -ForegroundColor White
Write-Host "  Platform : $Platform" -ForegroundColor White
Write-Host "  Provider : $providerName" -ForegroundColor White
Write-Host "  Output   : $OutputDir" -ForegroundColor White
Write-Host "======================================================" -ForegroundColor White
Write-Host ""

# ── Step 0: Pre-flight checks ─────────────────────────────────────────────
Write-Host "[PRE-FLIGHT] Validating environment..." -ForegroundColor White

# Check admin
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    Write-Result "Running as Administrator" "PASS"
} else {
    Write-Result "Running as Administrator" "FAIL" "Re-run from an elevated PowerShell session"
    exit 1
}

# Check CertSvc running
$svc = Get-Service certsvc -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    Write-Result "Certificate Services Running" "PASS" "certsvc status: Running"
} else {
    Write-Result "Certificate Services Running" "FAIL" "certsvc is not running. Start it first: Start-Service certsvc"
    exit 1
}

# Auto-detect CA name
if (-not $CAName) {
    try {
        $caReg = certutil -getreg CA\CommonName 2>&1
        $caMatch = $caReg | Select-String "CommonName\s+REG_SZ\s+=\s+(.*)"
        if ($caMatch) {
            $caCommonName = $caMatch.Matches[0].Groups[1].Value.Trim()
            $serverName = $env:COMPUTERNAME
            $CAName = "$serverName\$caCommonName"
            Write-Result "CA Auto-detected" "PASS" $CAName
        } else {
            Write-Result "CA Auto-detect" "FAIL" "Could not read CA\CommonName from registry"
            exit 1
        }
    } catch {
        Write-Result "CA Auto-detect" "FAIL" $_.Exception.Message
        exit 1
    }
}

# Verify keys
$verifyOutput = certutil -verifykeys 2>&1
$verifyText = $verifyOutput -join " "
if ($verifyText -match "completed successfully") {
    Write-Result "HSM Key Verification" "PASS" "certutil -verifykeys succeeded"
} else {
    Write-Result "HSM Key Verification" "FAIL" "certutil -verifykeys failed: $verifyText"
    exit 1
}

Write-Host ""

# ── Step 1: Generate request INF ──────────────────────────────────────────
Write-Host "[STEP 1/7] Generating certificate request INF..." -ForegroundColor White

$infContent = @"
[Version]
Signature="`$Windows NT`$"

[NewRequest]
Subject = "CN=$SubjectCN, OU=ADCS-Sanity-Check, O=HSM-Scenario-Builder"
KeySpec = 2
KeyLength = 2048
ProviderName = "$providerName"
ProviderType = $providerType
RequestType = PKCS10
HashAlgorithm = SHA256
"@

Set-Content -Path $infFile -Value $infContent -Encoding ASCII
if (Test-Path $infFile) {
    Write-Result "INF file created" "PASS" $infFile
    Write-Host ""
    Write-Host "  INF Contents:" -ForegroundColor Gray
    Get-Content $infFile | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
} else {
    Write-Result "INF file created" "FAIL" "Could not create $infFile"
    exit 1
}

Write-Host ""

# ── Step 2: Generate CSR ──────────────────────────────────────────────────
Write-Host "[STEP 2/7] Generating certificate signing request (CSR)..." -ForegroundColor White

$certreqOutput = certreq -new $infFile $reqFile 2>&1
$certreqText = $certreqOutput -join " "
if (($certreqText -match "Request Created") -and (Test-Path $reqFile)) {
    Write-Result "CSR generated" "PASS" $reqFile
} else {
    Write-Result "CSR generated" "FAIL" "certreq -new failed: $certreqText"
    exit 1
}

Write-Host ""

# ── Step 3: Verify CSR references HSM provider ───────────────────────────
Write-Host "[STEP 3/7] Verifying CSR references HSM provider..." -ForegroundColor White

$dumpOutput = certutil -dump $reqFile 2>&1
$dumpText = $dumpOutput -join "`n"

if ($dumpText -match [regex]::Escape($providerName)) {
    Write-Result "CSR Provider" "PASS" "Provider = $providerName"
} else {
    Write-Result "CSR Provider" "FAIL" "Expected '$providerName' in CSR dump but not found"
}

if ($dumpText -match "CN=$([regex]::Escape($SubjectCN))") {
    Write-Result "CSR Subject" "PASS" "CN=$SubjectCN"
} else {
    Write-Result "CSR Subject" "FAIL" "Expected CN=$SubjectCN in CSR"
}

# Show relevant dump lines
$dumpOutput | ForEach-Object {
    $line = $_.ToString()
    if ($line -match "Provider|Subject:|CN=|Algorithm") {
        Write-Host "    $line" -ForegroundColor DarkGray
    }
}

Write-Host ""

# ── Step 4: Submit CSR to CA ──────────────────────────────────────────────
Write-Host "[STEP 4/7] Submitting CSR to CA ($CAName)..." -ForegroundColor White

$submitOutput = certreq -submit -config $CAName $reqFile $cerFile 2>&1
$submitText = $submitOutput -join "`n"

$requestId = $null

# Check if cert was issued immediately (auto-approve for standalone CA)
if (($submitText -match "certificate was issued") -and (Test-Path $cerFile)) {
    # Standalone CA auto-issued
    $idMatch = $submitText | Select-String "RequestId:\s*(\d+)"
    if ($idMatch) { $requestId = $idMatch.Matches[0].Groups[1].Value }
    Write-Result "CSR submitted and issued" "PASS" "RequestId: $requestId (auto-approved)"
} else {
    # May be pending -- extract RequestId
    $idMatch = $submitText | Select-String "RequestId:\s*(\d+)"
    if ($idMatch) {
        $requestId = $idMatch.Matches[0].Groups[1].Value
        Write-Result "CSR submitted" "PASS" "RequestId: $requestId (pending approval)"

        Write-Host ""

        # ── Step 5: Approve the request ───────────────────────────────
        Write-Host "[STEP 5/7] Approving pending request $requestId..." -ForegroundColor White

        $resubmitOutput = certutil -resubmit $requestId 2>&1
        $resubmitText = $resubmitOutput -join " "
        if ($resubmitText -match "completed successfully|Certificate issued") {
            Write-Result "Request approved" "PASS" "RequestId $requestId issued"
        } else {
            Write-Result "Request approved" "FAIL" "certutil -resubmit failed: $resubmitText"
            exit 1
        }

        Write-Host ""

        # ── Step 6: Retrieve the issued cert ──────────────────────────
        # Use ICertRequest COM to retrieve cert non-interactively (no GUI popups)
        Write-Host "[STEP 6/7] Retrieving issued certificate..." -ForegroundColor White

        try {
            $certReqObj = New-Object -ComObject CertificateAuthority.Request
            $disposition = $certReqObj.RetrievePending($requestId, $CAName)
            # Disposition 3 = Issued
            if ($disposition -eq 3) {
                # CR_OUT_BASE64 = 0x1
                $certBase64 = $certReqObj.GetCertificate(0x1)
                $certPem = "-----BEGIN CERTIFICATE-----`r`n$certBase64-----END CERTIFICATE-----`r`n"
                Set-Content -Path $cerFile -Value $certPem -Encoding ASCII
                Write-Result "Certificate retrieved" "PASS" $cerFile
            } else {
                Write-Result "Certificate retrieved" "FAIL" "Unexpected disposition: $disposition (expected 3=Issued)"
                exit 1
            }
        } catch {
            Write-Result "Certificate retrieved" "FAIL" $_.Exception.Message
            exit 1
        }
    } else {
        Write-Result "CSR submitted" "FAIL" "Could not determine RequestId: $submitText"
        exit 1
    }
}

# Steps 5/6 are skipped when auto-approved above

Write-Host ""

# ── Step 7: Verify the issued certificate ─────────────────────────────────
Write-Host "[STEP 7/7] Verifying issued certificate..." -ForegroundColor White

if (-not (Test-Path $cerFile)) {
    Write-Result "Certificate file" "FAIL" "Certificate file not found: $cerFile"
    exit 1
}

$certDump = certutil -dump $cerFile 2>&1
$certText = $certDump -join "`n"

# Check subject
if ($certText -match "CN=$([regex]::Escape($SubjectCN))") {
    Write-Result "Certificate Subject" "PASS" "CN=$SubjectCN"
} else {
    Write-Result "Certificate Subject" "FAIL" "CN=$SubjectCN not found in certificate"
}

# Check issuer is our CA
if ($certText -match "Issuer:.*CN=$([regex]::Escape($caCommonName))") {
    Write-Result "Certificate Issuer" "PASS" "Signed by $caCommonName"
} elseif ($certText -match [regex]::Escape($caCommonName)) {
    Write-Result "Certificate Issuer" "PASS" "Issuer contains $caCommonName"
} else {
    Write-Result "Certificate Issuer" "WARN" "Could not confirm issuer is $caCommonName"
}

# Check signature algorithm
if ($certText -match "sha256RSA|sha384RSA|sha512RSA") {
    $sigAlg = $Matches[0]
    Write-Result "Signature Algorithm" "PASS" $sigAlg
} else {
    Write-Result "Signature Algorithm" "WARN" "Could not determine signature algorithm"
}

# Check key length
if ($certText -match "Public Key Length:\s*(\d+)\s*bits") {
    $keyLen = $Matches[1]
    Write-Result "Key Length" "PASS" "$keyLen bits"
} else {
    Write-Result "Key Length" "WARN" "Could not determine key length"
}

# Show cert summary lines
Write-Host ""
Write-Host "  Certificate dump (key fields):" -ForegroundColor Gray
$certDump | ForEach-Object {
    $line = $_.ToString()
    if ($line -match "Subject:|Issuer:|NotBefore|NotAfter|Serial|Public Key Length|Signature Algorithm|Cert Hash") {
        Write-Host "    $line" -ForegroundColor DarkGray
    }
}

# ══════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "======================================================" -ForegroundColor White
Write-Host "  ADCS Sanity Check Results" -ForegroundColor White
Write-Host "======================================================" -ForegroundColor White
Write-Host ""
Write-Host "  Platform   : $Platform" -ForegroundColor White
Write-Host "  Provider   : $providerName" -ForegroundColor White
Write-Host "  CA         : $CAName" -ForegroundColor White
Write-Host "  Test Cert  : CN=$SubjectCN" -ForegroundColor White
Write-Host ""
Write-Host "  Passed     : $passed" -ForegroundColor Green
if ($warnings -gt 0) { Write-Host "  Warnings   : $warnings" -ForegroundColor Yellow }
if ($failed -gt 0) {
    Write-Host "  Failed     : $failed" -ForegroundColor Red
    Write-Host ""
    Write-Host "  RESULT: FAIL" -ForegroundColor Red
} else {
    Write-Host "  Failed     : 0" -ForegroundColor Green
    Write-Host ""
    Write-Host "  RESULT: PASS -- ADCS is issuing certificates with $providerName" -ForegroundColor Green
}

# ── Cleanup ───────────────────────────────────────────────────────────────
if (-not $SkipCleanup) {
    Write-Host ""
    Write-Host "  Cleaning up test artifacts..." -ForegroundColor Gray
    Remove-Item $infFile -ErrorAction SilentlyContinue
    Remove-Item $reqFile -ErrorAction SilentlyContinue
    Remove-Item $cerFile -ErrorAction SilentlyContinue
    # Remove the pending cert from the user store (certreq adds it)
    $testCerts = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -match $SubjectCN }
    $testCerts | ForEach-Object { Remove-Item $_.PSPath -ErrorAction SilentlyContinue }
    Write-Host "  Artifacts removed." -ForegroundColor Gray
} else {
    Write-Host ""
    Write-Host "  Test artifacts preserved in: $OutputDir" -ForegroundColor Gray
    Write-Host "    INF: $infFile" -ForegroundColor Gray
    Write-Host "    REQ: $reqFile" -ForegroundColor Gray
    Write-Host "    CER: $cerFile" -ForegroundColor Gray
}

Write-Host ""
