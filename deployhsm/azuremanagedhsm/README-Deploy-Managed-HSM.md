# Deploy Azure Managed HSM Infrastructure

This folder contains an ARM template and deployment scripts to provision the Azure Managed HSM infrastructure required by HSM Scenario Builder.

> **Key Difference from Cloud HSM:** Azure Managed HSM uses **Entra ID (Azure AD) RBAC-only** authentication -- there are no legacy access policies. You must provide at least one Entra ID object ID as an initial administrator.

---

## What Gets Deployed

| Resource                | Resource Group      | Description                                                                                              |
| ----------------------- | ------------------- | -------------------------------------------------------------------------------------------------------- |
| Virtual Network         | MHSM-HSB-CLIENT-RG  | `mhsmclient-vnet` with a `default` subnet (10.1.0.0/24)                                              |
| Private DNS Zone        | MHSM-HSB-CLIENT-RG  | `privatelink.managedhsm.azure.net`                                                                     |
| DNS -> VNet Link        | MHSM-HSB-CLIENT-RG  | Links DNS zone to the VNet for private name resolution                                                   |
| Private Endpoint        | MHSM-HSB-CLIENT-RG  | Connects VNet to Managed HSM (target sub-resource:`managedhsm`)                                        |
| DNS Zone Group          | MHSM-HSB-CLIENT-RG  | Auto-registers the private endpoint IP in the DNS zone                                                   |
| Admin VM*(optional)*  | MHSM-HSB-ADMINVM-RG | Ubuntu 24.04 LTS Gen2 VM for HSM administration (only deployed when `-AdminPasswordOrKey` is provided) |
| Public IP               | MHSM-HSB-ADMINVM-RG | Static Standard SKU public IP for admin VM access                                                        |
| NSG                     | MHSM-HSB-ADMINVM-RG | Network security group allowing SSH (22) and RDP (3389)                                                  |
| NIC                     | MHSM-HSB-ADMINVM-RG | Network interface connected to the client VNet subnet                                                    |
| Storage Account         | MHSM-HSB-LOGS-RG    | Diagnostic log archive (name auto-generated if left empty)                                               |
| Log Analytics Workspace | MHSM-HSB-LOGS-RG    | Query interface for Managed HSM audit logs                                                               |
| Diagnostic Setting      | MHSM-HSB-HSM-RG     | Routes `AuditEvent` logs to storage + workspace                                                        |
| Managed HSM             | MHSM-HSB-HSM-RG     | Standard_B1 SKU, Entra ID RBAC, soft delete + purge protection                                           |

> **Private Endpoint:** Enabled by default for better security. Set `enablePrivateEndpoint` to `false` in the parameters file to use public network access only.

---

## Quick Deploy (One Command)

### PowerShell

```powershell
# From the deployhsm/ directory:
.\deploy-hsm.ps1 -Platform AzureManagedHSM -SubscriptionId "<YOUR_SUBSCRIPTION_ID>" `
    -InitialAdminObjectIds "<YOUR_ENTRA_OBJECT_ID>"
```

### PowerShell (with Admin VM -- SSH key)

```powershell
.\deploy-hsm.ps1 -Platform AzureManagedHSM -SubscriptionId "<YOUR_SUBSCRIPTION_ID>" `
    -InitialAdminObjectIds "<OBJECT_ID_1>,<OBJECT_ID_2>" `
    -AdminPasswordOrKey (ConvertTo-SecureString "ssh-rsa AAAA..." -AsPlainText -Force) `
    -AdminUsername "azureuser" `
    -AuthenticationType sshPublicKey
```

### PowerShell (with Admin VM -- password)

```powershell
.\deploy-hsm.ps1 -Platform AzureManagedHSM -SubscriptionId "<YOUR_SUBSCRIPTION_ID>" `
    -InitialAdminObjectIds "<YOUR_ENTRA_OBJECT_ID>" `
    -AdminPasswordOrKey (Read-Host -AsSecureString -Prompt "Admin password") `
    -AdminUsername "<YOUR_USERNAME>" `
    -AuthenticationType password
```

### Bash / Azure CLI

```bash
# From the deployhsm/ directory:
./deploy-hsm.sh --platform azuremanagedhsm --subscription-id "<YOUR_SUBSCRIPTION_ID>" \
    --initial-admin-ids "<YOUR_ENTRA_OBJECT_ID>"
```

### Bash / Azure CLI (with Admin VM -- SSH key)

```bash
./deploy-hsm.sh --platform azuremanagedhsm --subscription-id "<YOUR_SUBSCRIPTION_ID>" \
    --initial-admin-ids "<OBJECT_ID_1>,<OBJECT_ID_2>" \
    --admin-password-or-key "ssh-rsa AAAA..." \
    --admin-username "azureuser" \
    --auth-type "sshPublicKey"
```

Both scripts will:

1. Set your active subscription
2. Deploy the ARM template with the parameters file
3. Display the Managed HSM URI, private endpoint DNS, and admin VM details on completion

---

## Script Options

| Parameter                                            | Required | Description                                                                                                  |
| ---------------------------------------------------- | -------- | ------------------------------------------------------------------------------------------------------------ |
| `Platform` / `--platform`                        | Yes      | HSM platform to deploy:`AzureManagedHSM`                                                                   |
| `SubscriptionId` / `--subscription-id`           | Yes      | Azure subscription ID                                                                                        |
| `InitialAdminObjectIds` / `--initial-admin-ids`  | Yes*     | Comma-separated Entra ID object IDs for initial HSM administrators. *Can also be set in the parameters file. |
| `AdminPasswordOrKey` / `--admin-password-or-key` | No       | SSH public key or password for the admin VM. If omitted, no VM is deployed                                   |
| `AdminUsername` / `--admin-username`             | No       | Admin username for the VM (default:`azureuser`)                                                            |
| `AuthenticationType` / `--auth-type`             | No       | `sshPublicKey` or `password` (default: `sshPublicKey`)                                                 |
| `Location` / `--location`                        | No       | Azure region (default:`UK West`)                                                                           |
| `ParameterFile` / `--parameter-file`             | No       | Path to ARM parameters file. Defaults to `managedhsm-parameters.json`                                      |

> **Finding your Entra ID Object ID:**
>
> ```bash
> # Azure CLI
> az ad signed-in-user show --query id -o tsv
> ```
>
> ```powershell
> # PowerShell
> (Get-AzADUser -SignedIn).Id
> ```

---

## Manual Deploy

### Azure CLI

```bash
az account set --subscription "<YOUR_SUBSCRIPTION_ID>"

az deployment sub create \
  --location "UK West" \
  --template-file managedhsm-deploy.json \
  --parameters managedhsm-parameters.json \
  --parameters initialAdminObjectIds='["<YOUR_ENTRA_OBJECT_ID>"]'
```

### PowerShell (Az Module)

```powershell
Set-AzContext -SubscriptionId "<YOUR_SUBSCRIPTION_ID>"

New-AzSubscriptionDeployment `
  -Location "UK West" `
  -TemplateFile managedhsm-deploy.json `
  -TemplateParameterFile managedhsm-parameters.json `
  -initialAdminObjectIds @("<YOUR_ENTRA_OBJECT_ID>")
```

### Azure Portal

1. Go to **Deploy a custom template** in the Azure Portal
2. Click **Build your own template in the editor**
3. Paste the contents of `managedhsm-deploy.json` -> **Save**
4. Click **Edit parameters** -> paste `managedhsm-parameters.json` -> **Save**
5. Add your Entra ID object IDs to `initialAdminObjectIds`
6. Select your subscription -> **Review + Create** -> **Create**

---

## Customizing Parameters

Edit `managedhsm-parameters.json` before deploying, or pass overrides on the command line.

### Core Parameters

| Parameter                   | Default                   | Description                                                            |
| --------------------------- | ------------------------- | ---------------------------------------------------------------------- |
| `location`                | `UK West`               | Azure region for all resources                                         |
| `clientResourceGroupName` | `MHSM-HSB-CLIENT-RG`    | Resource group for networking + private endpoint                       |
| `serverResourceGroupName` | `MHSM-HSB-HSM-RG`       | Resource group for the Managed HSM                                     |
| `managedHsmName`          | *(auto-generated)*      | Leave empty to generate a unique name, or provide your own             |
| `hsmSkuName`              | `Standard_B1`           | SKU name                                                               |
| `tenantId`                | *(subscription tenant)* | Entra ID tenant ID (auto-detected)                                     |
| `initialAdminObjectIds`   | `[]`                    | **Required.** Entra ID object IDs for initial HSM administrators |

### Security & Network Parameters

| Parameter                     | Default  | Description                                                                 |
| ----------------------------- | -------- | --------------------------------------------------------------------------- |
| `enablePrivateEndpoint`     | `true` | Deploy private endpoint (recommended). Set `false` for public-only access |
| `networkAclDefaultAction`   | `Deny` | Firewall default action (`Deny` recommended with private endpoint)        |
| `firewallIpRules`           | `[]`   | IP allow-list rules, e.g.`[{"value":"203.0.113.0/24"}]`                   |
| `softDeleteRetentionInDays` | `90`   | Soft-delete retention (7-90 days)                                           |
| `enablePurgeProtection`     | `true` | Purge protection (recommended, cannot be disabled once enabled)             |

### Networking Parameters

| Parameter               | Default                              | Description                    |
| ----------------------- | ------------------------------------ | ------------------------------ |
| `vnetName`            | `mhsmclient-vnet`                  | Virtual network name           |
| `vnetAddressPrefix`   | `10.1.0.0/16`                      | VNet address space             |
| `subnetName`          | `default`                          | Subnet name                    |
| `subnetAddressPrefix` | `10.1.0.0/24`                      | Subnet address range           |
| `privateDnsZoneName`  | `privatelink.managedhsm.azure.net` | Private DNS zone               |
| `privateEndpointName` | `mhsm-client-private-endpoint`     | Private endpoint resource name |

### Admin VM Parameters

| Parameter                    | Default                 | Description                                                                  |
| ---------------------------- | ----------------------- | ---------------------------------------------------------------------------- |
| `adminVmResourceGroupName` | `MHSM-HSB-ADMINVM-RG` | Resource group for the admin VM                                              |
| `vmName`                   | `mhsm-admin-vm`       | Admin VM name                                                                |
| `vmSize`                   | `Standard_D2s_v3`     | VM size (2 vCPUs, 8 GiB memory)                                              |
| `vmImagePublisher`         | `Canonical`           | VM image publisher                                                           |
| `vmImageOffer`             | `ubuntu-24_04-lts`    | VM image offer                                                               |
| `vmImageSku`               | `server`              | VM image SKU                                                                 |
| `adminUsername`            | `azureuser`           | Admin username for the VM                                                    |
| `authenticationType`       | `sshPublicKey`        | `sshPublicKey` or `password`                                             |
| `adminPasswordOrKey`       | *(empty)*             | SSH public key or password.**If empty, the admin VM is not deployed.** |

### Logging Parameters

| Parameter                     | Default              | Description                                                       |
| ----------------------------- | -------------------- | ----------------------------------------------------------------- |
| `logsResourceGroupName`     | `MHSM-HSB-LOGS-RG` | Resource group for logging resources                              |
| `storageAccountName`        | *(auto-generated)* | Storage account for diagnostic logs. Leave empty to auto-generate |
| `logAnalyticsWorkspaceName` | *(auto-generated)* | Log Analytics workspace name. Leave empty to auto-generate        |
| `logRetentionDays`          | `365`              | Log Analytics workspace retention (1-730 days)                    |

---

## Post-Deployment: Activate the Managed HSM

After deployment, the Managed HSM is provisioned but **not yet operational**. You must download the security domain to activate it. This requires a minimum of 3 RSA Security Officer key pairs and a quorum threshold (e.g. 2-of-3 or 3-of-5).

### Why this is required

- Azure Managed HSM uses a **security domain** to encrypt and protect its internal keys
- The security domain is encrypted with your RSA public keys and can only be restored using the corresponding private keys
- Until the security domain is downloaded, the HSM will not process any key operations
- The downloaded security domain file is your **disaster recovery backup** -- if you lose it and the required quorum of private keys, the HSM data is **unrecoverable**

### Quick activation (automated script)

The activation script (`activate-mhsm.ps1`) runs from your **Windows laptop** using an SSH tunnel through the admin VM to reach the Managed HSM's private endpoint. This avoids Conditional Access issues and doesn't require Azure CLI on the VM.

> **Requires `openssl` in PATH.** Git for Windows includes openssl -- add
> `C:\Program Files\Git\usr\bin` to your PATH if needed. Alternatively:
> `winget install ShiningLight.OpenSSL.Light` or `choco install openssl`.

#### Step 1: Open an SSH tunnel through the admin VM

Open an **Administrator PowerShell** terminal and create an SSH tunnel that forwards
port 443 through the admin VM to the Managed HSM's private endpoint. Keep this
terminal open for the duration of the activation.

```powershell
ssh -L 443:<YOUR_MHSM_NAME>.privatelink.managedhsm.azure.net:443 <user>@<vm-public-ip>
```

#### Step 2: Add a hosts file entry and flush DNS

In a **second Administrator PowerShell** terminal, redirect the HSM's hostname to
localhost so traffic flows through the SSH tunnel:

```powershell
Add-Content C:\Windows\System32\drivers\etc\hosts "127.0.0.1 <YOUR_MHSM_NAME>.managedhsm.azure.net"
ipconfig /flushdns
```

Verify the hosts entry is working (should show `127.0.0.1`):

```powershell
ping <YOUR_MHSM_NAME>.managedhsm.azure.net -n 1
```

> **Note:** `nslookup` bypasses the hosts file and will still show the public IP.
> Use `ping` to verify the hosts entry is active.

#### Step 3: Run the activation script

In the same second terminal, run the PowerShell activation script:

```powershell
.\deployhsm\azuremanagedhsm\activate-mhsm.ps1 -HsmName <YOUR_MHSM_NAME>
```

The script will:

1. Generate 3 RSA key pairs (configurable with `-KeyCount`)
2. Download the security domain (activates the HSM)
3. Verify the HSM is operational
4. Print backup instructions

#### Step 4: Clean up the hosts entry

After activation completes, remove the hosts file entry:

```powershell
(Get-Content C:\Windows\System32\drivers\etc\hosts) -notmatch '<YOUR_MHSM_NAME>' | Set-Content C:\Windows\System32\drivers\etc\hosts
ipconfig /flushdns
```

#### Examples

```powershell
# Default: 3 RSA keys, quorum of 2 (2-of-3)
.\activate-mhsm.ps1 -HsmName my-prod-mhsm

# Require all 3 key holders for recovery (3-of-3)
.\activate-mhsm.ps1 -HsmName my-prod-mhsm -Quorum 3

# 5 RSA keys with a quorum of 3 (3-of-5)
.\activate-mhsm.ps1 -HsmName my-prod-mhsm -KeyCount 5 -Quorum 3

# Custom output directory
.\activate-mhsm.ps1 -HsmName my-prod-mhsm -OutputDir C:\secure\sd-backup

# All options combined
.\activate-mhsm.ps1 -HsmName my-prod-mhsm -KeyCount 5 -Quorum 3 -OutputDir C:\secure\sd-backup
```

#### Options

| Parameter      | Default                               | Description                                          |
| -------------- | ------------------------------------- | ---------------------------------------------------- |
| `-HsmName`   | *(required)*                        | Name of the Managed HSM (short name, not FQDN)       |
| `-Quorum`    | `2`                                 | Minimum keys needed to recover (must be ≤ KeyCount) |
| `-KeyCount`  | `3`                                 | Number of RSA key pairs to generate (minimum 3)      |
| `-OutputDir` | `~\mhsm-security-domain\<hsm-name>` | Directory for certs and security domain              |

### Manual activation

If you prefer to run the steps manually:

```bash
# Generate 3 RSA key pairs for security domain
openssl req -newkey rsa:2048 -nodes -keyout cert_0.key -x509 -days 365 -out cert_0.cer -subj "/CN=MHSM SD 0"
openssl req -newkey rsa:2048 -nodes -keyout cert_1.key -x509 -days 365 -out cert_1.cer -subj "/CN=MHSM SD 1"
openssl req -newkey rsa:2048 -nodes -keyout cert_2.key -x509 -days 365 -out cert_2.cer -subj "/CN=MHSM SD 2"

# Download security domain (activates the HSM)
az keyvault security-domain download \
    --hsm-name <YOUR_MHSM_NAME> \
    --sd-wrapping-keys cert_0.cer cert_1.cer cert_2.cer \
    --sd-quorum 2 \
    --security-domain-file mhsm-security-domain.json
```

> **Critical:** Store the security domain file and private keys in secure offline storage immediately. Distribute private keys to different Security Officers -- no single person should hold all keys. If you lose the security domain file AND the required quorum of private keys, the HSM data is **permanently lost**.

---

## Verify Deployment

```bash
# Check Managed HSM
az keyvault show --hsm-name <YOUR_MHSM_NAME>

# Check private endpoint (if enabled)
az network private-endpoint show \
  --resource-group MHSM-HSB-CLIENT-RG \
  --name mhsm-client-private-endpoint

# Check HSM provisioning status
az keyvault show --hsm-name <YOUR_MHSM_NAME> --query "properties.statusMessage" -o tsv
```

---

## RBAC Role Assignments

Azure Managed HSM uses RBAC-only (no access policies). Common roles:

```bash
# Assign Managed HSM Crypto User role
az keyvault role assignment create \
    --hsm-name <YOUR_MHSM_NAME> \
    --role "Managed HSM Crypto User" \
    --assignee <USER_OR_APP_OBJECT_ID> \
    --scope /

# Assign Managed HSM Crypto Officer role
az keyvault role assignment create \
    --hsm-name <YOUR_MHSM_NAME> \
    --role "Managed HSM Crypto Officer" \
    --assignee <USER_OR_APP_OBJECT_ID> \
    --scope /
```

---

## Diagnostic Logging

Every deployment automatically provisions a **Storage Account** and **Log Analytics Workspace** in `MHSM-HSB-LOGS-RG`, plus a diagnostic setting that routes `AuditEvent` logs to both targets.

### Query Managed HSM Audit Logs (KQL)

```kql
// All Managed HSM operations in the last 24 hours
AzureDiagnostics
| where ResourceType == "MANAGEDHSMS"
| where TimeGenerated > ago(24h)
| project TimeGenerated, OperationName, ResultType, CallerIPAddress, Resource
| order by TimeGenerated desc

// Failed operations
AzureDiagnostics
| where ResourceType == "MANAGEDHSMS"
| where TimeGenerated > ago(7d)
| where ResultType != "Success"
| summarize FailCount=count() by OperationName, ResultType
| order by FailCount desc
```

---

## VPN Gateway (Optional)

Add `-EnableVpnGateway` to the deploy command to provision a **Point-to-Site VPN Gateway** in the client VNet. This enables remote/WFH access directly into the HSM environment via OpenVPN.

```powershell
.\deploy-hsm.ps1 -Platform AzureManagedHSM -SubscriptionId "<SUB_ID>" `
    -AdminPasswordOrKey (Read-Host -AsSecureString -Prompt "Admin password") `
    -AuthenticationType password `
    -EnableVpnGateway
```

After the gateway deploys (~20-45 min), generate certificates and download the VPN client config:

```powershell
& ".\vpngateway\P2S VPN Gateway\setup-vpn-certs.ps1" `
    -VpnGatewayName "mhsm-vpn-gateway" `
    -ResourceGroupName "MHSM-HSB-CLIENT-RG"
```

| Detail              | Value                  |
| ------------------- | ---------------------- |
| Gateway Name        | `mhsm-vpn-gateway`   |
| GatewaySubnet       | `10.1.255.0/26`      |
| Client RG           | `MHSM-HSB-CLIENT-RG` |
| Default Client Pool | `192.168.100.0/24`   |

To remove just the VPN Gateway without affecting the Managed HSM deployment:

```powershell
.\..\uninstallhsm\vpngateway\uninstall-vpn-gateway.ps1 `
    -VpnGatewayName "mhsm-vpn-gateway" `
    -ResourceGroupName "MHSM-HSB-CLIENT-RG" -RemoveLocalCerts
```

See [`deployhsm/vpngateway/P2S VPN Gateway/README.md`](../vpngateway/P2S%20VPN%20Gateway/README.md) for full VPN documentation.

---

## Next Steps

Once deployment and activation complete, your Azure Managed HSM environment is ready for testing.

## Files in This Folder

| File                           | Description                                                                  |
| ------------------------------ | ---------------------------------------------------------------------------- |
| `managedhsm-deploy.json`     | ARM template (subscription-level deployment)                                 |
| `managedhsm-parameters.json` | Parameter values -- edit this before deploying                               |
| `activate-mhsm.sh`           | Security domain activation script (pre-installed on admin VM via cloud-init) |
| `README.md`                  | This file                                                                    |

The deployment scripts are in the parent `deployhsm/` directory:

| File                  | Description                                  |
| --------------------- | -------------------------------------------- |
| `../deploy-hsm.ps1` | Universal PowerShell deployment script       |
| `../deploy-hsm.sh`  | Universal Bash / Azure CLI deployment script |
