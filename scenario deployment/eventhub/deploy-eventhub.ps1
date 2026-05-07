<#
.SYNOPSIS
    Deploys an Event Hub namespace for streaming HSM diagnostic logs.

.DESCRIPTION
    Event Hub Scenario - Deploy Event Hub for HSM Log Streaming

    Creates an Event Hub namespace, Event Hub (topic), authorization rules, and
    a consumer group in the existing logs resource group. After deployment,
    optionally wires up the diagnostic setting on the HSM/KV resource to
    stream audit logs to the Event Hub.

    Supports Azure Cloud HSM, Azure Key Vault, and Azure Managed HSM.
    The -Platform parameter controls which resource groups, resource types,
    and log categories are used.

    This script is designed to run AFTER the base HSM deployment is complete.
    It reuses the existing logs resource group.

    Workflow:
      1. Deploy Event Hub resources (namespace, hub, auth rules, consumer group)
      2. Optionally update the diagnostic setting to add Event Hub as a destination

    Prerequisites:
      - HSM platform must be deployed via HSM Scenario Builder.
      - Az PowerShell module must be installed and authenticated.

.PARAMETER Platform
    The HSM platform to target. Determines resource group names, resource
    types, and diagnostic log categories.
    Valid values: AzureCloudHSM, AzureKeyVault, AzureManagedHSM

.PARAMETER SubscriptionId
    The Azure subscription ID (required).

.PARAMETER Location
    Azure region override. If not specified, uses the value from the parameters file.

.PARAMETER ParameterFile
    Path to the ARM parameters file. Defaults to the platform-specific
    parameters file (e.g., eventhub-parameters-cloudhsm.json).

.PARAMETER SkipDiagnosticSetting
    If specified, skips the diagnostic setting update. You can wire it up manually later.

.EXAMPLE
    .\deploy-eventhub.ps1 -Platform AzureCloudHSM -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    .\deploy-eventhub.ps1 -Platform AzureKeyVault -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    .\deploy-eventhub.ps1 -Platform AzureManagedHSM -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -SkipDiagnosticSetting

.EXAMPLE
    .\deploy-eventhub.ps1 -Platform AzureCloudHSM -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -Location "East US"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "HSM platform to target.")]
    [ValidateSet("AzureCloudHSM", "AzureKeyVault", "AzureManagedHSM")]
    [string]$Platform,

    [Parameter(Mandatory = $true, HelpMessage = "Azure subscription ID to deploy into.")]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false, HelpMessage = "Azure region override (e.g., 'UK West', 'East US').")]
    [string]$Location,

    [Parameter(Mandatory = $false, HelpMessage = "Path to the ARM parameters file.")]
    [string]$ParameterFile,

    [Parameter(Mandatory = $false, HelpMessage = "Skip wiring up the diagnostic setting on the HSM/KV resource.")]
    [switch]$SkipDiagnosticSetting
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------
# Platform configuration map
# ------------------------------------------------------------------
$platformMap = @{
    "AzureCloudHSM"  = @{
        DisplayName   = "Azure Cloud HSM"
        DeployPrefix  = "chsm"
        LogsRgName    = "CHSM-HSB-LOGS-RG"
        HsmRgName     = "CHSM-HSB-HSM-RG"
        ResourceType  = "Microsoft.HardwareSecurityModules/cloudHsmClusters"
        LogCategory   = "HsmServiceOperations"
        ParamsFile    = "eventhub-parameters-cloudhsm.json"
    }
    "AzureKeyVault"  = @{
        DisplayName   = "Azure Key Vault"
        DeployPrefix  = "akv"
        LogsRgName    = "AKV-HSB-LOGS-RG"
        HsmRgName     = "AKV-HSB-HSM-RG"
        ResourceType  = "Microsoft.KeyVault/vaults"
        LogCategory   = "AuditEvent"
        ParamsFile    = "eventhub-parameters-keyvault.json"
    }
    "AzureManagedHSM" = @{
        DisplayName   = "Azure Managed HSM"
        DeployPrefix  = "mhsm"
        LogsRgName    = "MHSM-HSB-LOGS-RG"
        HsmRgName     = "MHSM-HSB-HSM-RG"
        ResourceType  = "Microsoft.KeyVault/managedHSMs"
        LogCategory   = "AuditEvent"
        ParamsFile    = "eventhub-parameters-managedhsm.json"
    }
}

$platformInfo = $platformMap[$Platform]
$displayName  = $platformInfo.DisplayName
$logsRgName   = $platformInfo.LogsRgName
$hsmRgName    = $platformInfo.HsmRgName
$resourceType = $platformInfo.ResourceType
$logCategory  = $platformInfo.LogCategory

# ------------------------------------------------------------------
# Banner
# ------------------------------------------------------------------
Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Event Hub Scenario - Deploy Event Hub"               -ForegroundColor Cyan
Write-Host "  Platform : $displayName"                             -ForegroundColor Cyan
Write-Host "  Purpose  : Stream diagnostic logs in real-time"      -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""

# ------------------------------------------------------------------
# Resolve paths
# ------------------------------------------------------------------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$templateFile = Join-Path $scriptDir "eventhub-deploy.json"

if (-not $ParameterFile) {
    $ParameterFile = Join-Path $scriptDir $platformInfo.ParamsFile
}

if (-not (Test-Path $templateFile)) {
    Write-Error "ARM template not found: $templateFile"
    exit 1
}
if (-not (Test-Path $ParameterFile)) {
    Write-Error "Parameters file not found: $ParameterFile"
    exit 1
}

Write-Host "[INFO] Template file  : $templateFile" -ForegroundColor Gray
Write-Host "[INFO] Parameters file: $ParameterFile" -ForegroundColor Gray

# ------------------------------------------------------------------
# Read parameters file for defaults
# ------------------------------------------------------------------
$paramContent = Get-Content -Path $ParameterFile -Raw | ConvertFrom-Json
$paramValues = $paramContent.parameters

$locationOverride = $PSBoundParameters.ContainsKey('Location')
if (-not $Location) {
    $Location = $paramValues.location.value
    Write-Host "[INFO] Using location from parameters file: $Location" -ForegroundColor Gray
}

# ------------------------------------------------------------------
# Build deployment parameter overrides
# ------------------------------------------------------------------
$deployParams = @{}

if ($locationOverride) {
    $deployParams["location"] = $Location
}

# ------------------------------------------------------------------
# Set subscription context
# ------------------------------------------------------------------
Write-Host ""
Write-Host "[STEP 1/4] Setting Azure subscription context..." -ForegroundColor White
Set-AzContext -SubscriptionId $SubscriptionId -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
Write-Host "  Subscription: $SubscriptionId" -ForegroundColor Green

$savedWarningPref = $WarningPreference
$WarningPreference = 'SilentlyContinue'
Import-Module Az.Resources -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module Az.EventHub  -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module Az.Monitor   -DisableNameChecking -ErrorAction SilentlyContinue
$WarningPreference = $savedWarningPref

$diagSettingUpdated = $false

# ------------------------------------------------------------------
# Pre-flight: verify logs resource group exists
# ------------------------------------------------------------------

Write-Host "[PRE-FLIGHT] Checking for existing resource group '$logsRgName'..." -ForegroundColor White

$logsRgExists = $false
try {
    Get-AzResourceGroup -Name $logsRgName -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    $logsRgExists = $true
    Write-Host "  Resource group '$logsRgName' found." -ForegroundColor Green
} catch {
    # Resource group doesn't exist
}

if (-not $logsRgExists) {
    Write-Host ""
    Write-Host "======================================================" -ForegroundColor Red
    Write-Host "  PREREQUISITE NOT MET" -ForegroundColor Red
    Write-Host "======================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "  $displayName must be deployed before running this script." -ForegroundColor Yellow
    Write-Host "  The Event Hub is deployed into the existing logs resource group" -ForegroundColor Yellow
    Write-Host "  created by the base deployment ($logsRgName)." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Deploy $displayName first:" -ForegroundColor White
    Write-Host "    .\deployhsm\deploy-hsm.ps1 -Platform $Platform -SubscriptionId `"$SubscriptionId`"" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Then re-run this script." -ForegroundColor White
    Write-Host ""
    exit 1
}

# ------------------------------------------------------------------
# Pre-flight: find the HSM/KV resource (needed for diagnostic setting)
# ------------------------------------------------------------------
$hsmResourceName = $null
$hsmResourceId = $null

if (-not $SkipDiagnosticSetting) {
    Write-Host "[PRE-FLIGHT] Looking for $displayName resource in '$hsmRgName'..." -ForegroundColor White
    try {
        $hsmResources = Get-AzResource -ResourceGroupName $hsmRgName `
            -ResourceType $resourceType `
            -ErrorAction Stop -WarningAction SilentlyContinue

        if ($hsmResources -and $hsmResources.Count -gt 0) {
            $hsmResourceName = $hsmResources[0].Name
            $hsmResourceId = $hsmResources[0].ResourceId
            Write-Host "  Found: $hsmResourceName" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: No $displayName resource found in '$hsmRgName'." -ForegroundColor Yellow
            Write-Host "  Diagnostic setting will be skipped. You can wire it up manually later." -ForegroundColor Yellow
            $SkipDiagnosticSetting = $true
        }
    } catch {
        Write-Host "  WARNING: Could not query $displayName resource: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  Diagnostic setting will be skipped." -ForegroundColor Yellow
        $SkipDiagnosticSetting = $true
    }
}

# ------------------------------------------------------------------
# Validate the template
# ------------------------------------------------------------------
Write-Host "[STEP 2/4] Validating ARM template..." -ForegroundColor White

$deploymentName = "eventhub-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

try {
    $validation = Test-AzResourceGroupDeployment `
        -ResourceGroupName $logsRgName `
        -TemplateFile $templateFile `
        -TemplateParameterFile $ParameterFile `
        @deployParams `
        -ErrorAction Stop

    if ($validation.Count -gt 0) {
        Write-Host "  Validation warnings:" -ForegroundColor Yellow
        $validation | ForEach-Object { Write-Host "    - $($_.Message)" -ForegroundColor Yellow }
    } else {
        Write-Host "  Validation passed." -ForegroundColor Green
    }
} catch {
    Write-Error "Template validation failed: $_"
    exit 1
}

# ------------------------------------------------------------------
# Deploy Event Hub resources
# ------------------------------------------------------------------
Write-Host "[STEP 3/4] Deploying Event Hub resources..." -ForegroundColor White
Write-Host "  Deployment name  : $deploymentName" -ForegroundColor Gray
Write-Host "  Resource group   : $logsRgName" -ForegroundColor Gray
Write-Host "  Namespace        : $($paramValues.eventHubNamespaceName.value)" -ForegroundColor Gray
Write-Host "  Event Hub        : $($paramValues.eventHubName.value)" -ForegroundColor Gray
Write-Host "  This may take 1-2 minutes..." -ForegroundColor Gray
Write-Host ""

try {
    $result = New-AzResourceGroupDeployment `
        -Name $deploymentName `
        -ResourceGroupName $logsRgName `
        -TemplateFile $templateFile `
        -TemplateParameterFile $ParameterFile `
        @deployParams `
        -ErrorAction Stop

    $nsName    = $result.Outputs.eventHubNamespaceName.Value
    $ehName    = $result.Outputs.eventHubName.Value
    $cgName    = $result.Outputs.consumerGroupName.Value
    $sendRuleId = $result.Outputs.sendAuthRuleId.Value

    Write-Host "  Event Hub namespace deployed successfully." -ForegroundColor Green

} catch {
    Write-Error "Deployment failed: $($_.Exception.Message)"
    exit 1
}

# ------------------------------------------------------------------
# Wire up diagnostic setting (unless skipped)
# ------------------------------------------------------------------
if (-not $SkipDiagnosticSetting) {
    Write-Host "[STEP 4/4] Updating diagnostic setting on $displayName resource..." -ForegroundColor White
    Write-Host "  Resource         : $hsmResourceName" -ForegroundColor Gray
    Write-Host "  Setting name     : hsb-diagnostic-setting" -ForegroundColor Gray

    try {
        # Get the existing storage account and Log Analytics workspace from the logs RG
        $storageAccounts = Get-AzStorageAccount -ResourceGroupName $logsRgName -ErrorAction Stop -WarningAction SilentlyContinue
        $workspaces = Get-AzOperationalInsightsWorkspace -ResourceGroupName $logsRgName -ErrorAction Stop -WarningAction SilentlyContinue

        if (-not $storageAccounts -or $storageAccounts.Count -eq 0) {
            Write-Host "  WARNING: No storage account found in '$logsRgName'. Diagnostic setting will include Event Hub only." -ForegroundColor Yellow
        }
        if (-not $workspaces -or $workspaces.Count -eq 0) {
            Write-Host "  WARNING: No Log Analytics workspace found in '$logsRgName'. Diagnostic setting will include Event Hub only." -ForegroundColor Yellow
        }

        # Build the diagnostic setting parameters
        $diagParams = @{
            Name       = "hsb-diagnostic-setting"
            ResourceId = $hsmResourceId
            EventHubName              = $ehName
            EventHubAuthorizationRuleId = $sendRuleId
        }

        # Preserve existing destinations
        if ($storageAccounts -and $storageAccounts.Count -gt 0) {
            $diagParams["StorageAccountId"] = $storageAccounts[0].Id
        }
        if ($workspaces -and $workspaces.Count -gt 0) {
            $diagParams["WorkspaceId"] = $workspaces[0].ResourceId
        }

        # Build the log settings object
        $logSetting = New-AzDiagnosticSettingLogSettingsObject -Category $logCategory -Enabled $true

        New-AzDiagnosticSetting @diagParams -Log $logSetting -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null

        Write-Host "  Diagnostic setting updated - Event Hub added as a destination." -ForegroundColor Green
        Write-Host "  Existing Storage + Log Analytics destinations preserved." -ForegroundColor Green
        $diagSettingUpdated = $true

    } catch {
        Write-Host ""
        Write-Host "  WARNING: Could not update diagnostic setting automatically." -ForegroundColor Yellow
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  You can wire it up manually - see the configure-eventhub doc for your platform." -ForegroundColor Yellow
    }
} else {
    Write-Host "[STEP 4/4] Skipping diagnostic setting (--SkipDiagnosticSetting specified)." -ForegroundColor Gray
}

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
Write-Host ""
Write-Host "======================================================" -ForegroundColor Green
Write-Host "  Event Hub Deployment Complete"                        -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Resource Group       : $logsRgName" -ForegroundColor White
Write-Host "  Namespace            : $nsName" -ForegroundColor White
Write-Host "  Event Hub            : $ehName" -ForegroundColor White
Write-Host "  Consumer Group       : $cgName" -ForegroundColor White
Write-Host "  Send Auth Rule       : DiagnosticSettingsSendRule" -ForegroundColor White
Write-Host "  Listen Auth Rule     : ConsumerListenRule" -ForegroundColor White
if ($diagSettingUpdated) {
    Write-Host "  Diagnostic Setting   : hsb-diagnostic-setting (updated)" -ForegroundColor White
} elseif (-not $SkipDiagnosticSetting) {
    Write-Host "  Diagnostic Setting   : NOT updated (see warning above)" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  ----------------------------------------------------" -ForegroundColor Yellow
Write-Host "  VERIFY - Check Event Hub Is Receiving Logs"            -ForegroundColor Yellow
Write-Host "  ----------------------------------------------------" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. Wait 5-10 minutes for diagnostic logs to start flowing." -ForegroundColor White
Write-Host "  2. Check Event Hub metrics in the Azure Portal:" -ForegroundColor White
Write-Host "     Portal > Event Hub Namespace > $nsName > Metrics > Incoming Messages" -ForegroundColor Gray
Write-Host ""
Write-Host "  3. Or use Azure CLI:" -ForegroundColor White
Write-Host "     az monitor metrics list ``" -ForegroundColor Cyan
Write-Host "       --resource `"/subscriptions/$SubscriptionId/resourceGroups/$logsRgName/providers/Microsoft.EventHub/namespaces/$nsName`" ``" -ForegroundColor Cyan
Write-Host "       --metric `"IncomingMessages`" --interval PT1H --output table" -ForegroundColor Cyan
Write-Host ""
Write-Host "  For full details, see the configure-eventhub doc for your platform." -ForegroundColor Gray
Write-Host ""

# ------------------------------------------------------------------
# Quick metric check
# ------------------------------------------------------------------
$nsResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$logsRgName/providers/Microsoft.EventHub/namespaces/$nsName"

Write-Host "  Checking Event Hub metrics (last hour)..." -ForegroundColor Gray
Write-Host ""

try {
    $endTime   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $startTime = (Get-Date).AddHours(-1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    $metricsJson = az monitor metrics list `
        --resource $nsResourceId `
        --metric "SuccessfulRequests" `
        --interval PT1M `
        --start-time $startTime `
        --end-time $endTime `
        --output json 2>$null

    if ($metricsJson) {
        $metrics = $metricsJson | ConvertFrom-Json
        $dataPoints = $metrics.value[0].timeseries[0].data | Where-Object { $_.total -gt 0 }

        if ($dataPoints -and $dataPoints.Count -gt 0) {
            $totalRequests = ($dataPoints | Measure-Object -Property total -Sum).Sum
            Write-Host "  SuccessfulRequests in the last hour: $totalRequests" -ForegroundColor Green
            Write-Host ""
            Write-Host "  Timestamp (UTC)        Requests" -ForegroundColor White
            Write-Host "  -------------------    --------" -ForegroundColor White
            $dataPoints | ForEach-Object {
                $ts = ([datetime]$_.timeStamp).ToString("yyyy-MM-dd HH:mm")
                Write-Host "  $ts           $($_.total)" -ForegroundColor White
            }
        } else {
            Write-Host "  SuccessfulRequests in the last hour: 0" -ForegroundColor Yellow
            Write-Host "  (This is normal if the namespace was just created. Check again in a few minutes.)" -ForegroundColor Gray
        }
    }
} catch {
    Write-Host "  Could not retrieve metrics: $($_.Exception.Message)" -ForegroundColor Yellow
}
Write-Host ""
