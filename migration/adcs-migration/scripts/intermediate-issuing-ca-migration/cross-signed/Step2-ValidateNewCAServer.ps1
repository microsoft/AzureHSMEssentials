<#
.SYNOPSIS
    Step 2: Validate new CA server prerequisites (Azure Cloud HSM).

.DESCRIPTION
    Checks that the new CA server is properly configured for Azure Cloud HSM
    ADCS integration before CSR generation. Validates:
    - Azure Cloud HSM SDK is installed
    - Cavium Key Storage Provider (KSP) is enumerated
    - ADCS role is NOT yet installed (must install SDK first)
    - Network connectivity to Cloud HSM
    - Windows Server version and features

    RUN ON: NEW ADCS Server (Azure Cloud HSM)

.PARAMETER SkipNetworkCheck
    Skip the Cloud HSM network connectivity test.

.EXAMPLE
    .\Step2-ValidateNewCAServer.ps1

.EXAMPLE
    .\Step2-ValidateNewCAServer.ps1 -SkipNetworkCheck
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$SkipNetworkCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Banner ------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ICA Migration (Cross-Signed) - Step 2: Validate New Server" -ForegroundColor Cyan
Write-Host "  Run on: NEW ADCS Server (Azure Cloud HSM)" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$checks = @()
$allPassed = $true

# -- Helper ------------------------------------------------------------------
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

# -- Check 1: Windows Server OS ----------------------------------------------
Write-Host "[1/7] Checking Windows Server version..." -ForegroundColor White
$os = Get-CimInstance Win32_OperatingSystem
$isServer = $os.ProductType -ne 1  # 1 = Workstation, 2 = DC, 3 = Server
Add-CheckResult -Name "Windows Server OS" `
    -Passed $isServer `
    -Detail "$($os.Caption) ($($os.Version))"

# -- Check 2: Cavium KSP installed -------------------------------------------
Write-Host ""
Write-Host "[2/7] Checking for Cavium Key Storage Provider..." -ForegroundColor White

$kspFound = $false
$kspDetail = ""

# Check via certutil -csplist
$cspList = certutil -csplist 2>&1
$cspText = $cspList -join "`n"
if ($cspText -match 'Cavium') {
    $kspFound = $true
    $kspDetail = "Cavium KSP found in certutil -csplist"
} else {
    # Check registry
    $kspRegPath = "HKLM:\SOFTWARE\Microsoft\Cryptography\Providers"
    if (Test-Path $kspRegPath) {
        $providers = Get-ChildItem $kspRegPath -ErrorAction SilentlyContinue
        foreach ($p in $providers) {
            if ($p.PSChildName -match 'Cavium') {
                $kspFound = $true
                $kspDetail = "Cavium KSP found in registry: $($p.PSChildName)"
                break
            }
        }
    }
    if (-not $kspFound) {
        $kspDetail = "Cavium Key Storage Provider not found. Install Azure Cloud HSM SDK first."
    }
}

Add-CheckResult -Name "Cavium KSP Installed" -Passed $kspFound -Detail $kspDetail

# -- Check 3: Cloud HSM SDK files --------------------------------------------
Write-Host ""
Write-Host "[3/7] Checking for Azure Cloud HSM SDK installation..." -ForegroundColor White

$sdkPaths = @(
    "C:\Program Files\Microsoft Azure Cloud HSM Client SDK",
    "C:\Program Files\Cavium",
    "C:\Program Files\Amazon\CloudHSM",
    "C:\ProgramData\Cavium"
)
$sdkFound = $false
$sdkPath = ""
foreach ($path in $sdkPaths) {
    if (Test-Path $path) {
        $sdkFound = $true
        $sdkPath = $path
        break
    }
}

Add-CheckResult -Name "Cloud HSM SDK Files" `
    -Passed $sdkFound `
    -Detail $(if ($sdkFound) { "Found at: $sdkPath" } else { "SDK not found in expected locations. Install Azure Cloud HSM SDK." })

# -- Check 4: ADCS role status -----------------------------------------------
Write-Host ""
Write-Host "[4/7] Checking ADCS role installation status..." -ForegroundColor White

$adcsInstalled = $false
$adcsDetail = ""
$caConfigured = $false
try {
    $adcsFeature = Get-WindowsFeature -Name ADCS-Cert-Authority -ErrorAction Stop
    $adcsInstalled = $adcsFeature.Installed
    if ($adcsInstalled) {
        # ADCS is installed - check if it was configured with Cavium KSP
        $caConfigured = $false
        try {
            $cspReg = certutil -getreg CA\CSP 2>&1
            $cspRegText = $cspReg -join "`n"
            if ($cspRegText -match 'Cavium') {
                $caConfigured = $true
                $adcsDetail = "ADCS role installed and configured with Cavium KSP"
            } else {
                $adcsDetail = "ADCS role installed but NOT configured with Cavium KSP. May need to remove/reinstall ADCS role after SDK install."
            }
        } catch {
            $adcsDetail = "ADCS role installed but CA not yet configured"
        }
    } else {
        $adcsDetail = "ADCS role not yet installed (correct - install SDK first, then ADCS)"
    }
} catch {
    $adcsDetail = "Could not check ADCS role (may not be a Windows Server)"
}

# For this check: PASS if ADCS is not installed (correct order) or if it's installed (SDK present)
$adcsCheckPassed = (-not $adcsInstalled) -or $kspFound
Add-CheckResult -Name "ADCS Role Status" -Passed $adcsCheckPassed -Detail $adcsDetail

# -- Check 4b: If CA is configured WITH Cavium KSP, verify Interactive=0 -----
if ($adcsInstalled -and $caConfigured) {
    Write-Host ""
    Write-Host "[4b/7] Checking HSM Interactive mode (CA\CSP\Interactive)..." -ForegroundColor White
    try {
        $interactiveReg = certutil -getreg CA\CSP\Interactive 2>&1
        $interactiveText = $interactiveReg -join "`n"
        $interactiveValue = -1
        if ($interactiveText -match 'Interactive REG_DWORD = (\d+)') {
            $interactiveValue = [int]$Matches[1]
        }
        $interactiveOk = ($interactiveValue -eq 0)
        Add-CheckResult -Name "HSM Interactive Mode" -Passed $interactiveOk `
            -Detail $(if ($interactiveOk) { "CA\CSP\Interactive = 0 (correct)" } else { "CA\CSP\Interactive = $interactiveValue -- MUST be 0. Interactive=1 causes GUI prompts that hang certsvc and headless sessions. Fix: certutil -setreg CA\CSP\Interactive 0" })
    } catch {
        Add-CheckResult -Name "HSM Interactive Mode" -Passed $false `
            -Detail "Could not read CA\CSP\Interactive: $($_.Exception.Message)"
    }
}

# -- Check 5: ADCS role NOT installed before SDK -----------------------------
Write-Host ""
Write-Host "[5/7] Checking installation order (SDK before ADCS)..." -ForegroundColor White

if ($adcsInstalled -and -not $kspFound) {
    Add-CheckResult -Name "Installation Order" `
        -Passed $false `
        -Detail "CRITICAL: ADCS is installed but Cavium KSP is NOT present. Remove ADCS role, install SDK, then reinstall ADCS."
} elseif ($adcsInstalled -and $kspFound) {
    Add-CheckResult -Name "Installation Order" `
        -Passed $true `
        -Detail "Both ADCS and Cavium KSP are present"
} elseif (-not $adcsInstalled -and $kspFound) {
    Add-CheckResult -Name "Installation Order" `
        -Passed $true `
        -Detail "SDK installed, ADCS not yet installed (correct order)"
} else {
    Add-CheckResult -Name "Installation Order" `
        -Passed $false `
        -Detail "Neither ADCS nor Cloud HSM SDK is installed. Install SDK first, then ADCS."
}

# -- Check 6: certreq available ----------------------------------------------
Write-Host ""
Write-Host "[6/7] Checking certreq availability..." -ForegroundColor White

$certreqAvailable = $null -ne (Get-Command certreq -ErrorAction SilentlyContinue)
Add-CheckResult -Name "certreq Available" -Passed $certreqAvailable -Detail $(if ($certreqAvailable) { "certreq.exe found" } else { "certreq.exe not found in PATH" })

# -- Check 7: Network connectivity -------------------------------------------
Write-Host ""
Write-Host "[7/7] Checking Cloud HSM network connectivity..." -ForegroundColor White

if ($SkipNetworkCheck) {
    Add-CheckResult -Name "Network Connectivity" -Passed $true -Detail "Skipped (use -SkipNetworkCheck:`$false to enable)"
} else {
    $networkOk = $false
    $networkDetail = ""

    $configPaths = @(
        "C:\ProgramData\Cavium\config\cloudhsm_client.cfg",
        "C:\ProgramData\Amazon\CloudHSM\data\cloudhsm_client.cfg"
    )

    $clusterIp = $null
    foreach ($cfg in $configPaths) {
        if (Test-Path $cfg) {
            $content = Get-Content $cfg -Raw
            if ($content -match '"hostname"\s*:\s*"([^"]+)"') {
                $clusterIp = $Matches[1]
                break
            }
        }
    }

    if ($clusterIp) {
        $pingResult = Test-Connection -ComputerName $clusterIp -Count 1 -Quiet -ErrorAction SilentlyContinue
        $networkOk = $pingResult
        $networkDetail = if ($networkOk) { "Cluster IP $clusterIp is reachable" } else { "Cluster IP $clusterIp is NOT reachable" }
    } else {
        $networkDetail = "Could not determine cluster IP from config files. Verify Cloud HSM connectivity manually."
        $networkOk = $true  # Don't fail on this - it's informational
    }

    Add-CheckResult -Name "Network Connectivity" -Passed $networkOk -Detail $networkDetail
}

# -- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor $(if ($allPassed) { "Green" } else { "Red" })
$statusMsg = if ($allPassed) { "  Step 2 Complete: All prerequisite checks passed" } else { "  Step 2: Some checks FAILED - resolve before continuing" }
Write-Host $statusMsg -ForegroundColor $(if ($allPassed) { "Green" } else { "Red" })
Write-Host "============================================================" -ForegroundColor $(if ($allPassed) { "Green" } else { "Red" })
Write-Host ""

# Display results table
Write-Host "  Check Results:" -ForegroundColor White
foreach ($c in $checks) {
    $color = if ($c.Status -eq "PASS") { "Green" } else { "Red" }
    Write-Host "    $($c.Status)  $($c.Check)" -ForegroundColor $color
}

Write-Host ""
if ($allPassed) {
    Write-Host "  NEXT: Run Step3-GenerateCSR.ps1 on THIS server (NEW ADCS)" -ForegroundColor Yellow
    Write-Host "        with the ca-migration-details.json from Step 1." -ForegroundColor Yellow
} else {
    Write-Host "  ACTION: Resolve failed checks before proceeding to Step 3." -ForegroundColor Red
}
Write-Host ""
