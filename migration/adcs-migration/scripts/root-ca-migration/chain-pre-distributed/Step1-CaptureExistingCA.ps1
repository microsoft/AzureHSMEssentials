<#
.SYNOPSIS
    Step 1: Capture existing Root CA details from the OLD ADCS server.

.DESCRIPTION
    Exports and parses the current Root CA certificate details to prepare for
    migration. Captures subject name, key algorithm, key length, extensions, and
    other certificate properties needed to build a matching new Root CA.

    The output JSON file is used by Step 3 (Build New Root CA) to ensure the
    new root matches the old root's configuration where appropriate.

    RUN ON: OLD ADCS Server (source Root CA)

.PARAMETER OutputDir
    Directory to save exported certificate and details report.
    Defaults to a timestamped subfolder under the user's home directory.

.PARAMETER CAName
    Common Name of the Root CA certificate to capture. If omitted, the script
    reads the active CA name from the registry.

.EXAMPLE
    .\Step1-CaptureExistingCA.ps1

.EXAMPLE
    .\Step1-CaptureExistingCA.ps1 -OutputDir "C:\Migration\OldRoot"
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
Write-Host "  Root CA Migration - Step 1: Capture Existing Root CA" -ForegroundColor Cyan
Write-Host "  Run on: OLD ADCS Server (source Root CA)" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# -- Output directory --------------------------------------------------------
if (-not $OutputDir) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputDir = Join-Path $env:USERPROFILE "rootca-migration-step1-$timestamp"
}
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}
Write-Host "[INFO] Output directory: $OutputDir" -ForegroundColor Gray

# -- Resolve CA name ---------------------------------------------------------
Write-Host ""
Write-Host "[1/6] Resolving active CA name..." -ForegroundColor White

if (-not $CAName) {
    try { $regActive = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA Stop).Active } catch { $regActive = $null }
    if (-not $regActive) {
        Write-Host "[ERROR] No active CA found in registry. Is this an ADCS server?" -ForegroundColor Red
        exit 1
    }
    $CAName = $regActive
    Write-Host "       Active CA from registry: $CAName" -ForegroundColor Green
} else {
    Write-Host "       Using specified CA name: $CAName" -ForegroundColor Green
}

# -- Export CA certificate ---------------------------------------------------
Write-Host ""
Write-Host "[2/6] Exporting Root CA certificate..." -ForegroundColor White

$certFile = Join-Path $OutputDir "OldRootCA.cer"
# Use PowerShell to export (avoids certutil filename parsing issues)
$caCert = $null
foreach ($cert in (Get-ChildItem Cert:\LocalMachine\My)) {
    if ($cert.Subject -notmatch [regex]::Escape($CAName)) { continue }
    foreach ($ext in $cert.Extensions) {
        if ($ext.Oid.FriendlyName -eq 'Basic Constraints') {
            $caCert = $cert
            break
        }
    }
    if ($caCert) { break }
}

if (-not $caCert) {
    Write-Host "[WARN] CA cert not found in My store. Trying certutil..." -ForegroundColor Yellow
    $exportOut = certutil -ca.cert $certFile 2>&1
    $exportText = ($exportOut | Out-String)
    if ($exportText -notmatch 'command completed successfully') {
        Write-Host "[ERROR] Failed to export CA certificate." -ForegroundColor Red
        Write-Host $exportOut -ForegroundColor Red
        exit 1
    }
} else {
    $derBytes = $caCert.Export('Cert')
    [IO.File]::WriteAllBytes($certFile, $derBytes)
}
Write-Host "       Exported to: $certFile" -ForegroundColor Green

# -- Dump certificate details ------------------------------------------------
Write-Host ""
Write-Host "[3/6] Dumping certificate details..." -ForegroundColor White

$dumpFile = Join-Path $OutputDir "OldRootCA-details.txt"
$dumpOutput = certutil -dump $certFile 2>&1
$dumpOutput | Out-File -FilePath $dumpFile -Encoding UTF8
Write-Host "       Saved certificate dump to: $dumpFile" -ForegroundColor Green

# -- Parse key properties ----------------------------------------------------
Write-Host ""
Write-Host "[4/6] Parsing certificate properties..." -ForegroundColor White

$details = @{
    CACommonName      = $CAName
    SubjectName       = ""
    Issuer            = ""
    SerialNumber      = ""
    NotBefore         = ""
    NotAfter          = ""
    KeyAlgorithm      = ""
    KeyLength         = ""
    HashAlgorithm     = ""
    SKI               = ""
    BasicConstraints  = ""
    KeyUsage          = ""
    ProviderName      = ""
    Thumbprint        = ""
    IsSelfSigned      = $false
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

# Self-signed check (Subject == Issuer)
if ($details.SubjectName -and $details.Issuer) {
    $details.IsSelfSigned = ($details.SubjectName -eq $details.Issuer)
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

# Thumbprint
if ($caCert) {
    $details.Thumbprint = $caCert.Thumbprint
} elseif ($fullDump -match 'Cert Hash\(sha1\):\s*([0-9a-f ]+)') {
    $details.Thumbprint = ($Matches[1].Trim() -replace ' ', '')
}

# Provider (from CSP registry)
$cspOutput = certutil -getreg CA\CSP 2>&1
$cspText = $cspOutput -join "`n"
if ($cspText -match 'Provider\s*=\s*(.+)') {
    $details.ProviderName = $Matches[1].Trim()
}

# Interactive mode
$interactiveOutput = certutil -getreg CA\CSP\Interactive 2>&1
$interactiveText = $interactiveOutput -join "`n"
$interactiveValue = "unknown"
if ($interactiveText -match 'Interactive REG_DWORD = (\d+)') {
    $interactiveValue = $Matches[1]
}

# Display parsed details
Write-Host ""
Write-Host "  +------------------------------------------------------+" -ForegroundColor Cyan
Write-Host "  |  Existing Root CA Certificate Summary                |" -ForegroundColor Cyan
Write-Host "  +------------------------------------------------------+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  CA Common Name:    $($details.CACommonName)" -ForegroundColor White
Write-Host "  Subject Name:      $($details.SubjectName)" -ForegroundColor White
Write-Host "  Issuer:            $($details.Issuer)" -ForegroundColor White
Write-Host "  Self-Signed:       $($details.IsSelfSigned)" -ForegroundColor $(if ($details.IsSelfSigned) { 'Green' } else { 'Yellow' })
Write-Host "  Serial Number:     $($details.SerialNumber)" -ForegroundColor Gray
Write-Host "  Thumbprint:        $($details.Thumbprint)" -ForegroundColor Gray
Write-Host "  Not Before:        $($details.NotBefore)" -ForegroundColor White
Write-Host "  Not After:         $($details.NotAfter)" -ForegroundColor White
Write-Host "  Key Algorithm:     $($details.KeyAlgorithm)" -ForegroundColor White
Write-Host "  Key Length:        $($details.KeyLength)" -ForegroundColor White
Write-Host "  Hash Algorithm:    $($details.HashAlgorithm)" -ForegroundColor White
Write-Host "  Basic Constraints: $($details.BasicConstraints)" -ForegroundColor White
Write-Host "  Key Usage:         $($details.KeyUsage)" -ForegroundColor White
Write-Host "  Provider:          $($details.ProviderName)" -ForegroundColor White
Write-Host "  Interactive:       $interactiveValue" -ForegroundColor $(if ($interactiveValue -eq '0') { 'Green' } else { 'Red' })
Write-Host ""

if (-not $details.IsSelfSigned) {
    Write-Host "  [WARN] This CA does NOT appear to be self-signed." -ForegroundColor Yellow
    Write-Host "         Subject and Issuer differ. If this is an Issuing CA," -ForegroundColor Yellow
    Write-Host "         use the Issuing CA migration scripts instead." -ForegroundColor Yellow
    Write-Host ""
}

# -- Export CSP details ------------------------------------------------------
Write-Host "[5/6] Exporting CSP/KSP provider details..." -ForegroundColor White

$cspFile = Join-Path $OutputDir "csp-details.txt"
$cspOutput | Out-File -FilePath $cspFile -Encoding UTF8
Write-Host "       Saved CSP details to: $cspFile" -ForegroundColor Green

# -- Save structured summary -------------------------------------------------
Write-Host ""
Write-Host "[6/6] Saving structured summary for Step 3..." -ForegroundColor White

$summaryFile = Join-Path $OutputDir "rootca-migration-details.json"
$details | ConvertTo-Json -Depth 3 | Out-File -FilePath $summaryFile -Encoding UTF8
Write-Host "       Saved JSON summary to: $summaryFile" -ForegroundColor Green

# Also export root cert as base64 for easy transfer
$b64File = Join-Path $OutputDir "OldRootCA.b64"
if ($caCert) {
    $b64 = [Convert]::ToBase64String($caCert.RawData)
} else {
    $certObj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certFile)
    $b64 = [Convert]::ToBase64String($certObj.RawData)
}
$b64 | Out-File -FilePath $b64File -Encoding ASCII
Write-Host "       Saved base64 cert to: $b64File" -ForegroundColor Green

# -- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Step 1 Complete: Existing Root CA details captured" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Output files:" -ForegroundColor White
Write-Host "    - $certFile" -ForegroundColor Gray
Write-Host "    - $dumpFile" -ForegroundColor Gray
Write-Host "    - $cspFile" -ForegroundColor Gray
Write-Host "    - $summaryFile" -ForegroundColor Gray
Write-Host "    - $b64File" -ForegroundColor Gray
Write-Host ""
Write-Host "  NEXT: Copy the output folder to the NEW ADCS server" -ForegroundColor Yellow
Write-Host "        and run Step2-ValidateNewCAServer.ps1" -ForegroundColor Yellow
Write-Host ""
