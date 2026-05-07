# Azure Key Vault Deployment — HSM Scenario Builder

Deploys an **Azure Key Vault** (Premium SKU by default — HSM-backed keys) with:

- **Entra ID RBAC-only** authentication (no legacy access policies)
- **Private endpoint** with private DNS zone (enabled by default, opt-out with `enablePrivateEndpoint: false`)
- **Firewall** with default-Deny network ACLs
- **Soft delete** (90 days) and **purge protection** enabled
- **Optional admin VM** connected to the same VNet for private access
- **Diagnostic logging** to Storage Account + Log Analytics Workspace (always-on)
- Four resource groups: `AKV-HSB-CLIENT-RG` (networking), `AKV-HSB-HSM-RG` (Key Vault), `AKV-HSB-ADMINVM-RG` (VM), `AKV-HSB-LOGS-RG` (logging)

---

## What Gets Deployed

| Resource | Resource Group | Description |
|---|---|---|
| Virtual Network | AKV-HSB-CLIENT-RG | `akvclient-vnet` with a `default` subnet |
| Private DNS Zone | AKV-HSB-CLIENT-RG | `privatelink.vaultcore.azure.net` |
| DNS → VNet Link | AKV-HSB-CLIENT-RG | Links DNS zone to the VNet for private name resolution |
| Private Endpoint | AKV-HSB-CLIENT-RG | Connects VNet to Key Vault (target sub-resource: `vault`) |
| DNS Zone Group | AKV-HSB-CLIENT-RG | Auto-registers the private endpoint IP in the DNS zone |
| Admin VM *(optional)* | AKV-HSB-ADMINVM-RG | Ubuntu 24.04 LTS Gen2 VM for Key Vault administration (only deployed when `-AdminPasswordOrKey` is provided) |
| Public IP | AKV-HSB-ADMINVM-RG | Static Standard SKU public IP for admin VM access |
| NSG | AKV-HSB-ADMINVM-RG | Network security group allowing SSH (22) and RDP (3389) |
| NIC | AKV-HSB-ADMINVM-RG | Network interface connected to the client VNet subnet |
| Storage Account | AKV-HSB-LOGS-RG | Diagnostic log archive (name auto-generated if left empty) |
| Log Analytics Workspace | AKV-HSB-LOGS-RG | Query interface for Key Vault audit logs |
| Diagnostic Setting | AKV-HSB-HSM-RG | Routes `AuditEvent` logs to storage + workspace |
| Key Vault (Premium) | AKV-HSB-HSM-RG | Premium SKU, Entra ID RBAC, soft delete + purge protection |

---

## Quick Deploy

### PowerShell (no admin VM)

```powershell
.\deploy-hsm.ps1 -Platform AzureKeyVault `
    -SubscriptionId "<YOUR_SUBSCRIPTION_ID>"
```

### PowerShell (with admin VM — password auth)

```powershell
.\deploy-hsm.ps1 -Platform AzureKeyVault `
    -SubscriptionId "<YOUR_SUBSCRIPTION_ID>" `
    -AdminPasswordOrKey (Read-Host -AsSecureString -Prompt "Admin password") `
    -AdminUsername "chsmVMAdmin" `
    -AuthenticationType password
```

### PowerShell (with admin VM — SSH key)

```powershell
.\deploy-hsm.ps1 -Platform AzureKeyVault `
    -SubscriptionId "<YOUR_SUBSCRIPTION_ID>" `
    -AdminPasswordOrKey (ConvertTo-SecureString -AsPlainText -Force (Get-Content ~/.ssh/id_rsa.pub)) `
    -AdminUsername "azureuser" `
    -AuthenticationType sshPublicKey
```

### Bash (no admin VM)

```bash
./deploy-hsm.sh --platform azurekeyvault \
    --subscription-id "<YOUR_SUBSCRIPTION_ID>"
```

### Bash (with admin VM — password auth)

```bash
./deploy-hsm.sh --platform azurekeyvault \
    --subscription-id "<YOUR_SUBSCRIPTION_ID>" \
    --admin-password-or-key "YourP@ssw0rd!" \
    --admin-username "chsmVMAdmin" \
    --auth-type password
```

---

## Script Options

| Option (PowerShell)         | Option (Bash)                  | Required | Description |
|-----------------------------|--------------------------------|----------|-------------|
| `-Platform`                 | `--platform`, `-t`             | Yes      | Set to `AzureKeyVault` (PS) or `azurekeyvault` (bash) |
| `-SubscriptionId`           | `--subscription-id`, `-s`      | Yes      | Azure subscription ID |
| `-Location`                 | `--location`, `-l`             | No       | Azure region override (default from parameters file) |
| `-ParameterFile`            | `--parameter-file`, `-p`       | No       | Custom parameters file path |
| `-AdminPasswordOrKey`       | `--admin-password-or-key`      | No       | SSH key or password — triggers admin VM deployment |
| `-AdminUsername`             | `--admin-username`             | No       | VM admin username (default: `azureuser`) |
| `-AuthenticationType`       | `--auth-type`                  | No       | `sshPublicKey` or `password` (default: `sshPublicKey`) |

---

## Customizing Parameters

Edit `keyvault-parameters.json` or pass a custom file via `-ParameterFile` / `--parameter-file`.

### Core Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `location` | `UK West` | Azure region |
| `keyVaultName` | `""` (auto-generated) | Globally unique Key Vault name (3-24 chars) |
| `skuName` | `premium` | `premium` = HSM-backed keys; `standard` = software keys only |

### Security Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `softDeleteRetentionInDays` | `90` | Days to retain soft-deleted vault (7-90) |
| `enablePurgeProtection` | `true` | Prevent purging of soft-deleted vault (cannot be disabled once enabled) |

### Network Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `enablePrivateEndpoint` | `true` | Deploy private endpoint (set `false` for public-only access) |
| `privateEndpointName` | `akv-client-private-endpoint` | Name for the private endpoint |
| `networkAclDefaultAction` | `Deny` | Firewall default action (`Deny` recommended) |
| `firewallIpRules` | `[]` | IP rules array, e.g. `[{"value":"203.0.113.0/24"}]` |
| `vnetName` | `akvclient-vnet` | Virtual network name |
| `vnetAddressPrefix` | `10.2.0.0/16` | VNet address space |
| `subnetName` | `default` | Subnet name |
| `subnetAddressPrefix` | `10.2.0.0/24` | Subnet CIDR |
| `privateDnsZoneName` | `privatelink.vaultcore.azure.net` | Private DNS zone for Key Vault |

### VM Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `adminVmResourceGroupName` | `AKV-HSB-ADMINVM-RG` | Resource group for the admin VM |
| `vmName` | `akv-admin-vm` | VM name |
| `vmSize` | `Standard_D2s_v3` | VM size (2 vCPUs, 8 GiB) |
| `vmImagePublisher` | `Canonical` | Image publisher |
| `vmImageOffer` | `ubuntu-24_04-lts` | Image offer |
| `vmImageSku` | `server` | Image SKU |
| `adminUsername` | `azureuser` | VM admin username |
| `authenticationType` | `sshPublicKey` | `sshPublicKey` or `password` |

### Logging Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `logsResourceGroupName` | `AKV-HSB-LOGS-RG` | Resource group for logging resources |
| `storageAccountName` | `""` (auto-generated) | Storage account for diagnostic logs |
| `logAnalyticsWorkspaceName` | `""` (auto-generated) | Log Analytics workspace name |
| `logRetentionDays` | `365` | Log Analytics workspace retention (1-730 days) |

---

## Post-Deployment

### Assign RBAC Roles

Azure Key Vault uses Entra ID RBAC. Assign roles to users/apps:

```bash
# Key Vault Crypto Officer — full key management
az role assignment create \
    --role "Key Vault Crypto Officer" \
    --assignee "<USER_OR_APP_OBJECT_ID>" \
    --scope "/subscriptions/<SUB_ID>/resourceGroups/AKV-HSB-HSM-RG/providers/Microsoft.KeyVault/vaults/<VAULT_NAME>"

# Key Vault Secrets Officer — full secret management
az role assignment create \
    --role "Key Vault Secrets Officer" \
    --assignee "<USER_OR_APP_OBJECT_ID>" \
    --scope "/subscriptions/<SUB_ID>/resourceGroups/AKV-HSB-HSM-RG/providers/Microsoft.KeyVault/vaults/<VAULT_NAME>"

# Key Vault Certificates Officer — full certificate management
az role assignment create \
    --role "Key Vault Certificates Officer" \
    --assignee "<USER_OR_APP_OBJECT_ID>" \
    --scope "/subscriptions/<SUB_ID>/resourceGroups/AKV-HSB-HSM-RG/providers/Microsoft.KeyVault/vaults/<VAULT_NAME>"
```

### Verify Deployment

```bash
# Check Key Vault
az keyvault show --name <VAULT_NAME> --query "{name:name, sku:properties.sku.name, uri:properties.vaultUri, rbac:properties.enableRbacAuthorization}"

# Create an HSM-backed test key (Premium SKU)
az keyvault key create --vault-name <VAULT_NAME> --name test-key --kty RSA-HSM --size 2048

# List keys
az keyvault key list --vault-name <VAULT_NAME> --output table
```

### Premium vs Standard SKU

| Feature | Standard | Premium |
|---------|----------|---------|
| Software-protected keys | Yes | Yes |
| HSM-backed keys (RSA-HSM, EC-HSM) | No | **Yes** |
| FIPS 140-2 Level 2 | No | **Yes** |
| Price per operation | Lower | Higher |

The default `premium` SKU is recommended for HSM Scenario Builder to enable HSM-backed key operations.

---

## Resource Groups

See the [What Gets Deployed](#what-gets-deployed) table above for full resource details.

---

## Diagnostic Logging

Every deployment automatically provisions a **Storage Account** and **Log Analytics Workspace** in `AKV-HSB-LOGS-RG`, plus a diagnostic setting that routes `AuditEvent` logs to both targets.

### Query Key Vault Audit Logs (KQL)

```kql
// All Key Vault operations in the last 24 hours
AzureDiagnostics
| where ResourceType == "VAULTS"
| where TimeGenerated > ago(24h)
| project TimeGenerated, OperationName, ResultType, CallerIPAddress, Resource
| order by TimeGenerated desc

// Failed operations
AzureDiagnostics
| where ResourceType == "VAULTS"
| where TimeGenerated > ago(7d)
| where ResultType != "Success"
| summarize FailCount=count() by OperationName, ResultType
| order by FailCount desc
```

---

## VPN Gateway (Optional)

Add `-EnableVpnGateway` to the deploy command to provision a **Point-to-Site VPN Gateway** in the client VNet. This enables remote/WFH access directly into the HSM environment via OpenVPN.

```powershell
.\deploy-hsm.ps1 -Platform AzureKeyVault -SubscriptionId "<SUB_ID>" `
    -AdminPasswordOrKey (Read-Host -AsSecureString -Prompt "Admin password") `
    -AuthenticationType password `
    -EnableVpnGateway
```

After the gateway deploys (~20-45 min), generate certificates and download the VPN client config:

```powershell
& ".\vpngateway\P2S VPN Gateway\setup-vpn-certs.ps1" `
    -VpnGatewayName "akv-vpn-gateway" `
    -ResourceGroupName "AKV-HSB-CLIENT-RG"
```

| Detail | Value |
|---|---|
| Gateway Name | `akv-vpn-gateway` |
| GatewaySubnet | `10.2.255.0/26` |
| Client RG | `AKV-HSB-CLIENT-RG` |
| Default Client Pool | `192.168.100.0/24` |

To remove just the VPN Gateway without affecting the Key Vault deployment:

```powershell
.\..\uninstallhsm\vpngateway\uninstall-vpn-gateway.ps1 `
    -VpnGatewayName "akv-vpn-gateway" `
    -ResourceGroupName "AKV-HSB-CLIENT-RG" -RemoveLocalCerts
```

See [`deployhsm/vpngateway/P2S VPN Gateway/README.md`](../vpngateway/P2S%20VPN%20Gateway/README.md) for full VPN documentation.
