<#
.SYNOPSIS
    Deploys an Azure Function App to monitor Cloud HSM audit logs via Event Hub.

.DESCRIPTION
    Event Hub Scenario - Deploy Audit Monitor Function App

    Creates a Linux Consumption Function App (Python 3.11) that triggers on
    Cloud HSM diagnostic logs arriving in Event Hub. The function filters for
    key operations (CN_CREATE_USER, CN_GENERATE_KEY_PAIR, CN_LOGIN, etc.) and
    logs them with structured audit detail to Application Insights.

    This script is designed to run AFTER deploy-eventhub.ps1 has created
    the Event Hub namespace and wired up the diagnostic setting.

    Workflow:
      1. Deploy Function App infrastructure (storage, plan, App Insights, function app)
      2. Deploy function code from azure_functions/
      3. Verify function is running and connected to Event Hub

    Prerequisites:
      - Event Hub must be deployed via deploy-eventhub.ps1
      - Azure Functions Core Tools must be installed (npm i -g azure-functions-core-tools@4)
      - Az PowerShell module must be installed and authenticated

.PARAMETER SubscriptionId
    The Azure subscription ID (required).

.PARAMETER Location
    Azure region override. If not specified, uses the value from the parameters file (UK West).

.PARAMETER ParameterFile
    Path to the ARM parameters file. Defaults to functionapp-parameters-cloudhsm.json.

.PARAMETER SkipCodeDeploy
    If specified, only deploys infrastructure without pushing function code.

.EXAMPLE
    .\deploy-functionapp.ps1 -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    .\deploy-functionapp.ps1 -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -SkipCodeDeploy
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Azure subscription ID to deploy into.")]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false, HelpMessage = "Azure region override (e.g., 'UK West', 'East US').")]
    [string]$Location,

    [Parameter(Mandatory = $false, HelpMessage = "Path to the ARM parameters file.")]
    [string]$ParameterFile,

    [Parameter(Mandatory = $false, HelpMessage = "Skip deploying function code (infrastructure only).")]
    [switch]$SkipCodeDeploy
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------
# Banner
# ------------------------------------------------------------------
Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Event Hub Scenario - Deploy Audit Monitor Function"   -ForegroundColor Cyan
Write-Host "  Platform : Azure Cloud HSM"                           -ForegroundColor Cyan
Write-Host "  Purpose  : Real-time HSM operation monitoring"        -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""

# ------------------------------------------------------------------
# Resolve paths
# ------------------------------------------------------------------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$repoRoot = (Resolve-Path (Join-Path $scriptDir "..\..")).Path
$templateFile = Join-Path $scriptDir "functionapp-deploy.json"
$functionAppDir = Join-Path $repoRoot "azure_functions"

if (-not $ParameterFile) {
    $ParameterFile = Join-Path $scriptDir "functionapp-parameters-cloudhsm.json"
}

if (-not (Test-Path $templateFile)) {
    Write-Error "ARM template not found: $templateFile"
    exit 1
}
if (-not (Test-Path $ParameterFile)) {
    Write-Error "Parameters file not found: $ParameterFile"
    exit 1
}

Write-Host "[INFO] Template file     : $templateFile" -ForegroundColor Gray
Write-Host "[INFO] Parameters file   : $ParameterFile" -ForegroundColor Gray
Write-Host "[INFO] Function app code : $functionAppDir" -ForegroundColor Gray

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
# Set subscription context
# ------------------------------------------------------------------
Write-Host ""
Write-Host "[STEP 1/5] Setting Azure subscription context..." -ForegroundColor White
Set-AzContext -SubscriptionId $SubscriptionId -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
Write-Host "  Subscription: $SubscriptionId" -ForegroundColor Green

$savedWarningPref = $WarningPreference
$WarningPreference = 'SilentlyContinue'
Import-Module Az.Resources -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module Az.Websites  -DisableNameChecking -ErrorAction SilentlyContinue
$WarningPreference = $savedWarningPref

# ------------------------------------------------------------------
# Pre-flight: verify Event Hub namespace exists
# ------------------------------------------------------------------
$logsRgName = "CHSM-HSB-LOGS-RG"

Write-Host "[PRE-FLIGHT] Checking for Event Hub namespace in '$logsRgName'..." -ForegroundColor White

$ehNamespace = $null
try {
    $ehResources = Get-AzResource -ResourceGroupName $logsRgName `
        -ResourceType "Microsoft.EventHub/namespaces" `
        -ErrorAction Stop -WarningAction SilentlyContinue

    if ($ehResources -and $ehResources.Count -gt 0) {
        $ehNamespace = $ehResources[0].Name
        Write-Host "  Found Event Hub namespace: $ehNamespace" -ForegroundColor Green
    }
} catch {
    # Namespace doesn't exist
}

if (-not $ehNamespace) {
    Write-Host ""
    Write-Host "======================================================" -ForegroundColor Red
    Write-Host "  PREREQUISITE NOT MET" -ForegroundColor Red
    Write-Host "======================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Event Hub must be deployed before running this script." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Deploy Event Hub first:" -ForegroundColor White
    Write-Host "    .\deploy-eventhub.ps1 -SubscriptionId `"$SubscriptionId`"" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Then re-run this script." -ForegroundColor White
    Write-Host ""
    exit 1
}

# ------------------------------------------------------------------
# Get Event Hub Listen connection string
# ------------------------------------------------------------------
Write-Host "[PRE-FLIGHT] Retrieving Event Hub connection string..." -ForegroundColor White

$listenConnStr = $null
try {
    $listenConnStr = (az eventhubs namespace authorization-rule keys list `
        --name "ConsumerListenRule" `
        --namespace-name $ehNamespace `
        --resource-group $logsRgName `
        --query primaryConnectionString --output tsv 2>$null)

    if ($listenConnStr) {
        Write-Host "  Connection string retrieved (ConsumerListenRule)." -ForegroundColor Green
    }
} catch {
    # Fall through
}

if (-not $listenConnStr) {
    Write-Host "  ERROR: Could not retrieve ConsumerListenRule connection string." -ForegroundColor Red
    Write-Host "  Ensure deploy-eventhub.ps1 completed successfully." -ForegroundColor Yellow
    exit 1
}

# ------------------------------------------------------------------
# Build deployment parameter overrides
# ------------------------------------------------------------------
$deployParams = @{
    "eventHubConnectionString" = (ConvertTo-SecureString -String $listenConnStr -AsPlainText -Force)
}

if ($locationOverride) {
    $deployParams["location"] = $Location
}

# ------------------------------------------------------------------
# Validate the template
# ------------------------------------------------------------------
Write-Host "[STEP 2/5] Validating ARM template..." -ForegroundColor White

$deploymentName = "functionapp-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

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
# Deploy Function App infrastructure
# ------------------------------------------------------------------
$funcAppName = $paramValues.functionAppName.value

Write-Host "[STEP 3/5] Deploying Function App infrastructure..." -ForegroundColor White
Write-Host "  Deployment name  : $deploymentName" -ForegroundColor Gray
Write-Host "  Resource group   : $logsRgName" -ForegroundColor Gray
Write-Host "  Function App     : $funcAppName" -ForegroundColor Gray
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

    $deployedFuncName = $result.Outputs.functionAppName.Value
    $deployedFuncUrl  = $result.Outputs.functionAppUrl.Value
    $deployedAiName   = $result.Outputs.appInsightsName.Value

    Write-Host "  Function App infrastructure deployed." -ForegroundColor Green

} catch {
    Write-Error "Deployment failed: $($_.Exception.Message)"
    exit 1
}

# ------------------------------------------------------------------
# Deploy function code
# ------------------------------------------------------------------
$codeDeployed = $false

if (-not $SkipCodeDeploy) {
    Write-Host "[STEP 4/5] Deploying function code..." -ForegroundColor White

    # Check Azure Functions Core Tools
    $funcToolsAvailable = $false
    try {
        $funcVersion = func --version 2>$null
        if ($funcVersion) {
            $funcToolsAvailable = $true
            Write-Host "  Azure Functions Core Tools v$funcVersion detected." -ForegroundColor Gray
        }
    } catch {
        # Not installed
    }

    if ($funcToolsAvailable) {
        Write-Host "  Publishing to $deployedFuncName..." -ForegroundColor Gray
        try {
            Push-Location $functionAppDir
            $publishOutput = func azure functionapp publish $deployedFuncName --python 2>&1
            Pop-Location

            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Function code deployed successfully." -ForegroundColor Green
                $codeDeployed = $true
            } else {
                Write-Host "  WARNING: Code deployment returned exit code $LASTEXITCODE." -ForegroundColor Yellow
                $publishOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
            }
        } catch {
            Pop-Location -ErrorAction SilentlyContinue
            Write-Host "  WARNING: Code deployment failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  WARNING: Azure Functions Core Tools not found." -ForegroundColor Yellow
        Write-Host "  Install with: npm i -g azure-functions-core-tools@4 --unsafe-perm true" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  After installing, deploy code manually:" -ForegroundColor White
        Write-Host "    cd $functionAppDir" -ForegroundColor Cyan
        Write-Host "    func azure functionapp publish $deployedFuncName --python" -ForegroundColor Cyan
    }
} else {
    Write-Host "[STEP 4/5] Skipping code deployment (-SkipCodeDeploy specified)." -ForegroundColor Gray
}

# ------------------------------------------------------------------
# Verify function is running
# ------------------------------------------------------------------
Write-Host "[STEP 5/5] Verifying function app status..." -ForegroundColor White

try {
    $funcApp = Get-AzWebApp -ResourceGroupName $logsRgName -Name $deployedFuncName -ErrorAction Stop -WarningAction SilentlyContinue
    $state = $funcApp.State
    Write-Host "  Function App state: $state" -ForegroundColor $(if ($state -eq 'Running') { 'Green' } else { 'Yellow' })
} catch {
    Write-Host "  Could not verify function app state: $($_.Exception.Message)" -ForegroundColor Yellow
}

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
Write-Host ""
Write-Host "======================================================" -ForegroundColor Green
Write-Host "  Audit Monitor Function App Deployed"                  -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Resource Group       : $logsRgName" -ForegroundColor White
Write-Host "  Function App         : $deployedFuncName" -ForegroundColor White
Write-Host "  URL                  : $deployedFuncUrl" -ForegroundColor White
Write-Host "  App Insights         : $deployedAiName" -ForegroundColor White
Write-Host "  Event Hub            : $ehNamespace / cloudhsm-logs" -ForegroundColor White
Write-Host "  Consumer Group       : hsm-scenario-builder" -ForegroundColor White
if ($codeDeployed) {
    Write-Host "  Code                 : Deployed" -ForegroundColor Green
} else {
    Write-Host "  Code                 : NOT deployed (see instructions above)" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Monitored Operations:" -ForegroundColor White
Write-Host "    CN_DELETE_USER, CN_TOMBSTONE_OBJECT," -ForegroundColor Gray
Write-Host "    CN_CREATE_USER, CN_GENERATE_KEY," -ForegroundColor Gray
Write-Host "    CN_GENERATE_KEY_PAIR, CN_INSERT_MASKED_OBJECT_USER," -ForegroundColor Gray
Write-Host "    CN_EXTRACT_MASKED_OBJECT_USER, CN_LOGIN," -ForegroundColor Gray
Write-Host "    CN_LOGOUT, CN_AUTHORIZE_SESSION," -ForegroundColor Gray
Write-Host "    CN_FIND_OBJECTS_USING_COUNT" -ForegroundColor Gray
Write-Host ""
Write-Host "  ----------------------------------------------------" -ForegroundColor Yellow
Write-Host "  VERIFY - Check Function Is Processing Events"         -ForegroundColor Yellow
Write-Host "  ----------------------------------------------------" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. Perform an HSM operation (e.g., generate a key, login)." -ForegroundColor White
Write-Host "  2. Wait 2-5 minutes for logs to flow through the pipeline:" -ForegroundColor White
Write-Host "     HSM operation > Diagnostic Setting > Event Hub > Function" -ForegroundColor Gray
Write-Host "  3. Check Application Insights for [HSM AUDIT] log entries:" -ForegroundColor White
Write-Host "     Portal > Application Insights > $deployedAiName > Logs" -ForegroundColor Gray
Write-Host ""
Write-Host "     traces | where message contains '[HSM AUDIT]' | order by timestamp desc" -ForegroundColor Cyan
Write-Host ""
