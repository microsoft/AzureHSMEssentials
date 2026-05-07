<#
.SYNOPSIS
    Master CA Migration Orchestrator -- Runs all 8 steps end-to-end with zero interaction.

.DESCRIPTION
    Single entry point for ADCS CA migration. Reads a JSON parameters file,
    determines the correct script path (Scenario + Option), generates any
    required wrappers for scripts with mandatory parameters, handles all
    inter-VM certificate transfers, tracks timing for each step, and
    produces a structured summary report.

    Supports all combinations:
      - Scenario A: Root CA + Option 1 (Pre-Distributed)
      - Scenario A: Root CA + Option 2 (Cross-Signed)
      - Scenario B: Intermediate/Issuing CA + Option 1 (Pre-Distributed)
      - Scenario B: Intermediate/Issuing CA + Option 2 (Cross-Signed)

    ZERO user interaction required. Once started, runs to completion.

.PARAMETER ParamsFile
    Path to the JSON parameters file (see migration-params.template.json).

.PARAMETER ResetFirst
    Run Reset-MigrationEnvironment.ps1 before starting migration.

.PARAMETER ResetOnly
    Only run the reset (do not execute migration steps).

.PARAMETER OutputDir
    Directory for the migration report and logs. Defaults to C:\temp\migration-<timestamp>.

.EXAMPLE
    .\Invoke-CaMigration.ps1 -ParamsFile .\migration-params.hsb-rootca-predist.json

.EXAMPLE
    .\Invoke-CaMigration.ps1 -ParamsFile .\migration-params.hsb-rootca-crosssigned.json -ResetFirst

.EXAMPLE
    .\Invoke-CaMigration.ps1 -ParamsFile .\migration-params.hsb-rootca-predist.json -ResetOnly
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ParamsFile,

    [Parameter(Mandatory = $false)]
    [switch]$ResetFirst,

    [Parameter(Mandatory = $false)]
    [switch]$ResetOnly,

    [Parameter(Mandatory = $false)]
    [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region -- Helpers -------------------------------------------------------------

function Wait-VmReady {
    <#
    .SYNOPSIS
        Pre-flight check (M3): Ensures the VM provisioning state is "Succeeded"
        before issuing an az vm run-command. If the VM is wedged in "Updating",
        performs a deallocate + start cycle to clear the ARM lock.
    #>
    param(
        [string]$ResourceGroup,
        [string]$VMName
    )

    $state = az vm show -g $ResourceGroup -n $VMName --query "provisioningState" -o tsv 2>&1
    if ($state -eq 'Succeeded') { return }

    # Check if VM is actually running despite non-Succeeded provisioning state
    $jmesQuery = 'instanceView.statuses[?starts_with(code,`PowerState/`)].displayStatus | [0]'
    $power = az vm get-instance-view -g $ResourceGroup -n $VMName --query $jmesQuery -o tsv 2>&1
    if ($power -match 'running') {
        Write-Host "  [M3] VM $VMName provisioning='$state' but power='$power' - skipping deallocate, testing run-command..." -ForegroundColor Yellow
        $testResult = az vm run-command invoke -g $ResourceGroup -n $VMName `
            --command-id RunPowerShellScript --scripts "Write-Output 'M3-OK'" -o tsv 2>&1
        if ($testResult -match 'M3-OK') {
            Write-Host "  [M3] Run-command works despite '$state' - proceeding" -ForegroundColor Green
            return
        }
        Write-Host "  [M3] Run-command failed - falling through to deallocate cycle" -ForegroundColor Yellow
    }

    Write-Host "  [M3] VM $VMName provisioning state is '$state' - clearing ARM wedge..." -ForegroundColor Yellow
    Write-Host "  [M3] Deallocating $VMName..." -ForegroundColor Yellow
    az vm deallocate -g $ResourceGroup -n $VMName --no-wait 2>&1 | Out-Null
    # Wait for deallocate to complete (power state = deallocated)
    $maxWait = 180  # seconds
    $waited = 0
    while ($waited -lt $maxWait) {
        Start-Sleep -Seconds 10
        $waited += 10
        $jmesQuery = 'instanceView.statuses[?starts_with(code,`PowerState/`)].displayStatus | [0]'
        $power = az vm get-instance-view -g $ResourceGroup -n $VMName --query $jmesQuery -o tsv 2>&1
        if ($power -match 'deallocated') { break }
        Write-Host "  [M3] Waiting for deallocate... ${waited}s, power=$power" -ForegroundColor Yellow
    }

    Write-Host "  [M3] Starting $VMName..." -ForegroundColor Yellow
    az vm start -g $ResourceGroup -n $VMName 2>&1 | Out-Null

    # Wait for provisioning state to return to Succeeded
    $waited = 0
    while ($waited -lt $maxWait) {
        Start-Sleep -Seconds 10
        $waited += 10
        $state = az vm show -g $ResourceGroup -n $VMName --query "provisioningState" -o tsv 2>&1
        if ($state -eq 'Succeeded') {
            Write-Host "  [M3] VM $VMName recovered - provisioningState=Succeeded after ${waited}s" -ForegroundColor Green
            return
        }
        Write-Host "  [M3] Waiting for Succeeded... ${waited}s, state=$state" -ForegroundColor Yellow
    }

    Write-Host "  [M3] WARNING: VM $VMName still not Succeeded after ${maxWait}s - proceeding anyway" -ForegroundColor Red
}

function Write-StepBanner {
    param([int]$StepNum, [string]$Name, [string]$VM, [string]$Role)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host "  Step $StepNum : $Name" -ForegroundColor Cyan
    Write-Host "  VM: $VM ($Role)" -ForegroundColor Yellow
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Invoke-RemoteScript {
    <#
    .SYNOPSIS
        Runs a PowerShell script on an Azure VM via az vm run-command invoke.
        Returns a PSCustomObject with .Success, .Message, .Duration.
    #>
    param(
        [string]$ResourceGroup,
        [string]$VMName,
        [string]$ScriptPath,
        [string]$InlineScript
    )

    # M3: Pre-flight check -- clear ARM wedge before attempting run-command
    Wait-VmReady -ResourceGroup $ResourceGroup -VMName $VMName

    $start = Get-Date
    $tempScriptPath = $null
    $maxRetries = 12          # up to ~2 minutes of retries for Conflict
    $retryDelaySec = 10

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        if ($ScriptPath) {
            $raw = az vm run-command invoke `
                -g $ResourceGroup -n $VMName `
                --command-id RunPowerShellScript `
                --scripts "@$ScriptPath" `
                --output json 2>&1
        }
        else {
            # Save inline script to temp file to avoid az cli multi-line quoting issues on Windows
            $tempScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) "inline-$([guid]::NewGuid().ToString('N').Substring(0,8)).ps1"
            $InlineScript | Set-Content -Path $tempScriptPath -Encoding UTF8
            $raw = az vm run-command invoke `
                -g $ResourceGroup -n $VMName `
                --command-id RunPowerShellScript `
                --scripts "@$tempScriptPath" `
                --output json 2>&1
            Remove-Item $tempScriptPath -ErrorAction SilentlyContinue
        }

        $rawText = ($raw -join "`n")
        if ($rawText -match 'Conflict.*Run command extension execution is in progress') {
            Write-Host "  [RETRY] VM run-command busy, waiting ${retryDelaySec}s (attempt $attempt/$maxRetries)..." -ForegroundColor Yellow
            Start-Sleep -Seconds $retryDelaySec
            continue
        }
        break   # not a Conflict -- proceed to parse
    }

    $end = Get-Date
    $duration = $end - $start

    # Parse JSON to get message
    $message = ""
    $stderr  = ""
    $success = $false
    try {
        $json = $rawText | ConvertFrom-Json
        $message = $json.value[0].message
        if ($json.value.Count -gt 1) { $stderr = $json.value[1].message }
        # Determine success: no [ERROR] or [FAIL] in output, no STDERR errors, and az exit code 0
        $stderrFail = $stderr -and ($stderr -match 'cannot be retrieved|FullyQualifiedErrorId|TerminatingError|Exception')
        $success = ($message -notmatch '\[ERROR\]|\[FAIL\]') -and (-not $stderrFail) -and ($LASTEXITCODE -eq 0)
    }
    catch {
        $message = $rawText
        $success = $false
    }

    [PSCustomObject]@{
        Success  = $success
        Message  = $message
        StdErr   = $stderr
        Duration = $duration
        RawJson  = $rawText
    }
}

function New-Wrapper {
    <#
    .SYNOPSIS
        Creates a wrapper script by stripping the param block and injecting hardcoded values.
        Unspecified optional params are initialized to safe defaults so Set-StrictMode won't error.
    #>
    param(
        [string]$SourceScript,
        [hashtable]$Params,
        [string]$WrapperPath
    )

    $lines = Get-Content $SourceScript
    $helpEnd   = -1
    $paramStart = -1
    $paramEnd  = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^#>') { $helpEnd = $i }
        if ($lines[$i] -match '^\[CmdletBinding') { $paramStart = $i }
        if ($paramStart -ge 0 -and $paramEnd -lt 0 -and $lines[$i] -match '^\)') { $paramEnd = $i }
    }

    if ($paramEnd -lt 0) {
        throw "Could not find param block end in $SourceScript"
    }

    # Parse param block to find all parameter names and their defaults (for StrictMode safety)
    $paramDefaults = @{}
    for ($i = $paramStart; $i -le $paramEnd; $i++) {
        if ($lines[$i] -match '\$(\w+)\s*=\s*(.+)$') {
            $pName = $Matches[1]
            $pDefault = $Matches[2].Trim().TrimEnd(',').Trim()
            $paramDefaults[$pName] = $pDefault
        }
        elseif ($lines[$i] -match '\$(\w+)\s*[,\)]?\s*$' -or $lines[$i] -match '\]\s*\$(\w+)') {
            $paramDefaults[$Matches[1]] = $null
        }
    }
    $paramNames = @($paramDefaults.Keys)

    $bodyLines = $lines[($paramEnd + 1)..($lines.Count - 1)]

    $header = @("# Auto-generated wrapper -- Invoke-CaMigration.ps1")
    $header += "# Source: $SourceScript"
    $header += "# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $header += ""

    # Inject specified params
    foreach ($key in $Params.Keys) {
        $val = $Params[$key]
        if ($val -is [bool]) {
            $header += "`$$key = `$$($val.ToString().ToLower())"
        }
        elseif ($val -is [int]) {
            $header += "`$$key = $val"
        }
        elseif ($val -is [switch]) {
            $header += "`$$key = `$false"
        }
        else {
            $header += "`$$key = `"$val`""
        }
    }

    # Initialize unspecified params -- preserve script defaults, fallback to empty string
    foreach ($name in $paramNames) {
        if (-not $Params.ContainsKey($name)) {
            $default = $paramDefaults[$name]
            if ($null -ne $default) {
                # Preserve the original default from the script (e.g. "SHA256", $true, 4096)
                $header += "`$$name = $default"
            }
            else {
                $header += "`$$name = `"`""
            }
        }
    }

    $header += ""

    $wrapper = $header + $bodyLines
    $wrapper | Out-File $WrapperPath -Encoding UTF8
    Write-Host "  [WRAPPER] Created: $WrapperPath ($($wrapper.Count) lines)" -ForegroundColor Gray
}

function Export-CertFromVM {
    <#
    .SYNOPSIS
        Exports a certificate from a VM's cert store as base64, returns the b64 string.
    #>
    param(
        [string]$ResourceGroup,
        [string]$VMName,
        [string]$StoreName,
        [string]$FindBy,
        [string]$FindValue
    )

    $script = @"
`$cert = `$null
if ('$FindBy' -eq 'Subject') {
    `$cert = Get-ChildItem Cert:\LocalMachine\$StoreName | Where-Object {
        `$_.Subject -match [regex]::Escape('$FindValue')
    } | Sort-Object NotAfter -Descending | Select-Object -First 1
} elseif ('$FindBy' -eq 'Thumbprint') {
    `$cert = Get-ChildItem Cert:\LocalMachine\$StoreName | Where-Object {
        `$_.Thumbprint -eq '$FindValue'
    }
} elseif ('$FindBy' -eq 'ActiveCA') {
    try {
        `$caName = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA Stop).Active
        `$cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
            `$_.Subject -match [regex]::Escape(`$caName)
        } | Where-Object {
            `$_.Extensions | Where-Object { `$_.Oid.FriendlyName -eq 'Basic Constraints' }
        } | Select-Object -First 1
    } catch { }
}
if (`$cert) {
    Write-Output "THUMB:`$(`$cert.Thumbprint)"
    Write-Output "SUBJECT:`$(`$cert.Subject)"
    Write-Output "B64:BEGIN"
    Write-Output ([Convert]::ToBase64String(`$cert.RawData))
} else {
    Write-Output "ERROR:Certificate not found ($FindBy=$FindValue in $StoreName)"
}
"@

    $result = Invoke-RemoteScript -ResourceGroup $ResourceGroup -VMName $VMName -InlineScript $script
    if (-not $result.Success -and $result.Message -match 'ERROR:') {
        throw "Export-CertFromVM failed: $($result.Message)"
    }

    # Parse output
    $thumb = ""
    $subject = ""
    $b64 = ""
    $capturingB64 = $false
    foreach ($line in ($result.Message -split "`n")) {
        $line = $line.Trim()
        if ($line -match '^THUMB:(.+)') { $thumb = $Matches[1] }
        elseif ($line -match '^SUBJECT:(.+)') { $subject = $Matches[1] }
        elseif ($line -match '^B64:BEGIN') { $capturingB64 = $true }
        elseif ($capturingB64 -and $line.Length -gt 10 -and $line -match '^[A-Za-z0-9+/=]+$') { $b64 = $line }
    }

    [PSCustomObject]@{
        Thumbprint = $thumb
        Subject    = $subject
        Base64     = $b64
    }
}

function Import-CertToVM {
    <#
    .SYNOPSIS
        Imports a base64-encoded certificate into a VM's cert store.
    #>
    param(
        [string]$ResourceGroup,
        [string]$VMName,
        [string]$StoreName,
        [string]$Base64Cert,
        [string]$CertFileName
    )

    $script = @"
`$b64 = '$Base64Cert'
`$bytes = [Convert]::FromBase64String(`$b64)
`$dir = 'C:\temp\migration-certs'
if (-not (Test-Path `$dir)) { New-Item -ItemType Directory -Path `$dir -Force | Out-Null }
`$certPath = "`$dir\$CertFileName"
[IO.File]::WriteAllBytes(`$certPath, `$bytes)
`$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(`$certPath)
`$store = New-Object System.Security.Cryptography.X509Certificates.X509Store("$StoreName", "LocalMachine")
`$store.Open("ReadWrite")
`$existing = `$store.Certificates | Where-Object { `$_.Thumbprint -eq `$cert.Thumbprint }
if (-not `$existing) {
    `$store.Add(`$cert)
    Write-Output "IMPORTED:`$(`$cert.Subject) to $StoreName (Thumb: `$(`$cert.Thumbprint))"
} else {
    Write-Output "ALREADY_EXISTS:`$(`$cert.Subject) in $StoreName"
}
`$store.Close()
Write-Output "CERTPATH:`$certPath"
Write-Output "THUMB:`$(`$cert.Thumbprint)"
"@

    $result = Invoke-RemoteScript -ResourceGroup $ResourceGroup -VMName $VMName -InlineScript $script
    if (-not $result.Success) {
        throw "Import-CertToVM failed: $($result.Message)"
    }

    # Parse thumb and path from output
    $thumb = ""
    $certPath = ""
    foreach ($line in ($result.Message -split "`n")) {
        $line = $line.Trim()
        if ($line -match '^THUMB:(.+)') { $thumb = $Matches[1] }
        if ($line -match '^CERTPATH:(.+)') { $certPath = $Matches[1] }
    }

    [PSCustomObject]@{
        Thumbprint = $thumb
        CertPath   = $certPath
        Message    = $result.Message
    }
}

#endregion

#region -- Load & Validate Parameters -----------------------------------------

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Magenta
Write-Host "  ADCS CA Migration Orchestrator v1.0" -ForegroundColor Magenta
Write-Host ("=" * 70) -ForegroundColor Magenta
Write-Host ""

# Load params
if (-not (Test-Path $ParamsFile)) {
    Write-Host "[FATAL] Parameters file not found: $ParamsFile" -ForegroundColor Red
    exit 1
}
$p = Get-Content $ParamsFile -Raw | ConvertFrom-Json
Write-Host "[CONFIG] Loaded: $ParamsFile" -ForegroundColor Gray

# Validate required fields
$errors = @()
if ($p.scenario -notin @('RootCA', 'IssuingCA')) { $errors += "scenario must be 'RootCA' or 'IssuingCA'" }
if ($p.option -notin @('PreDistributed', 'CrossSigned')) { $errors += "option must be 'PreDistributed' or 'CrossSigned'" }
if (-not $p.oldServer.resourceGroup) { $errors += "oldServer.resourceGroup is required" }
if (-not $p.oldServer.vmName) { $errors += "oldServer.vmName is required" }
if (-not $p.newServer.resourceGroup) { $errors += "newServer.resourceGroup is required" }
if (-not $p.newServer.vmName) { $errors += "newServer.vmName is required" }
if (-not $p.newCA.caCommonName) { $errors += "newCA.caCommonName is required" }

if ($p.scenario -eq 'IssuingCA') {
    if (-not $p.parentCA) { $errors += "parentCA section is required for IssuingCA scenario" }
    elseif (-not $p.parentCA.resourceGroup -or -not $p.parentCA.vmName -or -not $p.parentCA.caConfig) {
        $errors += "parentCA.resourceGroup, parentCA.vmName, and parentCA.caConfig are required for IssuingCA scenario"
    }
}

if ($p.scenario -eq 'IssuingCA' -and $p.option -eq 'CrossSigned') {
    # B2 requires parentCA for CSR signing AND oldServer for cross-signing
    if (-not $p.parentCA -or -not $p.parentCA.vmName) {
        $errors += "parentCA config is required for IssuingCA + CrossSigned (Root CA signs the CSR)"
    }
}

if ($errors.Count -gt 0) {
    Write-Host "[FATAL] Parameter validation failed:" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

# Convenience aliases
$oldRG  = $p.oldServer.resourceGroup
$oldVM  = $p.oldServer.vmName
$newRG  = $p.newServer.resourceGroup
$newVM  = $p.newServer.vmName
$caName = $p.newCA.caCommonName
$newVmAdmin = if ($p.newServer.PSObject.Properties['vmAdminUsername']) { $p.newServer.vmAdminUsername } else { "" }

# Parent CA aliases (Issuing CA scenarios only)
$parentRG     = if ($p.PSObject.Properties['parentCA'] -and $p.parentCA) { $p.parentCA.resourceGroup } else { "" }
$parentVM     = if ($p.PSObject.Properties['parentCA'] -and $p.parentCA) { $p.parentCA.vmName } else { "" }
$parentConfig = if ($p.PSObject.Properties['parentCA'] -and $p.parentCA) { $p.parentCA.caConfig } else { "" }

# Determine script folder
$scriptRoot = $PSScriptRoot
if ($p.scenario -eq 'RootCA') {
    if ($p.option -eq 'PreDistributed') {
        $stepDir = Join-Path $scriptRoot "root-ca-migration\chain-pre-distributed"
    } else {
        $stepDir = Join-Path $scriptRoot "root-ca-migration\cross-signed"
    }
} else {
    if ($p.option -eq 'PreDistributed') {
        $stepDir = Join-Path $scriptRoot "intermediate-issuing-ca-migration\chain-pre-distributed"
    } else {
        $stepDir = Join-Path $scriptRoot "intermediate-issuing-ca-migration\cross-signed"
    }
}

if (-not (Test-Path $stepDir)) {
    Write-Host "[FATAL] Script directory not found: $stepDir" -ForegroundColor Red
    exit 1
}

# Output / working directory
if (-not $OutputDir) {
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputDir = "C:\temp\migration-$($p.scenario)-$($p.option)-$ts"
}
if (-not (Test-Path $OutputDir)) { New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null }

# Wrapper staging directory
$wrapperDir = Join-Path $OutputDir "wrappers"
if (-not (Test-Path $wrapperDir)) { New-Item -Path $wrapperDir -ItemType Directory -Force | Out-Null }

Write-Host ""
Write-Host "  Configuration:" -ForegroundColor White
Write-Host "    Scenario:     $($p.scenario)" -ForegroundColor White
Write-Host "    Option:       $($p.option)" -ForegroundColor White
Write-Host "    OLD VM:       $oldVM ($oldRG)" -ForegroundColor White
Write-Host "    NEW VM:       $newVM ($newRG)" -ForegroundColor White
if ($parentVM) {
    Write-Host "    Parent CA:    $parentVM ($parentRG) [$parentConfig]" -ForegroundColor White
}
Write-Host "    New CA Name:  $caName" -ForegroundColor White
Write-Host "    Script Dir:   $stepDir" -ForegroundColor Gray
Write-Host "    Output Dir:   $OutputDir" -ForegroundColor Gray
Write-Host ""

# -- Auto-detect old CA thumbprint from the running CA on the old VM ----------
# This replaces the hardcoded caThumbprint in the JSON -- works for RSA or ECDSA
$oldCAThumbprint = ""
try {
    Write-Host "[DETECT] Querying active CA thumbprint on $oldVM..." -ForegroundColor Yellow
    $detectResult = Export-CertFromVM -ResourceGroup $oldRG -VMName $oldVM `
        -StoreName "My" -FindBy "ActiveCA" -FindValue ""
    if ($detectResult.Thumbprint) {
        $oldCAThumbprint = $detectResult.Thumbprint
        Write-Host "[DETECT] Old CA thumbprint: $oldCAThumbprint ($($detectResult.Subject))" -ForegroundColor Green
    } else {
        Write-Host "[DETECT] Could not auto-detect old CA thumbprint -- old root transfer may fail" -ForegroundColor Yellow
    }
} catch {
    Write-Host "[DETECT] Auto-detect failed: $_ -- old root transfer may fail" -ForegroundColor Yellow
}

#endregion

#region -- Reset (optional) ---------------------------------------------------

if ($ResetFirst -or $ResetOnly) {
    Write-Host "[RESET] Running environment reset..." -ForegroundColor Yellow

    $resetParams = @{
        Scenario           = $p.scenario
        Option             = $p.option
        OldVMResourceGroup = $oldRG
        OldVMName          = $oldVM
        NewVMResourceGroup = $newRG
        NewVMName          = $newVM
        SkipConfirmation   = $true
    }
    if ($oldCAThumbprint) {
        $resetParams['OldCAThumbprint'] = $oldCAThumbprint
    }
    if ($parentRG -and $parentVM) {
        $resetParams['ParentVMResourceGroup'] = $parentRG
        $resetParams['ParentVMName']          = $parentVM
    }

    $resetScript = Join-Path $scriptRoot "Reset-MigrationEnvironment.ps1"
    & $resetScript @resetParams 2>&1 | ForEach-Object { Write-Host "  $_" }

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[FATAL] Reset failed with exit code $LASTEXITCODE" -ForegroundColor Red
        exit 1
    }
    Write-Host "[RESET] Complete" -ForegroundColor Green

    if ($ResetOnly) {
        Write-Host ""
        Write-Host "  Reset-only mode. Exiting." -ForegroundColor Yellow
        exit 0
    }
}

#endregion

#region -- Migration Execution Engine -----------------------------------------

$runStart = Get-Date
$results  = @()

function Record-Step {
    param(
        [int]$StepNum,
        [string]$Name,
        [string]$VM,
        [PSCustomObject]$Result
    )

    $status = if ($Result.Success) { "PASS" } else { "FAIL" }
    $color  = if ($Result.Success) { "Green" } else { "Red" }
    $secs   = [Math]::Round($Result.Duration.TotalSeconds)

    Write-Host "  [$status] Step $StepNum ($($secs)s)" -ForegroundColor $color

    $script:results += [PSCustomObject]@{
        Step     = $StepNum
        Name     = $Name
        VM       = $VM
        Status   = $status
        Duration = $Result.Duration
        Seconds  = $secs
    }

    # Save full output to log
    $logFile = Join-Path $OutputDir "step$StepNum-output.txt"
    $Result.Message | Out-File $logFile -Encoding UTF8
    if ($Result.StdErr) {
        "`n--- STDERR ---`n$($Result.StdErr)" | Out-File $logFile -Append -Encoding UTF8
    }

    if (-not $Result.Success) {
        Write-Host "  [FATAL] Step $StepNum failed. See $logFile" -ForegroundColor Red
        Write-Host "  Migration aborted." -ForegroundColor Red
        Write-Summary
        exit 1
    }
}

function Write-Summary {
    $runEnd = Get-Date
    $totalDur = $runEnd - $runStart

    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Magenta
    Write-Host "  Migration Summary" -ForegroundColor Magenta
    Write-Host ("=" * 70) -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  Scenario: $($p.scenario) | Option: $($p.option)" -ForegroundColor White
    Write-Host "  Started:  $($runStart.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Gray
    Write-Host "  Ended:    $($runEnd.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Gray
    Write-Host "  Total:    $([Math]::Round($totalDur.TotalMinutes, 1)) minutes ($([Math]::Round($totalDur.TotalSeconds))s)" -ForegroundColor White
    Write-Host ""

    $passCount = @($results | Where-Object Status -eq 'PASS').Count
    $failCount = @($results | Where-Object Status -eq 'FAIL').Count

    Write-Host "  +------+----------------------------------------------+------+--------+" -ForegroundColor White
    Write-Host "  | Step | Name                                         | Status | Time  |" -ForegroundColor White
    Write-Host "  +------+----------------------------------------------+------+--------+" -ForegroundColor White

    foreach ($r in $results) {
        $color = if ($r.Status -eq 'PASS') { 'Green' } else { 'Red' }
        $name  = $r.Name.PadRight(44).Substring(0, 44)
        $time  = "$($r.Seconds)s".PadLeft(5)
        Write-Host "  |  $($r.Step)   | $name | $($r.Status.PadRight(4)) | $time |" -ForegroundColor $color
    }

    Write-Host "  +------+----------------------------------------------+------+--------+" -ForegroundColor White
    Write-Host ""
    Write-Host "  Result: $passCount PASS, $failCount FAIL -- Total: $([Math]::Round($totalDur.TotalMinutes, 1))m" -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Red' })
    Write-Host ""

    # Save report
    $reportFile = Join-Path $OutputDir "migration-report.txt"
    $reportLines = @(
        "ADCS CA Migration Report"
        "========================"
        "Scenario: $($p.scenario) | Option: $($p.option)"
        "Old VM: $oldVM ($oldRG)"
        "New VM: $newVM ($newRG)"
        "New CA: $caName"
        "Started: $($runStart.ToString('yyyy-MM-dd HH:mm:ss'))"
        "Ended: $($runEnd.ToString('yyyy-MM-dd HH:mm:ss'))"
        "Total: $([Math]::Round($totalDur.TotalMinutes, 1)) minutes"
        ""
        "Step Results:"
    )
    foreach ($r in $results) {
        $reportLines += "  Step $($r.Step): $($r.Status) ($($r.Seconds)s) - $($r.Name) [$($r.VM)]"
    }
    $reportLines += ""
    $reportLines += "Result: $passCount PASS, $failCount FAIL"
    $reportLines -join "`r`n" | Out-File $reportFile -Encoding UTF8
    Write-Host "  Report saved: $reportFile" -ForegroundColor Gray
    Write-Host ""

    # Post-summary: manual test issuance for Scenario B (Cavium KSP requires interactive session)
    if ($p.scenario -eq 'IssuingCA' -and $failCount -eq 0) {
        $postIp = (az vm list-ip-addresses --name $newVM --resource-group $newRG --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv 2>$null)
        if (-not $postIp) { $postIp = "(check Azure Portal)" }
        Write-Host ("=" * 70) -ForegroundColor Yellow
        Write-Host "  POST-MIGRATION: Test Certificate Issuance (Manual)" -ForegroundColor Yellow
        Write-Host ("=" * 70) -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  All 8 steps PASSED. To verify end-to-end certificate issuance," -ForegroundColor White
        Write-Host "  RDP to $newVM ($postIp) and run in an elevated PowerShell:" -ForegroundColor White
        Write-Host ""
        Write-Host '  @("[NewRequest]",''Subject = "CN=Migration-Test-Cert"'',"KeyLength = 2048","RequestType = PKCS10") | Out-File C:\temp\test.inf -Encoding ASCII' -ForegroundColor Cyan
        Write-Host "  certreq -new C:\temp\test.inf C:\temp\test.req" -ForegroundColor Cyan
        Write-Host "  certreq -submit C:\temp\test.req C:\temp\test.cer" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  The request will show 'pending' (normal for standalone CA)." -ForegroundColor Yellow
        Write-Host "  Approve and retrieve with:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  certutil -resubmit <RequestId>" -ForegroundColor Cyan
        Write-Host "  certreq -retrieve <RequestId> C:\temp\test.cer" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Replace <RequestId> with the number shown by certreq -submit." -ForegroundColor Gray
        Write-Host ""
        Write-Host "  A successful issuance confirms the new CA is fully operational" -ForegroundColor White
        Write-Host "  with the Cloud HSM key." -ForegroundColor White
        Write-Host ""
    }
}

#endregion

#region -- Scenario A: Root CA ------------------------------------------------

if ($p.scenario -eq 'RootCA') {

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  ADCS Migration Started" -ForegroundColor Cyan
    Write-Host "  Scenario: $($p.scenario) | Option: $($p.option)" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""

    # -- Shared: Steps 1 and 2 are identical for both options --

    # STEP 1 -- Capture Existing Root CA (OLD server)
    $stepScripts = Get-ChildItem $stepDir -Filter "Step1-*.ps1"
    Write-StepBanner 1 $stepScripts.BaseName $oldVM "OLD"
    $r1 = Invoke-RemoteScript -ResourceGroup $oldRG -VMName $oldVM -ScriptPath $stepScripts.FullName
    Record-Step 1 $stepScripts.BaseName $oldVM $r1

    # STEP 2 -- Validate New CA Server (NEW server)
    $stepScripts = Get-ChildItem $stepDir -Filter "Step2-*.ps1"
    Write-StepBanner 2 $stepScripts.BaseName $newVM "NEW"
    $r2 = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -ScriptPath $stepScripts.FullName
    Record-Step 2 $stepScripts.BaseName $newVM $r2

    if ($p.option -eq 'PreDistributed') {

        # STEP 3 -- Build New Root CA (NEW server) -- needs wrapper for CACommonName
        $step3Src = (Get-ChildItem $stepDir -Filter "Step3-*.ps1").FullName
        $step3Wrapper = Join-Path $wrapperDir "Step3-wrapper.ps1"
        $step3Params = @{
            CACommonName     = $caName
            Platform         = ""
            KeyAlgorithm     = if ($p.newCA.PSObject.Properties['keyAlgorithm']) { $p.newCA.keyAlgorithm } else { '' }
            KeyLength        = $p.newCA.keyLength
            HashAlgorithm    = $p.newCA.hashAlgorithm
            ValidityYears    = [int]$p.newCA.validityYears
            OverwriteExisting = [bool]$p.newCA.overwriteExisting
            Step1OutputDir   = ""
        }
        New-Wrapper -SourceScript $step3Src -Params $step3Params -WrapperPath $step3Wrapper

        Write-StepBanner 3 "BuildNewCA" $newVM "NEW"
        $r3 = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -ScriptPath $step3Wrapper
        Record-Step 3 "BuildNewCA" $newVM $r3

        # STEP 4 -- Validate New Root CA (NEW server)
        $step4Src = (Get-ChildItem $stepDir -Filter "Step4-*.ps1").FullName
        Write-StepBanner 4 "ValidateNewCACert" $newVM "NEW"
        $r4 = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -ScriptPath $step4Src
        Record-Step 4 "ValidateNewCACert" $newVM $r4

        # STEP 5 -- Export and Distribute (NEW server)
        $step5Src = (Get-ChildItem $stepDir -Filter "Step5-*.ps1").FullName
        Write-StepBanner 5 "PreDistribute" $newVM "NEW"
        $r5 = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -ScriptPath $step5Src
        Record-Step 5 "PreDistribute" $newVM $r5

        # -- CERT TRANSFER: New root from NEW -> OLD (import to Root store) --
        # Parse new root thumbprint from Step 4 output for reliable lookup
        $newThumb = ""
        if ($r4.Message -match 'Thumbprint:\s+([A-Fa-f0-9]{40})') {
            $newThumb = $Matches[1]
        }
        Write-Host ""
        Write-Host "  [TRANSFER] Exporting new root cert from $newVM (Thumb: $newThumb)..." -ForegroundColor Yellow
        if ($newThumb) {
            $newCert = Export-CertFromVM -ResourceGroup $newRG -VMName $newVM `
                -StoreName "My" -FindBy "Thumbprint" -FindValue $newThumb
        } else {
            $newCert = Export-CertFromVM -ResourceGroup $newRG -VMName $newVM `
                -StoreName "My" -FindBy "ActiveCA" -FindValue ""
        }
        Write-Host "  [TRANSFER] New root: $($newCert.Subject) (Thumb: $($newCert.Thumbprint))" -ForegroundColor Gray

        if (-not $newCert.Thumbprint -or -not $newCert.Base64) {
            Write-Host "  [FATAL] Failed to export new root certificate from $newVM" -ForegroundColor Red
            Write-Host "          Check that Step 3/4 completed and the CA cert is in LocalMachine\My" -ForegroundColor Red
            Write-Summary
            exit 1
        }

        Write-Host "  [TRANSFER] Importing new root cert to $oldVM Root store..." -ForegroundColor Yellow
        $importResult = Import-CertToVM -ResourceGroup $oldRG -VMName $oldVM `
            -StoreName "Root" -Base64Cert $newCert.Base64 -CertFileName "NewRootCA-G2.cer"
        Write-Host "  [TRANSFER] $($importResult.Message)" -ForegroundColor Gray

        # Transfer old root from OLD -> NEW so Step 6 trust validation passes
        # (NEW VM may not have the old root if it was rebuilt for a different scenario)
        Write-Host "  [TRANSFER] Exporting old root cert from $oldVM..." -ForegroundColor Yellow
        $oldCert = Export-CertFromVM -ResourceGroup $oldRG -VMName $oldVM `
            -StoreName "My" -FindBy "Thumbprint" -FindValue $oldCAThumbprint
        if ($oldCert.Base64) {
            Write-Host "  [TRANSFER] Importing old root cert to $newVM Root store..." -ForegroundColor Yellow
            $oldImportResult = Import-CertToVM -ResourceGroup $newRG -VMName $newVM `
                -StoreName "Root" -Base64Cert $oldCert.Base64 -CertFileName "OldRootCA.cer"
            Write-Host "  [TRANSFER] $($oldImportResult.Message)" -ForegroundColor Gray
        } else {
            Write-Host "  [WARN] Could not export old root from $oldVM -- Step 6 old root check may fail" -ForegroundColor Yellow
        }
        Write-Host ""

        # STEP 6 -- Validate Trust (BOTH servers)
        $step6Src = (Get-ChildItem $stepDir -Filter "Step6-*.ps1").FullName
        $step6Wrapper = Join-Path $wrapperDir "Step6-wrapper.ps1"

        # Step 6 needs NewRootThumbprint -- create wrapper
        $step6Lines = Get-Content $step6Src
        $s6HelpEnd = -1; $s6ParamStart = -1; $s6ParamEnd = -1
        for ($i = 0; $i -lt $step6Lines.Count; $i++) {
            if ($step6Lines[$i] -match '^#>') { $s6HelpEnd = $i }
            if ($step6Lines[$i] -match '^\[CmdletBinding') { $s6ParamStart = $i }
            if ($s6ParamStart -ge 0 -and $s6ParamEnd -lt 0 -and $step6Lines[$i] -match '^\)') { $s6ParamEnd = $i }
        }
        $s6Body = $step6Lines[($s6ParamEnd + 1)..($step6Lines.Count - 1)]
        $s6Header = @(
            "# Auto-generated wrapper -- Step 6"
            "`$NewRootThumbprint = `"$($newCert.Thumbprint)`""
        )
        if ($oldCAThumbprint) {
            $s6Header += "`$OldRootThumbprint = `"$($oldCAThumbprint)`""
        }
        $s6Header += "`$NewRootCertPath = `"`""
        $s6Header += ""
        ($s6Header + $s6Body) | Out-File $step6Wrapper -Encoding UTF8

        Write-StepBanner 6 "ValidateTrust (NEW)" $newVM "NEW"
        $r6a = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -ScriptPath $step6Wrapper
        Record-Step 6 "ValidateTrust-NewVM" $newVM $r6a

        Write-Host ""
        Write-Host "  [STEP 6b] Running trust validation on OLD server..." -ForegroundColor Yellow
        $r6b = Invoke-RemoteScript -ResourceGroup $oldRG -VMName $oldVM -ScriptPath $step6Wrapper
        # Log but don't fail on OLD VM (it may not have the cert in all stores)
        $s6bStatus = if ($r6b.Success) { "PASS" } else { "WARN" }
        Write-Host "  [$s6bStatus] Step 6b - ValidateTrust on $oldVM ($([Math]::Round($r6b.Duration.TotalSeconds))s)" `
            -ForegroundColor $(if ($r6b.Success) { 'Green' } else { 'Yellow' })
        $logFile6b = Join-Path $OutputDir "step6b-output.txt"
        $r6b.Message | Out-File $logFile6b -Encoding UTF8

        # STEP 7 -- Cross Validate (NEW server)
        $step7Src = (Get-ChildItem $stepDir -Filter "Step7-*.ps1").FullName
        Write-StepBanner 7 "CrossValidate" $newVM "NEW"
        $r7 = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -ScriptPath $step7Src
        Record-Step 7 "CrossValidate" $newVM $r7

        # STEP 8 -- Decommission Checks (OLD server)
        $step8Src = (Get-ChildItem $stepDir -Filter "Step8-*.ps1").FullName
        Write-StepBanner 8 "DecommissionChecks" $oldVM "OLD"
        $r8 = Invoke-RemoteScript -ResourceGroup $oldRG -VMName $oldVM -ScriptPath $step8Src
        Record-Step 8 "DecommissionChecks" $oldVM $r8

    }
    elseif ($p.option -eq 'CrossSigned') {

        # STEP 3 -- Install New Root CA (NEW server) -- needs wrapper for CACommonName
        $step3Src = (Get-ChildItem $stepDir -Filter "Step3-*.ps1").FullName
        $step3Wrapper = Join-Path $wrapperDir "Step3-wrapper.ps1"
        $step3Params = @{
            CACommonName      = $caName
            Platform          = ""
            KeyAlgorithm      = if ($p.newCA.PSObject.Properties['keyAlgorithm']) { $p.newCA.keyAlgorithm } else { '' }
            KeyLength         = $p.newCA.keyLength
            HashAlgorithm     = $p.newCA.hashAlgorithm
            ValidityYears     = [int]$p.newCA.validityYears
            OverwriteExisting = [bool]$p.newCA.overwriteExisting
            OutputDir         = ""
        }
        New-Wrapper -SourceScript $step3Src -Params $step3Params -WrapperPath $step3Wrapper

        Write-StepBanner 3 "BuildNewCA" $newVM "NEW"
        $r3 = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -ScriptPath $step3Wrapper
        Record-Step 3 "BuildNewCA" $newVM $r3

        # -- CERT TRANSFER: New self-signed cert from NEW -> OLD --
        Write-Host ""
        Write-Host "  [TRANSFER] Exporting new root self-signed cert from $newVM..." -ForegroundColor Yellow
        $newSelfCert = Export-CertFromVM -ResourceGroup $newRG -VMName $newVM `
            -StoreName "My" -FindBy "ActiveCA" -FindValue ""

        if (-not $newSelfCert.Thumbprint -or -not $newSelfCert.Base64) {
            Write-Host "  [FATAL] Failed to export new self-signed cert from $newVM" -ForegroundColor Red
            Write-Summary
            exit 1
        }
        Write-Host "  [TRANSFER] Cert: $($newSelfCert.Subject) (Thumb: $($newSelfCert.Thumbprint))" -ForegroundColor Gray

        Write-Host "  [TRANSFER] Writing cert to $oldVM for cross-signing..." -ForegroundColor Yellow
        $importForCross = Import-CertToVM -ResourceGroup $oldRG -VMName $oldVM `
            -StoreName "Root" -Base64Cert $newSelfCert.Base64 -CertFileName "NewRootCA-SelfSigned.cer"
        $newCertPathOnOld = $importForCross.CertPath
        Write-Host "  [TRANSFER] Cert at: $newCertPathOnOld" -ForegroundColor Gray
        Write-Host ""

        # STEP 4 -- Cross-Sign New CA (OLD server) -- needs wrapper for NewCACertPath
        $step4Src = (Get-ChildItem $stepDir -Filter "Step4-*.ps1").FullName
        $step4Wrapper = Join-Path $wrapperDir "Step4-wrapper.ps1"
        $step4Params = @{
            NewCACertPath = $newCertPathOnOld
            ValidityYears = [int]$p.newCA.validityYears
            OutputDir     = ""
        }
        New-Wrapper -SourceScript $step4Src -Params $step4Params -WrapperPath $step4Wrapper

        Write-StepBanner 4 "CrossSignNewCA" $oldVM "OLD"
        $r4 = Invoke-RemoteScript -ResourceGroup $oldRG -VMName $oldVM -ScriptPath $step4Wrapper
        Record-Step 4 "CrossSignNewCA" $oldVM $r4

        # -- CERT TRANSFER: Cross-signed cert + old root from OLD -> NEW --
        Write-Host ""
        Write-Host "  [TRANSFER] Exporting cross-signed cert from $oldVM..." -ForegroundColor Yellow

        # Find the cross-signed cert output directory and extract certs
        $exportScript = @"
`$dirs = Get-ChildItem 'C:\Windows\system32\config\systemprofile\rootca-crosssign-step4-*' -Directory -EA SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not `$dirs) {
    `$dirs = Get-ChildItem 'C:\Users\*\rootca-crosssign-step4-*' -Directory -EA SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if (`$dirs) {
    `$crossCert = Get-ChildItem `$dirs.FullName -Filter '*CrossSigned*' -Recurse | Select-Object -First 1
    `$oldCert = Get-ChildItem `$dirs.FullName -Filter '*OldRootCA*' -Recurse | Select-Object -First 1
    if (`$crossCert) {
        `$bytes = [IO.File]::ReadAllBytes(`$crossCert.FullName)
        Write-Output "CROSSCERT_B64:BEGIN"
        Write-Output ([Convert]::ToBase64String(`$bytes))
        Write-Output "CROSSCERT_PATH:`$(`$crossCert.FullName)"
    }
    if (`$oldCert) {
        `$bytes2 = [IO.File]::ReadAllBytes(`$oldCert.FullName)
        Write-Output "OLDCERT_B64:BEGIN"
        Write-Output ([Convert]::ToBase64String(`$bytes2))
        Write-Output "OLDCERT_PATH:`$(`$oldCert.FullName)"
    }
    Write-Output "DIR:`$(`$dirs.FullName)"
} else {
    Write-Output "ERROR:No step4 output directory found"
}
"@
        $exportResult = Invoke-RemoteScript -ResourceGroup $oldRG -VMName $oldVM -InlineScript $exportScript

        # Parse the b64 values
        $crossB64 = ""; $oldCertB64 = ""
        $lines = $exportResult.Message -split "`n"
        $nextIsCross = $false; $nextIsOld = $false
        foreach ($line in $lines) {
            $line = $line.Trim()
            if ($line -match '^CROSSCERT_B64:') { $nextIsCross = $true; continue }
            if ($line -match '^OLDCERT_B64:') { $nextIsOld = $true; continue }
            if ($nextIsCross -and $line.Length -gt 100 -and $line -match '^[A-Za-z0-9+/=]+$') {
                $crossB64 = $line; $nextIsCross = $false
            }
            if ($nextIsOld -and $line.Length -gt 100 -and $line -match '^[A-Za-z0-9+/=]+$') {
                $oldCertB64 = $line; $nextIsOld = $false
            }
        }

        if (-not $crossB64 -or -not $oldCertB64) {
            Write-Host "  [FATAL] Failed to extract certs from $oldVM step4 output (crossB64=$($crossB64.Length) oldB64=$($oldCertB64.Length))" -ForegroundColor Red
            Write-Host "  [DEBUG] Export output:" -ForegroundColor Yellow
            Write-Host $exportResult.Message
            Write-Summary
            exit 1
        }

        if ($crossB64) {
            Write-Host "  [TRANSFER] Uploading cross-signed cert to $newVM..." -ForegroundColor Yellow
            $crossImport = Import-CertToVM -ResourceGroup $newRG -VMName $newVM `
                -StoreName "CA" -Base64Cert $crossB64 -CertFileName "NewRootCA-CrossSigned.cer"
            $crossCertPathOnNew = $crossImport.CertPath
        }
        if ($oldCertB64) {
            Write-Host "  [TRANSFER] Uploading old root cert to $newVM..." -ForegroundColor Yellow
            $oldImport = Import-CertToVM -ResourceGroup $newRG -VMName $newVM `
                -StoreName "Root" -Base64Cert $oldCertB64 -CertFileName "OldRootCA.cer"
            $oldCertPathOnNew = $oldImport.CertPath
        }
        Write-Host ""

        # STEP 5 -- Publish Cross Cert (NEW server) -- needs wrapper for CrossCertPath
        $step5Src = (Get-ChildItem $stepDir -Filter "Step5-*.ps1").FullName
        $step5Wrapper = Join-Path $wrapperDir "Step5-wrapper.ps1"
        $step5Params = @{
            CrossCertPath   = $crossCertPathOnNew
            OldRootCertPath = $oldCertPathOnNew
            OutputDir       = ""
        }
        New-Wrapper -SourceScript $step5Src -Params $step5Params -WrapperPath $step5Wrapper

        Write-StepBanner 5 "PublishCrossCert" $newVM "NEW"
        $r5 = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -ScriptPath $step5Wrapper
        Record-Step 5 "PublishCrossCert" $newVM $r5

        # STEP 6 -- Validate Cross-Signed CA (NEW server)
        $step6Src = (Get-ChildItem $stepDir -Filter "Step6-*.ps1").FullName
        $step6Wrapper = Join-Path $wrapperDir "Step6-wrapper.ps1"
        New-Wrapper -SourceScript $step6Src -Params @{
            OldRootCertPath = $oldCertPathOnNew
        } -WrapperPath $step6Wrapper

        Write-StepBanner 6 "ValidateCrossSignedCA" $newVM "NEW"
        $r6 = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -ScriptPath $step6Wrapper
        Record-Step 6 "ValidateCrossSignedCA" $newVM $r6

        # STEP 7 -- Cross Validate (NEW server)
        $step7Src = (Get-ChildItem $stepDir -Filter "Step7-*.ps1").FullName
        Write-StepBanner 7 "CrossValidate" $newVM "NEW"
        $r7 = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -ScriptPath $step7Src
        Record-Step 7 "CrossValidate" $newVM $r7

        # STEP 8 -- Decommission Checks (OLD server)
        $step8Src = (Get-ChildItem $stepDir -Filter "Step8-*.ps1").FullName
        Write-StepBanner 8 "DecommissionChecks" $oldVM "OLD"
        $r8 = Invoke-RemoteScript -ResourceGroup $oldRG -VMName $oldVM -ScriptPath $step8Src
        Record-Step 8 "DecommissionChecks" $oldVM $r8
    }
}

#endregion

#region -- Scenario B: Issuing CA ---------------------------------------------

if ($p.scenario -eq 'IssuingCA' -and $p.option -eq 'PreDistributed') {

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  ADCS Migration Started" -ForegroundColor Cyan
    Write-Host "  Scenario: $($p.scenario) | Option: $($p.option)" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""

    # STEP 1 -- Capture Existing CA (OLD server)
    $step1Src = (Get-ChildItem $stepDir -Filter "Step1-*.ps1").FullName

    # If customer specified caCommonName for old CA, we need a wrapper to avoid Read-Host
    if ($p.oldServer.caCommonName) {
        $step1Wrapper = Join-Path $wrapperDir "Step1-wrapper.ps1"
        New-Wrapper -SourceScript $step1Src -Params @{ CAName = $p.oldServer.caCommonName } -WrapperPath $step1Wrapper
        $step1Run = $step1Wrapper
    } else {
        $step1Run = $step1Src
    }

    Write-StepBanner 1 "CaptureExistingCA" $oldVM "OLD"
    $r1 = Invoke-RemoteScript -ResourceGroup $oldRG -VMName $oldVM -ScriptPath $step1Run
    Record-Step 1 "CaptureExistingCA" $oldVM $r1

    # -- TRANSFER: Step 1 output JSON to NEW server --
    Write-Host ""
    Write-Host "  [TRANSFER] Exporting Step 1 data from $oldVM..." -ForegroundColor Yellow

    $fetchStep1 = @"
`$dir = Get-ChildItem 'C:\Windows\system32\config\systemprofile\adcs-migration-step1-*' -Directory -EA SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not `$dir) {
    `$dir = Get-ChildItem 'C:\Users\*\adcs-migration-step1-*' -Directory -EA SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if (`$dir) {
    `$jsonBytes = [IO.File]::ReadAllBytes((Join-Path `$dir.FullName 'ca-migration-details.json'))
    `$jsonB64 = [Convert]::ToBase64String(`$jsonBytes)
    Write-Output "JSON_B64:`$jsonB64"
    `$cert = Join-Path `$dir.FullName 'OldIssuingCA.cer'
    if (Test-Path `$cert) {
        `$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes(`$cert))
        Write-Output "CERT_B64:`$b64"
    }
    Write-Output "DIR:`$(`$dir.FullName)"
} else { Write-Output "ERROR:No step1 output found" }
"@
    $fetchResult = Invoke-RemoteScript -ResourceGroup $oldRG -VMName $oldVM -InlineScript $fetchStep1
    # Parse and upload to new server
    $step1JsonB64 = ""; $step1CertB64 = ""; $step1DirOnOld = ""
    foreach ($line in ($fetchResult.Message -split "`n")) {
        $line = $line.Trim()
        if ($line -match '^JSON_B64:(.+)') { $step1JsonB64 = $Matches[1] }
        if ($line -match '^CERT_B64:(.+)') { $step1CertB64 = $Matches[1] }
        if ($line -match '^DIR:(.+)') { $step1DirOnOld = $Matches[1] }
    }

    # Upload Step 1 data to NEW server
    $uploadStep1 = @"
`$dir = 'C:\temp\migration-step1-data'
New-Item -Path `$dir -ItemType Directory -Force | Out-Null
`$jsonBytes = [Convert]::FromBase64String('$step1JsonB64')
[IO.File]::WriteAllBytes("`$dir\ca-migration-details.json", `$jsonBytes)
`$certBytes = [Convert]::FromBase64String('$step1CertB64')
[IO.File]::WriteAllBytes("`$dir\OldIssuingCA.cer", `$certBytes)
Write-Output "UPLOADED:`$dir"
"@
    $uploadResult = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -InlineScript $uploadStep1
    $step1DirOnNew = "C:\temp\migration-step1-data"
    Write-Host "  [TRANSFER] Step 1 data uploaded to $newVM at $step1DirOnNew" -ForegroundColor Gray
    Write-Host ""

    # STEP 2 -- Validate New CA Server (NEW server)
    $step2Src = (Get-ChildItem $stepDir -Filter "Step2-*.ps1").FullName
    Write-StepBanner 2 "ValidateNewCAServer" $newVM "NEW"
    $r2 = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -ScriptPath $step2Src
    Record-Step 2 "ValidateNewCAServer" $newVM $r2

    # STEP 3 -- Configure Subordinate CA + Generate CSR (NEW server)
    $step3Src = (Get-ChildItem $stepDir -Filter "Step3-*.ps1").FullName
    $step3Wrapper = Join-Path $wrapperDir "Step3-wrapper.ps1"
    New-Wrapper -SourceScript $step3Src -Params @{
        Step1OutputDir    = $step1DirOnNew
        KeyAlgorithm      = if ($p.newCA.PSObject.Properties['keyAlgorithm']) { $p.newCA.keyAlgorithm } else { '' }
        KeyLength         = $p.newCA.keyLength
        HashAlgorithm     = $p.newCA.hashAlgorithm
        SubjectName       = $caName
        OverwriteExisting = $true
    } -WrapperPath $step3Wrapper

    Write-StepBanner 3 "GenerateCSR" $newVM "NEW"
    $r3 = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -ScriptPath $step3Wrapper
    Record-Step 3 "GenerateCSR" $newVM $r3

    # -- TRANSFER: CSR from NEW -> Parent CA (Root CA) for signing --
    Write-Host ""
    Write-Host "  [TRANSFER] Exporting CSR from $newVM to $parentVM (Root CA) for signing..." -ForegroundColor Yellow

    $fetchCSR = @"
`$dir = Get-ChildItem 'C:\Windows\system32\config\systemprofile\adcs-migration-step3-*' -Directory -EA SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not `$dir) {
    `$dir = Get-ChildItem 'C:\Users\*\adcs-migration-step3-*' -Directory -EA SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if (`$dir) {
    `$req = Get-ChildItem `$dir.FullName -Filter '*.req' | Select-Object -First 1
    if (`$req) {
        `$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes(`$req.FullName))
        Write-Output "CSR_B64:`$b64"
        Write-Output "CSR_PATH:`$(`$req.FullName)"
    }
} else { Write-Output "ERROR:No step3 output found" }
"@
    $csrResult = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -InlineScript $fetchCSR
    $csrB64 = ""
    foreach ($line in ($csrResult.Message -split "`n")) {
        if ($line.Trim() -match '^CSR_B64:(.+)') { $csrB64 = $Matches[1] }
    }

    if (-not $csrB64) {
        Write-Host "  [ERROR] CSR not found on $newVM. CSR fetch output:" -ForegroundColor Red
        Write-Host ($csrResult.Message | Out-String) -ForegroundColor Gray
        if ($csrResult.StdErr) { Write-Host "  [STDERR] $($csrResult.StdErr)" -ForegroundColor Yellow }
        Write-Host "  [FATAL] Cannot submit empty CSR to Root CA. Aborting." -ForegroundColor Red
        exit 1
    }
    Write-Host "  [TRANSFER] CSR extracted ($($csrB64.Length) chars base64)" -ForegroundColor Gray

    # Upload CSR to OLD server and submit
    $parentCAName = ($parentConfig -split '\\')[-1]
    $submitCSR = @"
`$ErrorActionPreference = 'Continue'
`$dir = 'C:\temp\migration-csr'
New-Item -Path `$dir -ItemType Directory -Force | Out-Null
# B1 signing block (with resubmit fix)
# Ensure SafeNet Luna headless mode (no PIN popup in Session 0)
`$lunaPath = 'HKLM:\SOFTWARE\SafeNet\LunaClient'
if (Test-Path `$lunaPath) {
    `$iv = (Get-ItemProperty -Path `$lunaPath -Name 'Interactive' -EA SilentlyContinue).Interactive
    if (`$iv -ne 0) {
        Set-ItemProperty -Path `$lunaPath -Name 'Interactive' -Value 0
        Write-Output 'Set SafeNet Interactive=0 for headless HSM access'
    }
}
`$bytes = [Convert]::FromBase64String('$csrB64')
[IO.File]::WriteAllBytes("`$dir\NewCA.req", `$bytes)
Write-Output "CSR written to `$dir\NewCA.req (`$(`$bytes.Length) bytes)"

# Ensure certsvc is running and responsive
Start-Service certsvc -EA SilentlyContinue
Set-Service certsvc -StartupType Automatic -EA SilentlyContinue
`$caReady = `$false
for (`$w = 1; `$w -le 10; `$w++) {
    Start-Sleep 3
    `$ping = & certutil -config "$parentConfig" -ping 2>&1 | Out-String
    if (`$ping -match 'interface is alive') { `$caReady = `$true; break }
    Write-Output "Waiting for certsvc... attempt `$w/10"
}
if (`$caReady) { Write-Output "certsvc is responsive" } else { Write-Output "WARNING: certsvc not responsive after 30s" }

# --- COM Submit + certutil resubmit + certreq retrieve (proven B1 Attempt 4 approach) ---
# certreq -submit hangs in Session 0 (Finding 5). COM Submit doesn't hang.
# Standalone Root CA queues as PENDING (Finding). Use certutil -resubmit to approve,
# then certreq -retrieve to get the signed cert. This is the exact flow from Phase 10.
`$csrContent = Get-Content "`$dir\NewCA.req" -Raw
Write-Output "Submitting CSR via COM CertificateAuthority.Request..."

`$CertRequest = New-Object -ComObject CertificateAuthority.Request

# Flag 0x0 = CR_IN_BASE64HEADER (PEM with BEGIN/END headers)
# Pass CommonName attribute so Standalone CA policy module can construct subject
`$disposition = `$CertRequest.Submit(0x0, `$csrContent, "CommonName:$caName", "$parentConfig")
`$requestId = `$CertRequest.GetRequestId()
Write-Output "COM Submit: RequestId=`$requestId, Disposition=`$disposition"

# Disposition 5 = Pending (normal for Standalone CA)
if (`$disposition -eq 5) {
    Write-Output "Request is PENDING (expected). Approving with certutil -resubmit `$requestId..."
    `$resubOut = & certutil -resubmit `$requestId 2>&1 | Out-String
    Write-Output "certutil -resubmit output: `$resubOut"
    Start-Sleep 2
    Write-Output "Retrieving signed cert with certreq -retrieve..."
    `$retrieveOut = & certreq -retrieve -f -config "$parentConfig" `$requestId "`$dir\NewCA-signed.cer" 2>&1 | Out-String
    Write-Output "certreq -retrieve output: `$retrieveOut"
} elseif (`$disposition -eq 3) {
    # Issued immediately (unlikely for Standalone CA but handle it)
    `$certPem = `$CertRequest.GetCertificate(0x0)
    Set-Content "`$dir\NewCA-signed.cer" `$certPem -Encoding ASCII
    Write-Output "Cert issued immediately (disposition 3)"
} else {
    Write-Output "ERROR: Unexpected disposition `$disposition"
    `$dispMsg = `$CertRequest.GetDispositionMessage()
    Write-Output "DispositionMessage: `$dispMsg"
}

# Check result
if (Test-Path "`$dir\NewCA-signed.cer") {
    `$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes("`$dir\NewCA-signed.cer"))
    Write-Output "SIGNED_B64:`$b64"
    Write-Output "SIGNED_PATH:`$dir\NewCA-signed.cer"
} else {
    Write-Output 'ERROR:Signed cert not created'
}
"@
    $submitResult = Invoke-RemoteScript -ResourceGroup $parentRG -VMName $parentVM -InlineScript $submitCSR
    $signedB64 = ""
    foreach ($line in ($submitResult.Message -split "`n")) {
        if ($line.Trim() -match '^SIGNED_B64:(.+)') { $signedB64 = $Matches[1] }
    }

    if (-not $signedB64) {
        Write-Host "  [ERROR] Failed to retrieve signed certificate from Root CA ($parentVM)." -ForegroundColor Red
        Write-Host "          Raw stdout:" -ForegroundColor Yellow
        Write-Host ($submitResult.Message | Out-String) -ForegroundColor Gray
        if ($submitResult.StdErr) {
            Write-Host "          Raw stderr:" -ForegroundColor Yellow
            Write-Host ($submitResult.StdErr | Out-String) -ForegroundColor Gray
        }
        Write-Host "          RawJson (first 500):" -ForegroundColor Yellow
        Write-Host ($submitResult.RawJson.Substring(0, [Math]::Min(500, $submitResult.RawJson.Length))) -ForegroundColor Gray
        Write-Host "  [FATAL] Cannot continue without signed certificate. Aborting." -ForegroundColor Red
        exit 1
    }

    # Upload signed cert to NEW server
    $uploadSigned = @"
`$dir = 'C:\temp\migration-certs'
New-Item -Path `$dir -ItemType Directory -Force | Out-Null
`$bytes = [Convert]::FromBase64String('$signedB64')
[IO.File]::WriteAllBytes("`$dir\NewCA-signed.cer", `$bytes)
Write-Output "SIGNED_PATH:`$dir\NewCA-signed.cer"
"@
    $uploadSignedResult = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -InlineScript $uploadSigned
    $signedCertPathOnNew = "C:\temp\migration-certs\NewCA-signed.cer"
    Write-Host "  [TRANSFER] Signed cert at: $signedCertPathOnNew on $newVM" -ForegroundColor Gray
    Write-Host ""

    # -- TRANSFER: Root CA cert + CRL from Parent -> NEW (CRL pre-cache) ------
    # The signed ICA cert has CRL DP and AIA pointing to the parent CA hostname
    # (e.g., file:///dhsm-adcs-vm/CertEnroll/HSB-RootCA.crl). This is unreachable
    # cross-VNet, so certutil -installcert and certutil -verify will fail or pop
    # a GUI dialog. We pre-cache the Root CA cert + CRL locally and set up a
    # hostname redirect so the file:/// URIs resolve to localhost.
    Write-Host "  [CRL PRE-CACHE] Setting up Root CA trust + CRL cache on $newVM..." -ForegroundColor Yellow

    # 1. Fetch Root CA cert and CRL from parent VM
    $fetchRootCRL = @"
`$dir = 'C:\temp\migration-crl-export'
New-Item -Path `$dir -ItemType Directory -Force | Out-Null

# Export Root CA cert - try certutil -ca.cert first, fall back to Root store export
certutil -ca.cert "`$dir\RootCA.cer" 2>&1 | Out-Null
if (-not (Test-Path "`$dir\RootCA.cer")) {
    # certsvc may not be running -- export from the Trusted Root store instead
    `$parentCAName = '$parentCAName'
    certutil -store Root `$parentCAName "`$dir\RootCA.cer" 2>&1 | Out-Null
}

# Find CRL file - check CertEnroll directory
`$crlDir = 'C:\Windows\system32\CertSrv\CertEnroll'
`$crlFile = Get-ChildItem `$crlDir -Filter '*.crl' -EA SilentlyContinue | Select-Object -First 1
if (`$crlFile) {
    Copy-Item `$crlFile.FullName "`$dir\RootCA.crl" -Force
}

# Also grab any .crt files from CertEnroll (for AIA)
Get-ChildItem `$crlDir -Filter '*.crt' -EA SilentlyContinue | ForEach-Object {
    Copy-Item `$_.FullName "`$dir\`$(`$_.Name)" -Force
}

# Base64 encode everything for transfer
if (Test-Path "`$dir\RootCA.cer") {
    Write-Output ("ROOTCERT_B64:" + [Convert]::ToBase64String([IO.File]::ReadAllBytes("`$dir\RootCA.cer")))
}
if (Test-Path "`$dir\RootCA.crl") {
    Write-Output ("ROOTCRL_B64:" + [Convert]::ToBase64String([IO.File]::ReadAllBytes("`$dir\RootCA.crl")))
}
# Send all CertEnroll filenames for AIA
Get-ChildItem `$crlDir -EA SilentlyContinue | ForEach-Object {
    `$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes(`$_.FullName))
    Write-Output ("CERTENROLL_FILE:" + `$_.Name + "|" + `$b64)
}
Write-Output ("PARENT_HOSTNAME:" + `$env:COMPUTERNAME)
"@
    $crlFetchResult = Invoke-RemoteScript -ResourceGroup $parentRG -VMName $parentVM -InlineScript $fetchRootCRL
    Write-Host "  [CRL PRE-CACHE] Fetched Root CA cert + CRL from $parentVM" -ForegroundColor Gray

    # Parse the results
    $rootCertB64 = ""; $rootCrlB64 = ""; $parentHostname = ""
    $certEnrollFiles = @{}
    foreach ($line in ($crlFetchResult.Message -split "`n")) {
        $line = $line.Trim()
        if ($line -match '^ROOTCERT_B64:(.+)') { $rootCertB64 = $Matches[1] }
        if ($line -match '^ROOTCRL_B64:(.+)') { $rootCrlB64 = $Matches[1] }
        if ($line -match '^PARENT_HOSTNAME:(.+)') { $parentHostname = $Matches[1] }
        if ($line -match '^CERTENROLL_FILE:([^|]+)\|(.+)') {
            $certEnrollFiles[$Matches[1]] = $Matches[2]
        }
    }

    # Diagnostic: verify we captured the root cert
    if ($rootCertB64) {
        Write-Host "    Root CA cert captured ($($rootCertB64.Length) chars base64)" -ForegroundColor DarkGray
    } else {
        Write-Host "    [WARN] Root CA cert NOT captured from $parentVM! CRL pre-cache will fail." -ForegroundColor Yellow
        Write-Host "           Raw output ($($crlFetchResult.Message.Length) chars):" -ForegroundColor Yellow
        Write-Host "           $($crlFetchResult.Message.Substring(0, [Math]::Min(500, $crlFetchResult.Message.Length)))" -ForegroundColor Yellow
    }
    if ($parentHostname) {
        Write-Host "    Parent hostname: $parentHostname" -ForegroundColor DarkGray
    } else {
        Write-Host "    [WARN] Parent hostname NOT captured from fetch output." -ForegroundColor Yellow
    }

    # 2. Upload Root CA cert + CRL to NEW VM and set up CRL pre-cache
    $certEnrollFilesCode = ""
    foreach ($fname in $certEnrollFiles.Keys) {
        $fb64 = $certEnrollFiles[$fname]
        $certEnrollFilesCode += "`n[IO.File]::WriteAllBytes('C:\CertEnroll\$fname', [Convert]::FromBase64String('$fb64'))`nWrite-Output 'Cached: $fname'"
    }

    $setupCRLCache = @"
# Install Root CA cert in Root trust store
Write-Output '--- INSTALLING ROOT CA CERT ---'
`$rootBytes = [Convert]::FromBase64String('$rootCertB64')
`$rootCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,`$rootBytes)
`$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','LocalMachine')
`$store.Open('ReadWrite')
`$existing = `$store.Certificates | Where-Object { `$_.Thumbprint -eq `$rootCert.Thumbprint }
if (-not `$existing) {
    `$store.Add(`$rootCert)
    Write-Output ('Installed Root CA: ' + `$rootCert.Subject + ' (Thumb: ' + `$rootCert.Thumbprint + ')')
} else {
    Write-Output ('Root CA already in store: ' + `$rootCert.Subject)
}
`$store.Close()

# Create CertEnroll directory and populate with CRL + certs
Write-Output '--- SETTING UP CERTENROLL CACHE ---'
New-Item -Path 'C:\CertEnroll' -ItemType Directory -Force | Out-Null
if ('$rootCrlB64') {
    [IO.File]::WriteAllBytes('C:\CertEnroll\RootCA.crl', [Convert]::FromBase64String('$rootCrlB64'))
    Write-Output 'Cached: RootCA.crl'
}
$certEnrollFilesCode

# Set up hosts file redirect: parent hostname -> 127.0.0.1
Write-Output '--- HOSTS FILE REDIRECT ---'
`$hostsPath = 'C:\Windows\System32\drivers\etc\hosts'
`$hostsContent = Get-Content `$hostsPath -EA SilentlyContinue
`$parentHost = '$parentHostname'.ToLower()
`$hasEntry = `$hostsContent | Where-Object { `$_ -match `$parentHost }
if (-not `$hasEntry) {
    Add-Content `$hostsPath ("127.0.0.1 " + `$parentHost)
    Write-Output ('Added hosts entry: 127.0.0.1 ' + `$parentHost)
} else {
    Write-Output ('Hosts entry already exists for ' + `$parentHost)
}

# Enable DisableLoopbackCheck for SMB loopback
Write-Output '--- LOOPBACK CHECK ---'
`$lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
`$dlc = Get-ItemProperty `$lsa -Name DisableLoopbackCheck -EA SilentlyContinue
if (-not `$dlc) {
    New-ItemProperty `$lsa -Name DisableLoopbackCheck -Value 1 -PropertyType DWORD -Force | Out-Null
    Write-Output 'Set DisableLoopbackCheck = 1'
} else {
    Write-Output 'DisableLoopbackCheck already set'
}

# Create CertEnroll SMB share
Write-Output '--- SMB SHARE ---'
`$share = Get-SmbShare -Name CertEnroll -EA SilentlyContinue
if (-not `$share) {
    New-SmbShare -Name CertEnroll -Path 'C:\CertEnroll' -ReadAccess 'Everyone' -EA SilentlyContinue | Out-Null
    Write-Output 'Created CertEnroll SMB share'
} else {
    Write-Output 'CertEnroll SMB share already exists'
}

Write-Output '--- CRL PRE-CACHE COMPLETE ---'
Get-ChildItem 'C:\CertEnroll' -EA SilentlyContinue | ForEach-Object { Write-Output ('  ' + `$_.Name) }
"@
    $crlSetupResult = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -InlineScript $setupCRLCache
    Write-Host "  [CRL PRE-CACHE] Setup complete on $newVM" -ForegroundColor Gray
    # Show ALL output for diagnostics
    foreach ($line in ($crlSetupResult.Message -split "`n")) {
        $l = $line.Trim()
        if ($l) {
            Write-Host "    $l" -ForegroundColor DarkGray
        }
    }
    if ($crlSetupResult.StdErr) {
        Write-Host "  [CRL PRE-CACHE] STDERR on $newVM`:" -ForegroundColor Yellow
        foreach ($line in ($crlSetupResult.StdErr -split "`n")) {
            $l = $line.Trim()
            if ($l) { Write-Host "    $l" -ForegroundColor Yellow }
        }
    }
    Write-Host ""

    # STEP 4 -- Validate Signed Cert (NEW server) -- needs SignedCertPath
    $step4Src = (Get-ChildItem $stepDir -Filter "Step4-*.ps1").FullName
    $step4Wrapper = Join-Path $wrapperDir "Step4-wrapper.ps1"
    New-Wrapper -SourceScript $step4Src -Params @{
        SignedCertPath = $signedCertPathOnNew
    } -WrapperPath $step4Wrapper

    Write-StepBanner 4 "ValidateNewCACert" $newVM "NEW"
    $r4 = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -ScriptPath $step4Wrapper
    Record-Step 4 "ValidateNewCACert" $newVM $r4

    # STEP 5 -- Pre-Distribute (NEW server) -- needs SignedCertPath
    $step5Src = (Get-ChildItem $stepDir -Filter "Step5-*.ps1").FullName
    $step5Wrapper = Join-Path $wrapperDir "Step5-wrapper.ps1"
    New-Wrapper -SourceScript $step5Src -Params @{
        SignedCertPath = $signedCertPathOnNew
        SkipADPublish  = [bool]$p.trust.skipADPublish
    } -WrapperPath $step5Wrapper

    Write-StepBanner 5 "PreDistribute" $newVM "NEW"
    $r5 = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -ScriptPath $step5Wrapper
    Record-Step 5 "PreDistribute" $newVM $r5

    # -- STEP 6: Manual activation via RDP ------------------------------------------
    # The Cavium KSP (Azure Cloud HSM) requires an interactive Windows logon session
    # for certutil -installcert. This cannot be automated via az vm run-command,
    # scheduled tasks, or any non-interactive method.

    # Get VM IP for RDP connection guide
    $vmIpRaw = az vm list-ip-addresses --resource-group $newRG --name $newVM `
        --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv 2>$null
    if (-not $vmIpRaw) {
        $vmIpRaw = az vm list-ip-addresses --resource-group $newRG --name $newVM `
            --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv 2>$null
    }
    $vmIp = if ($vmIpRaw) { $vmIpRaw.Trim() } else { "(unable to determine -- check Azure Portal)" }

    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Yellow
    Write-Host "  Steps 1-5 COMPLETE - Manual Step Required" -ForegroundColor Yellow
    Write-Host ("=" * 70) -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Steps 1-5 automated successfully." -ForegroundColor Green
    Write-Host ""
    Write-Host "  STEP 6: Activate New CA (Manual Step)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  The Cavium KSP (Azure Cloud HSM) requires an interactive" -ForegroundColor White
    Write-Host "  Windows logon session for certutil -installcert. This" -ForegroundColor White
    Write-Host "  command cannot run via az vm run-command or scheduled tasks." -ForegroundColor White
    Write-Host ""
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |  RDP CONNECTION                                          |" -ForegroundColor Cyan
    Write-Host "  |  VM Name:   $($newVM.PadRight(45))|" -ForegroundColor Cyan
    Write-Host "  |  IP:        $($vmIp.PadRight(45))|" -ForegroundColor Cyan
    Write-Host "  |  Username:  $($newVmAdmin.PadRight(45))|" -ForegroundColor Cyan
    Write-Host "  |                                                          |" -ForegroundColor Cyan
    Write-Host "  |  Quick connect (copy/paste into Run or terminal):        |" -ForegroundColor Cyan
    Write-Host "  |  mstsc /v:$($vmIp.PadRight(47))|" -ForegroundColor Cyan
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Open an elevated PowerShell prompt on $newVM" -ForegroundColor White
    Write-Host "  and run the following commands in order:" -ForegroundColor White
    Write-Host ""
    Write-Host "  certutil -f -installcert `"$signedCertPathOnNew`"" -ForegroundColor White
    Write-Host "  certutil -setreg CA\CRLFlags +CRLF_REVCHECK_IGNORE_OFFLINE" -ForegroundColor White
    Write-Host "  net start certsvc" -ForegroundColor White
    Write-Host "  certutil -cainfo name" -ForegroundColor White
    Write-Host "  certutil -CRL" -ForegroundColor White
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Yellow
    Write-Host ""

    # Pause for user to complete manual step
    do {
        $proceed = Read-Host "  Type 'proceed' and press Enter after completing Step 6 on the VM"
    } while ($proceed -ne 'proceed')

    Write-Host ""
    Write-Host "  [INFO] Verifying VM is responsive..." -ForegroundColor Gray
    $jmesQuery = 'instanceView.statuses[?starts_with(code,`PowerState/`)].displayStatus | [0]'
    $vmState = az vm get-instance-view --resource-group $newRG --name $newVM --query $jmesQuery -o tsv 2>$null
    if ($vmState -notmatch 'running') {
        Write-Host "  [WARN] VM may not be running (state: $vmState). Waiting for VM..." -ForegroundColor Yellow
        az vm start --resource-group $newRG --name $newVM --no-wait 2>$null
        Start-Sleep -Seconds 30
    }

    # Verify Step 6 actually completed on the VM
    Write-Host ""
    Write-StepBanner 6 "ActivateNewCA (verify)" $newVM "NEW"
    $verifyScript = @"
`$caName = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA SilentlyContinue).Active
`$svc = Get-Service certsvc -EA SilentlyContinue
if (`$caName -and `$svc.Status -eq 'Running') {
    Write-Host "[PASS] CA '$caName' is active and certsvc is Running"
} else {
    Write-Host "[FAIL] CA not active or certsvc not running (Active='`$caName', certsvc='`$(`$svc.Status)')"
    exit 1
}
"@
    $verifyFile = Join-Path $wrapperDir "Step6-verify.ps1"
    $verifyScript | Out-File -FilePath $verifyFile -Encoding ASCII -Force
    $r6 = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -ScriptPath $verifyFile
    Record-Step 6 "ActivateNewCA" $newVM $r6

    # STEP 7 -- Validate Cutover (NEW server)
    $step7Src = (Get-ChildItem $stepDir -Filter "Step7-*.ps1").FullName
    Write-StepBanner 7 "ValidateIssuance" $newVM "NEW"
    $r7 = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -ScriptPath $step7Src
    Record-Step 7 "ValidateIssuance" $newVM $r7

    # STEP 8 -- Decommission Checks (OLD server)
    $step8Src = (Get-ChildItem $stepDir -Filter "Step8-*.ps1").FullName
    Write-StepBanner 8 "DecommissionChecks" $oldVM "OLD"
    $r8 = Invoke-RemoteScript -ResourceGroup $oldRG -VMName $oldVM -ScriptPath $step8Src
    Record-Step 8 "DecommissionChecks" $oldVM $r8
}

#--- Scenario B, Option 2: IssuingCA + CrossSigned ----------------------------

if ($p.scenario -eq 'IssuingCA' -and $p.option -eq 'CrossSigned') {

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  ADCS Migration Started" -ForegroundColor Cyan
    Write-Host "  Scenario: $($p.scenario) | Option: $($p.option)" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""

    # STEP 1 -- Capture Existing CA (OLD server)
    $step1Src = (Get-ChildItem $stepDir -Filter "Step1-*.ps1").FullName

    if ($p.oldServer.caCommonName) {
        $step1Wrapper = Join-Path $wrapperDir "Step1-wrapper.ps1"
        New-Wrapper -SourceScript $step1Src -Params @{ CAName = $p.oldServer.caCommonName } -WrapperPath $step1Wrapper
        $step1Run = $step1Wrapper
    } else {
        $step1Run = $step1Src
    }

    Write-StepBanner 1 "CaptureExistingCA" $oldVM "OLD"
    $r1 = Invoke-RemoteScript -ResourceGroup $oldRG -VMName $oldVM -ScriptPath $step1Run
    Record-Step 1 "CaptureExistingCA" $oldVM $r1

    # -- TRANSFER: Step 1 output JSON to NEW server --
    Write-Host ""
    Write-Host "  [TRANSFER] Exporting Step 1 data from $oldVM..." -ForegroundColor Yellow

    $fetchStep1 = @"
`$dir = Get-ChildItem 'C:\Windows\system32\config\systemprofile\ica-crosssign-step1-*' -Directory -EA SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not `$dir) {
    `$dir = Get-ChildItem 'C:\Users\*\ica-crosssign-step1-*' -Directory -EA SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if (-not `$dir) {
    `$dir = Get-ChildItem 'C:\Windows\system32\config\systemprofile\adcs-migration-step1-*' -Directory -EA SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if (-not `$dir) {
    `$dir = Get-ChildItem 'C:\Users\*\adcs-migration-step1-*' -Directory -EA SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if (`$dir) {
    `$jsonBytes = [IO.File]::ReadAllBytes((Join-Path `$dir.FullName 'ca-migration-details.json'))
    `$jsonB64 = [Convert]::ToBase64String(`$jsonBytes)
    Write-Output "JSON_B64:`$jsonB64"
    `$cert = Join-Path `$dir.FullName 'OldIssuingCA.cer'
    if (Test-Path `$cert) {
        `$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes(`$cert))
        Write-Output "CERT_B64:`$b64"
    }
    Write-Output "DIR:`$(`$dir.FullName)"
} else { Write-Output "ERROR:No step1 output found" }
"@
    $fetchResult = Invoke-RemoteScript -ResourceGroup $oldRG -VMName $oldVM -InlineScript $fetchStep1
    $step1JsonB64 = ""; $step1CertB64 = ""; $step1DirOnOld = ""
    foreach ($line in ($fetchResult.Message -split "`n")) {
        $line = $line.Trim()
        if ($line -match '^JSON_B64:(.+)') { $step1JsonB64 = $Matches[1] }
        if ($line -match '^CERT_B64:(.+)') { $step1CertB64 = $Matches[1] }
        if ($line -match '^DIR:(.+)') { $step1DirOnOld = $Matches[1] }
    }

    # Upload Step 1 data to NEW server
    $uploadStep1 = @"
`$dir = 'C:\temp\migration-step1-data'
New-Item -Path `$dir -ItemType Directory -Force | Out-Null
`$jsonBytes = [Convert]::FromBase64String('$step1JsonB64')
[IO.File]::WriteAllBytes("`$dir\ca-migration-details.json", `$jsonBytes)
if ('$step1CertB64') {
    `$certBytes = [Convert]::FromBase64String('$step1CertB64')
    [IO.File]::WriteAllBytes("`$dir\OldIssuingCA.cer", `$certBytes)
}
Write-Output "UPLOADED:`$dir"
"@
    $uploadResult = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -InlineScript $uploadStep1
    $step1DirOnNew = "C:\temp\migration-step1-data"
    Write-Host "  [TRANSFER] Step 1 data uploaded to $newVM at $step1DirOnNew" -ForegroundColor Gray
    Write-Host ""

    # STEP 2 -- Validate New CA Server (NEW server)
    $step2Src = (Get-ChildItem $stepDir -Filter "Step2-*.ps1").FullName
    Write-StepBanner 2 "ValidateNewCAServer" $newVM "NEW"
    $r2 = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -ScriptPath $step2Src
    Record-Step 2 "ValidateNewCAServer" $newVM $r2

    # STEP 3 -- Configure Subordinate CA + Generate CSR (NEW server)
    $step3Src = (Get-ChildItem $stepDir -Filter "Step3-*.ps1").FullName
    $step3Wrapper = Join-Path $wrapperDir "Step3-wrapper.ps1"
    New-Wrapper -SourceScript $step3Src -Params @{
        Step1OutputDir    = $step1DirOnNew
        KeyAlgorithm      = if ($p.newCA.PSObject.Properties['keyAlgorithm']) { $p.newCA.keyAlgorithm } else { '' }
        KeyLength         = $p.newCA.keyLength
        HashAlgorithm     = $p.newCA.hashAlgorithm
        SubjectName       = $caName
        OverwriteExisting = $true
    } -WrapperPath $step3Wrapper

    Write-StepBanner 3 "GenerateCSR" $newVM "NEW"
    $r3 = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -ScriptPath $step3Wrapper
    Record-Step 3 "GenerateCSR" $newVM $r3

    # -- TRANSFER: CSR from NEW -> Parent CA (Root CA) for signing --
    Write-Host ""
    Write-Host "  [TRANSFER] Exporting CSR from $newVM to $parentVM (Root CA) for signing..." -ForegroundColor Yellow

    $fetchCSR = @"
`$dir = Get-ChildItem 'C:\Windows\system32\config\systemprofile\ica-crosssign-step3-*' -Directory -EA SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not `$dir) {
    `$dir = Get-ChildItem 'C:\Users\*\ica-crosssign-step3-*' -Directory -EA SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if (-not `$dir) {
    `$dir = Get-ChildItem 'C:\Windows\system32\config\systemprofile\adcs-migration-step3-*' -Directory -EA SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if (`$dir) {
    `$req = Get-ChildItem `$dir.FullName -Filter '*.req' | Select-Object -First 1
    if (`$req) {
        `$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes(`$req.FullName))
        Write-Output "CSR_B64:`$b64"
        Write-Output "CSR_PATH:`$(`$req.FullName)"
    }
} else { Write-Output "ERROR:No step3 output found" }
"@
    $csrResult = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -InlineScript $fetchCSR
    $csrB64 = ""
    foreach ($line in ($csrResult.Message -split "`n")) {
        if ($line.Trim() -match '^CSR_B64:(.+)') { $csrB64 = $Matches[1] }
    }

    if (-not $csrB64) {
        Write-Host "  [ERROR] CSR not found on $newVM. CSR fetch output:" -ForegroundColor Red
        Write-Host ($csrResult.Message | Out-String) -ForegroundColor Gray
        if ($csrResult.StdErr) { Write-Host "  [STDERR] $($csrResult.StdErr)" -ForegroundColor Yellow }
        Write-Host "  [FATAL] Cannot submit empty CSR to Root CA. Aborting." -ForegroundColor Red
        exit 1
    }
    Write-Host "  [TRANSFER] CSR extracted ($($csrB64.Length) chars base64)" -ForegroundColor Gray

    # Upload CSR to Parent (Root CA) and submit for signing
    $parentCAName = ($parentConfig -split '\\')[-1]
    $submitCSR = @"
`$ErrorActionPreference = 'Continue'
`$dir = 'C:\temp\migration-csr'
New-Item -Path `$dir -ItemType Directory -Force | Out-Null
# B2 signing block -- COM approach (proven in B1, Finding 5: certreq hangs in Session 0)
# Ensure SafeNet Luna headless mode (no PIN popup in Session 0)
`$lunaPath = 'HKLM:\SOFTWARE\SafeNet\LunaClient'
if (Test-Path `$lunaPath) {
    `$iv = (Get-ItemProperty -Path `$lunaPath -Name 'Interactive' -EA SilentlyContinue).Interactive
    if (`$iv -ne 0) {
        Set-ItemProperty -Path `$lunaPath -Name 'Interactive' -Value 0
        Write-Output 'Set SafeNet Interactive=0 for headless HSM access'
    }
}
`$bytes = [Convert]::FromBase64String('$csrB64')
[IO.File]::WriteAllBytes("`$dir\NewCA.req", `$bytes)
Write-Output "CSR written to `$dir\NewCA.req (`$(`$bytes.Length) bytes)"

# Ensure certsvc is running and responsive
Start-Service certsvc -EA SilentlyContinue
Set-Service certsvc -StartupType Automatic -EA SilentlyContinue
`$caReady = `$false
for (`$w = 1; `$w -le 10; `$w++) {
    Start-Sleep 3
    `$ping = & certutil -config "$parentConfig" -ping 2>&1 | Out-String
    if (`$ping -match 'interface is alive') { `$caReady = `$true; break }
    Write-Output "Waiting for certsvc... attempt `$w/10"
}
if (`$caReady) { Write-Output "certsvc is responsive" } else { Write-Output "WARNING: certsvc not responsive after 30s" }

# --- COM Submit + certutil resubmit + certreq retrieve (proven B1 approach) ---
`$csrContent = Get-Content "`$dir\NewCA.req" -Raw
Write-Output "Submitting CSR via COM CertificateAuthority.Request..."

`$CertRequest = New-Object -ComObject CertificateAuthority.Request

# Flag 0x0 = CR_IN_BASE64HEADER (PEM with BEGIN/END headers)
`$disposition = `$CertRequest.Submit(0x0, `$csrContent, "CommonName:$caName", "$parentConfig")
`$requestId = `$CertRequest.GetRequestId()
Write-Output "COM Submit: RequestId=`$requestId, Disposition=`$disposition"

if (`$disposition -eq 5) {
    Write-Output "Request is PENDING (expected). Approving with certutil -resubmit `$requestId..."
    `$resubOut = & certutil -resubmit `$requestId 2>&1 | Out-String
    Write-Output "certutil -resubmit output: `$resubOut"
    Start-Sleep 2
    Write-Output "Retrieving signed cert with certreq -retrieve..."
    `$retrieveOut = & certreq -retrieve -f -config "$parentConfig" `$requestId "`$dir\NewCA-signed.cer" 2>&1 | Out-String
    Write-Output "certreq -retrieve output: `$retrieveOut"
} elseif (`$disposition -eq 3) {
    `$certPem = `$CertRequest.GetCertificate(0x0)
    Set-Content "`$dir\NewCA-signed.cer" `$certPem -Encoding ASCII
    Write-Output "Cert issued immediately (disposition 3)"
} else {
    Write-Output "ERROR: Unexpected disposition `$disposition"
    `$dispMsg = `$CertRequest.GetDispositionMessage()
    Write-Output "DispositionMessage: `$dispMsg"
}

# Check result
if (Test-Path "`$dir\NewCA-signed.cer") {
    `$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes("`$dir\NewCA-signed.cer"))
    Write-Output "SIGNED_B64:`$b64"
    Write-Output "SIGNED_PATH:`$dir\NewCA-signed.cer"
} else {
    Write-Output "No cert file after resubmit+retrieve."
    Write-Output 'ERROR:Signed cert not created'
}
"@
    $submitResult = Invoke-RemoteScript -ResourceGroup $parentRG -VMName $parentVM -InlineScript $submitCSR
    $signedB64 = ""
    foreach ($line in ($submitResult.Message -split "`n")) {
        if ($line.Trim() -match '^SIGNED_B64:(.+)') { $signedB64 = $Matches[1] }
    }

    if (-not $signedB64) {
        Write-Host "  [ERROR] Failed to retrieve signed certificate from Root CA ($parentVM)." -ForegroundColor Red
        Write-Host "          Raw stdout:" -ForegroundColor Yellow
        Write-Host ($submitResult.Message | Out-String) -ForegroundColor Gray
        if ($submitResult.StdErr) {
            Write-Host "          Raw stderr:" -ForegroundColor Yellow
            Write-Host ($submitResult.StdErr | Out-String) -ForegroundColor Gray
        }
        Write-Host "          RawJson (first 500):" -ForegroundColor Yellow
        Write-Host ($submitResult.RawJson.Substring(0, [Math]::Min(500, $submitResult.RawJson.Length))) -ForegroundColor Gray
        Write-Host "  [FATAL] Cannot continue without signed certificate. Aborting." -ForegroundColor Red
        exit 1
    }

    # Upload root-signed cert to NEW server (needed for Step 4 cross-signing AND Step 5 install)
    $uploadSigned = @"
`$dir = 'C:\temp\migration-certs'
New-Item -Path `$dir -ItemType Directory -Force | Out-Null
`$bytes = [Convert]::FromBase64String('$signedB64')
[IO.File]::WriteAllBytes("`$dir\NewCA-signed.cer", `$bytes)
Write-Output "SIGNED_PATH:`$dir\NewCA-signed.cer"
"@
    $uploadSignedResult = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -InlineScript $uploadSigned
    $signedCertPathOnNew = "C:\temp\migration-certs\NewCA-signed.cer"
    Write-Host "  [TRANSFER] Signed cert at: $signedCertPathOnNew on $newVM" -ForegroundColor Gray

    # Also upload the root-signed cert to OLD server for cross-signing in Step 4
    $uploadSignedToOld = @"
`$dir = 'C:\temp\migration-certs'
New-Item -Path `$dir -ItemType Directory -Force | Out-Null
`$bytes = [Convert]::FromBase64String('$signedB64')
[IO.File]::WriteAllBytes("`$dir\NewCA-signed.cer", `$bytes)
Write-Output "SIGNED_PATH:`$dir\NewCA-signed.cer"
"@
    $uploadOldResult = Invoke-RemoteScript -ResourceGroup $oldRG -VMName $oldVM -InlineScript $uploadSignedToOld
    $signedCertPathOnOld = "C:\temp\migration-certs\NewCA-signed.cer"
    Write-Host "  [TRANSFER] Signed cert at: $signedCertPathOnOld on $oldVM (for cross-signing)" -ForegroundColor Gray
    Write-Host ""

    # -- CRL PRE-CACHE: Root CA trust + CRL on NEW VM (same as B1) --
    Write-Host "  [CRL PRE-CACHE] Setting up Root CA trust + CRL cache on $newVM..." -ForegroundColor Yellow

    $fetchRootCRL = @"
`$dir = 'C:\temp\migration-crl-export'
New-Item -Path `$dir -ItemType Directory -Force | Out-Null
certutil -ca.cert "`$dir\RootCA.cer" 2>&1 | Out-Null
if (-not (Test-Path "`$dir\RootCA.cer")) {
    `$parentCAName = '$parentCAName'
    certutil -store Root `$parentCAName "`$dir\RootCA.cer" 2>&1 | Out-Null
}
`$crlDir = 'C:\Windows\system32\CertSrv\CertEnroll'
`$crlFile = Get-ChildItem `$crlDir -Filter '*.crl' -EA SilentlyContinue | Select-Object -First 1
if (`$crlFile) { Copy-Item `$crlFile.FullName "`$dir\RootCA.crl" -Force }
Get-ChildItem `$crlDir -Filter '*.crt' -EA SilentlyContinue | ForEach-Object {
    Copy-Item `$_.FullName "`$dir\`$(`$_.Name)" -Force
}
if (Test-Path "`$dir\RootCA.cer") {
    Write-Output ("ROOTCERT_B64:" + [Convert]::ToBase64String([IO.File]::ReadAllBytes("`$dir\RootCA.cer")))
}
if (Test-Path "`$dir\RootCA.crl") {
    Write-Output ("ROOTCRL_B64:" + [Convert]::ToBase64String([IO.File]::ReadAllBytes("`$dir\RootCA.crl")))
}
Get-ChildItem `$crlDir -EA SilentlyContinue | ForEach-Object {
    `$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes(`$_.FullName))
    Write-Output ("CERTENROLL_FILE:" + `$_.Name + "|" + `$b64)
}
Write-Output ("PARENT_HOSTNAME:" + `$env:COMPUTERNAME)
"@
    $crlFetchResult = Invoke-RemoteScript -ResourceGroup $parentRG -VMName $parentVM -InlineScript $fetchRootCRL
    Write-Host "  [CRL PRE-CACHE] Fetched Root CA cert + CRL from $parentVM" -ForegroundColor Gray

    $rootCertB64 = ""; $rootCrlB64 = ""; $parentHostname = ""
    $certEnrollFiles = @{}
    foreach ($line in ($crlFetchResult.Message -split "`n")) {
        $line = $line.Trim()
        if ($line -match '^ROOTCERT_B64:(.+)') { $rootCertB64 = $Matches[1] }
        if ($line -match '^ROOTCRL_B64:(.+)') { $rootCrlB64 = $Matches[1] }
        if ($line -match '^PARENT_HOSTNAME:(.+)') { $parentHostname = $Matches[1] }
        if ($line -match '^CERTENROLL_FILE:([^|]+)\|(.+)') {
            $certEnrollFiles[$Matches[1]] = $Matches[2]
        }
    }

    $certEnrollFilesCode = ""
    foreach ($fname in $certEnrollFiles.Keys) {
        $fb64 = $certEnrollFiles[$fname]
        $certEnrollFilesCode += "`n[IO.File]::WriteAllBytes('C:\CertEnroll\$fname', [Convert]::FromBase64String('$fb64'))`nWrite-Output 'Cached: $fname'"
    }

    $setupCRLCache = @"
Write-Output '--- INSTALLING ROOT CA CERT ---'
`$rootBytes = [Convert]::FromBase64String('$rootCertB64')
`$rootCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,`$rootBytes)
`$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','LocalMachine')
`$store.Open('ReadWrite')
`$existing = `$store.Certificates | Where-Object { `$_.Thumbprint -eq `$rootCert.Thumbprint }
if (-not `$existing) {
    `$store.Add(`$rootCert)
    Write-Output ('Installed Root CA: ' + `$rootCert.Subject + ' (Thumb: ' + `$rootCert.Thumbprint + ')')
} else {
    Write-Output ('Root CA already in store: ' + `$rootCert.Subject)
}
`$store.Close()
Write-Output '--- SETTING UP CERTENROLL CACHE ---'
New-Item -Path 'C:\CertEnroll' -ItemType Directory -Force | Out-Null
if ('$rootCrlB64') {
    [IO.File]::WriteAllBytes('C:\CertEnroll\RootCA.crl', [Convert]::FromBase64String('$rootCrlB64'))
    Write-Output 'Cached: RootCA.crl'
}
$certEnrollFilesCode
Write-Output '--- HOSTS FILE REDIRECT ---'
`$hostsPath = 'C:\Windows\System32\drivers\etc\hosts'
`$hostsContent = Get-Content `$hostsPath -EA SilentlyContinue
`$parentHost = '$parentHostname'.ToLower()
`$hasEntry = `$hostsContent | Where-Object { `$_ -match `$parentHost }
if (-not `$hasEntry) {
    Add-Content `$hostsPath ("127.0.0.1 " + `$parentHost)
    Write-Output ('Added hosts entry: 127.0.0.1 ' + `$parentHost)
} else {
    Write-Output ('Hosts entry already exists for ' + `$parentHost)
}
Write-Output '--- LOOPBACK CHECK ---'
`$lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
`$dlc = Get-ItemProperty `$lsa -Name DisableLoopbackCheck -EA SilentlyContinue
if (-not `$dlc) {
    New-ItemProperty `$lsa -Name DisableLoopbackCheck -Value 1 -PropertyType DWORD -Force | Out-Null
    Write-Output 'Set DisableLoopbackCheck = 1'
} else {
    Write-Output 'DisableLoopbackCheck already set'
}
Write-Output '--- SMB SHARE ---'
`$share = Get-SmbShare -Name CertEnroll -EA SilentlyContinue
if (-not `$share) {
    New-SmbShare -Name CertEnroll -Path 'C:\CertEnroll' -ReadAccess 'Everyone' -EA SilentlyContinue | Out-Null
    Write-Output 'Created CertEnroll SMB share'
} else {
    Write-Output 'CertEnroll SMB share already exists'
}
Write-Output '--- CRL PRE-CACHE COMPLETE ---'
"@
    $crlSetupResult = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -InlineScript $setupCRLCache
    Write-Host "  [CRL PRE-CACHE] Setup complete on $newVM" -ForegroundColor Gray
    foreach ($line in ($crlSetupResult.Message -split "`n")) {
        $l = $line.Trim()
        if ($l -match '^Installed|^Cached|^Added|^Set |^Created|^--- CRL') {
            Write-Host "    $l" -ForegroundColor DarkGray
        }
    }
    Write-Host ""

    # STEP 4 -- Cross-Sign New CA (OLD server) -- needs NewCACertPath (the root-signed cert)
    $step4Src = (Get-ChildItem $stepDir -Filter "Step4-*.ps1").FullName
    $step4Wrapper = Join-Path $wrapperDir "Step4-wrapper.ps1"
    New-Wrapper -SourceScript $step4Src -Params @{
        NewCACertPath = $signedCertPathOnOld
        ValidityYears = [int]$p.newCA.validityYears
    } -WrapperPath $step4Wrapper

    Write-StepBanner 4 "CrossSignNewCA" $oldVM "OLD"
    $r4 = Invoke-RemoteScript -ResourceGroup $oldRG -VMName $oldVM -ScriptPath $step4Wrapper
    Record-Step 4 "CrossSignNewCA" $oldVM $r4

    # -- TRANSFER: Cross-cert + old ICA cert from OLD -> NEW --
    Write-Host ""
    Write-Host "  [TRANSFER] Exporting cross-signed cert from $oldVM..." -ForegroundColor Yellow

    $exportCrossCert = @"
`$dirs = Get-ChildItem 'C:\Windows\system32\config\systemprofile\ica-crosssign-step4-*' -Directory -EA SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not `$dirs) {
    `$dirs = Get-ChildItem 'C:\Users\*\ica-crosssign-step4-*' -Directory -EA SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if (`$dirs) {
    `$crossCert = Get-ChildItem `$dirs.FullName -Filter '*CrossSigned*' -Recurse | Select-Object -First 1
    `$oldCert = Get-ChildItem `$dirs.FullName -Filter '*OldIssuingCA*' -Recurse | Select-Object -First 1
    if (-not `$oldCert) {
        `$oldCert = Get-ChildItem `$dirs.FullName -Filter '*OldICA*' -Recurse | Select-Object -First 1
    }
    if (`$crossCert) {
        `$bytes = [IO.File]::ReadAllBytes(`$crossCert.FullName)
        Write-Output "CROSSCERT_B64:BEGIN"
        Write-Output ([Convert]::ToBase64String(`$bytes))
        Write-Output "CROSSCERT_PATH:`$(`$crossCert.FullName)"
    }
    if (`$oldCert) {
        `$bytes2 = [IO.File]::ReadAllBytes(`$oldCert.FullName)
        Write-Output "OLDCERT_B64:BEGIN"
        Write-Output ([Convert]::ToBase64String(`$bytes2))
        Write-Output "OLDCERT_PATH:`$(`$oldCert.FullName)"
    }
    Write-Output "DIR:`$(`$dirs.FullName)"
} else {
    Write-Output "ERROR:No step4 output directory found"
}
"@
    $exportResult = Invoke-RemoteScript -ResourceGroup $oldRG -VMName $oldVM -InlineScript $exportCrossCert

    $crossB64 = ""; $oldICACertB64 = ""
    $lines = $exportResult.Message -split "`n"
    $nextIsCross = $false; $nextIsOld = $false
    foreach ($line in $lines) {
        $line = $line.Trim()
        if ($line -match '^CROSSCERT_B64:') { $nextIsCross = $true; continue }
        if ($line -match '^OLDCERT_B64:') { $nextIsOld = $true; continue }
        if ($nextIsCross -and $line.Length -gt 100 -and $line -match '^[A-Za-z0-9+/=]+$') {
            $crossB64 = $line; $nextIsCross = $false
        }
        if ($nextIsOld -and $line.Length -gt 100 -and $line -match '^[A-Za-z0-9+/=]+$') {
            $oldICACertB64 = $line; $nextIsOld = $false
        }
    }

    if (-not $crossB64) {
        Write-Host "  [FATAL] Failed to extract cross-cert from $oldVM step4 output" -ForegroundColor Red
        Write-Host "  [DEBUG] Export output:" -ForegroundColor Yellow
        Write-Host $exportResult.Message
        Write-Summary
        exit 1
    }

    # Upload cross-cert to NEW server
    Write-Host "  [TRANSFER] Uploading cross-signed cert to $newVM..." -ForegroundColor Yellow
    $crossImport = Import-CertToVM -ResourceGroup $newRG -VMName $newVM `
        -StoreName "CA" -Base64Cert $crossB64 -CertFileName "NewICA-CrossSigned.cer"
    $crossCertPathOnNew = $crossImport.CertPath
    Write-Host "  [TRANSFER] Cross-cert at: $crossCertPathOnNew" -ForegroundColor Gray

    # Upload old ICA cert to NEW server (for chain building)
    $oldICACertPathOnNew = ""
    if ($oldICACertB64) {
        Write-Host "  [TRANSFER] Uploading old ICA cert to $newVM..." -ForegroundColor Yellow
        $oldImport = Import-CertToVM -ResourceGroup $newRG -VMName $newVM `
            -StoreName "CA" -Base64Cert $oldICACertB64 -CertFileName "OldIssuingCA.cer"
        $oldICACertPathOnNew = $oldImport.CertPath
        Write-Host "  [TRANSFER] Old ICA cert at: $oldICACertPathOnNew" -ForegroundColor Gray
    }
    Write-Host ""

    # STEP 5 -- Publish Cross Cert + Activate (NEW server)
    # The Cavium KSP requires an interactive Windows logon session for
    # certutil -installcert. Copy the script to the VM and guide the user
    # to run it via RDP, then resume automation for Steps 6-8.

    $step5Src = (Get-ChildItem $stepDir -Filter "Step5-*.ps1").FullName

    # Build wrapper script content with params baked in, upload to VM
    $step5Wrapper = Join-Path $wrapperDir "Step5-wrapper.ps1"
    New-Wrapper -SourceScript $step5Src -Params @{
        SignedCertPath   = $signedCertPathOnNew
        CrossCertPath    = $crossCertPathOnNew
        OldICACertPath   = $oldICACertPathOnNew
        SkipConfirmation = $true
    } -WrapperPath $step5Wrapper

    # Upload wrapper to VM so user can run it from RDP
    $step5RemotePath = "C:\temp\migration-scripts\Step5-PublishCrossCert.ps1"
    $step5UploadScript = @"
New-Item -Path 'C:\temp\migration-scripts' -ItemType Directory -Force | Out-Null
Write-Output 'DIR_READY'
"@
    Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -InlineScript $step5UploadScript | Out-Null

    # Upload the wrapper script content via run-command
    $wrapperContent = Get-Content $step5Wrapper -Raw
    $wrapperB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($wrapperContent))
    $uploadScript = @"
`$bytes = [Convert]::FromBase64String('$wrapperB64')
`$text = [Text.Encoding]::UTF8.GetString(`$bytes)
Set-Content -Path '$step5RemotePath' -Value `$text -Encoding UTF8 -Force
Write-Output 'UPLOADED'
"@
    Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -InlineScript $uploadScript | Out-Null

    # Get VM IP for RDP connection guide
    $vmIpRaw = az vm list-ip-addresses --resource-group $newRG --name $newVM `
        --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv 2>$null
    if (-not $vmIpRaw) {
        $vmIpRaw = az vm list-ip-addresses --resource-group $newRG --name $newVM `
            --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv 2>$null
    }
    $vmIp = if ($vmIpRaw) { $vmIpRaw.Trim() } else { "(unable to determine - check Azure Portal)" }

    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Yellow
    Write-Host "  Steps 1-4 COMPLETE - Manual Step Required" -ForegroundColor Yellow
    Write-Host ("=" * 70) -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Steps 1-4 automated successfully." -ForegroundColor Green
    Write-Host ""
    Write-Host "  STEP 5: Publish Cross Cert + Activate CA (Manual Step)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  The Cavium KSP (Azure Cloud HSM) requires an interactive" -ForegroundColor White
    Write-Host "  Windows logon session for certutil -installcert. This" -ForegroundColor White
    Write-Host "  command cannot run via az vm run-command or scheduled tasks." -ForegroundColor White
    Write-Host ""
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |  RDP CONNECTION                                          |" -ForegroundColor Cyan
    Write-Host "  |  VM Name:   $($newVM.PadRight(45))|" -ForegroundColor Cyan
    Write-Host "  |  IP:        $($vmIp.PadRight(45))|" -ForegroundColor Cyan
    Write-Host "  |  Username:  $($newVmAdmin.PadRight(45))|" -ForegroundColor Cyan
    Write-Host "  |                                                          |" -ForegroundColor Cyan
    Write-Host "  |  Quick connect (copy/paste into Run or terminal):        |" -ForegroundColor Cyan
    Write-Host "  |  mstsc /v:$($vmIp.PadRight(47))|" -ForegroundColor Cyan
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Open an elevated PowerShell prompt on $newVM" -ForegroundColor White
    Write-Host "  and run the following command:" -ForegroundColor White
    Write-Host ""
    Write-Host "  powershell -ExecutionPolicy Bypass -File `"$step5RemotePath`"" -ForegroundColor White
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Yellow
    Write-Host ""

    # Pause for user to complete manual step
    do {
        $proceed = Read-Host "  Type 'proceed' and press Enter after completing Step 5 on the VM"
    } while ($proceed -ne 'proceed')

    Write-Host ""
    Write-Host "  [INFO] Verifying VM is responsive..." -ForegroundColor Gray
    $jmesQuery = 'instanceView.statuses[?starts_with(code,`PowerState/`)].displayStatus | [0]'
    $vmState = az vm get-instance-view --resource-group $newRG --name $newVM --query $jmesQuery -o tsv 2>$null
    if ($vmState -notmatch 'running') {
        Write-Host "  [WARN] VM may not be running (state: $vmState). Waiting for VM..." -ForegroundColor Yellow
        az vm start --resource-group $newRG --name $newVM --no-wait 2>$null
        Start-Sleep -Seconds 30
    }

    # Verify Step 5 completed on the VM
    Write-Host ""
    Write-StepBanner 5 "PublishCrossCert (verify)" $newVM "NEW"
    $verifyScript = @"
`$caName = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA SilentlyContinue).Active
`$svc = Get-Service certsvc -EA SilentlyContinue
if (`$caName -and `$svc.Status -eq 'Running') {
    Write-Host "[PASS] CA '`$caName' is active and certsvc is Running"
} else {
    Write-Host "[FAIL] CA not active or certsvc not running (Active='`$caName', certsvc='`$(`$svc.Status)')"
    exit 1
}
"@
    $verifyFile = Join-Path $wrapperDir "Step5-verify.ps1"
    $verifyScript | Out-File -FilePath $verifyFile -Encoding ASCII -Force
    $r5 = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -ScriptPath $verifyFile
    Record-Step 5 "PublishCrossCert" $newVM $r5

    # STEP 6 -- Validate Cross-Signed CA (NEW server)
    $step6Src = (Get-ChildItem $stepDir -Filter "Step6-*.ps1").FullName
    $step6Wrapper = Join-Path $wrapperDir "Step6-wrapper.ps1"
    New-Wrapper -SourceScript $step6Src -Params @{
        OldICACertPath = $oldICACertPathOnNew
    } -WrapperPath $step6Wrapper

    Write-StepBanner 6 "ValidateCrossSignedCA" $newVM "NEW"
    $r6 = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -ScriptPath $step6Wrapper
    Record-Step 6 "ValidateCrossSignedCA" $newVM $r6

    # STEP 7 -- Cross Validate (NEW server) -- non-HSM checks only
    $step7Src = (Get-ChildItem $stepDir -Filter "Step7-*.ps1").FullName

    Write-StepBanner 7 "CrossValidate" $newVM "NEW"
    $r7 = Invoke-RemoteScript -ResourceGroup $newRG -VMName $newVM -ScriptPath $step7Src
    Record-Step 7 "CrossValidate" $newVM $r7

    # STEP 8 -- Decommission Checks (OLD server)
    $step8Src = (Get-ChildItem $stepDir -Filter "Step8-*.ps1").FullName
    Write-StepBanner 8 "DecommissionChecks" $oldVM "OLD"
    $r8 = Invoke-RemoteScript -ResourceGroup $oldRG -VMName $oldVM -ScriptPath $step8Src
    Record-Step 8 "DecommissionChecks" $oldVM $r8
}

#endregion

# -- Final Summary ------------------------------------------------------------
Write-Summary
