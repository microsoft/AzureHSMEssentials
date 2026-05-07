# Configure Event Hub for HSM Platforms

If you configured Event Logging for your HSM platform then you already have a working Diagnostic Setting that routes audit logs to Storage and Log Analytics. Adding Event Hub is simply adding a third destination to that same Diagnostic Setting or creating a new one that targets Event Hub.

Supports **Azure Cloud HSM**, **Azure Key Vault**, and **Azure Managed HSM**.

> **Why this is easy:** Azure Monitor Diagnostic Settings support multiple destinations simultaneously. Since your Log Analytics pipeline already proves that log emission is working, Event Hub just becomes another sink receiving the same log category.

> **Prefer automation?** Run `deploy-eventhub.ps1` to deploy Event Hub and wire up the diagnostic setting in one step:
>
> ```powershell
> .\deploy-eventhub.ps1 -Platform AzureCloudHSM -SubscriptionId "<your-subscription-id>"
> .\deploy-eventhub.ps1 -Platform AzureKeyVault -SubscriptionId "<your-subscription-id>"
> .\deploy-eventhub.ps1 -Platform AzureManagedHSM -SubscriptionId "<your-subscription-id>"
> ```
>
> The steps below are the manual equivalent if you prefer to do it yourself.

---

## Platform Reference

The resource group names, resource types, and log categories differ by platform. Use this table throughout the guide -- replace the placeholders with the values for your platform.

| Value                      | Azure Cloud HSM                                        | Azure Key Vault               | Azure Managed HSM                  |
| -------------------------- | ------------------------------------------------------ | ----------------------------- | ---------------------------------- |
| **Logs RG**          | `CHSM-HSB-LOGS-RG`                                   | `AKV-HSB-LOGS-RG`           | `MHSM-HSB-LOGS-RG`               |
| **HSM/KV RG**        | `CHSM-HSB-HSM-RG`                                    | `AKV-HSB-HSM-RG`            | `MHSM-HSB-HSM-RG`                |
| **Resource type**    | `Microsoft.HardwareSecurityModules/cloudHsmClusters` | `Microsoft.KeyVault/vaults` | `Microsoft.KeyVault/managedHSMs` |
| **Log category**     | `HsmServiceOperations`                               | `AuditEvent`                | `AuditEvent`                     |
| **Namespace prefix** | `chsm-hsb-eventhub-ns`                               | `akv-hsb-eventhub-ns`       | `mhsm-hsb-eventhub-ns`           |
| **Hub name**         | `cloudhsm-logs`                                      | `keyvault-logs`             | `managedhsm-logs`                |
| **-Platform param**  | `AzureCloudHSM`                                      | `AzureKeyVault`             | `AzureManagedHSM`                |

---

## Prerequisites

* HSM platform deployed via HSM Scenario Builder (logs RG and HSM RG must exist -- see Platform Reference above)
* Diagnostic settings emitting event logs for your platform
* Permissions (`Contributor` or `Monitoring Contributor` on the resource group)

---

## Step 1: Verify the Logs Resource Group Exists

The Event Hub deploys into the logs resource group created by the base deployment. Verify it exists (substitute your platform's logs RG from the Platform Reference table):

```powershell
az group show --name "<LOGS-RG>" --query "{name:name, location:location}" --output table
```

If it doesn't exist, deploy your HSM platform first via `deploy-hsm.ps1`.

---

## Step 2: Create an Event Hub Namespace

The namespace is the container that holds one or more Event Hubs. Use **Standard** tier (required for Diagnostic Settings integration):

```powershell
az eventhubs namespace create `
  --name "<namespace-prefix>" `
  --resource-group "<LOGS-RG>" `
  --location "<location>" `
  --sku Standard `
  --capacity 1 `
  --enable-auto-inflate false
```

**Key options:**

- `--sku Standard` -- Basic tier does **not** support Diagnostic Settings as a destination
- `--capacity 1` -- 1 throughput unit (1 MB/s ingress, 2 MB/s egress) -- plenty for HSM audit logs
- `--enable-auto-inflate false` -- HSM log volume is low; auto-inflate is unnecessary

---

## Step 3: Create an Event Hub (Topic) Inside the Namespace

```powershell
az eventhubs eventhub create `
  --name "<hub-name>" `
  --namespace-name "<namespace-prefix>" `
  --resource-group "<LOGS-RG>" `
  --partition-count 2 `
  --retention-time-in-hours 168 `
  --cleanup-policy Delete
```

**Key options:**

- `--partition-count 2` -- 2 partitions is sufficient for HSM audit log throughput
- `--retention-time-in-hours 168` -- Keep messages for 7 days (168 hours; max 168 for Standard tier)
- `--cleanup-policy Delete` -- Delete messages after retention period expires

---

## Step 4: Create a Consumer Group

Create a dedicated consumer group for downstream processing (the default `$Default` group should be reserved):

```powershell
az eventhubs eventhub consumer-group create `
  --name "hsm-scenario-builder" `
  --namespace-name "<namespace-prefix>" `
  --eventhub-name "<hub-name>" `
  --resource-group "<LOGS-RG>"
```

---

## Step 5: Create an Authorization Rule (Shared Access Policy)

Diagnostic Settings needs **Send** permission to push logs into the Event Hub:

```powershell
az eventhubs namespace authorization-rule create `
  --name "DiagnosticSettingsSendRule" `
  --namespace-name "<namespace-prefix>" `
  --resource-group "<LOGS-RG>" `
  --rights Send
```

> **Security note:** This rule only grants `Send` -- not `Listen` or `Manage`. Follow least-privilege. Your downstream consumers (Azure Functions, Stream Analytics, etc.) will use a separate rule with `Listen`.

---

## Step 6: Get the Authorization Rule Resource ID

You'll need this for the Diagnostic Setting. Retrieve it:

```powershell
$authRuleId = az eventhubs namespace authorization-rule show `
  --name "DiagnosticSettingsSendRule" `
  --namespace-name "<namespace-prefix>" `
  --resource-group "<LOGS-RG>" `
  --query id --output tsv

Write-Host "Auth Rule ID: $authRuleId"
```

Save this value -- you'll use it in the next step.

---

## Step 7: Update the Diagnostic Setting to Add Event Hub

You have two options here:

### Option A: Update the Existing Diagnostic Setting (Recommended)

This updates `hsb-diagnostic-setting` to add Event Hub **while keeping** Storage and Log Analytics:

```powershell
# First, get your existing resource IDs
$hsmResourceGroup = "<HSM-RG>"
$logsResourceGroup = "<LOGS-RG>"

# Find the HSM cluster name (auto-generated during deployment)
$resourceName = az resource list `
  --resource-group $hsmResourceGroup `
  --resource-type <resource-type> `
  --query "[0].name" --output tsv
Write-Host "Resource: $resourceName"

# Get the resource ID
$resourceId = az resource show `
  --resource-group $hsmResourceGroup `
  --resource-type <resource-type> `
  --name $resourceName `
  --query id --output tsv

# Get your existing storage account ID
$storageAccountId = az storage account list `
  --resource-group $logsResourceGroup `
  --query "[0].id" --output tsv

# Get your existing Log Analytics workspace ID
$workspaceId = az monitor log-analytics workspace list `
  --resource-group $logsResourceGroup `
  --query "[0].id" --output tsv

# Get the Event Hub auth rule ID (from Step 5)
$authRuleId = az eventhubs namespace authorization-rule show `
  --name "DiagnosticSettingsSendRule" `
  --namespace-name "<namespace-prefix>" `
  --resource-group $logsResourceGroup `
  --query id --output tsv

# Update the diagnostic setting with all three destinations
az monitor diagnostic-settings create `
  --name "hsb-diagnostic-setting" `
  --resource $resourceId `
  --storage-account $storageAccountId `
  --workspace $workspaceId `
  --event-hub "<hub-name>" `
  --event-hub-rule $authRuleId `
  --logs '[{\"category\":\"<log-category>\",\"enabled\":true}]'
```

> **Important:** `az monitor diagnostic-settings create` is an **upsert** -- if the name matches an existing setting, it **replaces** it entirely. That's why you must include `--storage-account` and `--workspace` again, otherwise those destinations will be removed.

### Option B: Create a Separate Diagnostic Setting for Event Hub Only

If you prefer to keep your existing setting untouched and add a second one:

```powershell
# Find the resource name (if you don't already have it from Option A)
$resourceName = az resource list `
  --resource-group "<HSM-RG>" `
  --resource-type <resource-type> `
  --query "[0].name" --output tsv

$resourceId = az resource show `
  --resource-group "<HSM-RG>" `
  --resource-type <resource-type> `
  --name $resourceName `
  --query id --output tsv

$authRuleId = az eventhubs namespace authorization-rule show `
  --name "DiagnosticSettingsSendRule" `
  --namespace-name "<namespace-prefix>" `
  --resource-group "<LOGS-RG>" `
  --query id --output tsv

az monitor diagnostic-settings create `
  --name "hsb-eventhub-diagnostic-setting" `
  --resource $resourceId `
  --event-hub "<hub-name>" `
  --event-hub-rule $authRuleId `
  --logs '[{\"category\":\"<log-category>\",\"enabled\":true}]'
```

> **Note:** Azure supports up to 5 Diagnostic Settings per resource. A second setting is perfectly valid and keeps concerns separated.

---

## Step 8: Verify Event Hub Is Receiving Messages

### 8a. Check Diagnostic Setting in the Portal

1. Go to **Azure Portal** -> your HSM/Key Vault resource
2. Click **Diagnostic settings** under Monitoring
3. Confirm Event Hub is listed as a destination

### 8b. Check Event Hub Metrics

```powershell
# Get your subscription ID
$subId = az account show --query id --output tsv

# Check incoming messages (last 1 hour)
az monitor metrics list `
  --resource "/subscriptions/$subId/resourceGroups/<LOGS-RG>/providers/Microsoft.EventHub/namespaces/<namespace-prefix>" `
  --metric "SuccessfulRequests" `
  --interval PT1H `
  --output table
```

### 8c. Quick Peek at Messages (Optional)

If you want to actually read a few messages to confirm content, create a **Listen** rule:

```powershell
# Create a Listen rule for your consumer
az eventhubs namespace authorization-rule create `
  --name "ConsumerListenRule" `
  --namespace-name "<namespace-prefix>" `
  --resource-group "<LOGS-RG>" `
  --rights Listen

# Get the connection string
az eventhubs namespace authorization-rule keys list `
  --name "ConsumerListenRule" `
  --namespace-name "<namespace-prefix>" `
  --resource-group "<LOGS-RG>" `
  --query primaryConnectionString --output tsv
```

You can use this connection string with Azure Event Hub Explorer, VS Code Event Hub extension, or a quick Python script to peek at messages.

---

## Step 9: Deploy the Audit Monitor Function App (Optional)

Event Hub on its own is just a pipe. Messages arrive and sit there for up to 7 days. Without a **consumer** reading from the other end, you can't see or react to the HSM audit log content. The Event Hub metrics (`IncomingMessages`, `SuccessfulRequests`) only confirm messages are arriving, not what's inside them.

To close the loop, deploy the **Audit Monitor Function App** -- an Azure Function that triggers on each Event Hub message batch, extracts the audit records, and filters for security-relevant operations.

### Why use it?

| Without Function App                             | With Function App                                                     |
| ------------------------------------------------ | --------------------------------------------------------------------- |
| Messages sit in Event Hub for 7 days then expire | Each message is processed in near real-time                           |
| You can only see message counts (metrics)        | You see the full audit trail: operation, caller IP, timestamp, result |
| No alerting or downstream integration            | Structured logs in Application Insights -- queryable, alertable       |
| Manual effort to peek at messages                | Automatic processing of every HSM operation                           |

### What it monitors

The function filters for these HSM operations (Cloud HSM example -- Key Vault and Managed HSM emit different operation names):

| Operation                         | Why it matters                                    | Log Level    |
| --------------------------------- | ------------------------------------------------- | ------------ |
| `CN_DELETE_USER`                | HSM user deleted -- destructive identity event    | `CRITICAL` |
| `CN_TOMBSTONE_OBJECT`           | Key deleted from HSM -- destructive, irreversible | `CRITICAL` |
| `CN_CREATE_USER`                | New HSM user created -- identity management event | `WARNING`  |
| `CN_GENERATE_KEY`               | Symmetric key generated                           | `WARNING`  |
| `CN_GENERATE_KEY_PAIR`          | Asymmetric key pair generated                     | `WARNING`  |
| `CN_INSERT_MASKED_OBJECT_USER`  | Key imported into HSM -- key movement event       | `WARNING`  |
| `CN_EXTRACT_MASKED_OBJECT_USER` | Key exported from HSM -- key movement event       | `WARNING`  |
| `CN_LOGIN`                      | Session authentication                            | `INFO`     |
| `CN_LOGOUT`                     | Session ended                                     | `INFO`     |
| `CN_AUTHORIZE_SESSION`          | Session authorization -- access control event     | `INFO`     |
| `CN_FIND_OBJECTS_USING_COUNT`   | Key enumeration -- recon or inventory operation   | `INFO`     |

Destructive operations (user/key deletion) are logged at `CRITICAL` level. Key generation and key movement at `WARNING`. Login/logout, session, and enumeration at `INFO`.

### Prerequisites

- Event Hub deployed via `deploy-eventhub.ps1`
- [Azure Functions Core Tools v4](https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local#install-the-azure-functions-core-tools) installed:

  ```powershell
  npm i -g azure-functions-core-tools@4 --unsafe-perm true
  ```

### Deploy

```powershell
.\deploy-functionapp.ps1 -SubscriptionId "<your-subscription-id>"
```

The script will:

1. Verify the Event Hub namespace exists
2. Retrieve the `ConsumerListenRule` connection string automatically
3. Deploy a Linux Consumption Function App (Python 3.11) with Application Insights
4. Publish the function code from `azure_functions/`
5. Verify the function app is running

If Functions Core Tools are not installed, the script will deploy the infrastructure and give you the manual publish command to run after installing.

### Verify it's working

After deploying, perform an HSM operation (generate a key, login, etc.) and wait 2-5 minutes for logs to flow through the pipeline:

```
HSM operation → Diagnostic Setting → Event Hub → Function App → Application Insights
```

Query Application Insights to see the audit entries:

```kql
traces
| where message contains '[HSM AUDIT]'
| order by timestamp desc
| take 20
```

You should see structured entries like:

```
[HSM AUDIT] CN_GENERATE_KEY_PAIR from 10.0.2.4 | {"operation":"CN_GENERATE_KEY_PAIR","timestamp":"2026-04-07T16:23:45Z","callerIp":"10.0.2.4","result":"Success",...}
```

---

## Summary: What You End Up With

All resources deploy into the logs resource group for your platform (see Platform Reference).

| Resource                    | Name                              | Details                                                          |
| --------------------------- | --------------------------------- | ---------------------------------------------------------------- |
| Event Hub Namespace         | `<namespace-prefix>`            | Standard tier, 1 TU, auto-inflate disabled, TLS 1.2              |
| Event Hub                   | `<hub-name>`                    | 2 partitions, 7-day message retention                            |
| Consumer Group              | `hsm-scenario-builder`          | Dedicated group for audit monitor function                       |
| Auth Rule (Send)            | `DiagnosticSettingsSendRule`    | Send-only, used by Diagnostic Setting                            |
| Auth Rule (Listen)          | `ConsumerListenRule`            | Listen-only, used by Function App                                |
| Diagnostic Setting          | `hsb-diagnostic-setting`        | Routes `<log-category>` to Storage + Log Analytics + Event Hub |
| Function App (optional)     | `<prefix>-hsb-audit-monitor`    | Linux Consumption, Python 3.11                                   |
| App Insights (optional)     | `<prefix>-hsb-audit-monitor-ai` | Telemetry for function app                                       |
| Function Storage (optional) | `<prefix>hsbfuncstor`           | Standard LRS, used by function runtime                           |

**Log categories by platform:**

| Platform          | Log Category       | Description                      |
| ----------------- | ------------------ | -------------------------------- |
| Azure Cloud HSM   | `<log-category>` | HSM cluster operation audit logs |
| Azure Key Vault   | `AuditEvent`     | Key Vault audit events           |
| Azure Managed HSM | `AuditEvent`     | Managed HSM audit events         |

```
HSM / Key Vault Resource
  +-- Diagnostic Setting: "hsb-diagnostic-setting"
        |-- Storage Account                  <-- archival (long-term retention)
        |-- Log Analytics Workspace          <-- ad-hoc KQL queries & dashboards
        +-- Event Hub: "<hub-name>"       <-- real-time streaming
              +-- Namespace: "<namespace-prefix>" (Standard, 1 TU)
                    |-- Auth Rule: "DiagnosticSettingsSendRule" (Send only)
                    |-- Auth Rule: "ConsumerListenRule" (Listen only)
                    |-- Consumer Group: "hsm-scenario-builder"
                    +-- Function App: "<prefix>-hsb-audit-monitor" (optional)
                          |-- Runtime: Python 3.11, Linux Consumption
                          +-- Output: Application Insights ([HSM AUDIT] logs)
```

**Deployment scripts:**

| Script                     | Purpose                                                                                           |
| -------------------------- | ------------------------------------------------------------------------------------------------- |
| `deploy-eventhub.ps1`    | Steps 1-8: Event Hub namespace, hub, auth rules, consumer group, diagnostic setting, metric check |
| `deploy-functionapp.ps1` | Step 9: Function App infrastructure + code deployment                                             |

---

## Troubleshooting

| Issue                                                | Cause                                                    | Fix                                                                                                                                                            |
| ---------------------------------------------------- | -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| No messages appearing in Event Hub                   | Diagnostic Setting not yet propagated                    | Wait 5-10 minutes; diagnostic settings can take time to start flowing                                                                                          |
| `AuthorizationFailed` on diagnostic setting create | Missing permissions                                      | Need `Monitoring Contributor` on the HSM/KV resource and `Azure Event Hubs Data Owner` on the namespace                                                    |
| `InvalidEventHubEndpoint`                          | Wrong auth rule scope                                    | Ensure the auth rule is on the**namespace**, not on a specific Event Hub                                                                                 |
| Event Hub Basic tier error                           | Basic SKU doesn't support diagnostic logs                | Must use**Standard** or **Premium** tier                                                                                                           |
| Messages in Event Hub but wrong format               | Expected -- Diagnostic logs wrap in Azure Monitor schema | Messages arrive as JSON arrays in the[Azure Monitor diagnostic log schema](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/resource-logs-schema) |
| Function App not processing events                   | Function code not deployed                               | Run `func azure functionapp publish <prefix>-hsb-audit-monitor --python` from `azure_functions/`                                                           |
| No `[HSM AUDIT]` entries in App Insights           | No monitored operations performed yet                    | Perform an HSM/KV operation (generate key, login) and wait 2-5 minutes                                                                                         |
| Function App shows 0 executions                      | Event Hub connection string missing or wrong             | Check `EventHubConnection` app setting in the Function App configuration                                                                                     |

---

## Related Links

- [Azure Cloud HSM operation event logging](https://learn.microsoft.com/en-us/azure/cloud-hsm/tutorial-operation-event-logging)
- [Azure Key Vault logging](https://learn.microsoft.com/en-us/azure/key-vault/general/logging)
- [Azure Managed HSM logging](https://learn.microsoft.com/en-us/azure/key-vault/managed-hsm/logging)
- [Azure Event Hubs documentation](https://learn.microsoft.com/en-us/azure/event-hubs/event-hubs-about)
- [Diagnostic settings in Azure Monitor](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings)
- [Azure Monitor diagnostic log schema](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/resource-logs-schema)
