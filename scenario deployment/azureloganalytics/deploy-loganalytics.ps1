<#
.SYNOPSIS
    Deploys a Storage Account and Log Analytics workspace for HSM diagnostic
    logging.

.DESCRIPTION
    Log Analytics Scenario - Deploy Logging Resources

    Creates a Storage Account and Log Analytics workspace in the existing
    logs resource group, then wires up a diagnostic setting on the HSM
    resource to route audit logs to both destinations.

    Supports Azure Cloud HSM, Azure Key Vault, and Azure Managed HSM.
    The -Platform parameter controls which resource groups, resource types,
    and log categories are used.

    This script is designed for customers who deployed their HSM platform via
    deploy-hsm.ps1 WITHOUT the logging parameters (storageAccountName,
    logAnalyticsWorkspaceName were left empty and no logging resources were
    created), or who want to add logging after the fact without rerunning
    deploy-hsm.ps1 (which could create duplicate resources or orphaned
    resource groups).

    Workflow:
      1. Set subscription context
      2. Verify logs resource group exists (created by base deployment)
      3. Check for existing logging resources (skip if already present)
      4. Register Microsoft.Insights provider (required for diagnostic settings)
      5. Deploy Storage Account and Log Analytics workspace
      6. Create diagnostic setting on the HSM/KV resource

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
    Azure region override. If not specified, uses the value from the
    parameters file.

.PARAMETER ParameterFile
    Path to the ARM parameters file. Defaults to the platform-specific
    parameters file (e.g., loganalytics-parameters-cloudhsm.json).

.PARAMETER SkipDiagnosticSetting
    If specified, skips the diagnostic setting creation. Deploys only the
    Storage Account and Log Analytics workspace.

.EXAMPLE
    .\deploy-loganalytics.ps1 -Platform AzureCloudHSM -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    .\deploy-loganalytics.ps1 -Platform AzureKeyVault -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    .\deploy-loganalytics.ps1 -Platform AzureManagedHSM -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -SkipDiagnosticSetting

.EXAMPLE
    .\deploy-loganalytics.ps1 -Platform AzureCloudHSM -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -Location "East US"
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

    [Parameter(Mandatory = $false, HelpMessage = "Skip creating the diagnostic setting on the HSM/KV resource.")]
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
        KqlTable      = "CloudHsmServiceOperationAuditLogs"
        ParamsFile    = "loganalytics-parameters-cloudhsm.json"
    }
    "AzureKeyVault"  = @{
        DisplayName   = "Azure Key Vault"
        DeployPrefix  = "akv"
        LogsRgName    = "AKV-HSB-LOGS-RG"
        HsmRgName     = "AKV-HSB-HSM-RG"
        ResourceType  = "Microsoft.KeyVault/vaults"
        LogCategory   = "AuditEvent"
        KqlTable      = "AzureDiagnostics"
        ParamsFile    = "loganalytics-parameters-keyvault.json"
    }
    "AzureManagedHSM" = @{
        DisplayName   = "Azure Managed HSM"
        DeployPrefix  = "mhsm"
        LogsRgName    = "MHSM-HSB-LOGS-RG"
        HsmRgName     = "MHSM-HSB-HSM-RG"
        ResourceType  = "Microsoft.KeyVault/managedHSMs"
        LogCategory   = "AuditEvent"
        KqlTable      = "AzureDiagnostics"
        ParamsFile    = "loganalytics-parameters-managedhsm.json"
    }
}

$platformInfo = $platformMap[$Platform]
$displayName  = $platformInfo.DisplayName
$logsRgName   = $platformInfo.LogsRgName
$hsmRgName    = $platformInfo.HsmRgName
$resourceType = $platformInfo.ResourceType
$logCategory  = $platformInfo.LogCategory
$kqlTable     = $platformInfo.KqlTable

# ------------------------------------------------------------------
# Banner
# ------------------------------------------------------------------
Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Log Analytics Scenario - Deploy Logging Resources"    -ForegroundColor Cyan
Write-Host "  Platform : $displayName"                              -ForegroundColor Cyan
Write-Host "  Purpose  : Storage Account + Log Analytics + Diag"    -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""

# ------------------------------------------------------------------
# Resolve paths
# ------------------------------------------------------------------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$templateFile = Join-Path $scriptDir "loganalytics-deploy.json"

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
Write-Host "[STEP 1/6] Setting Azure subscription context..." -ForegroundColor White
Set-AzContext -SubscriptionId $SubscriptionId -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
Write-Host "  Subscription: $SubscriptionId" -ForegroundColor Green

$savedWarningPref = $WarningPreference
$WarningPreference = 'SilentlyContinue'
Import-Module Az.Resources           -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module Az.Storage             -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module Az.OperationalInsights -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module Az.Monitor             -DisableNameChecking -ErrorAction SilentlyContinue
$WarningPreference = $savedWarningPref

$diagSettingCreated = $false

# ------------------------------------------------------------------
# Pre-flight: verify logs resource group exists
# ------------------------------------------------------------------

Write-Host "[STEP 2/6] Checking for existing resource group '$logsRgName'..." -ForegroundColor White

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
    Write-Host "  The logging resources are deployed into the existing logs" -ForegroundColor Yellow
    Write-Host "  resource group created by the base deployment" -ForegroundColor Yellow
    Write-Host "  ($logsRgName)." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Deploy $displayName first:" -ForegroundColor White
    Write-Host "    .\deployhsm\deploy-hsm.ps1 -Platform $Platform -SubscriptionId `"$SubscriptionId`"" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Then re-run this script." -ForegroundColor White
    Write-Host ""
    exit 1
}

# ------------------------------------------------------------------
# Pre-flight: check for existing logging resources
# ------------------------------------------------------------------
Write-Host "[STEP 3/6] Checking for existing logging resources in '$logsRgName'..." -ForegroundColor White

$existingStorageAccounts = Get-AzStorageAccount -ResourceGroupName $logsRgName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
$existingWorkspaces = Get-AzOperationalInsightsWorkspace -ResourceGroupName $logsRgName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

$hasStorage = $existingStorageAccounts -and $existingStorageAccounts.Count -gt 0
$hasWorkspace = $existingWorkspaces -and $existingWorkspaces.Count -gt 0

if ($hasStorage -and $hasWorkspace) {
    $saName = $existingStorageAccounts[0].StorageAccountName
    $laName = $existingWorkspaces[0].Name

    Write-Host "  Storage Account already exists : $saName" -ForegroundColor Yellow
    Write-Host "  Log Analytics already exists   : $laName" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Logging resources are already deployed in '$logsRgName'." -ForegroundColor Yellow
    Write-Host "  The ARM deployment will be run in incremental mode (idempotent)." -ForegroundColor Yellow
    Write-Host "  Existing resources will be preserved; only missing resources" -ForegroundColor Yellow
    Write-Host "  will be created." -ForegroundColor Yellow
    Write-Host ""
} elseif ($hasStorage) {
    Write-Host "  Storage Account found: $($existingStorageAccounts[0].StorageAccountName)" -ForegroundColor Yellow
    Write-Host "  Log Analytics workspace: not found (will be created)" -ForegroundColor Green
} elseif ($hasWorkspace) {
    Write-Host "  Storage Account: not found (will be created)" -ForegroundColor Green
    Write-Host "  Log Analytics workspace found: $($existingWorkspaces[0].Name)" -ForegroundColor Yellow
} else {
    Write-Host "  No existing logging resources found. Both will be created." -ForegroundColor Green
}

# ------------------------------------------------------------------
# Register Microsoft.Insights provider
# ------------------------------------------------------------------
Write-Host "[STEP 4/6] Checking Microsoft.Insights provider registration..." -ForegroundColor White

$insightsProvider = Get-AzResourceProvider -ProviderNamespace Microsoft.Insights -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

if ($insightsProvider -and $insightsProvider[0].RegistrationState -eq 'Registered') {
    Write-Host "  Microsoft.Insights is already registered." -ForegroundColor Green
} else {
    Write-Host "  Registering Microsoft.Insights provider..." -ForegroundColor Gray
    Register-AzResourceProvider -ProviderNamespace Microsoft.Insights -ErrorAction Stop | Out-Null

    # Wait for registration to complete (up to 60 seconds)
    $maxWait = 60
    $elapsed = 0
    $registered = $false
    while ($elapsed -lt $maxWait) {
        $provider = Get-AzResourceProvider -ProviderNamespace Microsoft.Insights -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        if ($provider -and $provider[0].RegistrationState -eq 'Registered') {
            $registered = $true
            break
        }
        Start-Sleep -Seconds 5
        $elapsed += 5
    }

    if ($registered) {
        Write-Host "  Microsoft.Insights registered successfully." -ForegroundColor Green
    } else {
        Write-Host "  WARNING: Microsoft.Insights registration still pending after ${maxWait}s." -ForegroundColor Yellow
        Write-Host "  The diagnostic setting step may fail. You can retry later." -ForegroundColor Yellow
    }
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
# Deploy logging resources
# ------------------------------------------------------------------
Write-Host "[STEP 5/6] Deploying logging resources..." -ForegroundColor White

$deploymentName = "loganalytics-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

Write-Host "  Deployment name  : $deploymentName" -ForegroundColor Gray
Write-Host "  Resource group   : $logsRgName" -ForegroundColor Gray
Write-Host "  Location         : $Location" -ForegroundColor Gray
Write-Host "  Log retention    : $($paramValues.logRetentionDays.value) days" -ForegroundColor Gray
Write-Host "  This may take 1-2 minutes..." -ForegroundColor Gray
Write-Host ""

try {
    # Validate first
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

    # Deploy
    $result = New-AzResourceGroupDeployment `
        -Name $deploymentName `
        -ResourceGroupName $logsRgName `
        -TemplateFile $templateFile `
        -TemplateParameterFile $ParameterFile `
        @deployParams `
        -ErrorAction Stop

    $saName  = $result.Outputs.storageAccountName.Value
    $saId    = $result.Outputs.storageAccountId.Value
    $laName  = $result.Outputs.logAnalyticsWorkspaceName.Value
    $laId    = $result.Outputs.logAnalyticsWorkspaceId.Value

    Write-Host "  Logging resources deployed successfully." -ForegroundColor Green
    Write-Host "    Storage Account      : $saName" -ForegroundColor White
    Write-Host "    Log Analytics        : $laName" -ForegroundColor White

} catch {
    Write-Error "Deployment failed: $($_.Exception.Message)"
    exit 1
}

# ------------------------------------------------------------------
# Create diagnostic setting on the HSM/KV resource
# ------------------------------------------------------------------
if (-not $SkipDiagnosticSetting) {
    Write-Host "[STEP 6/6] Creating diagnostic setting on $displayName resource..." -ForegroundColor White
    Write-Host "  Resource         : $hsmResourceName" -ForegroundColor Gray
    Write-Host "  Setting name     : hsb-diagnostic-setting" -ForegroundColor Gray
    Write-Host "  Log category     : $logCategory" -ForegroundColor Gray
    Write-Host "  Destinations     : Storage Account + Log Analytics" -ForegroundColor Gray

    try {
        # Check for existing diagnostic setting
        $existingDiagSetting = $null
        try {
            $existingDiagSetting = Get-AzDiagnosticSetting -ResourceId $hsmResourceId `
                -Name "hsb-diagnostic-setting" -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        } catch {
            # Does not exist - this is fine
        }

        if ($existingDiagSetting) {
            Write-Host "  Diagnostic setting 'hsb-diagnostic-setting' already exists." -ForegroundColor Yellow
            Write-Host "  Updating to include current Storage Account and Log Analytics..." -ForegroundColor Yellow

            # Preserve Event Hub destination if present
            $diagParams = @{
                Name             = "hsb-diagnostic-setting"
                ResourceId       = $hsmResourceId
                StorageAccountId = $saId
                WorkspaceId      = $laId
            }

            if ($existingDiagSetting.EventHubAuthorizationRuleId) {
                $diagParams["EventHubAuthorizationRuleId"] = $existingDiagSetting.EventHubAuthorizationRuleId
                $diagParams["EventHubName"] = $existingDiagSetting.EventHubName
                Write-Host "  Preserving existing Event Hub destination." -ForegroundColor Gray
            }

            $logSetting = New-AzDiagnosticSettingLogSettingsObject -Category $logCategory -Enabled $true
            New-AzDiagnosticSetting @diagParams -Log $logSetting -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null

            Write-Host "  Diagnostic setting updated successfully." -ForegroundColor Green
            $diagSettingCreated = $true
        } else {
            # Create new diagnostic setting
            $logSetting = New-AzDiagnosticSettingLogSettingsObject -Category $logCategory -Enabled $true

            New-AzDiagnosticSetting `
                -Name "hsb-diagnostic-setting" `
                -ResourceId $hsmResourceId `
                -StorageAccountId $saId `
                -WorkspaceId $laId `
                -Log $logSetting `
                -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null

            Write-Host "  Diagnostic setting created successfully." -ForegroundColor Green
            $diagSettingCreated = $true
        }

    } catch {
        Write-Host ""
        Write-Host "  WARNING: Could not create diagnostic setting automatically." -ForegroundColor Yellow
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  You can wire it up manually - see the configure-loganalytics doc for your platform." -ForegroundColor Yellow
    }
} else {
    Write-Host "[STEP 6/6] Skipping diagnostic setting (--SkipDiagnosticSetting specified)." -ForegroundColor Gray
}

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
Write-Host ""
Write-Host "======================================================" -ForegroundColor Green
Write-Host "  Log Analytics Deployment Complete"                     -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Resource Group       : $logsRgName" -ForegroundColor White
Write-Host "  Storage Account      : $saName" -ForegroundColor White
Write-Host "  Log Analytics        : $laName" -ForegroundColor White
Write-Host "  Log Retention        : $($paramValues.logRetentionDays.value) days" -ForegroundColor White
if ($diagSettingCreated) {
    Write-Host "  Diagnostic Setting   : hsb-diagnostic-setting (created)" -ForegroundColor White
} elseif ($SkipDiagnosticSetting) {
    Write-Host "  Diagnostic Setting   : skipped" -ForegroundColor Yellow
} else {
    Write-Host "  Diagnostic Setting   : NOT created (see warning above)" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Log Category         : $logCategory" -ForegroundColor White
Write-Host "  Destinations         : Storage Account + Log Analytics Workspace" -ForegroundColor White
Write-Host ""
Write-Host "  ----------------------------------------------------" -ForegroundColor Yellow
Write-Host "  VERIFY - Check Logs Are Flowing"                       -ForegroundColor Yellow
Write-Host "  ----------------------------------------------------" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Logs start flowing within 1-2 minutes of creating the" -ForegroundColor White
Write-Host "  diagnostic setting. Query the Log Analytics workspace:" -ForegroundColor White
Write-Host ""
Write-Host "  1. Azure Portal:" -ForegroundColor White
Write-Host "     Portal > Log Analytics > $laName > Logs" -ForegroundColor Gray
Write-Host ""
Write-Host "  2. KQL query:" -ForegroundColor White
Write-Host "     $kqlTable | take 10" -ForegroundColor Cyan
Write-Host ""
Write-Host "  3. Azure CLI:" -ForegroundColor White
Write-Host "     `$workspaceId = az monitor log-analytics workspace show ``" -ForegroundColor Cyan
Write-Host "       --resource-group `"$logsRgName`" --workspace-name `"$laName`" ``" -ForegroundColor Cyan
Write-Host "       --query customerId -o tsv" -ForegroundColor Cyan
Write-Host "     az monitor log-analytics query -w `$workspaceId ``" -ForegroundColor Cyan
Write-Host "       --analytics-query `"$kqlTable | take 10`"" -ForegroundColor Cyan
Write-Host ""
Write-Host "  For full details, see the configure-loganalytics doc for your platform." -ForegroundColor Gray
Write-Host ""

# ------------------------------------------------------------------
# Quick verification: check diagnostic setting exists
# ------------------------------------------------------------------
if ($diagSettingCreated) {
    Write-Host "  Verifying diagnostic setting..." -ForegroundColor Gray
    Write-Host ""

    try {
        $verifySetting = Get-AzDiagnosticSetting -ResourceId $hsmResourceId `
            -Name "hsb-diagnostic-setting" -ErrorAction Stop -WarningAction SilentlyContinue

        $destCount = 0
        $destinations = @()
        if ($verifySetting.StorageAccountId) { $destCount++; $destinations += "Storage Account" }
        if ($verifySetting.WorkspaceId) { $destCount++; $destinations += "Log Analytics" }
        if ($verifySetting.EventHubAuthorizationRuleId) { $destCount++; $destinations += "Event Hub" }

        Write-Host "  Diagnostic setting verified: $destCount destination(s)" -ForegroundColor Green
        foreach ($dest in $destinations) {
            Write-Host "    - $dest" -ForegroundColor White
        }
    } catch {
        Write-Host "  Could not verify diagnostic setting: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    Write-Host ""
}
