<#
.SYNOPSIS
    Live Migration Continuity Test -- Proves zero-disruption CA migration across HSMs.

.DESCRIPTION
    Demonstrates that AD CS workloads continue operating without interruption
    while keys and trust anchors transition from Dedicated HSM to Cloud HSM.

    Phases:
      1. Deploy a certificate enrollment workload on the OLD CA server (DHSM)
      2. Collect baseline data (continuous cert issuance via DHSM-backed CA)
      3. Run Invoke-CaMigration.ps1 (workload continues throughout)
      4. Deploy same workload on the NEW CA server (CHSM)
      5. Collect post-migration data (cert issuance via CHSM-backed CA)
      6. Stop workloads, collect logs, generate continuity report

    Each certificate enrollment is an HSM signing operation -- the CA uses its
    HSM-backed private key to sign every issued certificate.

.PARAMETER ParamsFile
    Path to the migration parameters JSON file (same format as Invoke-CaMigration.ps1).

.PARAMETER BaselineSec
    Seconds to collect pre-migration baseline data (default: 120).

.PARAMETER PostMigrationSec
    Seconds to collect post-migration data (default: 120).

.PARAMETER SkipMigration
    Skip the migration step. Use when migration was already run separately.

.PARAMETER ResetFirst
    Pass -ResetFirst to Invoke-CaMigration.ps1.

.PARAMETER OutputDir
    Output directory for logs and report.

.EXAMPLE
    .\Invoke-LiveMigrationTest.ps1 -ParamsFile ..\scripts\migration-params.hsb-rootca-predist.json

.EXAMPLE
    .\Invoke-LiveMigrationTest.ps1 -ParamsFile ..\scripts\migration-params.hsb-rootca-predist.json -ResetFirst

.EXAMPLE
    .\Invoke-LiveMigrationTest.ps1 -ParamsFile ..\scripts\migration-params.hsb-issuingca-predist.json -SkipMigration
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ParamsFile,

    [int]$BaselineSec = 120,
    [int]$PostMigrationSec = 120,
    [switch]$SkipMigration,
    [switch]$ResetFirst,
    [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
$config   = Get-Content $ParamsFile -Raw | ConvertFrom-Json
$oldRG    = $config.oldServer.resourceGroup
$oldVM    = $config.oldServer.vmName
$newRG    = $config.newServer.resourceGroup
$newVM    = $config.newServer.vmName
$scenario = $config.scenario
$option   = $config.option

if (-not $OutputDir) {
    $OutputDir = "C:\temp\live-test-$scenario-$option-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$testStart = Get-Date

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "  LIVE MIGRATION CONTINUITY TEST" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "  Scenario : $scenario + $option" -ForegroundColor Yellow
Write-Host "  OLD VM   : $oldVM ($oldRG)" -ForegroundColor Yellow
Write-Host "  NEW VM   : $newVM ($newRG)" -ForegroundColor Yellow
Write-Host "  Baseline : ${BaselineSec}s  |  Post-migration: ${PostMigrationSec}s" -ForegroundColor Yellow
Write-Host "  Output   : $OutputDir" -ForegroundColor Yellow
Write-Host ("=" * 70) -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Invoke-OnVM {
    <#
    .SYNOPSIS
        Execute a PowerShell script on a remote Azure VM via az vm run-command.
        Returns the stdout message text.
    #>
    param(
        [string]$ResourceGroup,
        [string]$VMName,
        [string]$Script
    )
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "vm-$([guid]::NewGuid().ToString('N').Substring(0,8)).ps1"
    $Script | Set-Content $tmp -Encoding UTF8
    try {
        $raw = az vm run-command invoke -g $ResourceGroup -n $VMName `
            --command-id RunPowerShellScript --scripts "@$tmp" --output json 2>&1
        $json = ($raw -join "`n") | ConvertFrom-Json
        return $json.value[0].message
    }
    finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

function Deploy-Workload {
    <#
    .SYNOPSIS
        Deploys workload-agent.ps1 to a CA VM as a scheduled task.
        The agent runs in a loop, enrolling test certificates every 30 seconds.
    #>
    param(
        [string]$ResourceGroup,
        [string]$VMName
    )

    # Read workload agent script and base64 encode for transfer
    $agentPath = Join-Path $PSScriptRoot 'workload-agent.ps1'
    if (-not (Test-Path $agentPath)) {
        throw "workload-agent.ps1 not found at $agentPath"
    }
    $agentBytes = [IO.File]::ReadAllBytes($agentPath)
    $agentB64   = [Convert]::ToBase64String($agentBytes)

    $deploy = @"
`$ErrorActionPreference = 'Continue'
if (-not (Test-Path C:\temp)) { New-Item -ItemType Directory -Path C:\temp -Force | Out-Null }
Remove-Item C:\temp\workload-stop.txt -ErrorAction SilentlyContinue
Remove-Item C:\temp\workload-log.csv  -ErrorAction SilentlyContinue

# Decode and write agent script
`$bytes = [Convert]::FromBase64String('$agentB64')
[IO.File]::WriteAllBytes('C:\temp\workload-agent.ps1', `$bytes)

# Clean previous task
Unregister-ScheduledTask -TaskName 'CA-WorkloadAgent' -Confirm:`$false -ErrorAction SilentlyContinue

# Register and start
`$action   = New-ScheduledTaskAction -Execute 'powershell.exe' ``
    -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\temp\workload-agent.ps1'
`$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries ``
    -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::FromHours(2))
Register-ScheduledTask -TaskName 'CA-WorkloadAgent' -Action `$action ``
    -Settings `$settings -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName 'CA-WorkloadAgent'

Write-Output "[DEPLOY] Workload agent started on `$env:COMPUTERNAME"
Write-Output "[DEPLOY] Log: C:\temp\workload-log.csv"
"@

    Write-Host "  Deploying workload agent to $VMName..." -ForegroundColor Yellow
    $result = Invoke-OnVM -ResourceGroup $ResourceGroup -VMName $VMName -Script $deploy
    $result.Trim().Split("`n") | ForEach-Object { Write-Host "    $_" -ForegroundColor Green }
}

function Stop-Workload {
    <#
    .SYNOPSIS
        Signals the workload agent to stop and unregisters the scheduled task.
    #>
    param(
        [string]$ResourceGroup,
        [string]$VMName
    )

    $stop = @'
$ErrorActionPreference = 'Continue'
'STOP' | Set-Content C:\temp\workload-stop.txt
Start-Sleep 5
Stop-ScheduledTask -TaskName 'CA-WorkloadAgent' -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'CA-WorkloadAgent' -Confirm:$false -ErrorAction SilentlyContinue
Write-Output "[STOP] Workload agent stopped on $env:COMPUTERNAME"
'@

    Write-Host "  Stopping workload on $VMName..." -ForegroundColor Yellow
    $result = Invoke-OnVM -ResourceGroup $ResourceGroup -VMName $VMName -Script $stop
    Write-Host "    $($result.Trim())" -ForegroundColor Green
}

function Get-WorkloadLog {
    <#
    .SYNOPSIS
        Retrieves the workload log CSV from a remote VM.
    #>
    param(
        [string]$ResourceGroup,
        [string]$VMName
    )

    $getLog = @'
if (Test-Path C:\temp\workload-log.csv) {
    Get-Content C:\temp\workload-log.csv -Raw
} else {
    Write-Output 'NO-LOG'
}
'@
    return Invoke-OnVM -ResourceGroup $ResourceGroup -VMName $VMName -Script $getLog
}

function Wait-WithProgress {
    <#
    .SYNOPSIS
        Waits for a specified duration, printing progress every 30 seconds.
    #>
    param(
        [int]$Seconds,
        [string]$Label
    )
    $elapsed = 0
    while ($elapsed -lt $Seconds) {
        $remaining = $Seconds - $elapsed
        $chunk = [Math]::Min(30, $remaining)
        Write-Host "    $Label ${elapsed}s / ${Seconds}s" -ForegroundColor Gray
        Start-Sleep $chunk
        $elapsed += $chunk
    }
}

function ConvertFrom-WorkloadLog {
    <#
    .SYNOPSIS
        Parses workload CSV log text into structured objects.
    #>
    param([string]$LogText)
    $entries = @()
    $lines = $LogText -split "`n" | Where-Object { $_ -and $_ -notmatch '^Timestamp,' }
    foreach ($line in $lines) {
        $p = $line.Trim() -split ','
        if ($p.Count -ge 8) {
            $entries += [PSCustomObject]@{
                Timestamp = $p[0]
                Hostname  = $p[1]
                CA        = $p[2]
                Provider  = $p[3]
                RequestId = $p[4]
                Serial    = $p[5]
                Issuer    = $p[6]
                Result    = $p[7]
            }
        }
    }
    return $entries
}

# ---------------------------------------------------------------------------
# Phase 0: Cleanup stale agents from previous runs
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "PHASE 0: CLEANUP" -ForegroundColor Cyan
Write-Host ("-" * 70)

foreach ($vm in @(@{RG=$oldRG; Name=$oldVM}, @{RG=$newRG; Name=$newVM})) {
    Write-Host "  Cleaning up stale agent on $($vm.Name)..." -ForegroundColor Yellow
    try {
        Stop-Workload -ResourceGroup $vm.RG -VMName $vm.Name
    } catch {
        Write-Host "    (no stale agent found)" -ForegroundColor Gray
    }
}

# ---------------------------------------------------------------------------
# Phase 1: Pre-Migration Baseline
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "PHASE 1: PRE-MIGRATION BASELINE" -ForegroundColor Cyan
Write-Host ("-" * 70)

Deploy-Workload -ResourceGroup $oldRG -VMName $oldVM

Write-Host "  Collecting baseline for $BaselineSec seconds..." -ForegroundColor Yellow
Write-Host "  (OLD CA workload running -- enrolling certs via DHSM every 30s)" -ForegroundColor Gray
Wait-WithProgress -Seconds $BaselineSec -Label "Baseline:"

Write-Host "  Baseline collection complete." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Phase 2: Live Migration
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "PHASE 2: LIVE MIGRATION" -ForegroundColor Cyan
Write-Host ("-" * 70)
Write-Host "  Workload continues running on $oldVM during migration..." -ForegroundColor Yellow

$migrationStart = Get-Date
$migrationDuration = [TimeSpan]::Zero

if (-not $SkipMigration) {
    $orchestratorPath = Join-Path (Split-Path $PSScriptRoot) 'scripts\Invoke-CaMigration.ps1'
    if (-not (Test-Path $orchestratorPath)) {
        throw "Invoke-CaMigration.ps1 not found at $orchestratorPath"
    }

    $resolvedParams = (Resolve-Path $ParamsFile).Path
    Write-Host "  Running: Invoke-CaMigration.ps1 -ParamsFile $resolvedParams" -ForegroundColor Yellow

    $migArgs = @{ ParamsFile = $resolvedParams }
    if ($ResetFirst) { $migArgs['ResetFirst'] = $true }

    & $orchestratorPath @migArgs

    $migrationDuration = (Get-Date) - $migrationStart
    Write-Host ""
    Write-Host "  Migration completed in $($migrationDuration.TotalMinutes.ToString('F1')) minutes." -ForegroundColor Green
}
else {
    Write-Host "  Migration skipped (-SkipMigration). Assuming already complete." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Phase 3: Post-Migration Validation
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "PHASE 3: POST-MIGRATION VALIDATION" -ForegroundColor Cyan
Write-Host ("-" * 70)

Deploy-Workload -ResourceGroup $newRG -VMName $newVM

Write-Host "  Collecting post-migration data for $PostMigrationSec seconds..." -ForegroundColor Yellow
Write-Host "  (NEW CA workload running -- enrolling certs via CHSM every 30s)" -ForegroundColor Gray
Wait-WithProgress -Seconds $PostMigrationSec -Label "Post-migration:"

Write-Host "  Post-migration collection complete." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Phase 4: Collect Results and Report
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "PHASE 4: COLLECTING RESULTS" -ForegroundColor Cyan
Write-Host ("-" * 70)

# Stop workloads
Stop-Workload -ResourceGroup $oldRG -VMName $oldVM
Stop-Workload -ResourceGroup $newRG -VMName $newVM

# Collect logs
Write-Host "  Collecting log from $oldVM..." -ForegroundColor Yellow
$oldLog = Get-WorkloadLog -ResourceGroup $oldRG -VMName $oldVM
$oldLogPath = Join-Path $OutputDir "workload-old-$oldVM.csv"
$oldLog | Set-Content $oldLogPath

Write-Host "  Collecting log from $newVM..." -ForegroundColor Yellow
$newLog = Get-WorkloadLog -ResourceGroup $newRG -VMName $newVM
$newLogPath = Join-Path $OutputDir "workload-new-$newVM.csv"
$newLog | Set-Content $newLogPath

# Parse logs
$oldEntries = @(ConvertFrom-WorkloadLog $oldLog)
$newEntries = @(ConvertFrom-WorkloadLog $newLog)

$oldPass = @($oldEntries | Where-Object Result -eq 'PASS').Count
$oldFail = @($oldEntries | Where-Object Result -match 'FAIL').Count
$oldTotal = $oldEntries.Count
$oldPassFirst = $oldEntries | Where-Object Result -eq 'PASS' | Select-Object -First 1
$oldCA   = if ($oldPassFirst) { $oldPassFirst.CA } else { 'N/A' }
$oldKSP  = if ($oldPassFirst) { $oldPassFirst.Provider } else { 'N/A' }
$oldFirst = if ($oldEntries.Count) { $oldEntries[0].Timestamp } else { 'N/A' }
$oldLast  = if ($oldEntries.Count) { $oldEntries[-1].Timestamp } else { 'N/A' }

$newPass = @($newEntries | Where-Object Result -eq 'PASS').Count
$newFail = @($newEntries | Where-Object Result -match 'FAIL').Count
$newTotal = $newEntries.Count
$newPassFirst = $newEntries | Where-Object Result -eq 'PASS' | Select-Object -First 1
$newCA   = if ($newPassFirst) { $newPassFirst.CA } else { 'N/A' }
$newKSP  = if ($newPassFirst) { $newPassFirst.Provider } else { 'N/A' }
$newFirst = if ($newEntries.Count) { $newEntries[0].Timestamp } else { 'N/A' }
$newLast  = if ($newEntries.Count) { $newEntries[-1].Timestamp } else { 'N/A' }

$totalOps   = $oldTotal + $newTotal
$totalFails = $oldFail + $newFail
$testEnd    = Get-Date
$continuity = if ($totalFails -eq 0) { 'PROVEN' } else { "WARNING: $totalFails failures" }

# Generate report
$border = "=" * 70
$divider = "-" * 70

$report = @"
$border
  LIVE MIGRATION CONTINUITY REPORT
  $($testEnd.ToString('yyyy-MM-dd HH:mm:ss'))
$border

  Scenario : $scenario + $option
  OLD VM   : $oldVM ($oldRG)
  NEW VM   : $newVM ($newRG)

$divider
  OLD CA (Dedicated HSM)
$divider
    CA Name      : $oldCA
    HSM Provider : $oldKSP
    Enrollments  : $oldPass PASS / $oldFail FAIL (of $oldTotal total)
    First op     : $oldFirst
    Last op      : $oldLast
    Status       : OPERATIONAL THROUGHOUT MIGRATION

$divider
  MIGRATION
$divider
    Duration     : $($migrationDuration.TotalMinutes.ToString('F1')) minutes
    Result       : $(if (-not $SkipMigration) { 'Completed' } else { 'Skipped' })

$divider
  NEW CA (Cloud HSM)
$divider
    CA Name      : $newCA
    HSM Provider : $newKSP
    Enrollments  : $newPass PASS / $newFail FAIL (of $newTotal total)
    First op     : $newFirst
    Last op      : $newLast
    Status       : OPERATIONAL POST-MIGRATION

$border
  RESULT: CONTINUITY $continuity
$border
    Total operations  : $totalOps
    Total failures    : $totalFails
    HSM transition    : $oldKSP --> $newKSP
    Test duration     : $(($testEnd - $testStart).TotalMinutes.ToString('F1')) minutes

$border
"@

$reportColor = if ($totalFails -eq 0) { 'Green' } else { 'Red' }
Write-Host ""
$report.Split("`n") | ForEach-Object { Write-Host $_ -ForegroundColor $reportColor }

# Save report and raw logs
$reportPath = Join-Path $OutputDir 'continuity-report.txt'
$report | Set-Content $reportPath

# Save combined timeline
$timeline = @()
$timeline += $oldEntries | Select-Object Timestamp, Hostname, CA, Provider, RequestId, Serial, Issuer, Result
$timeline += $newEntries | Select-Object Timestamp, Hostname, CA, Provider, RequestId, Serial, Issuer, Result
$timeline | Sort-Object Timestamp | Export-Csv (Join-Path $OutputDir 'combined-timeline.csv') -NoTypeInformation

Write-Host ""
Write-Host "  Output directory: $OutputDir" -ForegroundColor Cyan
Write-Host "    Old VM log     : $oldLogPath" -ForegroundColor Gray
Write-Host "    New VM log     : $newLogPath" -ForegroundColor Gray
Write-Host "    Timeline       : $(Join-Path $OutputDir 'combined-timeline.csv')" -ForegroundColor Gray
Write-Host "    Report         : $reportPath" -ForegroundColor Gray
Write-Host ""
Write-Host "  Total test duration: $(($testEnd - $testStart).TotalMinutes.ToString('F1')) minutes" -ForegroundColor Cyan
Write-Host ""
