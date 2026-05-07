<#
.SYNOPSIS
    Step 3: Configure Subordinate CA and generate CSR using Azure Cloud HSM.

.DESCRIPTION
    Configures the ADCS Subordinate CA role on the new server and generates a
    Certificate Signing Request (CSR) using Install-AdcsCertificationAuthority
    with -OutputCertRequestFile. The private key is generated inside the HSM
    via the Cavium Key Storage Provider.

    This approach (vs. certreq -new) properly configures the CA role, leaving
    it in "pending cert install" state so that Step 5's certutil -installcert
    can complete the activation.

    After CSR generation:
    1. Submit the CSR to the parent Root CA for signing
    2. Copy the root-signed ICA cert AND the CSR to the OLD ADCS server
    3. Run Step4-CrossSignNewCA.ps1 on the OLD server to create the cross-cert

    RUN ON: NEW ADCS Server (Azure Cloud HSM)

.PARAMETER Step1OutputDir
    Path to the output directory from Step 1 (contains ca-migration-details.json).

.PARAMETER OutputDir
    Directory to save the CSR and diagnostic files. Defaults to a timestamped subfolder.

.PARAMETER SubjectName
    Override the CA Common Name. If omitted, extracts CN from Step 1 output subject.
    Provide the CN value only (e.g., "CHSM-IssuingCA"), not a full DN.

.PARAMETER KeyLength
    Key length for the new CA key. Defaults to the same as the old CA, or 4096.

.PARAMETER HashAlgorithm
    Hash algorithm for the CSR. Defaults to SHA256.

.PARAMETER OverwriteExisting
    Allow overwriting an existing CA configuration on this server.

.EXAMPLE
    .\Step3-GenerateCSR.ps1 -Step1OutputDir "C:\Migration\ica-crosssign-step1-20260301"

.EXAMPLE
    .\Step3-GenerateCSR.ps1 -Step1OutputDir "C:\Migration\step1" -SubjectName "CHSM-IssuingCA" -KeyLength 2048
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Step1OutputDir,

    [Parameter(Mandatory = $false)]
    [string]$OutputDir,

    [Parameter(Mandatory = $false)]
    [string]$SubjectName,

    [Parameter(Mandatory = $false)]
    [ValidateSet("RSA", "ECDSA_P256", "ECDSA_P384", "ECDSA_P521")]
    [string]$KeyAlgorithm,

    [Parameter(Mandatory = $false)]
    [string]$KeyLength,

    [Parameter(Mandatory = $false)]
    [ValidateSet("SHA256", "SHA384", "SHA512")]
    [string]$HashAlgorithm = "SHA256",

    [Parameter(Mandatory = $false)]
    [switch]$OverwriteExisting
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Banner ------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ICA Migration (Cross-Signed) - Step 3: Configure Sub CA" -ForegroundColor Cyan
Write-Host "  Run on: NEW ADCS Server (Azure Cloud HSM)" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# -- Output directory --------------------------------------------------------
if (-not $OutputDir) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputDir = Join-Path $env:USERPROFILE "ica-crosssign-step3-$timestamp"
}
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}
Write-Host "[INFO] Output directory: $OutputDir" -ForegroundColor Gray

# -- Load Step 1 details ----------------------------------------------------
Write-Host ""
Write-Host "[1/7] Loading existing CA details from Step 1..." -ForegroundColor White

$jsonFile = Join-Path $Step1OutputDir "ca-migration-details.json"
if (-not (Test-Path $jsonFile)) {
    Write-Host "[ERROR] Cannot find ca-migration-details.json in: $Step1OutputDir" -ForegroundColor Red
    Write-Host "        Run Step1-CaptureExistingCA.ps1 on the OLD ADCS server first." -ForegroundColor Red
    exit 1
}

$oldCA = Get-Content $jsonFile -Raw | ConvertFrom-Json
Write-Host "       Loaded CA details:" -ForegroundColor Green
Write-Host "         Subject:   $($oldCA.SubjectName)" -ForegroundColor Gray
Write-Host "         Algorithm: $($oldCA.KeyAlgorithm)" -ForegroundColor Gray
Write-Host "         Key Size:  $($oldCA.KeyLength)" -ForegroundColor Gray
Write-Host "         Provider:  $($oldCA.ProviderName)" -ForegroundColor Gray

# -- Resolve CA Common Name ---------------------------------------------------
$CACommonName = $SubjectName
if (-not $CACommonName) {
    if ($oldCA.SubjectName -match 'CN=([^,]+)') {
        $CACommonName = $Matches[1].Trim()
    }
    if (-not $CACommonName) {
        Write-Host "[ERROR] No CA name found in Step 1 output or -SubjectName parameter." -ForegroundColor Red
        exit 1
    }
}
# Strip CN= prefix if the caller passed it
if ($CACommonName -match '^CN=(.+)') {
    $CACommonName = $Matches[1].Trim()
}

# -- Resolve Key Algorithm (auto-detect from old CA or default to RSA) --
if (-not $KeyAlgorithm) {
    if ($oldCA.KeyAlgorithm -match 'ECC|ECDSA|EC') {
        $oldKeyLen = [int]$oldCA.KeyLength
        $KeyAlgorithm = switch ($oldKeyLen) {
            256  { 'ECDSA_P256' }
            384  { 'ECDSA_P384' }
            521  { 'ECDSA_P521' }
            default { 'ECDSA_P256' }
        }
        Write-Host "       [AUTO-DETECT] Old CA uses EC keys. Setting KeyAlgorithm=$KeyAlgorithm" -ForegroundColor Yellow
    } else {
        $KeyAlgorithm = 'RSA'
    }
}

# Resolve KeyLength based on algorithm (ECDSA curves have fixed key sizes)
if ($KeyAlgorithm -match '^ECDSA_P(\d+)$') {
    $KeyLength = $Matches[1]
} elseif (-not $KeyLength) {
    $KeyLength = if ($oldCA.KeyLength) { $oldCA.KeyLength } else { "2048" }
}

Write-Host ""
Write-Host "  New Subordinate CA parameters:" -ForegroundColor White
Write-Host "    CA Common Name:  $CACommonName" -ForegroundColor White
Write-Host "    CA Type:         StandaloneSubordinateCA" -ForegroundColor White
Write-Host "    Key Algorithm:   $KeyAlgorithm" -ForegroundColor White
Write-Host "    Key Length:      $KeyLength" -ForegroundColor White
Write-Host "    Hash:            $HashAlgorithm" -ForegroundColor White
Write-Host "    Crypto Provider: $KeyAlgorithm#Cavium Key Storage Provider" -ForegroundColor White
Write-Host ""

# -- Verify Cavium KSP is available ------------------------------------------
Write-Host "[2/7] Verifying Cavium Key Storage Provider is enumerated..." -ForegroundColor White

$KSPName = "Cavium Key Storage Provider"
$cspList = certutil -csplist 2>&1
$cspText = $cspList -join "`n"
if ($cspText -notmatch 'Cavium') {
    Write-Host "[ERROR] Cavium Key Storage Provider is NOT enumerated." -ForegroundColor Red
    Write-Host "        Install the Azure Cloud HSM SDK and ensure the KSP is registered." -ForegroundColor Red
    Write-Host "        Run Step2-ValidateNewCAServer.ps1 to diagnose." -ForegroundColor Red
    exit 1
}
Write-Host "       Cavium KSP confirmed available." -ForegroundColor Green

# -- Check for existing CA configuration -------------------------------------
Write-Host ""
Write-Host "[3/7] Checking for existing CA configuration..." -ForegroundColor White

try {
    $existingCA = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA Stop).Active
} catch {
    $existingCA = $null
}

$orphanedKey = $false
if (-not $existingCA) {
    $keyOutput = certutil -csp $KSPName -key 2>&1 | Out-String
    if ($keyOutput -match "(?m)^\s+($([regex]::Escape($CACommonName)))") {
        $orphanedKey = $true
        Write-Host "       [WARN] No CA configured, but orphaned HSM key found: $CACommonName" -ForegroundColor Yellow
        Write-Host "              Will use -OverwriteExistingKey to reuse/replace it." -ForegroundColor Yellow
    }
}

if ($existingCA -and -not $OverwriteExisting) {
    Write-Host "[ERROR] CA already configured: $existingCA" -ForegroundColor Red
    Write-Host "        Use -OverwriteExisting to replace the existing CA." -ForegroundColor Red
    exit 1
}

if ($existingCA -and $OverwriteExisting) {
    Write-Host "       Existing CA: $existingCA (will be overwritten)" -ForegroundColor Yellow
    try {
        $svc = Get-Service -Name certsvc -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Write-Host "       Stopping certsvc before overwrite..." -ForegroundColor Gray
            Stop-Service certsvc -Force -ErrorAction Stop
        }
        # Must uninstall the CA role before re-installing -- Install-AdcsCertificationAuthority
        # will reject with "already installed" even with -OverwriteExistingKey/Database/CAinDS.
        Write-Host "       Uninstalling existing CA configuration..." -ForegroundColor Gray
        Uninstall-AdcsCertificationAuthority -Force -ErrorAction Stop
        Write-Host "       Existing CA uninstalled." -ForegroundColor Green
    } catch {
        Write-Host "       [WARN] Uninstall error: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    # Verify CA is actually gone -- Uninstall can fail silently under SYSTEM with HSM KSPs
    $stillActive = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA SilentlyContinue).Active
    if ($stillActive) {
        Write-Host "[FAIL] CA still configured after uninstall: $stillActive" -ForegroundColor Red
        Write-Host "       Run manually: Uninstall-AdcsCertificationAuthority -Force" -ForegroundColor Red
        exit 1
    }
    Write-Host "       Ready for fresh install." -ForegroundColor Green
} elseif (-not $existingCA -and -not $orphanedKey) {
    Write-Host "       No existing CA. Ready for fresh install." -ForegroundColor Green
}

# -- Write CAPolicy.inf -------------------------------------------------------
Write-Host ""
Write-Host "[4/7] Writing CAPolicy.inf to C:\Windows\..." -ForegroundColor White

$caPolicyContent = @"
[Version]
Signature="`$Windows NT`$"

[Certsrv_Server]
RenewalKeyLength=$KeyLength
RenewalValidityPeriod=Years
RenewalValidityPeriodUnits=5
LoadDefaultTemplates=0
AlternateSignatureAlgorithm=0

[BasicConstraintsExtension]
PathLength=0
Critical=Yes
"@

$caPolicyPath = "C:\Windows\CAPolicy.inf"
$caPolicyContent | Out-File -FilePath $caPolicyPath -Encoding ASCII -Force
Write-Host "       Saved CAPolicy.inf to: $caPolicyPath" -ForegroundColor Green
Write-Host ""
Write-Host "       --- CAPolicy.inf Contents ---" -ForegroundColor Gray
$caPolicyContent -split "`n" | ForEach-Object { Write-Host "       $_" -ForegroundColor Gray }
Write-Host "       --- End CAPolicy.inf ---" -ForegroundColor Gray

# -- Install Subordinate CA (generates CSR) -----------------------------------
Write-Host ""
Write-Host "[5/7] Installing Subordinate CA (generates CSR in HSM)..." -ForegroundColor White
Write-Host ""
Write-Host "  The private key will be generated inside the HSM." -ForegroundColor Yellow
Write-Host "  This may take a moment..." -ForegroundColor Yellow
Write-Host ""

$csrFile = Join-Path $OutputDir "NewCA.req"
$CryptoProvider = "$KeyAlgorithm#$KSPName"

$installParams = @{
    CAType              = 'StandaloneSubordinateCA'
    CACommonName        = $CACommonName
    CryptoProviderName  = $CryptoProvider
    KeyLength           = [int]$KeyLength
    HashAlgorithmName   = $HashAlgorithm
    OutputCertRequestFile = $csrFile
    DatabaseDirectory   = "C:\Windows\system32\CertLog"
    LogDirectory        = "C:\Windows\system32\CertLog"
    Force               = $true
}

if ($OverwriteExisting -or $orphanedKey) {
    $installParams['OverwriteExistingKey']      = $true
    $installParams['OverwriteExistingDatabase'] = $true
    $installParams['OverwriteExistingCAinDS']   = $true
    if ($orphanedKey -and -not $OverwriteExisting) {
        Write-Host "       Auto-enabling -OverwriteExistingKey for orphaned HSM key" -ForegroundColor Yellow
    }
}

Write-Host "  Running Install-AdcsCertificationAuthority..." -ForegroundColor White
Write-Host "    -CAType             : StandaloneSubordinateCA" -ForegroundColor Gray
Write-Host "    -CryptoProviderName : $CryptoProvider" -ForegroundColor Gray
Write-Host "    -KeyLength          : $KeyLength" -ForegroundColor Gray
Write-Host "    -HashAlgorithmName  : $HashAlgorithm" -ForegroundColor Gray
Write-Host "    -CACommonName       : $CACommonName" -ForegroundColor Gray
Write-Host "    -OutputCertRequest  : $csrFile" -ForegroundColor Gray
Write-Host ""

try {
    Install-AdcsCertificationAuthority @installParams
    Write-Host ""
    Write-Host "       [PASS] Subordinate CA configured. CSR generated." -ForegroundColor Green
} catch {
    Write-Host ""
    Write-Host "[ERROR] Subordinate CA installation failed:" -ForegroundColor Red
    Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Common causes:" -ForegroundColor Yellow
    Write-Host "    - HSM KSP not properly registered" -ForegroundColor Yellow
    Write-Host "    - HSM cluster not reachable" -ForegroundColor Yellow
    Write-Host "    - Insufficient HSM permissions" -ForegroundColor Yellow
    Write-Host "    - CA already exists (use -OverwriteExisting)" -ForegroundColor Yellow
    Write-Host "    - ADCS role not installed (run Step 2)" -ForegroundColor Yellow
    exit 1
}

# -- Verify CSR was created ---------------------------------------------------
Write-Host ""
Write-Host "[6/7] Verifying CSR..." -ForegroundColor White

if (-not (Test-Path $csrFile)) {
    Write-Host "[ERROR] CSR file not found at: $csrFile" -ForegroundColor Red
    exit 1
}

$csrSize = (Get-Item $csrFile).Length
Write-Host "       CSR generated: $csrFile ($csrSize bytes)" -ForegroundColor Green

$verifyOutput = certutil -dump $csrFile 2>&1
$verifyText = $verifyOutput -join "`n"

$csrVerifyFile = Join-Path $OutputDir "NewCA-csr-details.txt"
$verifyOutput | Out-File -FilePath $csrVerifyFile -Encoding UTF8
Write-Host "       CSR details saved to: $csrVerifyFile" -ForegroundColor Gray

# -- Set Interactive=0 (headless HSM key access) ------------------------------
Write-Host ""
Write-Host "[7/7] Setting HSM Interactive mode to 0 (headless)..." -ForegroundColor White

$setOutput = certutil -setreg CA\CSP\Interactive 0 2>&1
$setText = ($setOutput | Out-String)

$verifyIntOutput = certutil -getreg CA\CSP\Interactive 2>&1
$verifyIntText = $verifyIntOutput -join "`n"
$interactiveValue = -1
if ($verifyIntText -match 'Interactive REG_DWORD = (\d+)') {
    $interactiveValue = [int]$Matches[1]
}

if ($interactiveValue -eq 0) {
    Write-Host "       [PASS] CA\CSP\Interactive = 0" -ForegroundColor Green
} else {
    Write-Host "       [WARN] Could not verify Interactive=0 (current: $interactiveValue)" -ForegroundColor Yellow
}

# -- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Step 3 Complete: Subordinate CA configured, CSR generated" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  CA State: Configured, pending signed certificate install" -ForegroundColor White
Write-Host ""
Write-Host "  Output files:" -ForegroundColor White
Write-Host "    - $csrFile     (CSR to submit to root CA)" -ForegroundColor Gray
Write-Host "    - $csrVerifyFile" -ForegroundColor Gray
Write-Host ""
Write-Host "  +--------------------------------------------------------+" -ForegroundColor Yellow
Write-Host "  |  NEXT STEPS (Cross-Signed ICA flow):                   |" -ForegroundColor Yellow
Write-Host "  |                                                        |" -ForegroundColor Yellow
Write-Host "  |  1. Submit CSR to the ROOT CA for signing              |" -ForegroundColor Yellow
Write-Host "  |  2. Copy signed cert + CSR to OLD ADCS server          |" -ForegroundColor Yellow
Write-Host "  |  3. Run Step4-CrossSignNewCA.ps1 on the OLD server     |" -ForegroundColor Yellow
Write-Host "  +--------------------------------------------------------+" -ForegroundColor Yellow
Write-Host ""
