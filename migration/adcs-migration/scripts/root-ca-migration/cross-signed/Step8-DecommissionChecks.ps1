<#
.SYNOPSIS
    Step 8: Decommission readiness checks for the OLD Root CA.

.DESCRIPTION
    Audits the old Root CA to determine if it is safe to decommission. Checks:
    - Issued certificates still valid (non-expired, non-revoked)
    - Pending requests
    - CRL publication status
    - Whether subordinate CAs chain to this root
    - Certificate Services status

    IMPORTANT: Do NOT revoke the old Root CA certificate. Let it expire
    naturally. Decommission services, not trust. Revoking a root cert
    is meaningless (self-signed) and removing it from trust stores
    will break all certificates in its chain.

    RUN ON: OLD ADCS Server (source Root CA)

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
Write-Host "  Root CA Migration - Step 8: Decommission Readiness Check" -ForegroundColor Cyan
Write-Host "  Run on: OLD ADCS Server (source Root CA)" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  REMINDER: Do NOT revoke the old Root CA certificate." -ForegroundColor Red
Write-Host "  Root CA certs are self-signed -- revocation is meaningless." -ForegroundColor Red
Write-Host "  Let certificates expire naturally. Decommission services," -ForegroundColor Red
Write-Host "  not trust." -ForegroundColor Red
Write-Host ""

# -- Output directory --------------------------------------------------------
if (-not $OutputDir) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputDir = Join-Path $env:USERPROFILE "rootca-migration-step8-$timestamp"
}
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}
Write-Host "[INFO] Output directory: $OutputDir" -ForegroundColor Gray

# -- Check 1: CA certificate validity ----------------------------------------
Write-Host ""
Write-Host "[1/6] Checking old Root CA certificate..." -ForegroundColor White

$caSubject = ""
$notAfter = ""
$daysRemaining = -1

try { $activeCA = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA Stop).Active } catch { $activeCA = $null }
if (-not $activeCA) {
    Write-Host "  [WARN] No active CA found in registry." -ForegroundColor Yellow
    Write-Host "         Certificate Services may already be removed." -ForegroundColor Gray
} else {
    Write-Host "  Active CA: $activeCA" -ForegroundColor White

    $caCertFile = Join-Path $OutputDir "OldRootCA-current.cer"

    # Export via PowerShell
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

    if ($caCert) {
        $derBytes = $caCert.Export('Cert')
        [IO.File]::WriteAllBytes($caCertFile, $derBytes)
        $caSubject = $caCert.Subject
        $notAfter = $caCert.NotAfter.ToString("yyyy-MM-dd HH:mm:ss")
        $daysRemaining = ($caCert.NotAfter - (Get-Date)).Days
    } else {
        # Fallback to certutil
        $exportOut = certutil -ca.cert $caCertFile 2>&1
        $exportText = ($exportOut | Out-String)
        if ($exportText -match 'completed successfully') {
            $certDump = certutil -dump $caCertFile 2>&1
            $certText = $certDump -join "`n"
            if ($certText -match 'Subject:\s*\r?\n\s*(.+)') { $caSubject = $Matches[1].Trim() }
            if ($certText -match 'NotAfter:\s*(.+)') {
                $notAfter = $Matches[1].Trim()
                try {
                    $daysRemaining = ([DateTime]::Parse($notAfter) - (Get-Date)).Days
                } catch { }
            }
        }
    }

    Write-Host "  Subject:  $caSubject" -ForegroundColor White
    Write-Host "  Expires:  $notAfter" -ForegroundColor White

    if ($daysRemaining -ge 0) {
        if ($daysRemaining -le 0) {
            Write-Host "  Status:   EXPIRED ($([Math]::Abs($daysRemaining)) days ago)" -ForegroundColor Green
        } elseif ($daysRemaining -le 90) {
            Write-Host "  Status:   Expiring in $daysRemaining days" -ForegroundColor Yellow
        } else {
            Write-Host "  Status:   $daysRemaining days remaining" -ForegroundColor White
        }
    }
}

# -- Check 2: Issued certificates still valid --------------------------------
Write-Host ""
Write-Host "[2/6] Auditing issued certificates (non-expired, non-revoked)..." -ForegroundColor White

$validCertCount = 0
$expiringCertCount = 0
$validCerts = @()
$pendingCount = 0

try {
    # Query the CA database for valid (non-expired, non-revoked) certs
    $dbOutput = certutil -view -restrict "NotAfter>now,Disposition=20" -out "RequestID,CommonName,NotAfter,CertificateTemplate" 2>&1
    $dbText = $dbOutput -join "`n"

    # Count results
    $rowMatches = [regex]::Matches($dbText, 'Row \d+:')
    $validCertCount = $rowMatches.Count

    # Parse individual certs
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

    # Count expiring within 90 days
    foreach ($vc in $validCerts) {
        try {
            if ($vc.Expires) {
                $exp = [DateTime]::Parse($vc.Expires)
                if (($exp - (Get-Date)).Days -le 90) { $expiringCertCount++ }
            }
        } catch { }
    }

    Write-Host "  Valid certificates:       $validCertCount" -ForegroundColor $(if ($validCertCount -eq 0) { "Green" } else { "Yellow" })
    Write-Host "  Expiring within 90 days:  $expiringCertCount" -ForegroundColor $(if ($expiringCertCount -gt 0) { "Cyan" } else { "Gray" })

    if ($validCertCount -gt 0 -and $validCerts.Count -gt 0) {
        Write-Host ""
        Write-Host "  Remaining valid certificates (up to $MaxCertsToShow):" -ForegroundColor White
        $showing = [Math]::Min($MaxCertsToShow, $validCerts.Count)
        for ($i = 0; $i -lt $showing; $i++) {
            $vc = $validCerts[$i]
            Write-Host "    - $($vc.CommonName) (expires: $($vc.Expires))" -ForegroundColor Gray
        }
        if ($validCerts.Count -gt $MaxCertsToShow) {
            Write-Host "    ... and $($validCerts.Count - $MaxCertsToShow) more" -ForegroundColor Gray
        }
    }

    # Save full list
    $certListFile = Join-Path $OutputDir "valid-certificates.csv"
    if ($validCerts.Count -gt 0) {
        $validCerts | Export-Csv -Path $certListFile -NoTypeInformation
        Write-Host ""
        Write-Host "  Full list saved to: $certListFile" -ForegroundColor Gray
    }
} catch {
    Write-Host "  [WARN] Could not query CA database: $($_.Exception.Message)" -ForegroundColor Yellow
}

# -- Check 3: Pending requests -----------------------------------------------
Write-Host ""
Write-Host "[3/6] Checking for pending certificate requests..." -ForegroundColor White

try {
    $pendingOutput = certutil -view -restrict "Disposition=9" -out "RequestID,CommonName,SubmittedWhen" 2>&1
    $pendingText = $pendingOutput -join "`n"
    $pendingMatches = [regex]::Matches($pendingText, 'Row \d+:')
    $pendingCount = $pendingMatches.Count

    Write-Host "  Pending requests: $pendingCount" -ForegroundColor $(if ($pendingCount -eq 0) { "Green" } else { "Yellow" })
    if ($pendingCount -gt 0) {
        Write-Host "  ACTION: Deny or resolve pending requests before decommission." -ForegroundColor Yellow
    }
} catch {
    Write-Host "  [WARN] Could not query pending requests" -ForegroundColor Yellow
}

# -- Check 4: Subordinate CA references --------------------------------------
Write-Host ""
Write-Host "[4/6] Checking for subordinate CA certificates issued..." -ForegroundColor White

$subCACount = 0
try {
    # Look for issued SubCA certs (Basic Constraints CA:TRUE in issued certs)
    $subCAOutput = certutil -view -restrict "Disposition=20,CertificateTemplate=SubCA" -out "RequestID,CommonName,NotAfter" 2>&1
    $subCAText = $subCAOutput -join "`n"
    $subCAMatches = [regex]::Matches($subCAText, 'Row \d+:')
    $subCACount = $subCAMatches.Count

    if ($subCACount -gt 0) {
        Write-Host "  [WARN] $subCACount subordinate CA certificate(s) issued by this root." -ForegroundColor Yellow
        Write-Host "         These ICAs chain to this root. Ensure they have been" -ForegroundColor Yellow
        Write-Host "         migrated or re-issued under the new root before decommission." -ForegroundColor Yellow
    } else {
        Write-Host "  No subordinate CA certificates found." -ForegroundColor Green
    }
} catch {
    Write-Host "  [INFO] Could not query SubCA template (standalone CA may not use templates)" -ForegroundColor Gray

    # For standalone CAs, check if any issued certs have CA:TRUE manually
    # This is less reliable but catches the common case
    try {
        $allIssuedOut = certutil -view -restrict "Disposition=20" -out "RequestID,CommonName,NotAfter" 2>&1
        $allIssuedText = $allIssuedOut -join "`n"
        $allIssuedMatches = [regex]::Matches($allIssuedText, 'Row \d+:')
        $totalIssued = $allIssuedMatches.Count
        Write-Host "  Total issued certificates: $totalIssued (check manually for SubCA certs)" -ForegroundColor Gray
    } catch {
        Write-Host "  [WARN] Could not enumerate issued certificates" -ForegroundColor Yellow
    }
}

# -- Check 5: Certificate Services status ------------------------------------
Write-Host ""
Write-Host "[5/6] Checking Certificate Services status..." -ForegroundColor White

$certsvcStatus = "Unknown"
try {
    $svc = Get-Service -Name certsvc -ErrorAction Stop
    $certsvcStatus = $svc.Status.ToString()
    Write-Host "  certsvc status: $certsvcStatus" -ForegroundColor White

    if ($svc.Status -eq 'Running') {
        Write-Host "  The old Root CA is still running." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  When ready to decommission, stop and disable:" -ForegroundColor Gray
        Write-Host "    Stop-Service certsvc" -ForegroundColor Gray
        Write-Host "    Set-Service certsvc -StartupType Disabled" -ForegroundColor Gray
    } else {
        Write-Host "  Certificate Services is stopped." -ForegroundColor Green
    }
} catch {
    Write-Host "  certsvc not found on this machine." -ForegroundColor Gray
}

# -- Check 6: CRL status -----------------------------------------------------
Write-Host ""
Write-Host "[6/6] Checking CRL publication..." -ForegroundColor White

Write-Host "  After decommission, you MUST publish a final CRL with an" -ForegroundColor Gray
Write-Host "  extended validity period to cover all remaining certificates." -ForegroundColor Gray
Write-Host ""
Write-Host "  If any certificates issued by this root are still valid," -ForegroundColor Gray
Write-Host "  CRL must remain available until the last cert expires." -ForegroundColor Gray
Write-Host ""
Write-Host "  To publish a long-lived final CRL:" -ForegroundColor Gray
Write-Host "    certutil -setreg CA\\CRLPeriod Years" -ForegroundColor Gray
Write-Host "    certutil -setreg CA\\CRLPeriodUnits <years>" -ForegroundColor Gray
Write-Host "    certutil -CRL" -ForegroundColor Gray

# -- Readiness Assessment ----------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Decommission Readiness Assessment" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$ready = ($validCertCount -eq 0) -and ($pendingCount -eq 0) -and ($subCACount -eq 0)

if ($ready) {
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
    Write-Host "  |  READY TO DECOMMISSION                              |" -ForegroundColor Green
    Write-Host "  |                                                      |" -ForegroundColor Green
    Write-Host "  |  No valid certificates remain. No pending requests.  |" -ForegroundColor Green
    Write-Host "  |  No subordinate CAs. Safe to decommission services.  |" -ForegroundColor Green
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Decommission steps:" -ForegroundColor White
    Write-Host "    1. Publish a final long-lived CRL" -ForegroundColor Gray
    Write-Host "    2. Stop-Service certsvc" -ForegroundColor Gray
    Write-Host "    3. Set-Service certsvc -StartupType Disabled" -ForegroundColor Gray
    Write-Host "    4. Remove ADCS role (optional): Uninstall-AdcsCertificationAuthority" -ForegroundColor Gray
    Write-Host "    5. Keep the old root cert in trust stores (do NOT remove)" -ForegroundColor Gray
    Write-Host "    6. Archive CA database and key material" -ForegroundColor Gray
} else {
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Yellow
    Write-Host "  |  NOT YET READY TO DECOMMISSION                      |" -ForegroundColor Yellow
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Yellow
    Write-Host ""
    if ($validCertCount -gt 0) {
        Write-Host "  - $validCertCount valid certificate(s) still active." -ForegroundColor Yellow
        Write-Host "    Reissue from new CA or wait for expiration." -ForegroundColor Gray
    }
    if ($pendingCount -gt 0) {
        Write-Host "  - $pendingCount pending request(s) need resolution." -ForegroundColor Yellow
    }
    if ($subCACount -gt 0) {
        Write-Host "  - $subCACount subordinate CA(s) chain to this root." -ForegroundColor Yellow
        Write-Host "    Migrate or reissue SubCA certs under the new root." -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "  REMINDER: Do NOT revoke the old Root CA certificate." -ForegroundColor Red
    Write-Host "  Let certificates expire naturally." -ForegroundColor Red
}

# -- Save report --------------------------------------------------------------
$reportFile = Join-Path $OutputDir "decommission-readiness-report.txt"
$report = @"
Root CA Migration - Decommission Readiness Report
Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Server:    $env:COMPUTERNAME

CA Name:                     $activeCA
CA Subject:                  $caSubject
CA Expires:                  $notAfter
Days Remaining:              $daysRemaining
Valid Certificates:          $validCertCount
Certs Expiring in 90 Days:  $expiringCertCount
Pending Requests:            $pendingCount
Subordinate CAs:             $subCACount
Certificate Services:        $certsvcStatus
Readiness:                   $(if ($ready) { 'READY' } else { 'NOT READY' })

Recommendation: $(if ($ready) { 'Safe to decommission. Stop certsvc, publish final CRL, and archive.' } else { 'Wait for remaining certificates to expire or reissue from the new CA.' })

IMPORTANT: Do NOT revoke the old Root CA certificate. Root CA certs are
self-signed; revocation is meaningless. Keep the old root in trust stores
indefinitely so any remaining certificates continue to validate.
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
