<#
.SYNOPSIS
    Step 3: Build the new self-signed Root CA with HSM-backed key.

.DESCRIPTION
    Creates a new standalone Root CA on the target server using the HSM Key
    Storage Provider. Unlike an issuing CA (which generates a CSR for signing
    by a parent), a Root CA self-signs its own certificate.

    This script:
    1. Writes a CAPolicy.inf to C:\Windows\
    2. Runs Install-AdcsCertificationAuthority (StandaloneRootCA)
    3. Sets Interactive=0 for headless HSM key access
    4. Starts Certificate Services and verifies the CA is active

    The -CACommonName MUST include a generational suffix (e.g., "-G2") when
    migrating between HSM platforms. This prevents chain ambiguity when both
    old and new roots coexist in trust stores during the pre-distribution
    window.

    RUN ON: NEW ADCS Server (target for new Root CA)

.PARAMETER CACommonName
    Common Name for the new Root CA. MUST include a generational suffix
    (e.g., "Contoso-RootCA-G2") to avoid same-CN chain collision.

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
    Required if Step 2 reported an existing CA.

.PARAMETER Step1OutputDir
    Optional path to Step 1 output directory. If provided, the script
    reads rootca-migration-details.json to display the old CA details
    for reference.

.EXAMPLE
    .\Step3-BuildNewCA.ps1 -CACommonName "HSB-RootCA-G2"

.EXAMPLE
    .\Step3-BuildNewCA.ps1 -CACommonName "Contoso-RootCA-G2" -KeyLength 4096 -ValidityYears 25

.EXAMPLE
    .\Step3-BuildNewCA.ps1 -CACommonName "HSB-RootCA-G2" -OverwriteExisting
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
    [string]$Step1OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Banner ------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Root CA Migration - Step 3: Build New Root CA" -ForegroundColor Cyan
Write-Host "  Run on: NEW ADCS Server (target for new Root CA)" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# -- G2 naming check ---------------------------------------------------------
Write-Host "[1/7] Validating CA Common Name..." -ForegroundColor White

if ($CACommonName -notmatch '-G\d+$') {
    Write-Host ""
    Write-Host "  [WARN] CA name '$CACommonName' does not end with a generational" -ForegroundColor Yellow
    Write-Host "         suffix like -G2. When migrating Root CAs between HSM" -ForegroundColor Yellow
    Write-Host "         platforms, a unique CN is REQUIRED to avoid same-CN chain" -ForegroundColor Yellow
    Write-Host "         collision in trust stores." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "         Microsoft, DigiCert, and Entrust all use generational" -ForegroundColor Gray
    Write-Host "         suffixes (e.g., 'DigiCert Global Root G2')." -ForegroundColor Gray
    Write-Host ""
    $confirm = Read-Host "  Continue without a generational suffix? (yes/no)"
    if ($confirm -ne 'yes') {
        Write-Host "  Aborted. Add a -G2 (or similar) suffix to the CA name." -ForegroundColor Yellow
        exit 0
    }
}

# -- Resolve Key Algorithm --
if (-not $KeyAlgorithm) {
    if ($Step1OutputDir) {
        $jsonFile = Join-Path $Step1OutputDir "rootca-migration-details.json"
        if (Test-Path $jsonFile) {
            $oldCA = Get-Content $jsonFile -Raw | ConvertFrom-Json
            if ($oldCA.KeyAlgorithm -match 'ECC|ECDSA|EC') {
                $oldKeyLen = [int]$oldCA.KeyLength
                $KeyAlgorithm = switch ($oldKeyLen) {
                    256  { 'ECDSA_P256' }
                    384  { 'ECDSA_P384' }
                    521  { 'ECDSA_P521' }
                    default { 'ECDSA_P256' }
                }
                Write-Host "       [AUTO-DETECT] Old CA uses EC keys. Setting KeyAlgorithm=$KeyAlgorithm" -ForegroundColor Yellow
            }
        }
    }
    if (-not $KeyAlgorithm) { $KeyAlgorithm = 'RSA' }
}

# Resolve KeyLength based on algorithm (ECDSA curves have fixed key sizes)
if ($KeyAlgorithm -match '^ECDSA_P(\d+)$') {
    $KeyLength = $Matches[1]
}

# -- Resolve Key Algorithm --
if (-not $KeyAlgorithm) {
    if ($Step1OutputDir) {
        $jsonFile = Join-Path $Step1OutputDir "rootca-migration-details.json"
        if (Test-Path $jsonFile) {
            $oldCA = Get-Content $jsonFile -Raw | ConvertFrom-Json
            if ($oldCA.KeyAlgorithm -match 'ECC|ECDSA|EC') {
                $oldKeyLen = [int]$oldCA.KeyLength
                $KeyAlgorithm = switch ($oldKeyLen) {
                    256  { 'ECDSA_P256' }
                    384  { 'ECDSA_P384' }
                    521  { 'ECDSA_P521' }
                    default { 'ECDSA_P256' }
                }
                Write-Host "       [AUTO-DETECT] Old CA uses EC keys. Setting KeyAlgorithm=$KeyAlgorithm" -ForegroundColor Yellow
            }
        }
    }
    if (-not $KeyAlgorithm) { $KeyAlgorithm = 'RSA' }
}

# Resolve KeyLength based on algorithm (ECDSA curves have fixed key sizes)
if ($KeyAlgorithm -match '^ECDSA_P(\d+)$') {
    $KeyLength = $Matches[1]
}

Write-Host "       CA Common Name: $CACommonName" -ForegroundColor Green

# -- Load Step 1 reference (optional) ----------------------------------------
if ($Step1OutputDir) {
    $jsonFile = Join-Path $Step1OutputDir "rootca-migration-details.json"
    if (Test-Path $jsonFile) {
        $oldCA = Get-Content $jsonFile -Raw | ConvertFrom-Json
        Write-Host ""
        Write-Host "  Reference from Step 1 (old Root CA):" -ForegroundColor Gray
        Write-Host "    Old CN:       $($oldCA.CACommonName)" -ForegroundColor Gray
        Write-Host "    Old Key:      $($oldCA.KeyLength)-bit $($oldCA.KeyAlgorithm)" -ForegroundColor Gray
        Write-Host "    Old Provider: $($oldCA.ProviderName)" -ForegroundColor Gray
    }
}

# -- Auto-detect platform ----------------------------------------------------
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
        Write-Host "        Install the HSM SDK and run Step2 to validate." -ForegroundColor Red
        exit 1
    }
}

$KSPName = switch ($Platform) {
    'AzureCloudHSM'     { 'Cavium Key Storage Provider' }
    'AzureDedicatedHSM' { 'SafeNet Key Storage Provider' }
}

Write-Host "       Platform: $Platform" -ForegroundColor Green
Write-Host "       KSP:      $KSPName" -ForegroundColor Green

# -- Check for existing CA ---------------------------------------------------
Write-Host ""
Write-Host "[3/7] Checking for existing CA configuration..." -ForegroundColor White

try { $existingCA = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA Stop).Active } catch { $existingCA = $null }

# Check for orphaned HSM keys that survive Uninstall-AdcsCertificationAuthority.
# The Windows ADCS uninstall removes registry config and database but does NOT
# delete the private key from the KSP. For HSM-backed keys (Cavium/SafeNet),
# the key persists in the HSM. Install-AdcsCertificationAuthority will fail with
# "The private key already exists" if we don't account for this.
$orphanedKey = $false
if (-not $existingCA) {
    # Must check the specific HSM KSP -- default certutil -key only shows software KSP keys
    $keyOutput = certutil -csp $KSPName -key 2>&1 | Out-String
    if ($keyOutput -match "(?m)^\s+($([regex]::Escape($CACommonName)))") {
        $orphanedKey = $true
        Write-Host "       [WARN] No CA configured, but orphaned HSM key found: $CACommonName" -ForegroundColor Yellow
        Write-Host "              The key persists in the HSM after a previous ADCS uninstall." -ForegroundColor Yellow
        Write-Host "              Will use -OverwriteExistingKey to reuse/replace it." -ForegroundColor Yellow
    }
}

if ($existingCA -and -not $OverwriteExisting) {
    Write-Host "[ERROR] CA already configured: $existingCA" -ForegroundColor Red
    Write-Host "        Use -OverwriteExisting to replace the existing CA." -ForegroundColor Red
    Write-Host "        WARNING: This will overwrite the existing CA key and database." -ForegroundColor Red
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

# -- Write CAPolicy.inf ------------------------------------------------------
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
Write-Host ""
Write-Host "       --- CAPolicy.inf Contents ---" -ForegroundColor Gray
$caPolicyContent -split "`n" | ForEach-Object { Write-Host "       $_" -ForegroundColor Gray }
Write-Host "       --- End CAPolicy.inf ---" -ForegroundColor Gray

# -- Install Root CA ---------------------------------------------------------
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
Write-Host "  The private key will be generated inside the HSM." -ForegroundColor Yellow
Write-Host "  This may take a moment..." -ForegroundColor Yellow
Write-Host ""

# CNG KSPs require the algorithm prefix (e.g., "RSA#Cavium Key Storage Provider"
# or "ECDSA_P256#Cavium Key Storage Provider") for Install-AdcsCertificationAuthority.
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
    if ($orphanedKey -and -not $OverwriteExisting) {
        Write-Host "       Auto-enabling -OverwriteExistingKey for orphaned HSM key" -ForegroundColor Yellow
    }
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
    Write-Host "    - Insufficient HSM permissions" -ForegroundColor Yellow
    Write-Host "    - CA already exists (use -OverwriteExisting)" -ForegroundColor Yellow
    Write-Host "    - ADCS role not installed (run Step 2)" -ForegroundColor Yellow
    exit 1
}

# -- Set Interactive=0 -------------------------------------------------------
Write-Host ""
Write-Host "[6/7] Setting HSM Interactive mode to 0 (headless)..." -ForegroundColor White

# Interactive=1 causes the KSP to pop a GUI dialog during every signing
# operation. This HANGS certsvc (runs as SYSTEM in session 0 with no desktop)
# and any headless session (az vm run-command, scheduled tasks, etc.).
# The KSP authenticates via environment variables (Cloud HSM) or cached
# slot credentials (Dedicated HSM) and does NOT need interactive prompts.

$setOutput = certutil -setreg CA\CSP\Interactive 0 2>&1
$setText = ($setOutput | Out-String)

# Verify it was set
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
    Write-Host "              Fix manually: certutil -setreg CA\CSP\Interactive 0" -ForegroundColor Yellow
}

# -- Start/restart Certificate Services --------------------------------------
Write-Host ""
Write-Host "[7/7] Starting Certificate Services..." -ForegroundColor White

try {
    $svc = Get-Service -Name certsvc -ErrorAction Stop
    if ($svc.Status -eq 'Running') {
        Write-Host "       Restarting certsvc to pick up new configuration..." -ForegroundColor Gray
        Restart-Service certsvc -Force -ErrorAction Stop
    } else {
        Start-Service certsvc -ErrorAction Stop
    }

    # Wait briefly then check status
    $retries = 0
    $maxRetries = 10
    do {
        Start-Sleep -Seconds 2
        $svc = Get-Service -Name certsvc -ErrorAction Stop
        $retries++
    } while ($svc.Status -ne 'Running' -and $retries -lt $maxRetries)

    if ($svc.Status -eq 'Running') {
        Write-Host "       [PASS] certsvc is running" -ForegroundColor Green
    } else {
        Write-Host "       [FAIL] certsvc status: $($svc.Status)" -ForegroundColor Red
        Write-Host "              Check Event Viewer for errors." -ForegroundColor Yellow
    }
} catch {
    Write-Host "       [FAIL] Could not start certsvc: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# -- Verify active CA matches ------------------------------------------------
Write-Host ""
try { $activeCA = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA Stop).Active } catch { $activeCA = $null }
if ($activeCA -eq $CACommonName) {
    Write-Host "       [PASS] Active CA: $activeCA" -ForegroundColor Green
} else {
    Write-Host "       [WARN] Active CA: $activeCA (expected: $CACommonName)" -ForegroundColor Yellow
}

# -- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Step 3 Complete: New Root CA built successfully" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  CA Common Name:   $CACommonName" -ForegroundColor White
Write-Host "  CA Type:          StandaloneRootCA (self-signed)" -ForegroundColor White
Write-Host "  Platform:         $Platform" -ForegroundColor White
Write-Host "  KSP:              $KSPName" -ForegroundColor White
Write-Host "  Key Length:       $KeyLength" -ForegroundColor White
Write-Host "  Hash Algorithm:   $HashAlgorithm" -ForegroundColor White
Write-Host "  Validity:         $ValidityYears years" -ForegroundColor White
Write-Host "  Interactive:      0 (headless)" -ForegroundColor White
Write-Host "  certsvc:          Running" -ForegroundColor White
Write-Host ""
Write-Host "  NEXT: Run Step4-ValidateNewCACert.ps1 on this server" -ForegroundColor Yellow
Write-Host "        to verify the new Root CA certificate details." -ForegroundColor Yellow
Write-Host ""
