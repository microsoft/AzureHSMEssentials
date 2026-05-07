# Configure Log Analytics for HSM Platforms

The base HSM deployment (`deploy-hsm.ps1`) can include logging resources automatically. However, if you deployed your HSM platform without the logging parameters, or if you want to add Log Analytics after the initial deployment without rerunning `deploy-hsm.ps1` (which could create duplicate or orphaned resources), this scenario deploys the logging resources independently.

This creates the same Storage Account, Log Analytics workspace, and diagnostic setting that the base deployment would have created -- carved out as a standalone, safe-to-rerun deployment.

Supports **Azure Cloud HSM**, **Azure Key Vault**, and **Azure Managed HSM**.

> **Prefer automation?** Run `deploy-loganalytics.ps1` to deploy everything in one step:
>
> ```powershell
> .\deploy-loganalytics.ps1 -Platform AzureCloudHSM -SubscriptionId "<your-subscription-id>"
> .\deploy-loganalytics.ps1 -Platform AzureKeyVault -SubscriptionId "<your-subscription-id>"
> .\deploy-loganalytics.ps1 -Platform AzureManagedHSM -SubscriptionId "<your-subscription-id>"
> ```
>
> The steps below are the manual equivalent if you prefer to do it yourself.

---

## Platform Reference

The resource group names, resource types, and log categories differ by platform. Use this table throughout the guide -- replace the placeholders with the values for your platform.

| Value | Azure Cloud HSM | Azure Key Vault | Azure Managed HSM |
|---|---|---|---|
| **Logs RG** | `CHSM-HSB-LOGS-RG` | `AKV-HSB-LOGS-RG` | `MHSM-HSB-LOGS-RG` |
| **HSM/KV RG** | `CHSM-HSB-HSM-RG` | `AKV-HSB-HSM-RG` | `MHSM-HSB-HSM-RG` |
| **Resource type** | `Microsoft.HardwareSecurityModules/cloudHsmClusters` | `Microsoft.KeyVault/vaults` | `Microsoft.KeyVault/managedHSMs` |
| **Log category** | `HsmServiceOperations` | `AuditEvent` | `AuditEvent` |
| **KQL table** | `CloudHsmServiceOperationAuditLogs` | `AzureDiagnostics` | `AzureDiagnostics` |
| **Storage prefix** | `chsmlogs` | `akvlogs` | `mhsmlogs` |
| **Workspace prefix** | `chsm-logs-` | `akv-logs-` | `mhsm-logs-` |
| **-Platform param** | `AzureCloudHSM` | `AzureKeyVault` | `AzureManagedHSM` |

---

## Prerequisites

* HSM platform deployed via HSM Scenario Builder (logs RG and HSM RG must exist -- see Platform Reference above)
* Permissions (`Contributor` or `Monitoring Contributor` on the subscription)
* `Microsoft.Insights` resource provider registered (the script handles this automatically)

---

## Step 1: Verify the Logs Resource Group Exists

The logging resources deploy into the logs resource group created by the base deployment. Verify it exists (substitute your platform's logs RG from the Platform Reference table):

```powershell
# Cloud HSM example -- replace with your platform's logs RG
az group show --name "CHSM-HSB-LOGS-RG" --query "{name:name, location:location}" --output table
```

You should see the resource group in your deployment region (e.g., `ukwest`). If it does not exist, deploy your HSM platform first via `deploy-hsm.ps1`.

---

## Step 2: Register the Microsoft.Insights Provider

Diagnostic settings require the `Microsoft.Insights` resource provider. If your subscription has not used diagnostic settings before, you need to register it:

```powershell
# Check registration state
az provider show --namespace Microsoft.Insights --query "registrationState" --output table
```

If it shows `NotRegistered`, register it:

```powershell
az provider register --namespace Microsoft.Insights

# Verify registration (may take a minute)
az provider show --namespace Microsoft.Insights --query "registrationState" --output table
```

Or with PowerShell:

```powershell
Register-AzResourceProvider -ProviderNamespace Microsoft.Insights
Get-AzResourceProvider -ProviderNamespace Microsoft.Insights |
    Select-Object ProviderNamespace, RegistrationState
```

> **Reference:** [Microsoft docs -- Registration error](https://learn.microsoft.com/en-us/azure/cloud-hsm/tutorial-operation-event-logging#registration-error)

---

## Step 3: Create a Storage Account for HSM Logs

The storage account provides long-term archival of diagnostic logs. Use your platform's storage prefix and logs RG from the Platform Reference table:

```powershell
# Cloud HSM example -- adjust name prefix and RG for your platform
az storage account create `
  --name "<prefix>logsXXXXXXXX" `
  --resource-group "<LOGS-RG>" `
  --location "<location>" `
  --sku Standard_LRS `
  --kind StorageV2 `
  --https-only true `
  --min-tls-version TLS1_2 `
  --allow-blob-public-access false
```

Replace `<prefix>` with your platform prefix (`chsm`, `akv`, or `mhsm`), `<LOGS-RG>` with your logs resource group, and `XXXXXXXX` with a unique suffix (storage account names must be globally unique, 3-24 chars, lowercase alphanumeric only).

**Key options:**

- `--sku Standard_LRS` -- Locally redundant storage; sufficient for diagnostic logs
- `--kind StorageV2` -- General-purpose v2 (required for blob lifecycle management)
- `--https-only true` -- Enforces HTTPS; no unencrypted traffic
- `--min-tls-version TLS1_2` -- Minimum TLS 1.2
- `--allow-blob-public-access false` -- No public blob access

> **Reference:** [Microsoft docs -- Create a storage account to store HSM logs](https://learn.microsoft.com/en-us/azure/cloud-hsm/tutorial-operation-event-logging#create-a-storage-account-to-store-hsm-logs)

---

## Step 4: Create a Log Analytics Workspace

The Log Analytics workspace enables KQL queries against your audit logs:

```powershell
# Cloud HSM example -- adjust name prefix and RG for your platform
az monitor log-analytics workspace create `
  --resource-group "<LOGS-RG>" `
  --workspace-name "<prefix>-logs-XXXXXXXX" `
  --location "<location>" `
  --retention-time 365
```

Replace `<prefix>` with your platform prefix and `<LOGS-RG>` with your logs resource group.

**Key options:**

- `--retention-time 365` -- Retain logs for 365 days (1-730 days supported). Adjust to meet your compliance requirements.

The workspace uses the `PerGB2018` pricing tier (pay-as-you-go), which is the default and most cost-effective for HSM audit log volumes.

> **Reference:** [Microsoft docs -- Create a Log Analytics workspace](https://learn.microsoft.com/en-us/azure/cloud-hsm/tutorial-operation-event-logging#create-a-log-analytics-workspace)

---

## Step 5: Create the Diagnostic Setting

The diagnostic setting connects your HSM/KV resource to both the Storage Account and Log Analytics workspace, routing audit logs to both. Use the resource type and log category for your platform from the Platform Reference table.

### Find Your HSM/KV Resource

```powershell
# Cloud HSM example
$resourceName = az resource list `
  --resource-group "<HSM-RG>" `
  --resource-type <resource-type> `
  --query "[0].name" --output tsv
Write-Host "Resource: $resourceName"
```

### Get Resource IDs

```powershell
$resourceId = az resource show `
  --resource-group "<HSM-RG>" `
  --resource-type <resource-type> `
  --name $resourceName `
  --query id --output tsv

$storageAccountId = az storage account list `
  --resource-group "<LOGS-RG>" `
  --query "[0].id" --output tsv

$workspaceId = az monitor log-analytics workspace list `
  --resource-group "<LOGS-RG>" `
  --query "[0].id" --output tsv
```

### Create the Diagnostic Setting

```powershell
# Replace <log-category> with HsmServiceOperations (Cloud HSM) or AuditEvent (KV/MHSM)
az monitor diagnostic-settings create `
  --name "hsb-diagnostic-setting" `
  --resource $resourceId `
  --storage-account $storageAccountId `
  --workspace $workspaceId `
  --logs '[{\"category\":\"<log-category>\",\"enabled\":true}]'
```

Or with PowerShell (Az.Monitor 7.x):

```powershell
$logSetting = New-AzDiagnosticSettingLogSettingsObject -Category "<log-category>" -Enabled $true

New-AzDiagnosticSetting `
  -Name "hsb-diagnostic-setting" `
  -ResourceId $resourceId `
  -StorageAccountId $storageAccountId `
  -WorkspaceId $workspaceId `
  -Log $logSetting
```

> **Important:** `az monitor diagnostic-settings create` is an **upsert**. If a setting with the same name already exists, it **replaces** it entirely. Always include all desired destinations (Storage, Log Analytics, and Event Hub if applicable) to avoid removing existing ones.

> **Reference:** [Microsoft docs -- Enable diagnostic settings](https://learn.microsoft.com/en-us/azure/cloud-hsm/tutorial-operation-event-logging#enable-diagnostic-settings-by-using-the-azure-cli-or-azure-powershell)

---

## Step 6: Verify Logs Are Flowing

Logs start flowing within 1-2 minutes after creating the diagnostic setting.

### 6a. Check the Diagnostic Setting in the Portal

1. Go to **Azure Portal** > your HSM/KV resource
2. Click **Diagnostic settings** under Monitoring
3. Confirm `hsb-diagnostic-setting` is listed with Storage Account and Log Analytics destinations

### 6b. Query Logs via Azure CLI

```powershell
$workspaceCustomerId = az monitor log-analytics workspace show `
  --resource-group "<LOGS-RG>" `
  --workspace-name "<workspace-name>" `
  --query customerId -o tsv

# Cloud HSM: CloudHsmServiceOperationAuditLogs | Key Vault/Managed HSM: AzureDiagnostics
az monitor log-analytics query `
  -w $workspaceCustomerId `
  --analytics-query "<KQL-table> | take 10"
```

### 6c. Query Logs via KQL in the Portal

Navigate to **Log Analytics workspace** > **Logs** and run the query for your platform:

**Cloud HSM:**
```kql
CloudHsmServiceOperationAuditLogs
| take 10
```

**Key Vault / Managed HSM:**
```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| take 10
```

> **Note:** If no logs appear immediately, perform an HSM operation (e.g., login, generate a key) and wait 1-2 minutes for the log to be emitted.

> **Reference:** [Microsoft docs -- Verify the configuration of Cloud HSM logging](https://learn.microsoft.com/en-us/azure/cloud-hsm/tutorial-operation-event-logging#verify-the-configuration-of-cloud-hsm-logging)

---

## Step 7: Example Queries

Once logs are flowing, use these KQL queries to investigate operations.

### Cloud HSM Queries

These use the `CloudHsmServiceOperationAuditLogs` table ([Microsoft docs](https://learn.microsoft.com/en-us/azure/cloud-hsm/tutorial-operation-event-logging#query-operation-event-logs)).

```kql
// Login and session events
CloudHsmServiceOperationAuditLogs
| where OperationName in ("CN_LOGIN", "CN_AUTHORIZE_SESSION")
| project OperationName, MemberId, CallerIpAddress, TimeGenerated
```

```kql
// User creation and deletion
CloudHsmServiceOperationAuditLogs
| where OperationName in ("CN_CREATE_USER", "CN_DELETE_USER")
| project OperationName, MemberId, CallerIpAddress, TimeGenerated
```

```kql
// Key generation
CloudHsmServiceOperationAuditLogs
| where OperationName in ("CN_GENERATE_KEY", "CN_GENERATE_KEY_PAIR")
| project OperationName, MemberId, CallerIpAddress, TimeGenerated
```

```kql
// Key deletion
CloudHsmServiceOperationAuditLogs
| where OperationName == "CN_TOMBSTONE_OBJECT"
| project OperationName, MemberId, CallerIpAddress, TimeGenerated
```

```kql
// All operations in the last 24 hours
CloudHsmServiceOperationAuditLogs
| where TimeGenerated > ago(24h)
| summarize count() by OperationName
| order by count_ desc
```

### Key Vault / Managed HSM Queries

These use the `AzureDiagnostics` table with `ResourceProvider == "MICROSOFT.KEYVAULT"`.

```kql
// All Key Vault/MHSM operations in the last 24 hours
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where TimeGenerated > ago(24h)
| summarize count() by OperationName
| order by count_ desc
```

```kql
// Key operations
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where OperationName has "Key"
| project OperationName, CallerIPAddress, TimeGenerated, ResultType
```

```kql
// Secret operations
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where OperationName has "Secret"
| project OperationName, CallerIPAddress, TimeGenerated, ResultType
```

---

## Summary: What You End Up With

All resources deploy into the platform's logs resource group (`CHSM-HSB-LOGS-RG`, `AKV-HSB-LOGS-RG`, or `MHSM-HSB-LOGS-RG`).

| Resource                | Name                           | Details                                                |
| ----------------------- | ------------------------------ | ------------------------------------------------------ |
| Storage Account         | `<prefix>logs{uniqueString}` | Standard LRS, StorageV2, TLS 1.2, no public access     |
| Log Analytics Workspace | `<prefix>-logs-{uniqueString}` | PerGB2018 SKU, 365-day retention                      |
| Diagnostic Setting      | `hsb-diagnostic-setting`     | Routes audit logs to Storage + Log Analytics           |

```
HSM / Key Vault Resource
  |-- Diagnostic Setting: "hsb-diagnostic-setting"
        |-- Storage Account          <-- archival (long-term blob retention)
        |-- Log Analytics Workspace  <-- KQL queries, dashboards, alerts
```

**Log categories by platform:**

| Platform | Log Category | KQL Table |
|---|---|---|
| Azure Cloud HSM | `HsmServiceOperations` | `CloudHsmServiceOperationAuditLogs` |
| Azure Key Vault | `AuditEvent` | `AzureDiagnostics` |
| Azure Managed HSM | `AuditEvent` | `AzureDiagnostics` |

**Deployment script:**

| Script                      | Purpose                                                                                                                |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `deploy-loganalytics.ps1` | Steps 1-6: Storage Account, Log Analytics workspace, Microsoft.Insights registration, diagnostic setting, verification |

---

## Troubleshooting

| Issue                                                          | Cause                                                  | Fix                                                                                                                                    |
| -------------------------------------------------------------- | ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| Logs RG does not exist                                         | HSM platform not deployed yet                          | Deploy your platform first via `deploy-hsm.ps1 -Platform <platform>`                                                                |
| `<subscription> is not registered to use microsoft.insights` | Microsoft.Insights provider not registered             | Run `az provider register --namespace Microsoft.Insights` (see Step 2)                                                               |
| No logs in Log Analytics after 5 minutes                       | No operations performed                                | Perform an operation (login, generate key, access secret) and wait 1-2 minutes                                                         |
| `AuthorizationFailed` on diagnostic setting                  | Missing permissions                                    | Need `Monitoring Contributor` on the HSM/KV resource group                                                                           |
| Storage account name already taken                             | Globally unique name conflict                          | Provide a custom name via the `storageAccountName` parameter                                                                         |
| Diagnostic setting removes Event Hub                           | `az monitor diagnostic-settings create` is an upsert | Include `--event-hub` and `--event-hub-rule` when updating (or use `deploy-loganalytics.ps1` which preserves existing Event Hub) |
| KQL table not found                                            | Logs have not been ingested yet                        | Wait for first operation; table is auto-created on first log ingestion                                                                 |
| Duplicate logging resources                                    | Reran `deploy-hsm.ps1` instead of this script        | Use this scenario to add logging independently; ARM incremental mode is idempotent                                                     |

---

## Related Links

- [Tutorial: Configure and query operation event logging for Azure Cloud HSM](https://learn.microsoft.com/en-us/azure/cloud-hsm/tutorial-operation-event-logging)
- [Azure Key Vault logging](https://learn.microsoft.com/en-us/azure/key-vault/general/logging)
- [Azure Managed HSM logging](https://learn.microsoft.com/en-us/azure/key-vault/managed-hsm/logging)
- [Azure Cloud HSM overview](https://learn.microsoft.com/en-us/azure/cloud-hsm/overview)
- [Create a Log Analytics workspace](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/quick-create-workspace)
- [Azure Monitor diagnostic settings](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings)
