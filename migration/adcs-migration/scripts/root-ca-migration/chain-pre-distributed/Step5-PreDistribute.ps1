<#
.SYNOPSIS
    Step 5: Export new Root CA certificate and prepare for trust distribution.

.DESCRIPTION
    Exports the new Root CA certificate in multiple formats (DER, Base64, PEM)
    and provides distribution guidance for pre-distributing the new root to
    relying parties BEFORE the old Root CA is decommissioned.

    Root CA distribution differs from Issuing CA distribution:
    - Root certs go to the Trusted Root Certification Authorities store
    - AD publishing uses "certutil -dspublish -f <cert> RootCA" (not SubCA)
    - All machines that trust the old root should also trust the new root

    RUN ON: NEW ADCS Server (after Step 4 validation)

.PARAMETER OutputDir
    Directory to save exported certificates. Defaults to a timestamped subfolder.

.PARAMETER PublishToAD
    Publish the root certificate to Active Directory via certutil -dspublish.

.PARAMETER SkipADPublish
    Skip the AD publishing step (standalone CAs or manual publishing).

.EXAMPLE
    .\Step5-PreDistribute.ps1

.EXAMPLE
    .\Step5-PreDistribute.ps1 -PublishToAD

.EXAMPLE
    .\Step5-PreDistribute.ps1 -SkipADPublish
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputDir,

    [Parameter(Mandatory = $false)]
    [switch]$PublishToAD,

    [Parameter(Mandatory = $false)]
    [switch]$SkipADPublish
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Banner ------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Root CA Migration - Step 5: Export and Distribute" -ForegroundColor Cyan
Write-Host "  Run on: NEW ADCS Server (after Step 4)" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  This step exports the new Root CA certificate and prepares" -ForegroundColor White
Write-Host "  it for distribution to ALL relying parties. The new root" -ForegroundColor White
Write-Host "  MUST be trusted everywhere before the old root is retired." -ForegroundColor White
Write-Host ""

# -- Output directory --------------------------------------------------------
if (-not $OutputDir) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputDir = Join-Path $env:USERPROFILE "rootca-migration-step5-$timestamp"
}
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}
Write-Host "[INFO] Output directory: $OutputDir" -ForegroundColor Gray

# -- Resolve active CA -------------------------------------------------------
Write-Host ""
Write-Host "[1/5] Resolving active CA..." -ForegroundColor White

try { $activeCA = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA Stop).Active } catch { $activeCA = $null }
if (-not $activeCA) {
    Write-Host "[ERROR] No active CA found. Run Step 3 and Step 4 first." -ForegroundColor Red
    exit 1
}
Write-Host "       Active CA: $activeCA" -ForegroundColor Green

# -- Export CA certificate in multiple formats --------------------------------
Write-Host ""
Write-Host "[2/5] Exporting Root CA certificate..." -ForegroundColor White

# Get cert from store
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

if (-not $caCert) {
    Write-Host "[ERROR] CA certificate not found in My store for: $activeCA" -ForegroundColor Red
    exit 1
}

# DER format (.cer)
$derFile = Join-Path $OutputDir "NewRootCA.cer"
$derBytes = $caCert.Export('Cert')
[IO.File]::WriteAllBytes($derFile, $derBytes)
Write-Host "       [PASS] DER format: $derFile" -ForegroundColor Green

# Base64 raw (single line, for embedding in scripts)
$b64File = Join-Path $OutputDir "NewRootCA.b64"
$b64String = [Convert]::ToBase64String($caCert.RawData)
$b64String | Out-File -FilePath $b64File -Encoding ASCII
Write-Host "       [PASS] Base64 raw: $b64File" -ForegroundColor Green

# PEM format (with BEGIN/END markers)
$pemFile = Join-Path $OutputDir "NewRootCA.pem"
$pemLines = @("-----BEGIN CERTIFICATE-----")
$b64Chars = [Convert]::ToBase64String($caCert.RawData)
for ($i = 0; $i -lt $b64Chars.Length; $i += 64) {
    $lineLen = [Math]::Min(64, $b64Chars.Length - $i)
    $pemLines += $b64Chars.Substring($i, $lineLen)
}
$pemLines += "-----END CERTIFICATE-----"
$pemLines -join "`r`n" | Out-File -FilePath $pemFile -Encoding ASCII
Write-Host "       [PASS] PEM format: $pemFile" -ForegroundColor Green

# Certificate details
Write-Host ""
Write-Host "  Certificate Summary:" -ForegroundColor White
Write-Host "    Subject:    $($caCert.Subject)" -ForegroundColor White
Write-Host "    Thumbprint: $($caCert.Thumbprint)" -ForegroundColor Gray
Write-Host "    Not After:  $($caCert.NotAfter)" -ForegroundColor White
Write-Host ""

# -- AD Publishing -----------------------------------------------------------
Write-Host "[3/5] Active Directory publishing..." -ForegroundColor White

$adPublished = $false

if ($SkipADPublish) {
    Write-Host "       [SKIP] AD publishing skipped (-SkipADPublish)" -ForegroundColor Yellow
} elseif ($PublishToAD) {
    # Root CAs use "RootCA" target, not "SubCA"
    Write-Host "       Publishing to AD as RootCA..." -ForegroundColor Gray
    $rootPubResult = certutil -dspublish -f $derFile RootCA 2>&1
    $rootPubText = ($rootPubResult | Out-String)
    if ($rootPubText -match 'completed successfully') {
        Write-Host "       [PASS] Published to Trusted Root CAs in AD" -ForegroundColor Green
        $adPublished = $true
    } else {
        Write-Host "       [FAIL] AD publish failed (requires Enterprise/Domain Admin)" -ForegroundColor Red
        $rootPubResult | ForEach-Object { Write-Host "         $_" -ForegroundColor Red }
    }

    # Force GPO update
    if ($adPublished) {
        Write-Host "       Triggering Group Policy update..." -ForegroundColor Gray
        try {
            gpupdate /force 2>&1 | Out-Null
            Write-Host "       [PASS] Group Policy update triggered" -ForegroundColor Green
        } catch {
            Write-Host "       [WARN] gpupdate failed - run manually on domain-joined machines" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "       [SKIP] Not requested. Use -PublishToAD to publish, or -SkipADPublish to skip." -ForegroundColor Yellow
}

# -- Generate import scripts --------------------------------------------------
Write-Host ""
Write-Host "[4/5] Generating distribution helper scripts..." -ForegroundColor White

# Windows import script
$winScript = Join-Path $OutputDir "Import-NewRoot-Windows.ps1"
$winContent = @"
# Import new Root CA certificate into Windows trust store
# Run on each Windows machine that needs to trust the new Root CA

`$certFile = "`$PSScriptRoot\NewRootCA.cer"
if (-not (Test-Path `$certFile)) {
    Write-Host "[ERROR] NewRootCA.cer not found in script directory" -ForegroundColor Red
    exit 1
}

# Import to Trusted Root Certification Authorities (LocalMachine)
`$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(`$certFile)
`$store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
`$store.Open("ReadWrite")

# Check if already present
`$existing = `$store.Certificates | Where-Object { `$_.Thumbprint -eq `$cert.Thumbprint }
if (`$existing) {
    Write-Host "[INFO] Certificate already in Root store (Thumbprint: `$(`$cert.Thumbprint))" -ForegroundColor Yellow
} else {
    `$store.Add(`$cert)
    Write-Host "[PASS] Imported to Trusted Root CAs: `$(`$cert.Subject)" -ForegroundColor Green
    Write-Host "       Thumbprint: `$(`$cert.Thumbprint)" -ForegroundColor Gray
}
`$store.Close()
"@
$winContent | Out-File -FilePath $winScript -Encoding ASCII
Write-Host "       [PASS] Windows import script: $winScript" -ForegroundColor Green

# Linux import guidance
$linuxScript = Join-Path $OutputDir "Import-NewRoot-Linux.sh"
$linuxContent = @"
#!/bin/bash
# Import new Root CA certificate on Linux
# Adjust paths for your distribution (Ubuntu/RHEL/etc.)

CERT_FILE="`$(dirname "`$0")/NewRootCA.pem"

if [ ! -f "`$CERT_FILE" ]; then
    echo "[ERROR] NewRootCA.pem not found in script directory"
    exit 1
fi

echo "Detected distribution:"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "  `$NAME `$VERSION"
fi

# Ubuntu / Debian
if command -v update-ca-certificates &>/dev/null; then
    sudo cp "`$CERT_FILE" /usr/local/share/ca-certificates/NewRootCA.crt
    sudo update-ca-certificates
    echo "[PASS] Certificate imported (Ubuntu/Debian)"

# RHEL / CentOS / Fedora
elif command -v update-ca-trust &>/dev/null; then
    sudo cp "`$CERT_FILE" /etc/pki/ca-trust/source/anchors/NewRootCA.pem
    sudo update-ca-trust extract
    echo "[PASS] Certificate imported (RHEL/CentOS)"

else
    echo "[WARN] Unknown distribution. Manually import NewRootCA.pem."
    echo "       Common paths:"
    echo "         /usr/local/share/ca-certificates/ (Debian)"
    echo "         /etc/pki/ca-trust/source/anchors/  (RHEL)"
fi
"@
$linuxContent | Out-File -FilePath $linuxScript -Encoding ASCII
Write-Host "       [PASS] Linux import script: $linuxScript" -ForegroundColor Green

# -- Distribution checklist ---------------------------------------------------
Write-Host ""
Write-Host "[5/5] Distribution Checklist" -ForegroundColor White
Write-Host ""
Write-Host "  The new Root CA certificate MUST be distributed to ALL" -ForegroundColor Red
Write-Host "  systems that trust the old root. Unlike issuing CA certs," -ForegroundColor Red
Write-Host "  root certs go to the ROOT trust store (not intermediate)." -ForegroundColor Red
Write-Host ""
Write-Host "  +----------------------------------------------------------+" -ForegroundColor White
Write-Host "  |  Distribution Target             | Status               |" -ForegroundColor White
Write-Host "  +----------------------------------------------------------+" -ForegroundColor White

$targets = @(
    @{ Name = "Active Directory (Root CAs)"; Auto = $adPublished },
    @{ Name = "Domain-joined Windows machines"; Auto = $adPublished },
    @{ Name = "Non-domain Windows machines"; Auto = $false },
    @{ Name = "Linux / Unix servers"; Auto = $false },
    @{ Name = "Network appliances (firewalls)"; Auto = $false },
    @{ Name = "Load balancers / WAF"; Auto = $false },
    @{ Name = "RADIUS servers (NPS/ISE)"; Auto = $false },
    @{ Name = "VPN concentrators"; Auto = $false },
    @{ Name = "IoT / embedded devices"; Auto = $false },
    @{ Name = "Mobile device management (MDM)"; Auto = $false },
    @{ Name = "Certificate pinning configs"; Auto = $false },
    @{ Name = "Cloud services trust stores"; Auto = $false }
)

foreach ($t in $targets) {
    $status = if ($t.Auto) { "DONE (via AD/GPO)" } else { "[ ] MANUAL" }
    $color  = if ($t.Auto) { "Green" } else { "Yellow" }
    $padded = $t.Name.PadRight(36)
    Write-Host "  |  $padded| $status" -ForegroundColor $color
}

Write-Host "  +----------------------------------------------------------+" -ForegroundColor White

# -- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Step 5: Export Complete - Distribution In Progress" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Output files:" -ForegroundColor White
Write-Host "    - $derFile (DER / Windows)" -ForegroundColor Gray
Write-Host "    - $b64File (Base64 / embedding)" -ForegroundColor Gray
Write-Host "    - $pemFile (PEM / Linux)" -ForegroundColor Gray
Write-Host "    - $winScript" -ForegroundColor Gray
Write-Host "    - $linuxScript" -ForegroundColor Gray
Write-Host ""
Write-Host "  AD Published: $(if ($adPublished) { 'Yes' } else { 'No / Not Requested' })" -ForegroundColor White
Write-Host ""
Write-Host "  CRITICAL: Do NOT decommission the old root until ALL" -ForegroundColor Red
Write-Host "  relying parties trust the new root certificate." -ForegroundColor Red
Write-Host ""
Write-Host "  NEXT: Distribute the certificate files to all targets" -ForegroundColor Yellow
Write-Host "        in the checklist above, then run" -ForegroundColor Yellow
Write-Host "        Step6-ValidateTrust.ps1 on target machines." -ForegroundColor Yellow
Write-Host ""
