<#
.SYNOPSIS
    Step 3: Install the new Root CA with HSM-backed key (self-signed).

.DESCRIPTION
    Creates a new standalone Root CA on the target server using the HSM Key
    Storage Provider with a self-signed certificate. This is architecturally
    identical to Option 1's Step 3.

    In the cross-signed flow, the CA MUST have a self-signed certificate as
    its identity (ADCS requires Subject == Issuer for StandaloneRootCA).
    The cross-certificate (created in Step 4-5) is a SEPARATE trust bridge
    artifact that shares the same public key.

    This script:
    1. Writes a CAPolicy.inf to C:\Windows\
    2. Runs Install-AdcsCertificationAuthority (StandaloneRootCA, NewKeyParameterSet)
    3. Sets Interactive=0 for headless HSM key access
    4. Starts Certificate Services and verifies the CA is active
    5. Exports the new CA certificate for cross-signing in Step 4

    RUN ON: NEW ADCS Server (target for new Root CA)

.PARAMETER CACommonName
    Common Name for the new Root CA. A generational suffix (e.g., "-G2")
    is recommended for clarity.

.PARAMETER Platform
    HSM platform: AzureCloudHSM or AzureDedicatedHSM.
    If omitted, auto-detects based on which KSP is registered.

.PARAMETER KeyLength
    Key length for the new CA key. Defaults to 2048.

.PARAMETER HashAlgorithm
    Hash algorithm. Defaults to SHA256.

.PARAMETER ValidityYears
    Root CA certificate validity in years. Defaults to 20.

.PARAMETER OverwriteExisting
    Allow overwriting an existing CA configuration on this server.

.PARAMETER OutputDir
    Directory to save the exported CA certificate. Defaults to a timestamped subfolder.

.EXAMPLE
    .\Step3-BuildNewCA.ps1 -CACommonName "HSB-RootCA-G2"

.EXAMPLE
    .\Step3-BuildNewCA.ps1 -CACommonName "HSB-RootCA-G2" -KeyLength 4096 -OverwriteExisting
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CACommonName,

    [Parameter(Mandatory = $false)]
    [ValidateSet('AzureCloudHSM', 'AzureDedicatedHSM')]
    [string]$Platform,

    [Parameter(Mandatory = $false)]
    [ValidateSet("RSA", "ECDSA_P256", "ECDSA_P384", "ECDSA_P521")]
    [string]$KeyAlgorithm,

    [Parameter(Mandatory = $false)]
    [string]$KeyLength = "2048",

    [Parameter(Mandatory = $false)]
    [ValidateSet("SHA256", "SHA384", "SHA512")]
    [string]$HashAlgorithm = "SHA256",

    [Parameter(Mandatory = $false)]
    [int]$ValidityYears = 20,

    [Parameter(Mandatory = $false)]
    [switch]$OverwriteExisting,

    [Parameter(Mandatory = $false)]
    [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Banner ------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Root CA Migration (Cross-Signed) - Step 3: Install New CA" -ForegroundColor Cyan
Write-Host "  Run on: NEW ADCS Server (target for new Root CA)" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  NOTE: The CA installs with a self-signed certificate." -ForegroundColor White
Write-Host "        The cross-certificate is created separately in Steps 4-5." -ForegroundColor White
Write-Host ""

# -- Output directory ---------------------------------------------------------
if (-not $OutputDir) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputDir = Join-Path $env:USERPROFILE "rootca-crosssign-step3-$timestamp"
}
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}
Write-Host "[INFO] Output directory: $OutputDir" -ForegroundColor Gray

# -- 1: Validate CA Common Name ----------------------------------------------
Write-Host ""
Write-Host "[1/7] Validating CA Common Name..." -ForegroundColor White

if ($CACommonName -notmatch '-G\d+$') {
    Write-Host ""
    Write-Host "  [WARN] CA name '$CACommonName' does not end with a generational" -ForegroundColor Yellow
    Write-Host "         suffix like -G2. A distinct CN is recommended for" -ForegroundColor Yellow
    Write-Host "         operational clarity during cross-signing." -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "  Continue without a generational suffix? (yes/no)"
    if ($confirm -ne 'yes') {
        Write-Host "  Aborted. Add a -G2 (or similar) suffix to the CA name." -ForegroundColor Yellow
        exit 0
    }
}

Write-Host "       CA Common Name: $CACommonName" -ForegroundColor Green

# -- Resolve Key Algorithm (default to RSA if not specified) --
if (-not $KeyAlgorithm) { $KeyAlgorithm = 'RSA' }
if ($KeyAlgorithm -match '^ECDSA_P(\d+)$') { $KeyLength = $Matches[1] }

# -- 2: Auto-detect platform ------------------------------------------------
Write-Host ""
Write-Host "[2/7] Detecting HSM platform..." -ForegroundColor White

$kspList = certutil -csplist 2>&1
$kspText = $kspList -join "`n"

$caviumFound = $kspText -match 'Cavium Key Storage Provider'
$safenetFound = $kspText -match 'SafeNet Key Storage Provider'

if (-not $Platform) {
    if ($caviumFound) { $Platform = 'AzureCloudHSM' }
    elseif ($safenetFound) { $Platform = 'AzureDedicatedHSM' }
    else {
        Write-Host "[ERROR] No HSM KSP detected (Cavium or SafeNet)." -ForegroundColor Red
        Write-Host "        Install the HSM SDK and run Step 2 to validate." -ForegroundColor Red
        exit 1
    }
}

$KSPName = switch ($Platform) {
    'AzureCloudHSM'     { 'Cavium Key Storage Provider' }
    'AzureDedicatedHSM' { 'SafeNet Key Storage Provider' }
}

Write-Host "       Platform: $Platform" -ForegroundColor Green
Write-Host "       KSP:      $KSPName" -ForegroundColor Green

# -- 3: Check for existing CA -----------------------------------------------
Write-Host ""
Write-Host "[3/7] Checking for existing CA configuration..." -ForegroundColor White

try { $existingCA = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA Stop).Active } catch { $existingCA = $null }

# Check for orphaned HSM keys
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

# -- 4: Write CAPolicy.inf --------------------------------------------------
Write-Host ""
Write-Host "[4/7] Writing CAPolicy.inf to C:\Windows\..." -ForegroundColor White

$caPolicyContent = @"
[Version]
Signature="`$Windows NT`$"

[Certsrv_Server]
RenewalKeyLength=$KeyLength
RenewalValidityPeriod=Years
RenewalValidityPeriodUnits=$ValidityYears
LoadDefaultTemplates=0
AlternateSignatureAlgorithm=0

[CRLDistributionPoint]

[AuthorityInformationAccess]

[BasicConstraintsExtension]
PathLength=
Critical=Yes
"@

$caPolicyPath = "C:\Windows\CAPolicy.inf"
$caPolicyContent | Out-File -FilePath $caPolicyPath -Encoding ASCII -Force
Write-Host "       Saved CAPolicy.inf to: $caPolicyPath" -ForegroundColor Green

# -- 5: Install Root CA (self-signed) ----------------------------------------
Write-Host ""
Write-Host "[5/7] Installing Root CA (self-signed)..." -ForegroundColor White
Write-Host ""
Write-Host "  CA Common Name:     $CACommonName" -ForegroundColor White
Write-Host "  CA Type:            StandaloneRootCA" -ForegroundColor White
Write-Host "  Key Algorithm:      $KeyAlgorithm" -ForegroundColor White
Write-Host "  Crypto Provider:    $KeyAlgorithm#$KSPName" -ForegroundColor White
Write-Host "  Key Length:         $KeyLength" -ForegroundColor White
Write-Host "  Hash Algorithm:     $HashAlgorithm" -ForegroundColor White
Write-Host "  Validity:           $ValidityYears years" -ForegroundColor White
Write-Host ""

$CryptoProvider = "$KeyAlgorithm#$KSPName"

$installParams = @{
    CAType              = 'StandaloneRootCA'
    CACommonName        = $CACommonName
    CryptoProviderName  = $CryptoProvider
    KeyLength           = [int]$KeyLength
    HashAlgorithmName   = $HashAlgorithm
    ValidityPeriod      = 'Years'
    ValidityPeriodUnits = $ValidityYears
    Force               = $true
}

if ($OverwriteExisting -or $orphanedKey) {
    $installParams['OverwriteExistingKey']       = $true
    $installParams['OverwriteExistingDatabase']  = $true
    $installParams['OverwriteExistingCAinDS']    = $true
}

try {
    Install-AdcsCertificationAuthority @installParams
    Write-Host ""
    Write-Host "       [PASS] Root CA installation completed." -ForegroundColor Green
} catch {
    Write-Host ""
    Write-Host "[ERROR] Root CA installation failed:" -ForegroundColor Red
    Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Common causes:" -ForegroundColor Yellow
    Write-Host "    - HSM KSP not properly registered" -ForegroundColor Yellow
    Write-Host "    - HSM cluster not reachable" -ForegroundColor Yellow
    Write-Host "    - CA already exists (use -OverwriteExisting)" -ForegroundColor Yellow
    Write-Host "    - ADCS role not installed (run Step 2)" -ForegroundColor Yellow
    exit 1
}

# -- 6: Set Interactive=0 ---------------------------------------------------
Write-Host ""
Write-Host "[6/7] Setting HSM Interactive mode to 0 (headless)..." -ForegroundColor White

$setOutput = certutil -setreg CA\CSP\Interactive 0 2>&1
$verifyOutput = certutil -getreg CA\CSP\Interactive 2>&1
$verifyText = $verifyOutput -join "`n"
$interactiveValue = -1
if ($verifyText -match 'Interactive REG_DWORD = (\d+)') {
    $interactiveValue = [int]$Matches[1]
}

if ($interactiveValue -eq 0) {
    Write-Host "       [PASS] CA\CSP\Interactive = 0" -ForegroundColor Green
} else {
    Write-Host "       [WARN] Could not verify Interactive=0 (current: $interactiveValue)" -ForegroundColor Yellow
}

# -- 7: Start certsvc and export CA cert ------------------------------------
Write-Host ""
Write-Host "[7/7] Starting Certificate Services and exporting CA cert..." -ForegroundColor White

try {
    $svc = Get-Service -Name certsvc -ErrorAction Stop
    if ($svc.Status -eq 'Running') {
        Restart-Service certsvc -Force -ErrorAction Stop
    } else {
        Start-Service certsvc -ErrorAction Stop
    }

    $retries = 0
    do {
        Start-Sleep -Seconds 2
        $svc = Get-Service -Name certsvc -ErrorAction Stop
        $retries++
    } while ($svc.Status -ne 'Running' -and $retries -lt 10)

    if ($svc.Status -eq 'Running') {
        Write-Host "       [PASS] certsvc is running" -ForegroundColor Green
    } else {
        Write-Host "       [FAIL] certsvc status: $($svc.Status)" -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host "       [FAIL] Could not start certsvc: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Verify active CA name
try { $activeCA = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA Stop).Active } catch { $activeCA = $null }
if ($activeCA -eq $CACommonName) {
    Write-Host "       [PASS] Active CA: $activeCA" -ForegroundColor Green
} else {
    Write-Host "       [WARN] Active CA: $activeCA (expected: $CACommonName)" -ForegroundColor Yellow
}

# Export the self-signed CA certificate for cross-signing in Step 4
$certFile = Join-Path $OutputDir "NewRootCA-SelfSigned.cer"
$caCert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
    $_.Subject -match [regex]::Escape($CACommonName) -and $_.Subject -eq $_.Issuer
}

if ($caCert) {
    $derBytes = $caCert.Export('Cert')
    [IO.File]::WriteAllBytes($certFile, $derBytes)
    Write-Host "       [PASS] CA certificate exported: $certFile" -ForegroundColor Green

    # Also export base64 for easy transfer
    $b64File = Join-Path $OutputDir "NewRootCA-SelfSigned.b64"
    $b64 = [Convert]::ToBase64String($derBytes)
    $b64 | Out-File -FilePath $b64File -Encoding ASCII -Force
    Write-Host "       Base64 export: $b64File" -ForegroundColor Gray
} else {
    Write-Host "       [WARN] Could not find self-signed CA cert in MY store" -ForegroundColor Yellow
    Write-Host "              Use 'certutil -ca.cert $certFile' to export manually." -ForegroundColor Yellow
}

# -- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Step 3 Complete: New Root CA installed (self-signed)" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  CA Common Name:   $CACommonName" -ForegroundColor White
Write-Host "  CA Type:          StandaloneRootCA" -ForegroundColor White
Write-Host "  Platform:         $Platform" -ForegroundColor White
Write-Host "  KSP:              $KSPName" -ForegroundColor White
Write-Host "  Key Length:        $KeyLength" -ForegroundColor White
Write-Host "  Hash Algorithm:   $HashAlgorithm" -ForegroundColor White
Write-Host "  Interactive:      0 (headless)" -ForegroundColor White
Write-Host "  certsvc:          Running" -ForegroundColor White
if ($caCert) {
    Write-Host "  CA Thumbprint:    $($caCert.Thumbprint)" -ForegroundColor White
}
Write-Host ""
Write-Host "  NEXT: Transfer $certFile to the OLD server," -ForegroundColor Yellow
Write-Host "        then run Step4-CrossSignNewCA.ps1 on the OLD server." -ForegroundColor Yellow
Write-Host ""
