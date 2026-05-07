<#
.SYNOPSIS
    Step 2: Validate new CA server prerequisites for Root CA migration.

.DESCRIPTION
    Checks that the new CA server is properly configured for HSM-backed ADCS
    Root CA deployment. Validates:
    - HSM SDK is installed (Cloud HSM or Dedicated HSM)
    - Key Storage Provider (KSP) is enumerated
    - ADCS role is installed
    - No existing CA is configured (or -AllowExisting is set)
    - Windows Server version and features
    - Network connectivity to HSM (optional)

    RUN ON: NEW ADCS Server (target for new Root CA)

.PARAMETER Platform
    HSM platform: AzureCloudHSM or AzureDedicatedHSM.
    If omitted, auto-detects based on which KSP is registered.

.PARAMETER AllowExisting
    Allow the script to pass even if a CA is already configured.
    Useful when re-running after a previous build (Step 3 with -OverwriteExisting).

.PARAMETER SkipNetworkCheck
    Skip the HSM network connectivity test.

.EXAMPLE
    .\Step2-ValidateNewCAServer.ps1

.EXAMPLE
    .\Step2-ValidateNewCAServer.ps1 -Platform AzureCloudHSM

.EXAMPLE
    .\Step2-ValidateNewCAServer.ps1 -AllowExisting
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('AzureCloudHSM', 'AzureDedicatedHSM')]
    [string]$Platform,

    [Parameter(Mandatory = $false)]
    [switch]$AllowExisting,

    [Parameter(Mandatory = $false)]
    [switch]$SkipNetworkCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Banner ------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Root CA Migration - Step 2: Validate New CA Server" -ForegroundColor Cyan
Write-Host "  Run on: NEW ADCS Server (target for new Root CA)" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$checks = @()
$allPassed = $true

function Add-CheckResult {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $script:checks += [PSCustomObject]@{
        Check  = $Name
        Status = if ($Passed) { "PASS" } else { "FAIL" }
        Detail = $Detail
    }
    if ($Passed) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        $script:allPassed = $false
    }
    if ($Detail) {
        Write-Host "         $Detail" -ForegroundColor Gray
    }
}

# -- Check 1: Windows Server version -----------------------------------------
Write-Host "[1/7] Checking Windows Server version..." -ForegroundColor White
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $isServer = $os.Caption -match 'Server'
    Add-CheckResult -Name "Windows Server OS" -Passed $isServer `
        -Detail "$($os.Caption) ($($os.Version))"
} catch {
    Add-CheckResult -Name "Windows Server OS" -Passed $false `
        -Detail "Failed to query OS: $($_.Exception.Message)"
}

# -- Check 2: ADCS role installed --------------------------------------------
Write-Host ""
Write-Host "[2/7] Checking ADCS role installation..." -ForegroundColor White
try {
    $adcsFeature = Get-WindowsFeature ADCS-Cert-Authority -EA SilentlyContinue
    $adcsInstalled = $adcsFeature -and $adcsFeature.Installed
    Add-CheckResult -Name "ADCS Cert Authority Role" -Passed $adcsInstalled `
        -Detail $(if ($adcsInstalled) { "Role is installed" } else { "Role NOT installed. Run: Install-WindowsFeature ADCS-Cert-Authority -IncludeManagementTools" })
} catch {
    Add-CheckResult -Name "ADCS Cert Authority Role" -Passed $false `
        -Detail "Failed to check ADCS role: $($_.Exception.Message)"
}

# -- Check 3: HSM KSP registered ---------------------------------------------
Write-Host ""
Write-Host "[3/7] Checking HSM Key Storage Provider..." -ForegroundColor White

$kspList = certutil -csplist 2>&1
$kspText = $kspList -join "`n"

$caviumFound = $kspText -match 'Cavium Key Storage Provider'
$safenetFound = $kspText -match 'SafeNet Key Storage Provider'

if (-not $Platform) {
    if ($caviumFound) { $Platform = 'AzureCloudHSM' }
    elseif ($safenetFound) { $Platform = 'AzureDedicatedHSM' }
}

$expectedKSP = switch ($Platform) {
    'AzureCloudHSM'     { 'Cavium Key Storage Provider' }
    'AzureDedicatedHSM' { 'SafeNet Key Storage Provider' }
    default             { $null }
}

if ($expectedKSP) {
    $kspFound = $kspText -match [regex]::Escape($expectedKSP)
    Add-CheckResult -Name "$expectedKSP Registered" -Passed $kspFound `
        -Detail $(if ($kspFound) { "$expectedKSP found in certutil -csplist" } else { "$expectedKSP NOT found. Install the HSM SDK first." })
} else {
    Add-CheckResult -Name "HSM KSP Registered" -Passed $false `
        -Detail "Neither Cavium nor SafeNet KSP found. Install HSM SDK before proceeding."
}

Write-Host "       Detected platform: $Platform" -ForegroundColor Gray

# -- Check 4: Cloud HSM environment variables (if Cloud HSM) -----------------
Write-Host ""
Write-Host "[4/7] Checking HSM credentials..." -ForegroundColor White

if ($Platform -eq 'AzureCloudHSM') {
    $hsmUser = [System.Environment]::GetEnvironmentVariable('azcloudhsm_username', 'Machine')
    $hsmPass = [System.Environment]::GetEnvironmentVariable('azcloudhsm_password', 'Machine')
    $credsOk = ($hsmUser -and $hsmPass)
    Add-CheckResult -Name "Cloud HSM Credentials" -Passed $credsOk `
        -Detail $(if ($credsOk) { "azcloudhsm_username=$hsmUser (password set)" } else { "Missing system environment variables: azcloudhsm_username / azcloudhsm_password" })
} elseif ($Platform -eq 'AzureDedicatedHSM') {
    # SafeNet uses cached slot credentials, check for Luna client
    $lunaPath = "C:\Program Files\SafeNet\LunaClient"
    $lunaExists = Test-Path $lunaPath
    Add-CheckResult -Name "SafeNet Luna Client" -Passed $lunaExists `
        -Detail $(if ($lunaExists) { "Luna client found at: $lunaPath" } else { "Luna client not found at expected path" })
} else {
    Add-CheckResult -Name "HSM Credentials" -Passed $false `
        -Detail "Platform not detected. Cannot check credentials."
}

# -- Check 5: Existing CA check ----------------------------------------------
Write-Host ""
Write-Host "[5/7] Checking for existing CA configuration..." -ForegroundColor White

try { $existingCA = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA Stop).Active } catch { $existingCA = $null }
if ($existingCA -and -not $AllowExisting) {
    Add-CheckResult -Name "No Existing CA" -Passed $false `
        -Detail "CA already configured: $existingCA. Use -AllowExisting to skip this check, or Step 3 with -OverwriteExisting."
} elseif ($existingCA -and $AllowExisting) {
    Add-CheckResult -Name "Existing CA (Allowed)" -Passed $true `
        -Detail "CA configured: $existingCA (-AllowExisting specified)"
} else {
    Add-CheckResult -Name "No Existing CA" -Passed $true `
        -Detail "No CA configured on this server. Ready for Step 3."
}

# -- Check 5b: Interactive mode (if CA exists) --------------------------------
if ($existingCA) {
    Write-Host ""
    Write-Host "[5b/7] Checking HSM Interactive mode..." -ForegroundColor White
    try {
        $interactiveReg = certutil -getreg CA\CSP\Interactive 2>&1
        $interactiveText = $interactiveReg -join "`n"
        $interactiveValue = -1
        if ($interactiveText -match 'Interactive REG_DWORD = (\d+)') {
            $interactiveValue = [int]$Matches[1]
        }
        $interactiveOk = ($interactiveValue -eq 0)
        Add-CheckResult -Name "HSM Interactive Mode" -Passed $interactiveOk `
            -Detail $(if ($interactiveOk) { "CA\CSP\Interactive = 0 (correct)" } else { "CA\CSP\Interactive = $interactiveValue -- MUST be 0. Fix: certutil -setreg CA\CSP\Interactive 0" })
    } catch {
        Add-CheckResult -Name "HSM Interactive Mode" -Passed $false `
            -Detail "Failed to read Interactive registry: $($_.Exception.Message)"
    }
}

# -- Check 6: Network connectivity to HSM ------------------------------------
Write-Host ""
Write-Host "[6/7] Checking HSM network connectivity..." -ForegroundColor White

if ($SkipNetworkCheck) {
    Write-Host "  [SKIP] Network check skipped per -SkipNetworkCheck" -ForegroundColor Yellow
} else {
    if ($Platform -eq 'AzureCloudHSM') {
        # Cloud HSM uses azcloudhsm_util for connectivity
        $utilPath = "C:\Program Files\Microsoft Azure Cloud HSM Client SDK\utils\azcloudhsm_util\azcloudhsm_util.exe"
        if (Test-Path $utilPath) {
            Add-CheckResult -Name "Cloud HSM SDK Utility" -Passed $true `
                -Detail "azcloudhsm_util found at expected path"
        } else {
            Add-CheckResult -Name "Cloud HSM SDK Utility" -Passed $false `
                -Detail "azcloudhsm_util not found. Install Azure Cloud HSM Client SDK."
        }
    } elseif ($Platform -eq 'AzureDedicatedHSM') {
        # Check vtl verify for Luna
        $vtlPath = "C:\Program Files\SafeNet\LunaClient\vtl.exe"
        if (Test-Path $vtlPath) {
            Add-CheckResult -Name "Luna VTL Utility" -Passed $true `
                -Detail "vtl.exe found at expected path"
        } else {
            Add-CheckResult -Name "Luna VTL Utility" -Passed $false `
                -Detail "vtl.exe not found. Check Luna client installation."
        }
    } else {
        Write-Host "  [SKIP] Platform not detected. Skipping network check." -ForegroundColor Yellow
    }
}

# -- Check 7: PowerShell version ---------------------------------------------
Write-Host ""
Write-Host "[7/7] Checking PowerShell version..." -ForegroundColor White

$psVer = $PSVersionTable.PSVersion
$psOk = ($psVer.Major -ge 5)
Add-CheckResult -Name "PowerShell Version" -Passed $psOk `
    -Detail "PowerShell $($psVer.ToString())"

# -- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Validation Summary" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

foreach ($c in $checks) {
    $color = if ($c.Status -eq "PASS") { "Green" } else { "Red" }
    Write-Host "  [$($c.Status)] $($c.Check)" -ForegroundColor $color
    if ($c.Detail) {
        Write-Host "         $($c.Detail)" -ForegroundColor Gray
    }
}

$passCount = @($checks | Where-Object { $_.Status -eq "PASS" }).Count
$failCount = @($checks | Where-Object { $_.Status -eq "FAIL" }).Count
Write-Host ""
Write-Host "  Result: $passCount PASS, $failCount FAIL" -ForegroundColor $(if ($allPassed) { "Green" } else { "Red" })
Write-Host ""

if ($allPassed) {
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "  Step 2 Complete: Server prerequisites validated" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Platform: $Platform" -ForegroundColor White
    Write-Host ""
    Write-Host "  NEXT: Run Step3-BuildNewCA.ps1 on this server" -ForegroundColor Yellow
    Write-Host "        to create the new self-signed Root CA." -ForegroundColor Yellow
    Write-Host ""
} else {
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host "  Step 2 INCOMPLETE: Fix failures before proceeding" -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host ""
    exit 1
}
