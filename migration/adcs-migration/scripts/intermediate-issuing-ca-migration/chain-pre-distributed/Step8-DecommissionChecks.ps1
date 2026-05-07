<#
.SYNOPSIS
    Step 8: Decommission readiness checks for the OLD issuing CA (Dedicated HSM).

.DESCRIPTION
    Audits the old CA to determine if it is safe to decommission. Checks for
    remaining valid (non-expired) certificates, pending requests, and provides
    a readiness report.

    IMPORTANT: Do NOT revoke the old issuing CA. Let it expire naturally.
    Decommission services, not trust.

    RUN ON: OLD ADCS Server (Azure Dedicated HSM)

.PARAMETER OutputDir
    Directory to save the decommission readiness report.
    Defaults to a timestamped subfolder.

.PARAMETER MaxCertsToShow
    Maximum number of remaining valid certificates to display. Defaults to 25.

.EXAMPLE
    .\Step8-DecommissionChecks.ps1

.EXAMPLE
    .\Step8-DecommissionChecks.ps1 -MaxCertsToShow 50
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputDir,

    [Parameter(Mandatory = $false)]
    [int]$MaxCertsToShow = 25
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Banner ------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ADCS Migration - Step 8: Decommission Readiness Check" -ForegroundColor Cyan
Write-Host "  Run on: OLD ADCS Server (Azure Dedicated HSM)" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  REMINDER: Do NOT revoke the old issuing CA certificate." -ForegroundColor Red
Write-Host "  Let it expire. Decommission services, not trust." -ForegroundColor Red
Write-Host ""

# -- Output directory --------------------------------------------------------
if (-not $OutputDir) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputDir = Join-Path $env:USERPROFILE "adcs-migration-step8-$timestamp"
}
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}
Write-Host "[INFO] Output directory: $OutputDir" -ForegroundColor Gray

# -- Check 1: CA certificate validity ----------------------------------------
Write-Host ""
Write-Host "[1/5] Checking old CA certificate validity..." -ForegroundColor White

$caSubject = "(unknown)"
$notAfter = "(unknown)"
$caCertFile = Join-Path $OutputDir "OldCA-current.cer"
$exportResult = certutil -ca.cert $caCertFile 2>&1
$exportText = ($exportResult | Out-String)

if ($exportText -match 'completed successfully') {
    $certDump = certutil -dump $caCertFile 2>&1
    $certText = $certDump -join "`n"

    $notAfter = ""
    if ($certText -match 'NotAfter:\s*(.+)') {
        $notAfter = $Matches[1].Trim()
    }

    $caSubject = ""
    if ($certText -match 'Subject:\s*\r?\n\s*(.+)') {
        $caSubject = $Matches[1].Trim()
    }

    Write-Host "  CA:         $caSubject" -ForegroundColor White
    Write-Host "  Expires:    $notAfter" -ForegroundColor White

    # Check if expired
    try {
        $expiryDate = [DateTime]::Parse($notAfter)
        $daysRemaining = ($expiryDate - (Get-Date)).Days
        if ($daysRemaining -le 0) {
            Write-Host "  Status:     EXPIRED ($([Math]::Abs($daysRemaining)) days ago)" -ForegroundColor Green
        } elseif ($daysRemaining -le 90) {
            Write-Host "  Status:     Expiring in $daysRemaining days" -ForegroundColor Yellow
        } else {
            Write-Host "  Status:     $daysRemaining days remaining" -ForegroundColor White
        }
    } catch {
        Write-Host "  Status:     Could not parse expiry date" -ForegroundColor Yellow
    }
} else {
    Write-Host "  [WARN] Could not export CA certificate" -ForegroundColor Yellow
}

# -- Check 2: Issued certificates still valid --------------------------------
Write-Host ""
Write-Host "[2/5] Auditing issued certificates (non-expired, non-revoked)..." -ForegroundColor White

$validCertCount = 0
$expiringCertCount = 0
$validCerts = @()

try {
    # Query the CA database for valid (non-expired, non-revoked) certs
    $dbOutput = certutil -view -restrict "NotAfter>now,Disposition=20" -out "RequestID,CommonName,NotAfter,CertificateTemplate" 2>&1
    $dbText = $dbOutput -join "`n"

    # Count results
    $rowMatches = [regex]::Matches($dbText, 'Row \d+:')
    $validCertCount = $rowMatches.Count

    # Parse individual certs for summary
    $certEntries = $dbText -split 'Row \d+:'
    foreach ($entry in $certEntries) {
        if ($entry.Trim().Length -eq 0) { continue }

        $cn = ""
        $expiry = ""
        $template = ""

        if ($entry -match 'Issued Common Name:\s*"([^"]*)"') { $cn = $Matches[1] }
        if ($entry -match 'Certificate Expiration Date:\s*(.+)') { $expiry = $Matches[1].Trim() }
        if ($entry -match 'Certificate Template:\s*"?([^"\r\n]*)"?') { $template = $Matches[1] }

        if ($cn) {
            $validCerts += [PSCustomObject]@{
                CommonName = $cn
                Expires    = $expiry
                Template   = $template
            }
        }
    }

    # Count certs expiring within 90 days
    foreach ($vc in $validCerts) {
        try {
            if ($vc.Expires) {
                $exp = [DateTime]::Parse($vc.Expires)
                if (($exp - (Get-Date)).Days -le 90) {
                    $expiringCertCount++
                }
            }
        } catch { }
    }

    Write-Host "  Valid certificates:       $validCertCount" -ForegroundColor $(if ($validCertCount -eq 0) { "Green" } else { "Yellow" })
    Write-Host "  Expiring within 90 days:  $expiringCertCount" -ForegroundColor $(if ($expiringCertCount -gt 0) { "Cyan" } else { "Gray" })

    if ($validCertCount -gt 0 -and $validCerts.Count -gt 0) {
        Write-Host ""
        Write-Host "  Remaining valid certificates (showing up to $MaxCertsToShow):" -ForegroundColor White
        $showing = [Math]::Min($MaxCertsToShow, $validCerts.Count)
        for ($i = 0; $i -lt $showing; $i++) {
            $vc = $validCerts[$i]
            Write-Host "    - $($vc.CommonName) (expires: $($vc.Expires))" -ForegroundColor Gray
        }
        if ($validCerts.Count -gt $MaxCertsToShow) {
            Write-Host "    ... and $($validCerts.Count - $MaxCertsToShow) more" -ForegroundColor Gray
        }
    }

    # Save full list to file
    $certListFile = Join-Path $OutputDir "valid-certificates.csv"
    if ($validCerts.Count -gt 0) {
        $validCerts | Export-Csv -Path $certListFile -NoTypeInformation
        Write-Host ""
        Write-Host "  Full list saved to: $certListFile" -ForegroundColor Gray
    }
} catch {
    Write-Host "  [WARN] Could not query CA database: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "         Ensure this script is run on the CA server." -ForegroundColor Gray
}

# -- Check 3: Pending requests -----------------------------------------------
Write-Host ""
Write-Host "[3/5] Checking for pending certificate requests..." -ForegroundColor White

try {
    $pendingOutput = certutil -view -restrict "Disposition=9" -out "RequestID,CommonName,SubmittedWhen" 2>&1
    $pendingText = $pendingOutput -join "`n"
    $pendingMatches = [regex]::Matches($pendingText, 'Row \d+:')
    $pendingCount = $pendingMatches.Count

    Write-Host "  Pending requests: $pendingCount" -ForegroundColor $(if ($pendingCount -eq 0) { "Green" } else { "Yellow" })
    if ($pendingCount -gt 0) {
        Write-Host "  ACTION: Resolve or deny pending requests before decommission." -ForegroundColor Yellow
    }
} catch {
    Write-Host "  [WARN] Could not query pending requests" -ForegroundColor Yellow
}

# -- Check 4: Certificate Services status ------------------------------------
Write-Host ""
Write-Host "[4/5] Checking Certificate Services status..." -ForegroundColor White

try {
    $svc = Get-Service -Name certsvc -ErrorAction Stop
    Write-Host "  certsvc status: $($svc.Status)" -ForegroundColor White
    if ($svc.Status -eq 'Running') {
        Write-Host "  The old CA is still running and issuing certificates." -ForegroundColor Yellow
        Write-Host "  When ready to decommission, stop the service:" -ForegroundColor Gray
        Write-Host "    Stop-Service certsvc" -ForegroundColor Gray
        Write-Host "    Set-Service certsvc -StartupType Disabled" -ForegroundColor Gray
    } else {
        Write-Host "  Certificate Services is stopped." -ForegroundColor Green
    }
} catch {
    Write-Host "  [WARN] certsvc not found on this machine" -ForegroundColor Yellow
}

# -- Check 5: CRL publication status -----------------------------------------
Write-Host ""
Write-Host "[5/5] Checking CRL status..." -ForegroundColor White

$crlOutput = certutil -getreg CA\CRLPeriod 2>&1
$crlText = $crlOutput -join "`n"
Write-Host "  Note: After decommission, ensure the last CRL is published" -ForegroundColor Gray
Write-Host "  with an extended validity period to cover remaining certificates." -ForegroundColor Gray

# -- Readiness Assessment ----------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Decommission Readiness Assessment" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$ready = ($validCertCount -eq 0) -and ($pendingCount -eq 0)

if ($ready) {
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
    Write-Host "  |  READY TO DECOMMISSION                              |" -ForegroundColor Green
    Write-Host "  |                                                      |" -ForegroundColor Green
    Write-Host "  |  No valid certificates remain. No pending requests.  |" -ForegroundColor Green
    Write-Host "  |  The old CA can be safely decommissioned.            |" -ForegroundColor Green
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
} else {
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Yellow
    Write-Host "  |  NOT YET READY TO DECOMMISSION                      |" -ForegroundColor Yellow
    Write-Host "  |                                                      |" -ForegroundColor Yellow
    if ($validCertCount -gt 0) {
        Write-Host "  |  $validCertCount valid certificate(s) still active." -ForegroundColor Yellow
        Write-Host "  |  Reissue from new CA or wait for expiration.        |" -ForegroundColor Yellow
    }
    if ($pendingCount -gt 0) {
        Write-Host "  |  $pendingCount pending request(s) need resolution." -ForegroundColor Yellow
    }
    Write-Host "  |                                                      |" -ForegroundColor Yellow
    Write-Host "  |  REMINDER: Do NOT revoke the old CA certificate.     |" -ForegroundColor Red
    Write-Host "  |  Let certificates expire naturally.                  |" -ForegroundColor Yellow
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Yellow
}

# -- Save summary report -----------------------------------------------------
$reportFile = Join-Path $OutputDir "decommission-readiness-report.txt"
$report = @"
ADCS Migration - Decommission Readiness Report
Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Server:    $env:COMPUTERNAME

CA Subject:                  $caSubject
CA Expires:                  $notAfter
Valid Certificates:          $validCertCount
Certs Expiring in 90 Days:  $expiringCertCount
Pending Requests:            $pendingCount
Readiness:                   $(if ($ready) { 'READY' } else { 'NOT READY' })

Recommendation: $(if ($ready) { 'Safe to decommission. Stop certsvc and publish a final long-lived CRL.' } else { 'Wait for remaining certificates to expire or reissue from the new CA.' })
"@

$report | Out-File -FilePath $reportFile -Encoding UTF8

Write-Host ""
Write-Host "  Report saved to: $reportFile" -ForegroundColor Gray
if ($validCerts.Count -gt 0) {
    Write-Host "  Certificate list: $certListFile" -ForegroundColor Gray
}
Write-Host ""
Write-Host "  Run this script periodically to track decommission readiness." -ForegroundColor Gray
Write-Host ""
