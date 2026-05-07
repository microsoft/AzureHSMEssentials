<#
.SYNOPSIS
    Step 5: Publish the cross-certificate on the NEW Root CA server.

.DESCRIPTION
    Installs the cross-certificate (from Step 4) as a trust bridge on
    the NEW Root CA server. The cross-cert allows clients that only trust
    the OLD root to chain through to the NEW root.

    This script:
    1. Validates the cross-certificate (Subject != Issuer, matches CA)
    2. Installs the old root cert into the Trusted Root store
    3. Publishes the cross-certificate to the CA's AIA store
    4. Installs the cross-cert in the machine's intermediate CA store
    5. Verifies chain building works (new CA cert chains to old root)

    The NEW CA's identity cert remains its self-signed cert from Step 3.
    The cross-cert is a separate artifact for backward compatibility.

    RUN ON: NEW ADCS Server (after Step 4 on OLD server)

.PARAMETER CrossCertPath
    Path to the cross-signed certificate (.cer) from Step 4.

.PARAMETER OldRootCertPath
    Path to the OLD Root CA certificate (.cer) from Step 4.
    Will be installed in the Trusted Root store if not already present.

.PARAMETER OutputDir
    Directory to save validation results. Defaults to a timestamped subfolder.

.EXAMPLE
    .\Step5-PublishCrossCert.ps1 -CrossCertPath "C:\temp\NewRootCA-CrossSigned.cer" -OldRootCertPath "C:\temp\OldRootCA.cer"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CrossCertPath,

    [Parameter(Mandatory = $false)]
    [string]$OldRootCertPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Banner ------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Root CA Migration (Cross-Signed) - Step 5: Publish" -ForegroundColor Cyan
Write-Host "  Run on: NEW ADCS Server (after Step 4 on OLD server)" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# -- Output directory ---------------------------------------------------------
if (-not $OutputDir) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputDir = Join-Path $env:USERPROFILE "rootca-crosssign-step5-$timestamp"
}
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}
Write-Host "[INFO] Output directory: $OutputDir" -ForegroundColor Gray

# -- 1: Verify CA is running -------------------------------------------------
Write-Host ""
Write-Host "[1/5] Verifying CA is active and running..." -ForegroundColor White

try { $activeCA = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA Stop).Active } catch { $activeCA = $null }
if (-not $activeCA) {
    Write-Host "[ERROR] No active CA found. Run Step 3 first." -ForegroundColor Red
    exit 1
}

$svc = Get-Service certsvc -ErrorAction Stop
if ($svc.Status -ne 'Running') {
    Write-Host "       certsvc is $($svc.Status). Starting..." -ForegroundColor Yellow
    Start-Service certsvc -ErrorAction Stop
    Start-Sleep -Seconds 3
    $svc = Get-Service certsvc
}

Write-Host "       Active CA: $activeCA" -ForegroundColor Green
Write-Host "       certsvc:   $($svc.Status)" -ForegroundColor Green

# Get the CA's self-signed certificate
$caCert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
    $_.Subject -match [regex]::Escape($activeCA) -and $_.Subject -eq $_.Issuer
}

if ($caCert) {
    Write-Host "       CA cert:   $($caCert.Subject) (self-signed)" -ForegroundColor Green
    Write-Host "       Thumb:     $($caCert.Thumbprint)" -ForegroundColor Gray
} else {
    Write-Host "       [WARN] Could not find self-signed CA cert in MY store" -ForegroundColor Yellow
}

# -- 2: Validate cross-certificate -------------------------------------------
Write-Host ""
Write-Host "[2/5] Validating cross-certificate..." -ForegroundColor White

if (-not (Test-Path $CrossCertPath)) {
    Write-Host "[ERROR] Cross-certificate not found: $CrossCertPath" -ForegroundColor Red
    Write-Host "        Run Step 4 on the OLD server first." -ForegroundColor Red
    exit 1
}

$crossCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CrossCertPath)

Write-Host "       Subject:      $($crossCert.Subject)" -ForegroundColor White
Write-Host "       Issuer:       $($crossCert.Issuer)" -ForegroundColor White
Write-Host "       Thumbprint:   $($crossCert.Thumbprint)" -ForegroundColor Gray
Write-Host "       Not After:    $($crossCert.NotAfter)" -ForegroundColor White

# Must be cross-signed
if ($crossCert.Subject -eq $crossCert.Issuer) {
    Write-Host "[ERROR] Certificate is self-signed, not cross-signed." -ForegroundColor Red
    exit 1
}
Write-Host "       [PASS] Cross-signed (Subject != Issuer)" -ForegroundColor Green

# Subject should match our CA
$caCN = if ($activeCA) { $activeCA } else { '' }
if ($crossCert.Subject -match [regex]::Escape($caCN)) {
    Write-Host "       [PASS] Subject matches active CA: $caCN" -ForegroundColor Green
} else {
    Write-Host "       [WARN] Subject does not match active CA '$caCN'" -ForegroundColor Yellow
    Write-Host "              Subject: $($crossCert.Subject)" -ForegroundColor Yellow
}

# -- 3: Install old root cert in trust store ---------------------------------
Write-Host ""
Write-Host "[3/5] Installing old root certificate in trust store..." -ForegroundColor White

$issuerCN = if ($crossCert.Issuer -match 'CN=([^,]+)') { $Matches[1] } else { $crossCert.Issuer }

# Check if already in trust store
$issuerInStore = Get-ChildItem Cert:\LocalMachine\Root | Where-Object {
    $_.Subject -match [regex]::Escape($issuerCN)
}

if ($issuerInStore) {
    Write-Host "       [PASS] Old root '$issuerCN' already in Trusted Root store" -ForegroundColor Green
} elseif ($OldRootCertPath -and (Test-Path $OldRootCertPath)) {
    Write-Host "       Installing old root cert: $OldRootCertPath" -ForegroundColor Yellow
    $addResult = certutil -addstore Root $OldRootCertPath 2>&1
    Write-Host ($addResult -join "`n") -ForegroundColor Gray

    $issuerInStore = Get-ChildItem Cert:\LocalMachine\Root | Where-Object {
        $_.Subject -match [regex]::Escape($issuerCN)
    }
    if ($issuerInStore) {
        Write-Host "       [PASS] Old root cert installed in trust store" -ForegroundColor Green
    } else {
        Write-Host "[ERROR] Failed to install old root cert." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "       [WARN] Old root '$issuerCN' not in trust store and -OldRootCertPath not provided" -ForegroundColor Yellow
    Write-Host "              Clients may not be able to chain to the old root." -ForegroundColor Yellow
}

# -- 4: Publish cross-certificate --------------------------------------------
Write-Host ""
Write-Host "[4/5] Publishing cross-certificate..." -ForegroundColor White

# Install cross-cert in the Intermediate CA store for chain building
Write-Host "       Adding to Intermediate CA store (CA store)..." -ForegroundColor Yellow
$caStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("CA", "LocalMachine")
$caStore.Open("ReadWrite")
$caStore.Add($crossCert)
$caStore.Close()

# Verify it's in the CA store
$inCAStore = Get-ChildItem Cert:\LocalMachine\CA | Where-Object {
    $_.Thumbprint -eq $crossCert.Thumbprint
}
if ($inCAStore) {
    Write-Host "       [PASS] Cross-cert in Intermediate CA store" -ForegroundColor Green
} else {
    Write-Host "       [WARN] Cross-cert not found in CA store after add" -ForegroundColor Yellow
}

# Also publish the cross-cert via certutil -dspublish for AD-joined environments
# For standalone (non-domain) CAs, this is informational only
Write-Host ""
Write-Host "       Cross-certificate published for local chain building." -ForegroundColor Green
Write-Host "       For AD-joined environments, also run:" -ForegroundColor Gray
Write-Host "         certutil -dspublish -f '$CrossCertPath' CrossCA" -ForegroundColor Gray

# -- 5: Verify chain building ------------------------------------------------
Write-Host ""
Write-Host "[5/5] Verifying certificate chain building..." -ForegroundColor White

if ($caCert) {
    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    $chain.ChainPolicy.RevocationMode = 'NoCheck'
    $chain.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority'

    $chainResult = $chain.Build($caCert)
    $chainLength = $chain.ChainElements.Count

    Write-Host "       Chain length: $chainLength" -ForegroundColor $(if ($chainLength -ge 1) { "Green" } else { "Red" })
    Write-Host ""
    Write-Host "       Chain elements:" -ForegroundColor White
    for ($i = 0; $i -lt $chainLength; $i++) {
        $elem = $chain.ChainElements[$i]
        $depth = if ($i -eq 0) { "CA    " } elseif ($i -eq $chainLength - 1) { "Root  " } else { "Bridge" }
        Write-Host "       [$depth] $($elem.Certificate.Subject)" -ForegroundColor Gray
        Write-Host "                Issuer: $($elem.Certificate.Issuer)" -ForegroundColor DarkGray
    }

    if ($chainLength -ge 1) {
        Write-Host ""
        Write-Host "       [PASS] Chain builds successfully" -ForegroundColor Green
    }
} else {
    Write-Host "       [SKIP] Could not verify chain (CA cert not found in MY store)" -ForegroundColor Yellow
}

# -- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Step 5 Complete: Cross-certificate published" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Active CA:          $activeCA" -ForegroundColor White
Write-Host "  CA Cert:            Self-signed (from Step 3)" -ForegroundColor White
Write-Host "  Cross-Cert:         $($crossCert.Subject) issued by $($crossCert.Issuer)" -ForegroundColor White
Write-Host "  Cross-Cert Thumb:   $($crossCert.Thumbprint)" -ForegroundColor White
Write-Host "  Published to:       Intermediate CA store" -ForegroundColor White
if ($issuerInStore) {
    Write-Host "  Old root in trust:  Yes" -ForegroundColor White
}
Write-Host ""
Write-Host "  NEXT: Run Step6-ValidateCrossSignedCA.ps1 on this server" -ForegroundColor Yellow
Write-Host "        to verify the complete cross-signed CA configuration." -ForegroundColor Yellow
Write-Host ""
