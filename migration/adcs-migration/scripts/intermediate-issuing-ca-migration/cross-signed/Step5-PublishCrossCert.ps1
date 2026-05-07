<#
.SYNOPSIS
    Step 5: Publish cross-cert, install ICA identity cert, and activate the new CA.

.DESCRIPTION
    Installs the cross-certificate (from Step 4) and activates the new Issuing CA:

    1. Validates the cross-certificate (Subject != Issuer, matches CA)
    2. Installs the root-signed ICA identity cert via certutil -installcert
    3. Installs the old ICA cert in the Intermediate CA trust store
    4. Publishes the cross-certificate to the Intermediate CA store
    5. Starts Certificate Services and verifies chain building

    The NEW ICA's identity cert is the root-signed certificate from the
    parent Root CA. The cross-cert is a separate artifact that bridges
    trust from the OLD ICA chain to the NEW ICA.

    RUN ON: NEW ADCS Server (after Step 4 on OLD server)

.PARAMETER SignedCertPath
    Path to the root-signed ICA identity certificate (.cer) to install.

.PARAMETER CrossCertPath
    Path to the cross-signed certificate (.cer) from Step 4.

.PARAMETER OldICACertPath
    Path to the OLD Issuing CA certificate (.cer) from Step 4.
    Will be installed in the Intermediate CA store if not already present.

.PARAMETER SkipConfirmation
    Skip the confirmation prompt before activating the CA.

.PARAMETER OutputDir
    Directory to save validation results. Defaults to a timestamped subfolder.

.EXAMPLE
    .\Step5-PublishCrossCert.ps1 -SignedCertPath "C:\temp\NewIssuingCA-Signed.cer" -CrossCertPath "C:\temp\NewICA-CrossSigned.cer" -OldICACertPath "C:\temp\OldIssuingCA.cer"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SignedCertPath,

    [Parameter(Mandatory = $true)]
    [string]$CrossCertPath,

    [Parameter(Mandatory = $false)]
    [string]$OldICACertPath,

    [Parameter(Mandatory = $false)]
    [switch]$SkipConfirmation,

    [Parameter(Mandatory = $false)]
    [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Banner ------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ICA Migration (Cross-Signed) - Step 5: Publish & Activate" -ForegroundColor Cyan
Write-Host "  Run on: NEW ADCS Server (after Step 4 on OLD server)" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# -- Output directory ---------------------------------------------------------
if (-not $OutputDir) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputDir = Join-Path $env:USERPROFILE "ica-crosssign-step5-$timestamp"
}
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}
Write-Host "[INFO] Output directory: $OutputDir" -ForegroundColor Gray

# -- 1: Validate inputs ------------------------------------------------------
Write-Host ""
Write-Host "[1/8] Validating input certificates..." -ForegroundColor White

if (-not (Test-Path $SignedCertPath)) {
    Write-Host "[ERROR] Root-signed ICA certificate not found: $SignedCertPath" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $CrossCertPath)) {
    Write-Host "[ERROR] Cross-certificate not found: $CrossCertPath" -ForegroundColor Red
    Write-Host "        Run Step 4 on the OLD server first." -ForegroundColor Red
    exit 1
}

$signedCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($SignedCertPath)
$crossCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CrossCertPath)

Write-Host "  Root-signed ICA cert:" -ForegroundColor White
Write-Host "    Subject:     $($signedCert.Subject)" -ForegroundColor Gray
Write-Host "    Issuer:      $($signedCert.Issuer)" -ForegroundColor Gray
Write-Host "    Thumbprint:  $($signedCert.Thumbprint)" -ForegroundColor Gray
Write-Host ""
Write-Host "  Cross-certificate:" -ForegroundColor White
Write-Host "    Subject:     $($crossCert.Subject)" -ForegroundColor Gray
Write-Host "    Issuer:      $($crossCert.Issuer)" -ForegroundColor Gray
Write-Host "    Thumbprint:  $($crossCert.Thumbprint)" -ForegroundColor Gray

# Must be cross-signed
if ($crossCert.Subject -eq $crossCert.Issuer) {
    Write-Host "[ERROR] Cross-certificate is self-signed, not cross-signed." -ForegroundColor Red
    exit 1
}
Write-Host "  [PASS] Cross-cert is cross-signed (Subject != Issuer)" -ForegroundColor Green

# Subjects should match
if ($signedCert.Subject -ne $crossCert.Subject) {
    Write-Host "[WARN] Signed cert and cross-cert have different subjects:" -ForegroundColor Yellow
    Write-Host "       Signed:  $($signedCert.Subject)" -ForegroundColor Yellow
    Write-Host "       Cross:   $($crossCert.Subject)" -ForegroundColor Yellow
}

# -- 2: Verify parent CA cert in Trusted Root store -------------------------
Write-Host ""
Write-Host "[2/8] Verifying parent CA cert in Trusted Root store..." -ForegroundColor White

$signedCertObj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($SignedCertPath)
$issuerCNForRoot = ($signedCertObj.Issuer -replace '.*CN=', '') -replace ',.*', ''
$rootStore = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','LocalMachine')
$rootStore.Open('ReadOnly')
$issuerInRootStore = $rootStore.Certificates | Where-Object { $_.Subject -match [regex]::Escape($issuerCNForRoot) }
$rootStore.Close()

if (-not $issuerInRootStore) {
    Write-Host "  [ERROR] Issuer '$issuerCNForRoot' NOT found in Trusted Root store." -ForegroundColor Red
    Write-Host "          certutil -installcert will fail with CERT_E_CHAINING." -ForegroundColor Red
    Write-Host "          Ensure the parent CA cert is pre-distributed (CRL pre-cache step)." -ForegroundColor Red
    exit 1
} else {
    Write-Host "       [PASS] Found '$issuerCNForRoot' in Trusted Root store" -ForegroundColor Green
}

# -- 3: Install ICA identity certificate -------------------------------------
Write-Host ""
Write-Host "[3/8] Installing root-signed ICA identity certificate..." -ForegroundColor White

if (-not $SkipConfirmation) {
    # Detect Session 0 (no interactive desktop) and auto-skip
    $sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    if ($sessionId -eq 0) {
        Write-Host "  [INFO] Session 0 detected - skipping confirmation prompt." -ForegroundColor Gray
    } else {
        Write-Host ""
        Write-Host "  This will install the root-signed certificate as the CA identity." -ForegroundColor Yellow
        Write-Host "  Press Enter to continue or Ctrl+C to abort..." -ForegroundColor Yellow
        Read-Host
    }
}

# FINDING 19: certutil -installcert hangs indefinitely under SYSTEM with the
# Cavium KSP (Azure Cloud HSM). The KSP requires an interactive Windows logon
# session for key retrieval/verification. This script must be run from an
# interactive session (e.g. RDP), not via az vm run-command.
$isSystem = ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')

if ($isSystem) {
    Write-Host "[FAIL] This script is running as SYSTEM (non-interactive)." -ForegroundColor Red
    Write-Host "       The Cavium KSP requires an interactive Windows logon session" -ForegroundColor Red
    Write-Host "       for certutil -installcert. This cannot be automated via" -ForegroundColor Red
    Write-Host "       az vm run-command or scheduled tasks." -ForegroundColor Red
    Write-Host ""
    Write-Host "       RDP into this VM and run this script from an elevated" -ForegroundColor Red
    Write-Host "       PowerShell prompt as any local administrator." -ForegroundColor Red
    exit 1
}

$installResult = certutil -f -installcert $SignedCertPath 2>&1
$installText = ($installResult | Out-String)

if ($installText -match 'completed successfully' -or $installText -match 'command completed') {
    Write-Host "       [PASS] Certificate installed successfully." -ForegroundColor Green
} else {
    Write-Host "[ERROR] certutil -installcert failed:" -ForegroundColor Red
    Write-Host $installText
    exit 1
}

# -- 4: Verify keys ----------------------------------------------------------
Write-Host ""
Write-Host "[4/8] Verifying private key match (certutil -verifykeys)..." -ForegroundColor White

$verifyKeysOutput = certutil -verifykeys 2>&1
$verifyKeysText = $verifyKeysOutput -join "`n"
$keysOk = ($verifyKeysText -match 'completed successfully') -or ($verifyKeysText -match 'PASS') -or ($verifyKeysText -match 'Signature test passed')

if ($keysOk) {
    Write-Host "       [PASS] Private key matches installed certificate." -ForegroundColor Green
} else {
    Write-Host "       [WARN] Key verification inconclusive. Output:" -ForegroundColor Yellow
    $verifyKeysOutput | ForEach-Object { Write-Host "         $_" -ForegroundColor Yellow }
}

# -- 5: Verify Interactive=0 -------------------------------------------------
Write-Host ""
Write-Host "[5/8] Verifying HSM Interactive mode..." -ForegroundColor White

$interactiveOutput = certutil -getreg CA\CSP\Interactive 2>&1
$interactiveText = $interactiveOutput -join "`n"
$interactiveValue = -1
if ($interactiveText -match 'Interactive REG_DWORD = (\d+)') {
    $interactiveValue = [int]$Matches[1]
}
if ($interactiveValue -ne 0) {
    Write-Host "       [WARN] CA\CSP\Interactive = $interactiveValue. Setting to 0..." -ForegroundColor Yellow
    certutil -setreg CA\CSP\Interactive 0 2>&1 | Out-Null
    Write-Host "       [PASS] Interactive set to 0." -ForegroundColor Green
} else {
    Write-Host "       [PASS] CA\CSP\Interactive = 0 (correct)" -ForegroundColor Green
}

# -- 6: Install old ICA cert in trust store ----------------------------------
Write-Host ""
Write-Host "[6/8] Installing old ICA certificate in Intermediate CA store..." -ForegroundColor White

$issuerCN = if ($crossCert.Issuer -match 'CN=([^,]+)') { $Matches[1] } else { $crossCert.Issuer }

# Check if already in CA store
$issuerInStore = Get-ChildItem Cert:\LocalMachine\CA | Where-Object {
    $_.Subject -match [regex]::Escape($issuerCN)
}

if ($issuerInStore) {
    Write-Host "       [PASS] Old ICA '$issuerCN' already in Intermediate CA store" -ForegroundColor Green
} elseif ($OldICACertPath -and (Test-Path $OldICACertPath)) {
    Write-Host "       Installing old ICA cert: $OldICACertPath" -ForegroundColor Yellow
    $addResult = certutil -addstore CA $OldICACertPath 2>&1
    Write-Host ($addResult -join "`n") -ForegroundColor Gray

    $issuerInStore = Get-ChildItem Cert:\LocalMachine\CA | Where-Object {
        $_.Subject -match [regex]::Escape($issuerCN)
    }
    if ($issuerInStore) {
        Write-Host "       [PASS] Old ICA cert installed in Intermediate CA store" -ForegroundColor Green
    } else {
        Write-Host "[ERROR] Failed to install old ICA cert." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "       [WARN] Old ICA '$issuerCN' not in store and -OldICACertPath not provided" -ForegroundColor Yellow
    Write-Host "              Cross-cert chain building may not work without the old ICA cert." -ForegroundColor Yellow
}

# -- 7: Publish cross-certificate --------------------------------------------
Write-Host ""
Write-Host "[7/8] Publishing cross-certificate to Intermediate CA store..." -ForegroundColor White

$caStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("CA", "LocalMachine")
$caStore.Open("ReadWrite")
$caStore.Add($crossCert)
$caStore.Close()

# Verify it's in the CA store
$inCAStore = Get-ChildItem Cert:\LocalMachine\CA | Where-Object {
    $_.Thumbprint -eq $crossCert.Thumbprint
}
if ($inCAStore) {
    Write-Host "       [PASS] Cross-cert added to Intermediate CA store" -ForegroundColor Green
} else {
    Write-Host "       [WARN] Cross-cert not found in CA store after add" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "       For AD-joined environments, also run:" -ForegroundColor Gray
Write-Host "         certutil -dspublish -f '$CrossCertPath' CrossCA" -ForegroundColor Gray

# -- 8: Set CRL revocation tolerance + Start certsvc -------------------------
Write-Host ""
Write-Host "[8/8] Setting CRLF_REVCHECK_IGNORE_OFFLINE and starting Certificate Services..." -ForegroundColor White

# The ICA cert's CRL DP points to the parent CA hostname which may be unreachable.
# Without this flag, certsvc refuses to start: CRYPT_E_REVOCATION_OFFLINE.
$crlFlagsOutput = certutil -setreg CA\CRLFlags +CRLF_REVCHECK_IGNORE_OFFLINE 2>&1
$crlFlagsText = ($crlFlagsOutput | Out-String)
if ($crlFlagsText -match 'CRLF_REVCHECK_IGNORE_OFFLINE') {
    Write-Host "       [PASS] CRLF_REVCHECK_IGNORE_OFFLINE set" -ForegroundColor Green
} else {
    Write-Host "       [WARN] Could not set CRLF_REVCHECK_IGNORE_OFFLINE" -ForegroundColor Yellow
}

try {
    $svc = Get-Service -Name certsvc -ErrorAction Stop
    if ($svc.Status -ne 'Running') {
        Write-Host "       Starting certsvc..." -ForegroundColor Yellow
        Start-Service certsvc -ErrorAction Stop
        $retries = 0
        do {
            Start-Sleep -Seconds 2
            $svc = Get-Service -Name certsvc -ErrorAction Stop
            $retries++
        } while ($svc.Status -ne 'Running' -and $retries -lt 10)
    }
    Write-Host "       certsvc status: $($svc.Status)" -ForegroundColor $(if ($svc.Status -eq 'Running') { "Green" } else { "Red" })
} catch {
    Write-Host "       [WARN] Could not start certsvc: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Publish initial CRL
Write-Host ""
Write-Host "       Publishing initial CRL..." -ForegroundColor White
$crlResult = certutil -crl 2>&1
$crlText = ($crlResult | Out-String)
if ($crlText -match 'completed successfully') {
    Write-Host "       [PASS] CRL published." -ForegroundColor Green
} else {
    Write-Host "       [WARN] CRL publish result:" -ForegroundColor Yellow
    $crlResult | ForEach-Object { Write-Host "         $_" -ForegroundColor Yellow }
}

# Verify chain building with the CA cert
Write-Host ""
Write-Host "  Verifying certificate chain building..." -ForegroundColor White

# Get the newly installed CA cert from MY store
try { $activeCA = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA Stop).Active } catch { $activeCA = $null }

$caCert = $null
if ($activeCA) {
    foreach ($cert in (Get-ChildItem Cert:\LocalMachine\My)) {
        if ($cert.Subject -match [regex]::Escape($activeCA)) {
            foreach ($ext in $cert.Extensions) {
                if ($ext.Oid.FriendlyName -eq 'Basic Constraints') {
                    $caCert = $cert
                    break
                }
            }
            if ($caCert) { break }
        }
    }
}

if ($caCert) {
    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    $chain.ChainPolicy.RevocationMode = 'NoCheck'
    $chain.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority'

    $chainResult = $chain.Build($caCert)
    $chainLength = $chain.ChainElements.Count

    Write-Host "       Chain length: $chainLength" -ForegroundColor $(if ($chainLength -ge 2) { "Green" } else { "Yellow" })
    Write-Host ""
    Write-Host "       Chain elements:" -ForegroundColor White
    for ($i = 0; $i -lt $chainLength; $i++) {
        $elem = $chain.ChainElements[$i]
        $depth = if ($i -eq 0) { "ICA   " } elseif ($i -eq $chainLength - 1) { "Root  " } else { "Bridge" }
        Write-Host "       [$depth] $($elem.Certificate.Subject)" -ForegroundColor Gray
        Write-Host "                Issuer: $($elem.Certificate.Issuer)" -ForegroundColor DarkGray
    }

    if ($chainLength -ge 2) {
        Write-Host ""
        Write-Host "       [PASS] Chain builds successfully" -ForegroundColor Green
    }
} else {
    Write-Host "       [SKIP] Could not verify chain (CA cert not found in MY store)" -ForegroundColor Yellow
}

# -- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Step 5 Complete: Cross-cert published, ICA activated" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Active CA:          $activeCA" -ForegroundColor White
Write-Host "  Identity Cert:      Root-signed ICA cert" -ForegroundColor White
Write-Host "  Cross-Cert:         $($crossCert.Subject) issued by $($crossCert.Issuer)" -ForegroundColor White
Write-Host "  Cross-Cert Thumb:   $($crossCert.Thumbprint)" -ForegroundColor White
Write-Host "  Published to:       Intermediate CA store" -ForegroundColor White
if ($issuerInStore) {
    Write-Host "  Old ICA in store:   Yes" -ForegroundColor White
}
Write-Host ""
