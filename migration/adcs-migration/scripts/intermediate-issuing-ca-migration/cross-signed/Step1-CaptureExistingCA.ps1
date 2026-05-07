<#
.SYNOPSIS
    Step 1: Capture existing CA details from the OLD ADCS server (Azure Dedicated HSM).

.DESCRIPTION
    Exports and parses the current issuing CA certificate details to prepare for
    migration. Captures subject name, key algorithm, key length, extensions, and
    other certificate properties needed to build a matching CSR on the new CA.

    RUN ON: OLD ADCS Server (Azure Dedicated HSM / Thales)

.PARAMETER OutputDir
    Directory to save exported certificate and details report.
    Defaults to a timestamped subfolder under the user's home directory.

.PARAMETER CAName
    Common Name of the issuing CA certificate to capture. If omitted, the script
    will auto-detect from registry or select the first CA cert found.

.EXAMPLE
    .\Step1-CaptureExistingCA.ps1

.EXAMPLE
    .\Step1-CaptureExistingCA.ps1 -CAName "Contoso Issuing CA" -OutputDir "C:\Migration"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputDir,

    [Parameter(Mandatory = $false)]
    [string]$CAName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Banner ------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ICA Migration (Cross-Signed) - Step 1: Capture Existing CA" -ForegroundColor Cyan
Write-Host "  Run on: OLD ADCS Server (Azure Dedicated HSM)" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# -- Output directory --------------------------------------------------------
if (-not $OutputDir) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputDir = Join-Path $env:USERPROFILE "ica-crosssign-step1-$timestamp"
}
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}
Write-Host "[INFO] Output directory: $OutputDir" -ForegroundColor Gray

# -- Enumerate CA certificates -----------------------------------------------
Write-Host ""
Write-Host "[1/6] Enumerating CA certificates in local store..." -ForegroundColor White

$caStoreOutput = certutil -store CA 2>&1
$caStoreFile = Join-Path $OutputDir "ca-store-listing.txt"
$caStoreOutput | Out-File -FilePath $caStoreFile -Encoding UTF8
Write-Host "       Saved CA store listing to: $caStoreFile" -ForegroundColor Gray

# Parse CA certificate common names from the store output
$caCerts = @()
foreach ($line in $caStoreOutput) {
    if ($line -match '^\s*Subject:\s*(.+)$') {
        $subject = $Matches[1].Trim()
        $caCerts += $subject
    }
}

if ($caCerts.Count -eq 0) {
    Write-Host "[ERROR] No CA certificates found in the local CA store." -ForegroundColor Red
    Write-Host "        Ensure this script is running on the ADCS server." -ForegroundColor Red
    exit 1
}

Write-Host "       Found $($caCerts.Count) CA certificate(s):" -ForegroundColor Green
for ($i = 0; $i -lt $caCerts.Count; $i++) {
    Write-Host "         [$($i + 1)] $($caCerts[$i])" -ForegroundColor White
}

# -- Select CA certificate ---------------------------------------------------
if ($CAName) {
    Write-Host ""
    Write-Host "[INFO] Using specified CA name: $CAName" -ForegroundColor Gray
} elseif ($caCerts.Count -eq 1) {
    $CAName = $caCerts[0]
    # Extract CN from subject string
    if ($CAName -match 'CN=([^,]+)') {
        $CAName = $Matches[1].Trim()
    }
    Write-Host ""
    Write-Host "[INFO] Auto-selected single CA: $CAName" -ForegroundColor Gray
} else {
    # Try to auto-detect from active CA registry (headless-safe for az vm run-command)
    try {
        $regActive = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA Stop).Active
        if ($regActive) {
            $CAName = $regActive
            Write-Host ""
            Write-Host "[INFO] Auto-detected active CA from registry: $CAName" -ForegroundColor Gray
        }
    } catch { }
    if (-not $CAName) {
        Write-Host ""
        Write-Host "[WARN] Multiple CA certificates found and no active CA in registry." -ForegroundColor Yellow
        Write-Host "       Selecting first CA certificate for headless compatibility." -ForegroundColor Yellow
        $CAName = $caCerts[0]
        if ($CAName -match 'CN=([^,]+)') {
            $CAName = $Matches[1].Trim()
        }
        Write-Host "[INFO] Selected: $CAName" -ForegroundColor Gray
    }
}

# -- Export CA certificate ---------------------------------------------------
Write-Host ""
Write-Host "[2/6] Exporting CA certificate..." -ForegroundColor White

$certFile = Join-Path $OutputDir "OldIssuingCA.cer"
if (Test-Path $certFile) { Remove-Item $certFile -Force }
$exportResult = certutil -ca.cert $certFile 2>&1
$exportText = ($exportResult | Out-String)
if ($exportText -notmatch 'completed successfully') {
    Write-Host "[WARN] certutil -ca.cert failed. Trying alternate export from CA store..." -ForegroundColor Yellow
    # Try exporting from the Intermediate CA store
    if (Test-Path $certFile) { Remove-Item $certFile -Force }
    $exportResult = certutil -store CA $CAName $certFile 2>&1
    $exportText = ($exportResult | Out-String)
    if ($exportText -notmatch 'completed successfully') {
        Write-Host "[WARN] Not in CA store. Trying Root store (standalone Root CA)..." -ForegroundColor Yellow
        # The CA may be a Root CA (self-signed) -- try the Root store
        if (Test-Path $certFile) { Remove-Item $certFile -Force }
        $exportResult = certutil -store Root $CAName $certFile 2>&1
        $exportText = ($exportResult | Out-String)
        if ($exportText -notmatch 'completed successfully') {
            Write-Host "[WARN] Not in Root store. Trying My store..." -ForegroundColor Yellow
            if (Test-Path $certFile) { Remove-Item $certFile -Force }
            $exportResult = certutil -store My $CAName $certFile 2>&1
            $exportText = ($exportResult | Out-String)
            if ($exportText -notmatch 'completed successfully') {
                Write-Host "[ERROR] Failed to export CA certificate from any store." -ForegroundColor Red
                Write-Host $exportResult -ForegroundColor Red
                exit 1
            }
        }
    }
}
Write-Host "       Exported to: $certFile" -ForegroundColor Green

# -- Dump certificate details ------------------------------------------------
Write-Host ""
Write-Host "[3/6] Dumping certificate details..." -ForegroundColor White

$dumpFile = Join-Path $OutputDir "OldIssuingCA-details.txt"
$dumpOutput = certutil -dump $certFile 2>&1
$dumpOutput | Out-File -FilePath $dumpFile -Encoding UTF8
Write-Host "       Saved certificate dump to: $dumpFile" -ForegroundColor Green

# -- Parse key properties ----------------------------------------------------
Write-Host ""
Write-Host "[4/6] Parsing certificate properties..." -ForegroundColor White

$details = @{
    SubjectName       = ""
    Issuer            = ""
    SerialNumber      = ""
    NotBefore         = ""
    NotAfter          = ""
    KeyAlgorithm      = ""
    KeyLength         = ""
    HashAlgorithm     = ""
    AKI               = ""
    SKI               = ""
    BasicConstraints  = ""
    KeyUsage          = ""
    EnhancedKeyUsage  = ""
    ProviderName      = ""
}

$fullDump = $dumpOutput -join "`n"

# Subject
if ($fullDump -match 'Subject:\s*\r?\n\s*(.+)') {
    $details.SubjectName = $Matches[1].Trim()
}

# Issuer
if ($fullDump -match 'Issuer:\s*\r?\n\s*(.+)') {
    $details.Issuer = $Matches[1].Trim()
}

# Serial Number
if ($fullDump -match 'Serial Number:\s*\r?\n?\s*([0-9a-fA-F\s]+)') {
    $details.SerialNumber = ($Matches[1].Trim() -replace '\s+', '')
}

# Validity
if ($fullDump -match 'NotBefore:\s*(.+)') {
    $details.NotBefore = $Matches[1].Trim()
}
if ($fullDump -match 'NotAfter:\s*(.+)') {
    $details.NotAfter = $Matches[1].Trim()
}

# Key Algorithm and Length
if ($fullDump -match 'Public Key Algorithm:\s*\r?\n?\s*(.+)') {
    $details.KeyAlgorithm = $Matches[1].Trim()
}
if ($fullDump -match 'Public Key Length:\s*(\d+)') {
    $details.KeyLength = $Matches[1].Trim()
}

# Signature Algorithm
if ($fullDump -match 'Signature Algorithm:\s*\r?\n?\s*(.+)') {
    $details.HashAlgorithm = $Matches[1].Trim()
}

# Basic Constraints
if ($fullDump -match 'Subject Type=(.+)') {
    $details.BasicConstraints = $Matches[1].Trim()
}

# Key Usage
if ($fullDump -match 'Key Usage:\s*(.+)') {
    $details.KeyUsage = $Matches[1].Trim()
}

# Provider (from CSP check)
$cspOutput = certutil -getreg CA\CSP 2>&1
$cspText = $cspOutput -join "`n"
if ($cspText -match 'Provider\s*=\s*(.+)') {
    $details.ProviderName = $Matches[1].Trim()
}

# Display parsed details
Write-Host ""
Write-Host "  +------------------------------------------------------+" -ForegroundColor Cyan
Write-Host "  |  Existing CA Certificate Summary                     |" -ForegroundColor Cyan
Write-Host "  +------------------------------------------------------+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Subject Name:      $($details.SubjectName)" -ForegroundColor White
Write-Host "  Issuer:            $($details.Issuer)" -ForegroundColor White
Write-Host "  Serial Number:     $($details.SerialNumber)" -ForegroundColor Gray
Write-Host "  Not Before:        $($details.NotBefore)" -ForegroundColor White
Write-Host "  Not After:         $($details.NotAfter)" -ForegroundColor White
Write-Host "  Key Algorithm:     $($details.KeyAlgorithm)" -ForegroundColor White
Write-Host "  Key Length:        $($details.KeyLength)" -ForegroundColor White
Write-Host "  Hash Algorithm:    $($details.HashAlgorithm)" -ForegroundColor White
Write-Host "  Basic Constraints: $($details.BasicConstraints)" -ForegroundColor White
Write-Host "  Key Usage:         $($details.KeyUsage)" -ForegroundColor White
Write-Host "  Provider:          $($details.ProviderName)" -ForegroundColor White
Write-Host ""

# -- Export CSP details ------------------------------------------------------
Write-Host "[5/6] Exporting CSP/KSP provider details..." -ForegroundColor White

$cspFile = Join-Path $OutputDir "csp-details.txt"
$cspOutput | Out-File -FilePath $cspFile -Encoding UTF8
Write-Host "       Saved CSP details to: $cspFile" -ForegroundColor Green

# -- Save structured summary -------------------------------------------------
Write-Host ""
Write-Host "[6/6] Saving structured summary for Step 3 (CSR generation)..." -ForegroundColor White

$summaryFile = Join-Path $OutputDir "ca-migration-details.json"
$details | ConvertTo-Json -Depth 3 | Out-File -FilePath $summaryFile -Encoding UTF8
Write-Host "       Saved JSON summary to: $summaryFile" -ForegroundColor Green

# -- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Step 1 Complete: Existing CA details captured" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Output files:" -ForegroundColor White
Write-Host "    - $certFile" -ForegroundColor Gray
Write-Host "    - $dumpFile" -ForegroundColor Gray
Write-Host "    - $caStoreFile" -ForegroundColor Gray
Write-Host "    - $cspFile" -ForegroundColor Gray
Write-Host "    - $summaryFile" -ForegroundColor Gray
Write-Host ""
Write-Host "  NEXT: Copy the output folder to the NEW ADCS server" -ForegroundColor Yellow
Write-Host "        and run Step2-ValidateNewCAServer.ps1" -ForegroundColor Yellow
Write-Host ""
