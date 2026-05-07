<#
.SYNOPSIS
    Reset the ADCS migration environment to a clean pre-migration state.

.DESCRIPTION
    Undoes a completed or partially completed ADCS migration so that
    migration scripts (Step 1 through Step 8) can be re-run from scratch.

    Actions performed:
    1. Uninstalls the CA configuration on the NEW server (if present)
    2. Removes migration-related certificates from trust stores on ALL servers
    3. Deletes test/migration artifacts from C:\temp on ALL servers
    4. For IssuingCA: cleans parent CA VM (CSR submission artifacts, issued certs)
    5. Preserves: ADCS role, HSM SDK/KSP, HSM credentials, Luna client,
       sanity check scripts, HSM config files

    Supports all four migration combinations:
    - Scenario A (Root CA) + Option 1 (Pre-Distributed)  -- 2 VMs (OLD + NEW)
    - Scenario A (Root CA) + Option 2 (Cross-Signed)     -- 2 VMs (OLD + NEW)
    - Scenario B (Issuing CA) + Option 1 (Pre-Distributed) -- 3 VMs (OLD + NEW + PARENT)
    - Scenario B (Issuing CA) + Option 2 (Cross-Signed)    -- 3 VMs (OLD + NEW + PARENT)

    RUN ON: Secure workstation with Azure CLI access to all VMs.

.PARAMETER Scenario
    Migration scenario: RootCA or IssuingCA.

.PARAMETER Option
    Distribution option: PreDistributed or CrossSigned.

.PARAMETER OldVMResourceGroup
    Resource group of the OLD ADCS server VM.

.PARAMETER OldVMName
    Name of the OLD ADCS server VM.

.PARAMETER NewVMResourceGroup
    Resource group of the NEW ADCS server VM.

.PARAMETER NewVMName
    Name of the NEW ADCS server VM.

.PARAMETER NewCAThumbprint
    Thumbprint of the new CA certificate to remove from trust stores.
    If omitted, the script discovers it from the NEW VM registry.

.PARAMETER OldCAThumbprint
    Thumbprint of the old CA certificate. Used to ensure the old CA cert
    is NOT accidentally removed from the OLD VM. Also removed from the
    NEW VM trust store during reset.

.PARAMETER ParentVMResourceGroup
    Resource group of the PARENT CA server VM. Required for IssuingCA scenario.
    This is the Root CA that signed the Issuing CA certificate.
    For RootCA scenario, this parameter is ignored.

.PARAMETER ParentVMName
    Name of the PARENT CA server VM. Required for IssuingCA scenario.

.PARAMETER SkipConfirmation
    Skip the confirmation prompt before executing reset.

.PARAMETER PreserveFiles
    Additional file/folder names to preserve in C:\temp (beyond defaults).

.EXAMPLE
    # Reset Scenario A, Option 1 (Root CA, Pre-Distributed)
    .\Reset-MigrationEnvironment.ps1 `
        -Scenario RootCA -Option PreDistributed `
        -OldVMResourceGroup "DHSM-HSB-ADCS-VM" -OldVMName "dhsm-adcs-vm" `
        -NewVMResourceGroup "CHSM-HSB-ADCS-VM" -NewVMName "chsm-adcs-vm"

.EXAMPLE
    # Reset Scenario B, Option 1 (Issuing CA, Pre-Distributed) -- 3 VMs
    .\Reset-MigrationEnvironment.ps1 `
        -Scenario IssuingCA -Option PreDistributed `
        -OldVMResourceGroup "DHSM-HSB-ADCS-VM" -OldVMName "dhsm-adcs-ica" `
        -NewVMResourceGroup "CHSM-HSB-ADCS-VM" -NewVMName "chsm-adcs-ica" `
        -ParentVMResourceGroup "DHSM-HSB-ADCS-VM" -ParentVMName "dhsm-adcs-vm" `
        -OldCAThumbprint "343A5FDCAEE2D22284410656E2A48A53EE015213"

.EXAMPLE
    # Reset with known thumbprints and no confirmation prompt
    .\Reset-MigrationEnvironment.ps1 `
        -Scenario RootCA -Option PreDistributed `
        -OldVMResourceGroup "DHSM-HSB-ADCS-VM" -OldVMName "dhsm-adcs-vm" `
        -NewVMResourceGroup "CHSM-HSB-ADCS-VM" -NewVMName "chsm-adcs-vm" `
        -NewCAThumbprint "42037055D8F84570DE590BCBEE2E9F83EEA9912F" `
        -OldCAThumbprint "343A5FDCAEE2D22284410656E2A48A53EE015213" `
        -SkipConfirmation
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('RootCA', 'IssuingCA')]
    [string]$Scenario,

    [Parameter(Mandatory = $true)]
    [ValidateSet('PreDistributed', 'CrossSigned')]
    [string]$Option,

    [Parameter(Mandatory = $true)]
    [string]$OldVMResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$OldVMName,

    [Parameter(Mandatory = $true)]
    [string]$NewVMResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$NewVMName,

    [Parameter(Mandatory = $false)]
    [string]$NewCAThumbprint,

    [Parameter(Mandatory = $false)]
    [string]$OldCAThumbprint,

    [Parameter(Mandatory = $false)]
    [string]$ParentVMResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$ParentVMName,

    [Parameter(Mandatory = $false)]
    [switch]$SkipConfirmation,

    [Parameter(Mandatory = $false)]
    [string[]]$PreserveFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# -- Validate IssuingCA requires ParentVM params ----------------------------
if ($Scenario -eq 'IssuingCA') {
    if (-not $ParentVMResourceGroup -or -not $ParentVMName) {
        Write-Error "IssuingCA scenario requires -ParentVMResourceGroup and -ParentVMName parameters (the Root CA that signs the ICA)."
        exit 1
    }
}

# -- Banner ------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ADCS Migration Environment Reset" -ForegroundColor Cyan
Write-Host "  Scenario: $Scenario | Option: $Option" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# -- Determine cert store targets based on scenario --------------------------
# Root CA certs go in the Root store; Issuing CA certs go in the CA (Intermediate) store
$certStore = switch ($Scenario) {
    'RootCA'    { 'Root' }
    'IssuingCA' { 'CA' }
}

Write-Host "  Configuration:" -ForegroundColor White
Write-Host "    Scenario:      $Scenario" -ForegroundColor Gray
Write-Host "    Option:        $Option" -ForegroundColor Gray
Write-Host "    Cert Store:    $certStore" -ForegroundColor Gray
Write-Host "    OLD VM:        $OldVMName ($OldVMResourceGroup)" -ForegroundColor Gray
Write-Host "    NEW VM:        $NewVMName ($NewVMResourceGroup)" -ForegroundColor Gray
if ($Scenario -eq 'IssuingCA') {
    Write-Host "    PARENT VM:     $ParentVMName ($ParentVMResourceGroup)" -ForegroundColor Gray
}
Write-Host ""

# Total step count depends on whether we have a parent VM
$totalSteps = if ($Scenario -eq 'IssuingCA') { 6 } else { 5 }

# -- Helper: run-command on a VM and return stdout ---------------------------
function Invoke-VMCommand {
    param(
        [string]$ResourceGroup,
        [string]$VMName,
        [string]$Script,
        [string]$Label
    )

    Write-Host "  [$Label] Executing on $VMName..." -ForegroundColor Gray

    # Write script to temp file - multi-line strings break when passed inline
    # to az cli via PowerShell. The @file syntax ensures reliable delivery.
    $tmpScript = Join-Path $env:TEMP "reset-cmd-$([guid]::NewGuid().ToString('N').Substring(0,8)).ps1"
    $Script | Out-File -FilePath $tmpScript -Encoding ASCII -Force

    try {
        $result = az vm run-command invoke `
            --resource-group $ResourceGroup `
            --name $VMName `
            --command-id RunPowerShellScript `
            --scripts "@$tmpScript" `
            --query "value[].message" -o tsv 2>&1
    } finally {
        Remove-Item $tmpScript -Force -EA SilentlyContinue
    }

    $resultText = $result | Out-String

    # az cli with 2>&1 may mix ErrorRecord objects with string output.
    # Filter to only string elements for stdout/stderr separation.
    $strings = @($result | Where-Object { $_ -is [string] })
    $stdout = ""
    $stderr = ""
    if ($strings.Count -ge 1) { $stdout = $strings[0] }
    if ($strings.Count -ge 2) { $stderr = $strings[1] }

    return @{
        StdOut = $stdout
        StdErr = $stderr
        Raw    = $resultText
    }
}

# -- Files to always preserve on each VM ------------------------------------
$defaultPreserveOld = @(
    'adcs-sanity-check'
    'ADCS-Sanity-Check.ps1'
    'configure-adcs.ps1'
    'Uninstall-AzIHSM.ps1'
    'LunaClient_10.9.2-282_Windows'
    '610-000396-016_SW_Windows_Luna_Client_V10.9.2_RevA.zip'
)

$defaultPreserveNew = @(
    'adcs-sanity-check'
    'ADCS-Sanity-Check.ps1'
    'Archive'
    'azcloudhsm_application.cfg'
)

if ($PreserveFiles) {
    $defaultPreserveOld += $PreserveFiles
    $defaultPreserveNew += $PreserveFiles
}

# Parent VM uses same preserve list as OLD VM (it's also an HSM-based CA)
$defaultPreserveParent = $defaultPreserveOld.Clone()

# -- Step 1: Discover thumbprints if not provided ----------------------------
Write-Host "[1/$totalSteps] Discovering certificate thumbprints..." -ForegroundColor White

if (-not $NewCAThumbprint -or -not $OldCAThumbprint) {
    $discoverScript = @'
$out = @{}
$active = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA SilentlyContinue).Active
if ($active) {
    $certs = Get-ChildItem Cert:\LocalMachine\My
    foreach ($c in $certs) {
        if ($c.Subject -match $active) {
            foreach ($ext in $c.Extensions) {
                if ($ext.Oid.FriendlyName -eq 'Basic Constraints') {
                    $out.Thumbprint = $c.Thumbprint
                    $out.Subject = $c.Subject
                    break
                }
            }
        }
        if ($out.Thumbprint) { break }
    }
}
Write-Output ("THUMB:" + $out.Thumbprint)
Write-Output ("SUBJECT:" + $out.Subject)
Write-Output ("CA:" + $active)
'@

    if (-not $OldCAThumbprint) {
        $oldResult = Invoke-VMCommand -ResourceGroup $OldVMResourceGroup -VMName $OldVMName `
            -Script $discoverScript -Label "OLD VM"
        if ($oldResult.StdOut -match 'THUMB:(\S+)') {
            $OldCAThumbprint = $Matches[1]
            Write-Host "       Old CA thumbprint: $OldCAThumbprint" -ForegroundColor Green
        } else {
            Write-Host "       [WARN] Could not discover old CA thumbprint." -ForegroundColor Yellow
            Write-Host "              Provide -OldCAThumbprint manually." -ForegroundColor Yellow
        }
    }

    if (-not $NewCAThumbprint) {
        $newResult = Invoke-VMCommand -ResourceGroup $NewVMResourceGroup -VMName $NewVMName `
            -Script $discoverScript -Label "NEW VM"
        if ($newResult.StdOut -match 'THUMB:(\S+)') {
            $NewCAThumbprint = $Matches[1]
            Write-Host "       New CA thumbprint: $NewCAThumbprint" -ForegroundColor Green
        } else {
            Write-Host "       [INFO] No active CA on new VM (may already be clean)." -ForegroundColor Gray
        }
    }
} else {
    Write-Host "       Old CA thumbprint: $OldCAThumbprint (provided)" -ForegroundColor Green
    Write-Host "       New CA thumbprint: $NewCAThumbprint (provided)" -ForegroundColor Green
}

# -- Confirmation prompt -----------------------------------------------------
if (-not $SkipConfirmation) {
    Write-Host ""
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Yellow
    Write-Host "  |  THIS WILL RESET THE MIGRATION ENVIRONMENT           |" -ForegroundColor Yellow
    Write-Host "  |                                                      |" -ForegroundColor Yellow
    Write-Host "  |  - Uninstall CA on NEW VM                           |" -ForegroundColor Yellow
    Write-Host "  |  - Remove new CA cert from trust stores (all VMs)   |" -ForegroundColor Yellow
    Write-Host "  |  - Remove old CA cert from NEW VM trust store       |" -ForegroundColor Yellow
    Write-Host "  |  - Delete test artifacts from C:\temp (all VMs)     |" -ForegroundColor Yellow
    if ($Scenario -eq 'IssuingCA') {
    Write-Host "  |  - Clean parent CA CSR/cert artifacts               |" -ForegroundColor Yellow
    }
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "  Proceed with reset? (yes/no)"
    if ($confirm -ne 'yes') {
        Write-Host "  Aborted." -ForegroundColor Yellow
        exit 0
    }
    Write-Host ""
}

# -- Step 2: Reset NEW VM (uninstall CA, clean stores, clean files) ----------
Write-Host "[2/$totalSteps] Resetting NEW VM ($NewVMName)..." -ForegroundColor White

# Build the preserve list as a PowerShell array literal for the remote script
$preserveNewLiteral = ($defaultPreserveNew | ForEach-Object { "'$_'" }) -join ','

# Build thumbprint removal list: new CA cert + old CA cert (both should be removed from NEW VM)
$thumbsToRemoveNew = @()
if ($NewCAThumbprint) { $thumbsToRemoveNew += $NewCAThumbprint }
if ($OldCAThumbprint) { $thumbsToRemoveNew += $OldCAThumbprint }

$removeThumbsNewCode = ""
foreach ($thumb in $thumbsToRemoveNew) {
    $removeThumbsNewCode += @"
`$c = `$store.Certificates | Where-Object { `$_.Thumbprint -eq '$thumb' }
if (`$c) { `$store.Remove(`$c); Write-Output 'Removed $thumb from $certStore store' } else { Write-Output '$thumb not in $certStore store' }
"@
}

# Always clean My store -- archived certs survive CA uninstall and must be removed
# unconditionally, not gated on thumbprint discovery (which fails when CA is already gone)
$cleanMyStoreCode = @"
Write-Output '--- CLEANING MY STORE ---'
`$myStore = New-Object System.Security.Cryptography.X509Certificates.X509Store('My','LocalMachine')
`$myStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]'ReadWrite,IncludeArchived')
$(if ($NewCAThumbprint) { @"
`$mc = `$myStore.Certificates | Where-Object { `$_.Thumbprint -eq '$NewCAThumbprint' }
if (`$mc) { `$myStore.Remove(`$mc); Write-Output 'Removed $NewCAThumbprint from My store' } else { Write-Output 'Not in My store (by thumbprint)' }
"@ })
`$stale = `$myStore.Certificates | Where-Object { `$_.Subject -match 'CHSM|HSB|DHSM|IssuingCA|Migration' -and (`$_.Archived -or -not `$_.HasPrivateKey) }
foreach (`$sc in `$stale) { `$myStore.Remove(`$sc); Write-Output ('Removed stale: ' + `$sc.Subject + ' Thumb=' + `$sc.Thumbprint + ' Archived=' + `$sc.Archived) }
if (-not `$stale -or `$stale.Count -eq 0) { Write-Output 'No stale migration certs in My store' }
`$myStore.Close()
"@

# For Issuing CA + CrossSigned, also remove cross-signed certs from Root and CA stores
$crossSignedCleanNew = ""
if ($Option -eq 'CrossSigned') {
    $crossSignedCleanNew = @"
Write-Output '--- CLEANING CROSS-SIGNED CERTS ---'
foreach (`$storeName in @('Root','CA')) {
    `$csStore = New-Object System.Security.Cryptography.X509Certificates.X509Store(`$storeName,'LocalMachine')
    `$csStore.Open('ReadWrite')
    `$crossCerts = `$csStore.Certificates | Where-Object { `$_.Subject -ne `$_.Issuer -and (`$_.Subject -match 'HSB|CHSM|DHSM|IssuingCA|Migration') }
    foreach (`$xc in `$crossCerts) { `$csStore.Remove(`$xc); Write-Output ('Removed cross-cert from ' + `$storeName + ': ' + `$xc.Subject + ' issued by ' + `$xc.Issuer + ' Thumb=' + `$xc.Thumbprint) }
    `$csStore.Close()
}
"@
}

# For Issuing CA, also clean NTAuth store
$ntAuthCleanNew = ""
if ($Scenario -eq 'IssuingCA') {
    $ntAuthCleanNew = @"
Write-Output '--- CLEANING NTAUTH ---'
try { certutil -viewdelstore -enterprise NTAuth 2>&1 | Out-Null } catch { Write-Output 'NTAuth cleanup skipped (not domain-joined or no access)' }
"@
}

# For Issuing CA, clean subordinate-CA-specific artifacts on NEW VM:
# - Root CA cert from Root trust store (parent cert installed during Phase 3)
# - CertEnroll directory (CRL/cert cache for offline CRL workaround)
# - SMB share "CertEnroll" (created for file:/// CDP loopback)
# - Hosts file entries for parent CA hostname (loopback redirect)
# - DisableLoopbackCheck registry key (non-default security setting)
$issuingCACleanNew = ""
if ($Scenario -eq 'IssuingCA') {
    # Build parent CA thumbprint removal if OldCAThumbprint provided (parent = old CA)
    $parentRootCleanCode = ""
    if ($OldCAThumbprint) {
        $parentRootCleanCode = @"
`$rc = `$rootStore2.Certificates | Where-Object { `$_.Thumbprint -eq '$OldCAThumbprint' }
if (`$rc) { `$rootStore2.Remove(`$rc); Write-Output 'Removed parent CA $OldCAThumbprint from Root store' } else { Write-Output 'Parent CA cert not in Root store' }
"@
    }

    $issuingCACleanNew = @"
Write-Output '--- CLEANING ISSUING CA ARTIFACTS ---'

Write-Output 'Cleaning Root trust store (parent CA cert)...'
`$rootStore2 = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','LocalMachine')
`$rootStore2.Open('ReadWrite')
$parentRootCleanCode
`$rootStore2.Close()

Write-Output 'Cleaning CertEnroll directory...'
if (Test-Path 'C:\CertEnroll') {
    Get-ChildItem 'C:\CertEnroll' -EA SilentlyContinue | ForEach-Object {
        Remove-Item `$_.FullName -Force -EA SilentlyContinue
        Write-Output ('Deleted CertEnroll: ' + `$_.Name)
    }
}

Write-Output 'Removing CertEnroll SMB share...'
`$share = Get-SmbShare -Name CertEnroll -EA SilentlyContinue
if (`$share) { Remove-SmbShare -Name CertEnroll -Force -EA SilentlyContinue; Write-Output 'Removed CertEnroll SMB share' }
else { Write-Output 'No CertEnroll SMB share found' }

Write-Output 'Cleaning hosts file entries for parent CA...'
`$hostsPath = 'C:\Windows\System32\drivers\etc\hosts'
`$hostsContent = Get-Content `$hostsPath -EA SilentlyContinue
`$filtered = `$hostsContent | Where-Object { `$_ -notmatch 'dhsm-adcs' -and `$_ -notmatch 'chsm-adcs' }
if (`$filtered.Count -ne `$hostsContent.Count) {
    Set-Content `$hostsPath `$filtered
    Write-Output ('Removed ' + (`$hostsContent.Count - `$filtered.Count) + ' host entries')
} else { Write-Output 'No migration host entries found' }

Write-Output 'Removing DisableLoopbackCheck registry key...'
`$lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
`$dlc = Get-ItemProperty `$lsa -Name DisableLoopbackCheck -EA SilentlyContinue
if (`$dlc) {
    Remove-ItemProperty `$lsa -Name DisableLoopbackCheck -Force -EA SilentlyContinue
    Write-Output 'Removed DisableLoopbackCheck'
} else { Write-Output 'DisableLoopbackCheck not set' }

Write-Output 'Cleaning migration-certs and migration-step1-data directories...'
@('C:\temp\migration-certs', 'C:\temp\migration-step1-data', 'C:\temp\migration-csr') | ForEach-Object {
    if (Test-Path `$_) { Remove-Item `$_ -Recurse -Force -EA SilentlyContinue; Write-Output ('Deleted: ' + `$_) }
}
"@
}

$newVMScript = @"
Write-Output '--- STOPPING CERTSVC ---'
`$svc = Get-Service certsvc -EA SilentlyContinue
if (`$svc -and `$svc.Status -eq 'Running') {
    try { Stop-Service certsvc -Force -EA Stop; Write-Output 'Stopped' }
    catch { Write-Output ('Stop-Service: ' + `$_.Exception.Message + ' (continuing)') }
} else { Write-Output 'Already stopped or not found' }

Write-Output '--- UNINSTALLING CA ---'
`$active = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA SilentlyContinue).Active
if (`$active) {
    try {
        Uninstall-AdcsCertificationAuthority -Force -EA Stop
        Write-Output ('Uninstalled: ' + `$active)
    } catch {
        Write-Output ('Uninstall error: ' + `$_.Exception.Message)
    }
    # Verify CA is actually gone -- Uninstall can fail silently under SYSTEM with HSM KSPs (Finding 19/20)
    `$stillActive = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA SilentlyContinue).Active
    if (`$stillActive) {
        Write-Output ('CA still configured after first uninstall attempt: ' + `$stillActive)
        Write-Output 'Retrying uninstall...'
        try {
            Uninstall-AdcsCertificationAuthority -Force -EA Stop
            Write-Output 'Retry succeeded'
        } catch {
            Write-Output ('Retry error: ' + `$_.Exception.Message)
        }
        `$finalCheck = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA SilentlyContinue).Active
        if (`$finalCheck) {
            Write-Output '[FAIL] CA configuration could not be removed after two attempts'
            Write-Output ('Registry Active value still present: ' + `$finalCheck)
        } else {
            Write-Output 'CA removed on retry'
        }
    }
} else {
    Write-Output 'No CA configured (already clean)'
}

Write-Output '--- DELETING ORPHANED HSM KEYS ---'
`$kspList = certutil -csplist 2>&1 | Out-String
`$hsmKSP = `$null
if (`$kspList -match 'Cavium Key Storage Provider') { `$hsmKSP = 'Cavium Key Storage Provider' }
elseif (`$kspList -match 'SafeNet Key Storage Provider') { `$hsmKSP = 'SafeNet Key Storage Provider' }
if (`$hsmKSP) {
    Write-Output ('Checking HSM KSP: ' + `$hsmKSP)
    `$keyOutput = certutil -csp `$hsmKSP -key 2>&1 | Out-String
    `$hsbKeys = @([regex]::Matches(`$keyOutput, '(?m)^\s+((?:HSB|CHSM|DHSM|tq|ADCS)-[^\r\n]+)') | ForEach-Object { `$_.Groups[1].Value.Trim() })
    if (`$hsbKeys.Count -gt 0) {
        foreach (`$keyName in `$hsbKeys) {
            Write-Output ('Deleting HSM key: ' + `$keyName)
            `$delResult = certutil -csp `$hsmKSP -delkey `$keyName 2>&1 | Out-String
            if (`$LASTEXITCODE -eq 0) {
                Write-Output ('  Deleted: ' + `$keyName)
            } else {
                Write-Output ('  Delete failed (may require HSM admin): ' + `$delResult.Trim())
            }
        }
    } else {
        Write-Output 'No orphaned HSM keys found'
    }
} else {
    Write-Output 'No HSM KSP detected, skipping HSM key cleanup'
}

Write-Output '--- CLEANING REQUEST STORE (pending CSRs) ---'
`$reqStore = New-Object System.Security.Cryptography.X509Certificates.X509Store('REQUEST','LocalMachine')
`$reqStore.Open('ReadWrite')
`$reqCerts = @(`$reqStore.Certificates)
if (`$reqCerts.Count -gt 0) {
    foreach (`$rc in `$reqCerts) {
        Write-Output ('Removing pending request: ' + `$rc.Subject + ' (Thumb: ' + `$rc.Thumbprint + ')')
        `$reqStore.Remove(`$rc)
    }
} else {
    Write-Output 'No pending requests found'
}
`$reqStore.Close()

Write-Output '--- CLEANING $certStore STORE ---'
`$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('$certStore','LocalMachine')
`$store.Open('ReadWrite')
$removeThumbsNewCode
`$store.Close()

$cleanMyStoreCode
$crossSignedCleanNew
$ntAuthCleanNew

$issuingCACleanNew

Write-Output '--- CLEANING TEST FILES ---'
`$keep = @($preserveNewLiteral)
Get-ChildItem C:\temp -EA SilentlyContinue | Where-Object { `$_.Name -notin `$keep } | ForEach-Object {
    Remove-Item `$_.FullName -Recurse -Force -EA SilentlyContinue
    Write-Output ('Deleted: ' + `$_.Name)
}

Write-Output '--- VERIFY ---'
Write-Output ('Active CA: ' + (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA SilentlyContinue).Active)
`$svc2 = Get-Service certsvc -EA SilentlyContinue
if (`$svc2) { Write-Output ('certsvc: ' + `$svc2.Status + ' / ' + `$svc2.StartType) }
Write-Output 'Remaining in C:\temp:'
Get-ChildItem C:\temp -EA SilentlyContinue | Select-Object -ExpandProperty Name
Write-Output '--- DONE ---'
"@

$newResult = Invoke-VMCommand -ResourceGroup $NewVMResourceGroup -VMName $NewVMName `
    -Script $newVMScript -Label "RESET NEW"

Write-Host ""
Write-Host $newResult.StdOut -ForegroundColor Gray
if ($newResult.StdErr) {
    Write-Host "  [STDERR]:" -ForegroundColor Yellow
    Write-Host $newResult.StdErr -ForegroundColor Yellow
}

# Check for critical failures in remote script output
if ($newResult.Raw -match '\[FAIL\]') {
    Write-Host ""
    Write-Host "  [FATAL] CA uninstall failed on NEW VM. Cannot proceed with reset." -ForegroundColor Red
    Write-Host "          The CA configuration is still present on $NewVMName." -ForegroundColor Red
    Write-Host "          RDP into the VM and run: Uninstall-AdcsCertificationAuthority -Force" -ForegroundColor Red
    exit 1
}

# -- Step 3: Reset OLD VM (clean trust store, clean files) -------------------
Write-Host ""
Write-Host "[3/$totalSteps] Resetting OLD VM ($OldVMName)..." -ForegroundColor White

$preserveOldLiteral = ($defaultPreserveOld | ForEach-Object { "'$_'" }) -join ','

$removeThumbsOldCode = ""
if ($NewCAThumbprint) {
    $removeThumbsOldCode = @"
`$c = `$store.Certificates | Where-Object { `$_.Thumbprint -eq '$NewCAThumbprint' }
if (`$c) { `$store.Remove(`$c); Write-Output 'Removed $NewCAThumbprint from $certStore store' } else { Write-Output '$NewCAThumbprint not in $certStore store' }
"@
}

# For CrossSigned, also remove cross-signed certs
$crossSignedCleanOld = ""
if ($Option -eq 'CrossSigned') {
    $crossSignedCleanOld = @"
Write-Output '--- CLEANING CROSS-SIGNED CERTS ---'
`$crossCerts = `$store.Certificates | Where-Object { `$_.Subject -ne `$_.Issuer -and (`$_.Subject -match 'HSB|CHSM|DHSM|IssuingCA|Migration') }
foreach (`$xc in `$crossCerts) { `$store.Remove(`$xc); Write-Output ('Removed cross-cert: ' + `$xc.Subject) }
"@
}

# For Issuing CA, clean Step 1 output dirs and decommission artifacts on OLD ICA VM
$issuingCACleanOld = ""
if ($Scenario -eq 'IssuingCA') {
    $issuingCACleanOld = @"
Write-Output '--- CLEANING ISSUING CA STEP OUTPUT DIRECTORIES ---'
@('adcs-migration-step*', 'ica-crosssign-step*', 'ica-predist-step*') | ForEach-Object {
    `$pattern = `$_
    Get-ChildItem 'C:\Windows\system32\config\systemprofile' -Directory -Filter `$pattern -EA SilentlyContinue | ForEach-Object {
        Remove-Item `$_.FullName -Recurse -Force -EA SilentlyContinue; Write-Output ('Deleted: ' + `$_.FullName)
    }
    Get-ChildItem 'C:\Users' -Directory -Recurse -Filter `$pattern -Depth 1 -EA SilentlyContinue | ForEach-Object {
        Remove-Item `$_.FullName -Recurse -Force -EA SilentlyContinue; Write-Output ('Deleted: ' + `$_.FullName)
    }
}

Write-Output '--- CLEANING REQUEST STORE (pending CSRs on OLD) ---'
`$reqStore2 = New-Object System.Security.Cryptography.X509Certificates.X509Store('REQUEST','LocalMachine')
`$reqStore2.Open('ReadWrite')
`$reqCerts2 = @(`$reqStore2.Certificates)
if (`$reqCerts2.Count -gt 0) {
    foreach (`$rc2 in `$reqCerts2) {
        Write-Output ('Removing pending request: ' + `$rc2.Subject + ' (Thumb: ' + `$rc2.Thumbprint + ')')
        `$reqStore2.Remove(`$rc2)
    }
} else {
    Write-Output 'No pending requests found'
}
`$reqStore2.Close()
"@
}

$oldVMScript = @"
Write-Output '--- CLEANING $certStore STORE ---'
`$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('$certStore','LocalMachine')
`$store.Open('ReadWrite')
$removeThumbsOldCode
$crossSignedCleanOld
`$store.Close()

$issuingCACleanOld

Write-Output '--- CLEANING MY STORE (OLD VM archived certs) ---'
`$myStoreOld = New-Object System.Security.Cryptography.X509Certificates.X509Store('My','LocalMachine')
`$myStoreOld.Open([System.Security.Cryptography.X509Certificates.OpenFlags]'ReadWrite,IncludeArchived')
`$staleOld = `$myStoreOld.Certificates | Where-Object { `$_.Subject -match 'CHSM|HSB|DHSM|IssuingCA|Migration' -and `$_.Archived }
foreach (`$sc in `$staleOld) { `$myStoreOld.Remove(`$sc); Write-Output ('Removed archived: ' + `$sc.Subject + ' Thumb=' + `$sc.Thumbprint) }
if (-not `$staleOld -or `$staleOld.Count -eq 0) { Write-Output 'No archived certs in My store' }
`$myStoreOld.Close()

Write-Output '--- CLEANING TEST FILES ---'
`$keep = @($preserveOldLiteral)
Get-ChildItem C:\temp -EA SilentlyContinue | Where-Object { `$_.Name -notin `$keep } | ForEach-Object {
    Remove-Item `$_.FullName -Recurse -Force -EA SilentlyContinue
    Write-Output ('Deleted: ' + `$_.Name)
}

Write-Output '--- VERIFY ---'
Write-Output ('Active CA: ' + (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA SilentlyContinue).Active)
Write-Output ('certsvc: ' + (Get-Service certsvc -EA SilentlyContinue).Status)

Write-Output '$certStore store HSB certs:'
`$vStore = New-Object System.Security.Cryptography.X509Certificates.X509Store('$certStore','LocalMachine')
`$vStore.Open('ReadOnly')
`$hsbCerts = `$vStore.Certificates | Where-Object { `$_.Subject -match 'HSB' }
foreach (`$hc in `$hsbCerts) { Write-Output ('  ' + `$hc.Subject + ' | ' + `$hc.Thumbprint) }
if (-not `$hsbCerts -or `$hsbCerts.Count -eq 0) { Write-Output '  (only old CA root expected)' }
`$vStore.Close()

Write-Output 'Remaining in C:\temp:'
Get-ChildItem C:\temp -EA SilentlyContinue | Select-Object -ExpandProperty Name
Write-Output '--- DONE ---'
"@

$oldResult = Invoke-VMCommand -ResourceGroup $OldVMResourceGroup -VMName $OldVMName `
    -Script $oldVMScript -Label "RESET OLD"

Write-Host ""
Write-Host $oldResult.StdOut -ForegroundColor Gray
if ($oldResult.StdErr) {
    Write-Host "  [STDERR]:" -ForegroundColor Yellow
    Write-Host $oldResult.StdErr -ForegroundColor Yellow
}

# -- Step 3.5: Reset PARENT VM (IssuingCA only) -- clean CSR/cert artifacts --
if ($Scenario -eq 'IssuingCA') {
    Write-Host ""
    Write-Host "[4/$totalSteps] Resetting PARENT VM ($ParentVMName)..." -ForegroundColor White

    $preserveParentLiteral = ($defaultPreserveParent | ForEach-Object { "'$_'" }) -join ','

    # Remove new ICA cert from parent's CA (Intermediate) store if it was distributed there
    $removeNewFromParentCode = ""
    if ($NewCAThumbprint) {
        $removeNewFromParentCode = @"
`$c = `$caStore.Certificates | Where-Object { `$_.Thumbprint -eq '$NewCAThumbprint' }
if (`$c) { `$caStore.Remove(`$c); Write-Output 'Removed new ICA cert $NewCAThumbprint from CA store' } else { Write-Output 'New ICA cert not in CA store' }
"@
    }

    $parentVMScript = @"
Write-Output '--- CLEANING PARENT CA MIGRATION ARTIFACTS ---'

Write-Output 'Cleaning migration directories...'
@('C:\temp\migration-csr', 'C:\temp\migration-certs', 'C:\temp\migration-step1-data') | ForEach-Object {
    if (Test-Path `$_) { Remove-Item `$_ -Recurse -Force -EA SilentlyContinue; Write-Output ('Deleted: ' + `$_) }
}

Write-Output 'Cleaning step output directories...'
@('adcs-migration-step*', 'ica-crosssign-step*', 'ica-predist-step*') | ForEach-Object {
    `$pattern = `$_
    Get-ChildItem 'C:\Windows\system32\config\systemprofile' -Directory -Filter `$pattern -EA SilentlyContinue | ForEach-Object {
        Remove-Item `$_.FullName -Recurse -Force -EA SilentlyContinue; Write-Output ('Deleted: ' + `$_.FullName)
    }
    Get-ChildItem 'C:\Users' -Directory -Recurse -Filter `$pattern -Depth 1 -EA SilentlyContinue | ForEach-Object {
        Remove-Item `$_.FullName -Recurse -Force -EA SilentlyContinue; Write-Output ('Deleted: ' + `$_.FullName)
    }
}

Write-Output '--- CLEANING CA STORE (new ICA cert) ---'
`$caStore = New-Object System.Security.Cryptography.X509Certificates.X509Store('CA','LocalMachine')
`$caStore.Open('ReadWrite')
$removeNewFromParentCode
`$caStore.Close()

Write-Output '--- CLEANING TEST FILES ---'
`$keep = @($preserveParentLiteral)
Get-ChildItem C:\temp -EA SilentlyContinue | Where-Object { `$_.Name -notin `$keep } | ForEach-Object {
    Remove-Item `$_.FullName -Recurse -Force -EA SilentlyContinue
    Write-Output ('Deleted: ' + `$_.Name)
}

Write-Output '--- VERIFY ---'
Write-Output ('Active CA: ' + (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA SilentlyContinue).Active)
`$svcP = Get-Service certsvc -EA SilentlyContinue
if (`$svcP) { Write-Output ('certsvc: ' + `$svcP.Status + ' / ' + `$svcP.StartType) }

Write-Output 'Remaining in C:\temp:'
Get-ChildItem C:\temp -EA SilentlyContinue | Select-Object -ExpandProperty Name
Write-Output '--- DONE ---'
"@

    $parentResult = Invoke-VMCommand -ResourceGroup $ParentVMResourceGroup -VMName $ParentVMName `
        -Script $parentVMScript -Label "RESET PARENT"

    Write-Host ""
    Write-Host $parentResult.StdOut -ForegroundColor Gray
    if ($parentResult.StdErr) {
        Write-Host "  [STDERR]:" -ForegroundColor Yellow
        Write-Host $parentResult.StdErr -ForegroundColor Yellow
    }
}

# -- Verify: determine step number based on scenario --------------------------
$verifyStepNum = $totalSteps - 1
Write-Host ""
Write-Host "[$verifyStepNum/$totalSteps] Verifying final state..." -ForegroundColor White

$verifyScript = @'
$out = @{}
$out.ActiveCA = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA SilentlyContinue).Active
$svc = Get-Service certsvc -EA SilentlyContinue
$out.CertsvcStatus = if ($svc) { $svc.Status.ToString() } else { 'not found' }
$out.CertsvcStartType = if ($svc) { $svc.StartType.ToString() } else { 'n/a' }

# Check KSP
$kspOut = certutil -csplist 2>&1 | Out-String
$out.CaviumKSP = $kspOut -match 'Cavium'
$out.SafeNetKSP = $kspOut -match 'SafeNet'

# Check ADCS role
$feat = Get-WindowsFeature ADCS-Cert-Authority -EA SilentlyContinue
$out.ADCSInstalled = if ($feat) { $feat.Installed } else { $false }

Write-Output ("ACTIVE_CA:" + $out.ActiveCA)
Write-Output ("CERTSVC:" + $out.CertsvcStatus + "/" + $out.CertsvcStartType)
Write-Output ("ADCS_ROLE:" + $out.ADCSInstalled)
Write-Output ("CAVIUM_KSP:" + $out.CaviumKSP)
Write-Output ("SAFENET_KSP:" + $out.SafeNetKSP)
'@

$oldVerify = Invoke-VMCommand -ResourceGroup $OldVMResourceGroup -VMName $OldVMName `
    -Script $verifyScript -Label "VERIFY OLD"
$newVerify = Invoke-VMCommand -ResourceGroup $NewVMResourceGroup -VMName $NewVMName `
    -Script $verifyScript -Label "VERIFY NEW"
if ($Scenario -eq 'IssuingCA') {
    $parentVerify = Invoke-VMCommand -ResourceGroup $ParentVMResourceGroup -VMName $ParentVMName `
        -Script $verifyScript -Label "VERIFY PARENT"
}

# Parse results - use Raw output to handle az CLI stderr mixing with 2>&1
function Parse-VerifyOutput {
    param([string]$Output)
    $parsed = @{}
    foreach ($line in ($Output -split "[\r\n]+")) {
        $line = $line.Trim()
        if ($line -match '^(ACTIVE_CA|CERTSVC|ADCS_ROLE|CAVIUM_KSP|SAFENET_KSP):(.*)$') {
            $parsed[$Matches[1]] = $Matches[2].Trim()
        }
    }
    return $parsed
}

$oldState = Parse-VerifyOutput $oldVerify.Raw
$newState = Parse-VerifyOutput $newVerify.Raw
if ($Scenario -eq 'IssuingCA') {
    $parentState = Parse-VerifyOutput $parentVerify.Raw
}

# -- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host "[$totalSteps/$totalSteps] Reset Summary" -ForegroundColor White
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Environment Reset Complete" -ForegroundColor Cyan
Write-Host "  Scenario: $Scenario | Option: $Option" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "  OLD VM ($OldVMName):" -ForegroundColor White
$oldActiveCA = if ($oldState.ContainsKey('ACTIVE_CA')) { $oldState['ACTIVE_CA'] } else { '' }
$oldCertsvc  = if ($oldState.ContainsKey('CERTSVC')) { $oldState['CERTSVC'] } else { '(unknown)' }
$oldADCS     = if ($oldState.ContainsKey('ADCS_ROLE')) { $oldState['ADCS_ROLE'] } else { '(unknown)' }
$oldSafeNet  = if ($oldState.ContainsKey('SAFENET_KSP')) { $oldState['SAFENET_KSP'] } else { '(unknown)' }
Write-Host "    Active CA:  $oldActiveCA" -ForegroundColor $(if ($oldActiveCA) { 'Green' } else { 'Red' })
Write-Host "    certsvc:    $oldCertsvc" -ForegroundColor Green
Write-Host "    ADCS Role:  $oldADCS" -ForegroundColor Green
Write-Host "    SafeNet:    $oldSafeNet" -ForegroundColor Green
Write-Host ""

Write-Host "  NEW VM ($NewVMName):" -ForegroundColor White
$newActiveCA = if ($newState.ContainsKey('ACTIVE_CA')) { $newState['ACTIVE_CA'] } else { '' }
$newCertsvc  = if ($newState.ContainsKey('CERTSVC')) { $newState['CERTSVC'] } else { '(unknown)' }
$newADCS     = if ($newState.ContainsKey('ADCS_ROLE')) { $newState['ADCS_ROLE'] } else { '(unknown)' }
$newCavium   = if ($newState.ContainsKey('CAVIUM_KSP')) { $newState['CAVIUM_KSP'] } else { '(unknown)' }
$newCAClean = (-not $newActiveCA) -or ($newActiveCA -eq '')
Write-Host "    Active CA:  $(if ($newCAClean) { '(none - clean)' } else { $newActiveCA })" -ForegroundColor $(if ($newCAClean) { 'Green' } else { 'Red' })
Write-Host "    certsvc:    $newCertsvc" -ForegroundColor Gray
Write-Host "    ADCS Role:  $newADCS" -ForegroundColor Green
Write-Host "    Cavium:     $newCavium" -ForegroundColor Green
Write-Host ""

# Parent VM summary (IssuingCA only)
$parentCAReady = $true
if ($Scenario -eq 'IssuingCA') {
    Write-Host "  PARENT VM ($ParentVMName):" -ForegroundColor White
    $parentActiveCA = if ($parentState.ContainsKey('ACTIVE_CA')) { $parentState['ACTIVE_CA'] } else { '' }
    $parentCertsvc  = if ($parentState.ContainsKey('CERTSVC')) { $parentState['CERTSVC'] } else { '(unknown)' }
    $parentADCS     = if ($parentState.ContainsKey('ADCS_ROLE')) { $parentState['ADCS_ROLE'] } else { '(unknown)' }
    $parentSafeNet  = if ($parentState.ContainsKey('SAFENET_KSP')) { $parentState['SAFENET_KSP'] } else { '(unknown)' }
    Write-Host "    Active CA:  $parentActiveCA" -ForegroundColor $(if ($parentActiveCA) { 'Green' } else { 'Red' })
    Write-Host "    certsvc:    $parentCertsvc" -ForegroundColor Green
    Write-Host "    ADCS Role:  $parentADCS" -ForegroundColor Green
    Write-Host "    SafeNet:    $parentSafeNet" -ForegroundColor Green
    Write-Host ""
    $parentCAReady = $parentActiveCA -and ($parentCertsvc -match 'Running')
}

$oldCAReady = $oldActiveCA -and ($oldCertsvc -match 'Running')
$newCAReady = $newCAClean

if ($oldCAReady -and $newCAReady -and $parentCAReady) {
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
    Write-Host "  |  RESET SUCCESSFUL - Ready for migration testing      |" -ForegroundColor Green
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
    Write-Host ""
    Write-Host "  OLD VM: CA running, ready as migration source" -ForegroundColor Green
    Write-Host "  NEW VM: Clean slate, ADCS + KSP ready for Step 1-8" -ForegroundColor Green
    if ($Scenario -eq 'IssuingCA') {
        Write-Host "  PARENT VM: Root CA running, ready to sign CSRs" -ForegroundColor Green
    }
} else {
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Red
    Write-Host "  |  RESET FAILED - Environment not ready                |" -ForegroundColor Red
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Red
    if (-not $oldCAReady) {
        Write-Host "  [FAIL] Old CA may not be running. Check OLD VM." -ForegroundColor Red
    }
    if (-not $newCAReady) {
        Write-Host "  [FAIL] New VM not clean - CA still configured or ADCS role missing." -ForegroundColor Red
        Write-Host "         RDP into $NewVMName and run: Uninstall-AdcsCertificationAuthority -Force" -ForegroundColor Red
    }
    if (-not $parentCAReady) {
        Write-Host "  [FAIL] Parent CA may not be running. Check PARENT VM." -ForegroundColor Red
    }
    Write-Host ""
    exit 1
}
Write-Host ""
