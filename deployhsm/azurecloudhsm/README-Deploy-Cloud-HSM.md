# Deploy Azure Cloud HSM Infrastructure

This folder contains an ARM template and deployment scripts to provision the Azure Cloud HSM infrastructure required by HSM Scenario Builder.

> **Prerequisite:** An active Azure subscription. For the full Cloud HSM onboarding walkthrough, see the [Azure Cloud HSM Onboarding Guide (PDF)](https://github.com/microsoft/MicrosoftAzureCloudHSM/blob/main/OnboardingGuides/Azure%20Cloud%20HSM%20Onboarding.pdf).

---

## What Gets Deployed

| Resource | Resource Group | Description |
|---|---|---|
| Virtual Network | CHSM-HSB-CLIENT-RG | `chsmclient-vnet` with a `default` subnet (10.0.2.0/24) |
| Private DNS Zone | CHSM-HSB-CLIENT-RG | `privatelink.cloudhsm.azure.net` |
| DNS → VNet Link | CHSM-HSB-CLIENT-RG | Links DNS zone to the VNet for private name resolution |
| Private Endpoint | CHSM-HSB-CLIENT-RG | Connects VNet to HSM cluster (target sub-resource: `cloudHSM`) |
| DNS Zone Group | CHSM-HSB-CLIENT-RG | Auto-registers the private endpoint IP in the DNS zone |
| Admin VM *(optional)* | CHSM-HSB-ADMINVM-RG | Ubuntu 24.04 LTS Gen2 VM for HSM administration (only deployed when `-AdminPasswordOrKey` is provided) |
| Public IP | CHSM-HSB-ADMINVM-RG | Static Standard SKU public IP for admin VM access |
| NSG | CHSM-HSB-ADMINVM-RG | Network security group allowing SSH (22) and RDP (3389) |
| NIC | CHSM-HSB-ADMINVM-RG | Network interface connected to the client VNet subnet |
| Storage Account | CHSM-HSB-LOGS-RG | Diagnostic log archive (name auto-generated if left empty) |
| Log Analytics Workspace | CHSM-HSB-LOGS-RG | Query interface for Cloud HSM audit logs |
| Diagnostic Setting | CHSM-HSB-HSM-RG | Routes `HsmServiceOperations` logs to storage + workspace |
| Cloud HSM Cluster | CHSM-HSB-HSM-RG | Standard_B1 SKU (name auto-generated if left empty) |

---

## Quick Deploy (One Command)

### PowerShell

```powershell
# From the deployhsm/ directory:
.\deploy-hsm.ps1 -Platform AzureCloudHSM -SubscriptionId "<YOUR_SUBSCRIPTION_ID>"
```

### PowerShell (with Admin VM -- SSH key)

```powershell
# Deploy with an admin VM using SSH public key authentication (default):
.\deploy-hsm.ps1 -Platform AzureCloudHSM -SubscriptionId "<YOUR_SUBSCRIPTION_ID>" `
    -AdminPasswordOrKey (ConvertTo-SecureString "ssh-rsa AAAA..." -AsPlainText -Force) `
    -AdminUsername "azureuser" `
    -AuthenticationType sshPublicKey
```

### PowerShell (with Admin VM -- password)

```powershell
# Deploy with an admin VM using password authentication:
# Option 1: Prompt securely (recommended - password is never visible)
.\deploy-hsm.ps1 -Platform AzureCloudHSM -SubscriptionId "<YOUR_SUBSCRIPTION_ID>" `
    -AdminPasswordOrKey (Read-Host -AsSecureString -Prompt "Admin password") `
    -AdminUsername "<YOUR_USERNAME>" `
    -AuthenticationType password

# Option 2: Inline (for automation only - password appears in command history)
.\deploy-hsm.ps1 -Platform AzureCloudHSM -SubscriptionId "<YOUR_SUBSCRIPTION_ID>" `
    -AdminPasswordOrKey (ConvertTo-SecureString "<YOUR_PASSWORD>" -AsPlainText -Force) `
    -AdminUsername "<YOUR_USERNAME>" `
    -AuthenticationType password
```

### Bash / Azure CLI

```bash
# From the deployhsm/ directory:
./deploy-hsm.sh --platform azurecloudhsm --subscription-id "<YOUR_SUBSCRIPTION_ID>"
```

### Bash / Azure CLI (with Admin VM -- SSH key)

```bash
# Deploy with an admin VM using SSH public key authentication (default):
./deploy-hsm.sh --platform azurecloudhsm --subscription-id "<YOUR_SUBSCRIPTION_ID>" \
    --admin-password-or-key "ssh-rsa AAAA..." \
    --admin-username "azureuser" \
    --auth-type "sshPublicKey"
```

### Bash / Azure CLI (with Admin VM -- password)

```bash
# Deploy with an admin VM using password authentication:
./deploy-hsm.sh --platform azurecloudhsm --subscription-id "<YOUR_SUBSCRIPTION_ID>" \
    --admin-password-or-key '<YOUR_PASSWORD>' \
    --admin-username "<YOUR_USERNAME>" \
    --auth-type "password"
```

Both scripts will:
1. Set your active subscription
2. Deploy the ARM template with the parameters file
3. Output the HSM cluster name and resource IDs on completion

---

## Script Options

| Parameter | Required | Description |
|---|---|---|
| `Platform` / `--platform` | Yes | HSM platform to deploy: `AzureCloudHSM`, `AzureKeyVault`, `AzureManagedHSM` |
| `SubscriptionId` / `--subscription-id` | Yes | Azure subscription ID |
| `AdminPasswordOrKey` / `--admin-password-or-key` | No | SSH public key or password for the admin VM. If omitted, no VM is deployed |
| `AdminUsername` / `--admin-username` | No | Admin username for the VM (default: `azureuser`) |
| `AuthenticationType` / `--auth-type` | No | `sshPublicKey` or `password` (default: `sshPublicKey`) |
| `Location` / `--location` | No | Azure region (default: `UK West`) |
| `ParameterFile` / `--parameter-file` | No | Path to ARM parameters file. Defaults to `cloudhsm-parameters.json` |

---

## Manual Deploy

### Azure CLI

```bash
az account set --subscription "<YOUR_SUBSCRIPTION_ID>"

az deployment sub create \
  --location "UK West" \
  --template-file cloudhsm-deploy.json \
  --parameters cloudhsm-parameters.json
```

### PowerShell (Az Module)

```powershell
Set-AzContext -SubscriptionId "<YOUR_SUBSCRIPTION_ID>"

New-AzSubscriptionDeployment `
  -Location "UK West" `
  -TemplateFile cloudhsm-deploy.json `
  -TemplateParameterFile cloudhsm-parameters.json
```

### Azure Portal

1. Go to **Deploy a custom template** in the Azure Portal
2. Click **Build your own template in the editor**
3. Paste the contents of `cloudhsm-deploy.json` → **Save**
4. Click **Edit parameters** → paste `cloudhsm-parameters.json` → **Save**
5. Select your subscription → **Review + Create** → **Create**

---

## Customizing Parameters

Edit `cloudhsm-parameters.json` before deploying, or pass overrides on the command line.

| Parameter | Default | Description |
|---|---|---|
| `location` | `UK West` | Azure region for all resources |
| `clientResourceGroupName` | `CHSM-HSB-CLIENT-RG` | Resource group for networking + private endpoint |
| `serverResourceGroupName` | `CHSM-HSB-HSM-RG` | Resource group for the Cloud HSM cluster |
| `vnetName` | `chsmclient-vnet` | Virtual network name |
| `vnetAddressPrefix` | `10.0.0.0/16` | VNet address space |
| `subnetName` | `default` | Subnet name |
| `subnetAddressPrefix` | `10.0.2.0/24` | Subnet address range |
| `privateDnsZoneName` | `privatelink.cloudhsm.azure.net` | Private DNS zone |
| `hsmClusterName` | *(auto-generated)* | Leave empty to generate a unique name, or provide your own |
| `hsmSkuFamily` | `B` | SKU family (only `B` supported) |
| `hsmSkuName` | `Standard_B1` | SKU name (only `Standard_B1` supported) |
| `privateEndpointName` | `chsm-client-private-endpoint` | Private endpoint resource name |
| `adminVmResourceGroupName` | `CHSM-HSB-ADMINVM-RG` | Resource group for the admin VM |
| `vmName` | `chsm-admin-vm` | Admin VM name |
| `vmSize` | `Standard_D2s_v3` | VM size (2 vCPUs, 8 GiB memory) |
| `vmImagePublisher` | `Canonical` | VM image publisher (`MicrosoftWindowsServer` for Windows) |
| `vmImageOffer` | `ubuntu-24_04-lts` | VM image offer (`WindowsServer` for Windows) |
| `vmImageSku` | `server` | VM image SKU (`2022-datacenter-g2` for Windows Gen2) |
| `adminUsername` | `azureuser` | Admin username for the VM |
| `authenticationType` | `sshPublicKey` | `sshPublicKey` or `password` |
| `adminPasswordOrKey` | *(empty)* | SSH public key or password. **If empty, the admin VM is not deployed.** |
| `logsResourceGroupName` | `CHSM-HSB-LOGS-RG` | Resource group for logging resources |
| `storageAccountName` | *(auto-generated)* | Storage account for diagnostic logs. Leave empty to auto-generate |
| `logAnalyticsWorkspaceName` | *(auto-generated)* | Log Analytics workspace name. Leave empty to auto-generate |
| `logRetentionDays` | `365` | Log Analytics workspace retention (1-730 days) |

### Override Example (CLI)

```bash
az deployment sub create \
  --location "East US" \
  --template-file cloudhsm-deploy.json \
  --parameters cloudhsm-parameters.json \
  --parameters location="East US" hsmClusterName="my-hsm-cluster"
```

---

## Verify Deployment

```bash
# Check HSM cluster
az resource show \
  --resource-group CHSM-HSB-HSM-RG \
  --resource-type Microsoft.HardwareSecurityModules/cloudHsmClusters \
  --name <hsm-cluster-name>

# Check private endpoint
az network private-endpoint show \
  --resource-group CHSM-HSB-CLIENT-RG \
  --name chsm-client-private-endpoint
```

---

## Diagnostic Logging

Every deployment automatically provisions a **Storage Account** and **Log Analytics Workspace** in `CHSM-HSB-LOGS-RG`, plus a diagnostic setting that routes `HsmServiceOperations` logs to both targets.

### Query Cloud HSM Audit Logs (KQL)

```kql
// All operations in the last 24 hours
CloudHsmServiceOperationAuditLogs
| where TimeGenerated > ago(24h)
| project TimeGenerated, OperationName, ResultType, CallerIpAddress
| order by TimeGenerated desc

// Failed operations
CloudHsmServiceOperationAuditLogs
| where TimeGenerated > ago(7d)
| where ResultType != "Success"
| summarize FailCount=count() by OperationName, ResultType
| order by FailCount desc
```

---

## Post-Deployment: Activate the Cloud HSM

After deployment, the Cloud HSM cluster is provisioned but **not yet operational**. You must install the Azure Cloud HSM SDK, configure connectivity, and create a Partition Officer (PO) certificate to activate the HSM.

> **All activation steps must run on the admin VM** (which has private endpoint access to the HSM).

### Why this is required

- Azure Cloud HSM requires the **Azure Cloud HSM SDK** (client tools + PKCS#11/JCE/OpenSSL libraries) to interact with the HSM
- The SDK includes the `azcloudhsm_resource.cfg` configuration file that must point to your HSM's FQDN
- A **Partition Officer (PO)** certificate must be created and uploaded to the HSM before it can process key operations
- Until the PO certificate is uploaded, the HSM partition is in an **uninitialized** state

### Step 1 — Install the Azure Cloud HSM SDK

Download the correct SDK package from GitHub for the OS running on your admin VM.
The deployment **defaults to Ubuntu 24.04**, but you can override the VM image via the
`vmImagePublisher` / `vmImageOffer` / `vmImageSku` parameters — so choose the matching
package from the [releases page](https://github.com/microsoft/MicrosoftAzureCloudHSM/releases).

| Admin VM OS | Package format | Install command |
|---|---|---|
| **Ubuntu / Debian** | `.deb` | `sudo dpkg -i <package>.deb` |
| **RHEL / CentOS / Fedora** | `.rpm` | `sudo rpm -i <package>.rpm` |
| **Windows Server** | `.msi` | Run the MSI installer |

> Pick the **OpenSSL 3** variant for Ubuntu 24.04+ and RHEL 9+.
> Pick the **OpenSSL 1.1** variant for Ubuntu 20.04/22.04 and RHEL 7/8.

**Default (Ubuntu 24.04 / OpenSSL 3):**

```bash
# SSH into the admin VM
ssh <user>@<vm-ip>

# Download the SDK
curl -LO https://github.com/microsoft/MicrosoftAzureCloudHSM/releases/download/AzureCloudHSM-ClientSDK-2.0.2.4/AzureCloudHSM-ClientSDK-OpenSSL3-2.0.2.4.deb

# Install
sudo dpkg -i AzureCloudHSM-ClientSDK-OpenSSL3-2.0.2.4.deb
```

> If a newer SDK version is available, check
> [github.com/microsoft/MicrosoftAzureCloudHSM/releases](https://github.com/microsoft/MicrosoftAzureCloudHSM/releases)
> and download the package that matches your OS and OpenSSL version.

### Step 2 — Configure the HSM hostname

Update the SDK configuration file with your HSM's FQDN (shown in deployment output as HSM1):

| OS | Config path |
|---|---|
| **Linux** | `/opt/azcloudhsm/bin/azcloudhsm_resource.cfg` |
| **Windows** | `C:\ProgramData\AzureCloudHSM\client\azcloudhsm_resource.cfg` |
| | `C:\ProgramData\AzureCloudHSM\mgmt_util\azcloudhsm_resource.cfg` |

```bash
# Linux — edit the resource configuration file
sudo nano /opt/azcloudhsm/bin/azcloudhsm_resource.cfg
```

Set the `hostname` to the FQDN of HSM1 from the deployment output (e.g., `<cluster-name>.hsm1.cloudhsm.azure.net`):

```ini
[server]
hostname = <YOUR_HSM1_FQDN>
```

### Step 3 — Create a Partition Officer and activate the HSM

Follow the [Azure Cloud HSM Onboarding Guide (PDF)](https://github.com/microsoft/MicrosoftAzureCloudHSM/blob/main/OnboardingGuides/Azure%20Cloud%20HSM%20Onboarding.pdf)
to create a Partition Officer (PO) certificate, upload it to the HSM, and complete activation.
The guide also includes verification steps to confirm the HSM is operational.

All onboarding guides are available at:
[github.com/microsoft/MicrosoftAzureCloudHSM/tree/main/OnboardingGuides](https://github.com/microsoft/MicrosoftAzureCloudHSM/tree/main/OnboardingGuides)

> **Additional resources from Microsoft:**
>
> | Resource | Link |
> |---|---|
> | **Onboarding Guides** (activation, provisioning) | [github.com/.../OnboardingGuides](https://github.com/microsoft/MicrosoftAzureCloudHSM/tree/main/OnboardingGuides) |
> | **Integration Guides** (customer scenarios) | [github.com/.../IntegrationGuides](https://github.com/microsoft/MicrosoftAzureCloudHSM/tree/main/IntegrationGuides) |

---

## VPN Gateway (Optional)

Add `-EnableVpnGateway` to the deploy command to provision a **Point-to-Site VPN Gateway** in the client VNet. This enables remote/WFH access directly into the HSM environment via OpenVPN.

```powershell
.\deploy-hsm.ps1 -Platform AzureCloudHSM -SubscriptionId "<SUB_ID>" `
    -AdminPasswordOrKey (Read-Host -AsSecureString -Prompt "Admin password") `
    -AuthenticationType password `
    -EnableVpnGateway
```

After the gateway deploys (~20-45 min), generate certificates and download the VPN client config:

```powershell
& ".\vpngateway\P2S VPN Gateway\setup-vpn-certs.ps1" `
    -VpnGatewayName "chsm-vpn-gateway" `
    -ResourceGroupName "CHSM-HSB-CLIENT-RG"
```

| Detail | Value |
|---|---|
| Gateway Name | `chsm-vpn-gateway` |
| GatewaySubnet | `10.0.255.0/26` |
| Client RG | `CHSM-HSB-CLIENT-RG` |
| Default Client Pool | `192.168.100.0/24` |

To remove just the VPN Gateway without affecting the HSM deployment:

```powershell
.\..\uninstallhsm\vpngateway\uninstall-vpn-gateway.ps1 `
    -VpnGatewayName "chsm-vpn-gateway" `
    -ResourceGroupName "CHSM-HSB-CLIENT-RG" -RemoveLocalCerts
```

See [`deployhsm/vpngateway/P2S VPN Gateway/README.md`](../vpngateway/P2S%20VPN%20Gateway/README.md) for full VPN documentation.

---

## Next Steps

Once deployment and activation complete, your Azure Cloud HSM environment is ready for testing.

## Files in This Folder

| File | Description |
|---|---|
| `cloudhsm-deploy.json` | ARM template (subscription-level deployment) |
| `cloudhsm-parameters.json` | Parameter values — edit this before deploying |
| `README.md` | This file |

The deployment scripts are in the parent `deployhsm/` directory:

| File | Description |
|---|---|
| `../deploy-hsm.ps1` | Universal PowerShell deployment script |
| `../deploy-hsm.sh` | Universal Bash / Azure CLI deployment script |
