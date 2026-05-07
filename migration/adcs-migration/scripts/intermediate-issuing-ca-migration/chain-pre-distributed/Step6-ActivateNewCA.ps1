<#
.SYNOPSIS
    Step 6: Activate the new issuing CA on the Azure Cloud HSM ADCS server.

.DESCRIPTION
    Installs the signed issuing CA certificate, verifies private key binding
    to the Cloud HSM, starts Certificate Services, and validates CRL publication.

    RUN ON: NEW ADCS Server (Azure Cloud HSM)

.PARAMETER SignedCertPath
    Path to the signed issuing CA certificate file (e.g., NewIssuingCA.cer).

.EXAMPLE
    .\Step6-ActivateNewCA.ps1 -SignedCertPath "C:\Migration\NewIssuingCA.cer"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SignedCertPath,

    [Parameter(Mandatory = $false)]
    [switch]$SkipConfirmation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Banner ------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ADCS Migration - Step 6: Activate New Issuing CA" -ForegroundColor Cyan
Write-Host "  Run on: NEW ADCS Server (Azure Cloud HSM)" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# -- Validate input ----------------------------------------------------------
if (-not (Test-Path $SignedCertPath)) {
    Write-Host "[ERROR] Signed certificate not found at: $SignedCertPath" -ForegroundColor Red
    exit 1
}

# -- Confirmation ------------------------------------------------------------
Write-Host "  IMPORTANT: Ensure Step 5 (Pre-Distribution) is COMPLETE" -ForegroundColor Red
Write-Host "  before activating this CA. Activating before distribution" -ForegroundColor Red
Write-Host "  will cause trust failures." -ForegroundColor Red
Write-Host ""

if ($SkipConfirmation) {
    Write-Host "  [INFO] -SkipConfirmation specified, proceeding..." -ForegroundColor Gray
} else {
    $confirm = Read-Host "  Have all relying parties received the new ICA cert? (yes/no)"
    if ($confirm -ne 'yes') {
        Write-Host ""
        Write-Host "  Aborted. Complete Step 5 pre-distribution first." -ForegroundColor Yellow
        exit 0
    }
}

$checks = @()
$allPassed = $true

function Add-CheckResult {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $script:checks += [PSCustomObject]@{
        Check  = $Name
        Status = if ($Passed) { "PASS" } else { "FAIL" }
        Detail = $Detail
    }
    if (-not $Passed) { $script:allPassed = $false }
    $color = if ($Passed) { "Green" } else { "Red" }
    $icon  = if ($Passed) { "[PASS]" } else { "[FAIL]" }
    Write-Host "  $icon $Name" -ForegroundColor $color
    if ($Detail) {
        Write-Host "        $Detail" -ForegroundColor Gray
    }
}

# -- Pre-check: Verify parent CA cert is in Trusted Root store ----------------
Write-Host ""
Write-Host "[PRE] Verifying parent CA cert in Trusted Root store..." -ForegroundColor White

$signedCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($SignedCertPath)
$issuerCN = ($signedCert.Issuer -replace '.*CN=', '') -replace ',.*', ''
$rootStore = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','LocalMachine')
$rootStore.Open('ReadOnly')
$issuerInStore = $rootStore.Certificates | Where-Object { $_.Subject -match [regex]::Escape($issuerCN) }
$rootStore.Close()

if (-not $issuerInStore) {
    Write-Host "  [WARN] Issuer '$issuerCN' NOT found in Trusted Root store." -ForegroundColor Yellow
    Write-Host "         Attempting self-heal: searching for parent CA cert locally..." -ForegroundColor Yellow

    # Try to find parent CA cert in common locations
    $parentCertFile = $null
    $searchPaths = @(
        "C:\CertEnroll\*$issuerCN*.crt",
        "C:\CertEnroll\*$issuerCN*.cer",
        "C:\temp\migration-certs\*$issuerCN*.cer",
        "C:\temp\migration-certs\*Root*.cer",
        "C:\temp\migration-crl-export\RootCA.cer"
    )
    foreach ($pattern in $searchPaths) {
        $found = Get-ChildItem $pattern -EA SilentlyContinue | Select-Object -First 1
        if ($found) {
            # Verify this cert matches the issuer
            $candidateCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($found.FullName)
            if ($candidateCert.Subject -match [regex]::Escape($issuerCN)) {
                $parentCertFile = $found.FullName
                Write-Host "         Found parent cert: $parentCertFile" -ForegroundColor Yellow
                break
            }
        }
    }

    if ($parentCertFile) {
        Write-Host "         Installing parent cert into Trusted Root store..." -ForegroundColor Yellow
        $addOutput = certutil -addstore Root $parentCertFile 2>&1
        $addText = ($addOutput | Out-String)
        if ($addText -match 'added to store' -or $addText -match 'completed successfully') {
            Write-Host "         [PASS] Parent CA cert installed via self-heal." -ForegroundColor Green
            # Re-check
            $rootStore.Open('ReadOnly')
            $issuerInStore = $rootStore.Certificates | Where-Object { $_.Subject -match [regex]::Escape($issuerCN) }
            $rootStore.Close()
        }
    }

    if (-not $issuerInStore) {
        Write-Host "  [ERROR] Issuer '$issuerCN' NOT found and self-heal failed." -ForegroundColor Red
        Write-Host "          certutil -installcert will fail with CERT_E_CHAINING." -ForegroundColor Red
        Write-Host "          Manually run: certutil -addstore Root <parent-ca-cert.cer>" -ForegroundColor Red
        Add-CheckResult -Name "Parent CA in Trust Store" -Passed $false `
            -Detail "Issuer '$issuerCN' not in LocalMachine\Root - self-heal attempted but failed"
        exit 1
    } else {
        Add-CheckResult -Name "Parent CA in Trust Store" -Passed $true `
            -Detail "Found '$issuerCN' in Trusted Root store via self-heal (Thumb: $($issuerInStore[0].Thumbprint))"
    }
} else {
    Add-CheckResult -Name "Parent CA in Trust Store" -Passed $true `
        -Detail "Found '$issuerCN' in Trusted Root store (Thumb: $($issuerInStore[0].Thumbprint))"
}

# -- Step 1: Install the signed certificate ----------------------------------
Write-Host ""
Write-Host "[1/7] Installing signed CA certificate..." -ForegroundColor White

# FINDING 19: certutil -installcert hangs indefinitely under SYSTEM with the
# Cavium Key Storage Provider (Azure Cloud HSM). The KSP requires an interactive
# Windows logon session for key retrieval/verification. This script must be run
# from an interactive session (e.g. RDP), not via az vm run-command.
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

$installOutput = certutil -f -installcert $SignedCertPath 2>&1
$installText = ($installOutput | Out-String)
$installSuccess = $installText -match 'completed successfully'

Add-CheckResult -Name "Install CA Certificate" -Passed $installSuccess `
    -Detail $(if ($installSuccess) { "certutil -installcert succeeded" } else { $installText.Trim() })

if (-not $installSuccess) {
    Write-Host ""
    Write-Host "  Installation failed. Common causes:" -ForegroundColor Red
    Write-Host "    - Private key not found (CSR was not generated on this server)" -ForegroundColor Yellow
    Write-Host "    - Certificate does not match pending request" -ForegroundColor Yellow
    Write-Host "    - CA service is running (stop certsvc first)" -ForegroundColor Yellow
    Write-Host "    - Parent CA cert not in Trusted Root store (CERT_E_CHAINING)" -ForegroundColor Yellow
    Write-Host ""
    $installOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    exit 1
}

# -- Step 2: Verify private key binding --------------------------------------
Write-Host ""
Write-Host "[2/7] Verifying private key binding to Cloud HSM..." -ForegroundColor White

$verifyKeysOutput = certutil -verifykeys 2>&1
$verifyKeysText = $verifyKeysOutput -join "`n"

$keysBound = ($verifyKeysText -match 'completed successfully') -or ($verifyKeysText -match 'PASS' -or $verifyKeysText -match 'Signature test passed')
Add-CheckResult -Name "Private Key Binding" -Passed $keysBound `
    -Detail $(if ($keysBound) { "Private key verified in HSM" } else { "Key verification failed - check Cloud HSM connectivity" })

# -- Step 3: Verify CSP is Cavium --------------------------------------------
Write-Host ""
Write-Host "[3/7] Verifying CSP provider is Cavium KSP..." -ForegroundColor White

$cspOutput = certutil -getreg CA\CSP 2>&1
$cspText = $cspOutput -join "`n"
$isCavium = $cspText -match 'Cavium'

Add-CheckResult -Name "CSP is Cavium KSP" -Passed $isCavium `
    -Detail $(if ($isCavium) { "CA is configured with Cavium Key Storage Provider" } else { "CA is NOT using Cavium KSP - check configuration" })

# -- Step 4: Enforce Interactive=0 (non-interactive HSM key access) -----------
Write-Host ""
Write-Host "[4/7] Enforcing non-interactive HSM key access (Interactive=0)..." -ForegroundColor White

# Interactive=1 causes the Cavium KSP to pop a GUI dialog during every signing
# operation. This HANGS certsvc (runs as SYSTEM in session 0 with no desktop)
# and any headless session (az vm run-command, scheduled tasks, etc.).
# The Cavium KSP authenticates via azcloudhsm_username/azcloudhsm_password
# environment variables and does NOT need interactive prompts.
$interactiveOutput = certutil -getreg CA\CSP\Interactive 2>&1
$interactiveText = $interactiveOutput -join "`n"
$currentInteractive = -1
if ($interactiveText -match 'Interactive REG_DWORD = (\d+)') {
    $currentInteractive = [int]$Matches[1]
}

if ($currentInteractive -eq 0) {
    Add-CheckResult -Name "HSM Interactive Mode" -Passed $true `
        -Detail "CA\CSP\Interactive = 0 (correct - no GUI prompts)"
} else {
    Write-Host "  [WARN] CA\CSP\Interactive = $currentInteractive (should be 0)" -ForegroundColor Yellow
    Write-Host "         Interactive=1 causes GUI prompts that HANG certsvc and headless sessions." -ForegroundColor Yellow
    Write-Host "         Fixing to Interactive=0..." -ForegroundColor Yellow
    $setOutput = certutil -setreg CA\CSP\Interactive 0 2>&1
    $setText = ($setOutput | Out-String)
    $setOk = $setText -match 'HKEY_LOCAL_MACHINE' -or $setText -match 'completed successfully' -or $setText -match 'Interactive'
    Add-CheckResult -Name "HSM Interactive Mode" -Passed $setOk `
        -Detail $(if ($setOk) { "Fixed: CA\CSP\Interactive set to 0 (Cavium KSP uses env var credentials)" } else { "FAILED to set Interactive=0 - fix manually: certutil -setreg CA\CSP\Interactive 0" })
}

# -- Step 5: Set CRL revocation check to tolerate offline parent CRL ----------
Write-Host ""
Write-Host "[5/7] Setting CRLF_REVCHECK_IGNORE_OFFLINE (parent CRL may be unreachable)..." -ForegroundColor White

# The ICA cert's CRL DP points to the parent CA hostname (e.g., file:///dhsm-adcs-vm/CertEnroll/...).
# In migration scenarios the parent may be unreachable from the new VM's network.
# Without this flag, certsvc refuses to start: CRYPT_E_REVOCATION_OFFLINE.
$crlFlagsOutput = certutil -setreg CA\CRLFlags +CRLF_REVCHECK_IGNORE_OFFLINE 2>&1
$crlFlagsText = ($crlFlagsOutput | Out-String)
$crlFlagsOk = $crlFlagsText -match 'CRLF_REVCHECK_IGNORE_OFFLINE' -or $crlFlagsText -match 'completed successfully'
Add-CheckResult -Name "CRL Revocation Offline Tolerance" -Passed $crlFlagsOk `
    -Detail $(if ($crlFlagsOk) { "CRLF_REVCHECK_IGNORE_OFFLINE set - certsvc will start even if parent CRL unreachable" } else { "Failed to set CRLFlags - certsvc may fail to start" })

# -- Step 6: Start Certificate Services --------------------------------------
Write-Host ""
Write-Host "[6/7] Starting Certificate Services (certsvc)..." -ForegroundColor White

try {
    $svc = Get-Service -Name certsvc -ErrorAction Stop
    if ($svc.Status -eq 'Running') {
        Write-Host "       certsvc is already running. Restarting to apply new cert..." -ForegroundColor Gray
        Restart-Service certsvc -Force -ErrorAction Stop
        Start-Sleep -Seconds 5
    } else {
        Start-Service certsvc -ErrorAction Stop
        Start-Sleep -Seconds 5
    }
    $svc = Get-Service -Name certsvc -ErrorAction Stop
    Add-CheckResult -Name "Certificate Services" -Passed ($svc.Status -eq 'Running') `
        -Detail "certsvc status: $($svc.Status)"
} catch {
    Add-CheckResult -Name "Certificate Services" -Passed $false `
        -Detail "Failed to start certsvc: $($_.Exception.Message)"
}

# -- Step 7: Validate CRL publication ----------------------------------------
Write-Host ""
Write-Host "[7/7] Validating CRL publication..." -ForegroundColor White

$crlOutput = certutil -CRL 2>&1
$crlText = ($crlOutput | Out-String)
$crlSuccess = $crlText -match 'completed successfully'

Add-CheckResult -Name "CRL Publication" -Passed $crlSuccess `
    -Detail $(if ($crlSuccess) { "CRL published successfully" } else { "CRL publication failed - check CDP/AIA configuration" })

# -- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor $(if ($allPassed) { "Green" } else { "Red" })
$statusMsg = if ($allPassed) { "  Step 6 Complete: New CA is ACTIVE" } else { "  Step 6: Activation had issues - review results" }
Write-Host $statusMsg -ForegroundColor $(if ($allPassed) { "Green" } else { "Red" })
Write-Host "============================================================" -ForegroundColor $(if ($allPassed) { "Green" } else { "Red" })
Write-Host ""

foreach ($c in $checks) {
    $color = if ($c.Status -eq "PASS") { "Green" } else { "Red" }
    Write-Host "    $($c.Status)  $($c.Check)" -ForegroundColor $color
}

Write-Host ""
if ($allPassed) {
    Write-Host "  The new issuing CA is now ACTIVE and ready to issue certificates." -ForegroundColor Green
    Write-Host ""
    Write-Host "  NEXT: Run Step7-ValidateIssuance.ps1 on THIS server to test" -ForegroundColor Yellow
    Write-Host "        certificate issuance and chain validation." -ForegroundColor Yellow
} else {
    Write-Host "  ACTION: Resolve failed checks before issuing certificates." -ForegroundColor Red
}
Write-Host ""
