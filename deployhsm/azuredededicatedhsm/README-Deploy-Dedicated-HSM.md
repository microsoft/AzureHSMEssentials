# Deploy Azure Dedicated HSM Infrastructure

This folder contains an ARM template and deployment scripts to provision Azure Dedicated HSM (Thales Luna Network HSM A790) infrastructure for HSM Scenario Builder.

> **Prerequisite:** An active Azure subscription with Azure Dedicated HSM access approved. Dedicated HSM requires subscription-level onboarding — contact your Microsoft account team or open a support request to enable the `Microsoft.HardwareSecurityModules/dedicatedHSMs` resource provider.

> **Important:** Azure Dedicated HSM uses **VNet injection** (delegated subnet) rather than private endpoints. The HSM is placed directly into a dedicated subnet in your virtual network.

> **Thales Luna Client OS Support:** The Thales Luna HSM Client software and tools (lunacm, vtl, ckdemo, etc.) are only officially supported on **RHEL 7/8/9** and **CentOS 7/8**. Ubuntu, Debian, and other Linux distributions are not supported. The Admin VM for this platform uses RHEL 8 for this reason. Refer to the [Thales Luna Client documentation](https://thalesdocs.com/gphsm/luna/7/docs/network/Content/Home_Luna.htm) for the latest supported OS matrix.

---

## What Gets Deployed

| Resource                  | Resource Group      | Description                                                                                                                             |
| ------------------------- | ------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| Virtual Network           | DHSM-HSB-CLIENT-RG  | `dhsmclient-vnet` with `default` subnet (10.3.0.0/24), delegated `hsmSubnet` (10.3.1.0/24), and `GatewaySubnet` (10.3.255.0/26) |
| ExpressRoute Gateway PIP  | DHSM-HSB-CLIENT-RG  | Static Standard SKU public IP for the ExpressRoute virtual network gateway                                                              |
| ExpressRoute VNet Gateway | DHSM-HSB-CLIENT-RG  | Standard SKU ExpressRoute gateway — required so the Dedicated HSM service can create a VNIC endpoint for connectivity                  |
| Dedicated HSM             | DHSM-HSB-HSM-RG     | Thales Luna Network HSM A790, injected into the delegated hsmSubnet                                                                     |
| Admin VM*(optional)*    | DHSM-HSB-ADMINVM-RG | Red Hat Enterprise Linux 8 Gen2 VM for HSM administration (only deployed when `-AdminPasswordOrKey` is provided)                      |
| Public IP                 | DHSM-HSB-ADMINVM-RG | Static Standard SKU public IP for admin VM access                                                                                       |
| NSG                       | DHSM-HSB-ADMINVM-RG | Network security group allowing SSH (22) and RDP (3389)                                                                                 |
| NIC                       | DHSM-HSB-ADMINVM-RG | Network interface connected to the client VNet default subnet                                                                           |

---

## Quick Deploy (One Command)

### PowerShell

```powershell
# From the deployhsm/ directory:
.\deploy-hsm.ps1 -Platform AzureDedicatedHSM -SubscriptionId "<YOUR_SUBSCRIPTION_ID>"
```

### PowerShell (with Admin VM -- SSH key)

```powershell
# Deploy with an admin VM using SSH public key authentication (default):
.\deploy-hsm.ps1 -Platform AzureDedicatedHSM -SubscriptionId "<YOUR_SUBSCRIPTION_ID>" `
    -AdminPasswordOrKey (ConvertTo-SecureString "ssh-rsa AAAA..." -AsPlainText -Force) `
    -AdminUsername "azureuser" `
    -AuthenticationType sshPublicKey
```

### PowerShell (with Admin VM -- password)

```powershell
# Deploy with an admin VM using password authentication:
.\deploy-hsm.ps1 -Platform AzureDedicatedHSM -SubscriptionId "<YOUR_SUBSCRIPTION_ID>" `
    -AdminPasswordOrKey (Read-Host -AsSecureString -Prompt "Admin password") `
    -AdminUsername "<YOUR_USERNAME>" `
    -AuthenticationType password
```

### Bash / Azure CLI

```bash
# From the deployhsm/ directory:
./deploy-hsm.sh --platform azuredededicatedhsm --subscription-id "<YOUR_SUBSCRIPTION_ID>"
```

### Bash / Azure CLI (with Admin VM -- SSH key)

```bash
./deploy-hsm.sh --platform azuredededicatedhsm --subscription-id "<YOUR_SUBSCRIPTION_ID>" \
    --admin-password-or-key "ssh-rsa AAAA..." \
    --admin-username "azureuser" \
    --auth-type "sshPublicKey"
```

Both scripts will:

1. Set your active subscription
2. Deploy the ARM template with the parameters file
3. Output the Dedicated HSM name and resource IDs on completion

---

## Script Options

| Parameter                                            | Required | Description                                                                |
| ---------------------------------------------------- | -------- | -------------------------------------------------------------------------- |
| `Platform` / `--platform`                        | Yes      | Set to `AzureDedicatedHSM` (PS) or `azuredededicatedhsm` (bash)        |
| `SubscriptionId` / `--subscription-id`           | Yes      | Azure subscription ID                                                      |
| `AdminPasswordOrKey` / `--admin-password-or-key` | No       | SSH public key or password for the admin VM. If omitted, no VM is deployed |
| `AdminUsername` / `--admin-username`             | No       | Admin username for the VM (default:`azureuser`)                          |
| `AuthenticationType` / `--auth-type`             | No       | `sshPublicKey` or `password` (default: `sshPublicKey`)               |
| `Location` / `--location`                        | No       | Azure region (default:`East US`)                                         |
| `ParameterFile` / `--parameter-file`             | No       | Path to ARM parameters file. Defaults to `dedicatedhsm-parameters.json`  |

---

## Manual Deploy

### Azure CLI

```bash
az account set --subscription "<YOUR_SUBSCRIPTION_ID>"

az deployment sub create \
  --location "East US" \
  --template-file dedicatedhsm-deploy.json \
  --parameters dedicatedhsm-parameters.json
```

### PowerShell (Az Module)

```powershell
Set-AzContext -SubscriptionId "<YOUR_SUBSCRIPTION_ID>"

New-AzSubscriptionDeployment `
  -Location "East US" `
  -TemplateFile dedicatedhsm-deploy.json `
  -TemplateParameterFile dedicatedhsm-parameters.json
```

### Azure Portal

1. Go to **Deploy a custom template** in the Azure Portal
2. Click **Build your own template in the editor**
3. Paste the contents of `dedicatedhsm-deploy.json` → **Save**
4. Click **Edit parameters** → paste `dedicatedhsm-parameters.json` → **Save**
5. Select your subscription → **Review + Create** → **Create**

---

## Customizing Parameters

Edit `dedicatedhsm-parameters.json` before deploying, or pass overrides on the command line.

| Parameter                      | Default                           | Description                                                             |
| ------------------------------ | --------------------------------- | ----------------------------------------------------------------------- |
| `location`                   | `East US`                       | Azure region (must support Dedicated HSM)                               |
| `clientResourceGroupName`    | `DHSM-HSB-CLIENT-RG`            | Resource group for networking                                           |
| `serverResourceGroupName`    | `DHSM-HSB-HSM-RG`               | Resource group for the Dedicated HSM                                    |
| `vnetName`                   | `dhsmclient-vnet`               | Virtual network name                                                    |
| `vnetAddressPrefix`          | `10.3.0.0/16`                   | VNet address space                                                      |
| `subnetName`                 | `default`                       | General-purpose subnet name                                             |
| `subnetAddressPrefix`        | `10.3.0.0/24`                   | General-purpose subnet address range                                    |
| `hsmSubnetName`              | `hsmSubnet`                     | Delegated subnet name for Dedicated HSM                                 |
| `hsmSubnetAddressPrefix`     | `10.3.1.0/24`                   | Delegated subnet address range                                          |
| `gatewaySubnetAddressPrefix` | `10.3.255.0/26`                 | GatewaySubnet address range for ExpressRoute gateway                    |
| `erGatewayName`              | `dhsm-er-gateway`               | Name of the ExpressRoute virtual network gateway                        |
| `dedicatedHsmName`           | *(auto-generated)*              | Leave empty to generate a unique name                                   |
| `hsmSkuName`                 | `SafeNet Luna Network HSM A790` | HSM SKU (only Luna A790 supported; for payShield use Azure Payment HSM) |
| `stampId`                    | `stamp1`                        | Availability zone stamp (e.g., stamp1, stamp2)                          |
| `adminVmResourceGroupName`   | `DHSM-HSB-ADMINVM-RG`           | Resource group for the admin VM                                         |
| `vmName`                     | `dhsm-admin-vm`                 | Admin VM name                                                           |
| `vmSize`                     | `Standard_D2s_v3`               | VM size                                                                 |
| `adminUsername`              | `azureuser`                     | Admin username for the VM                                               |
| `authenticationType`         | `sshPublicKey`                  | `sshPublicKey` or `password`                                        |
| `adminPasswordOrKey`         | *(empty)*                       | SSH key or password.**If empty, the admin VM is not deployed.**   |

### Override Example (CLI)

```bash
az deployment sub create \
  --location "East US 2" \
  --template-file dedicatedhsm-deploy.json \
  --parameters dedicatedhsm-parameters.json \
  --parameters location="East US 2" dedicatedHsmName="my-dedicated-hsm"
```

---

## Key Differences from Other HSM Platforms

| Feature                   | Azure Dedicated HSM               | Azure Payment HSM                    | Azure Cloud HSM          | Azure Managed HSM        |
| ------------------------- | --------------------------------- | ------------------------------------ | ------------------------ | ------------------------ |
| **Network model**   | VNet injection (delegated subnet) | VNet injection (delegated subnet)    | Private endpoint         | Private endpoint         |
| **HSM hardware**    | Thales Luna Network HSM A790      | Thales payShield 10K                 | Marvell LiquidSecurity   | Marvell LiquidSecurity   |
| **Use case**        | General-purpose crypto            | Payment processing (PCI)             | General-purpose crypto   | General-purpose crypto   |
| **Access model**    | Direct network access from VNet   | Direct network access from VNet      | Private endpoint         | Entra ID RBAC            |
| **Multi-tenant**    | No (single-tenant)                | No (single-tenant)                   | Yes (isolated partition) | Yes (isolated partition) |
| **FIPS validation** | FIPS 140-2 Level 3                | FIPS 140-2 Level 3                   | FIPS 140-3 Level 3       | FIPS 140-3 Level 3       |
| **Management**      | Customer-managed (Luna client)    | Customer-managed (payShield Manager) | Azure-managed            | Azure-managed            |

---

## Verify Deployment

```bash
# Check Dedicated HSM
az resource show \
  --resource-group DHSM-HSB-HSM-RG \
  --resource-type Microsoft.HardwareSecurityModules/dedicatedHSMs \
  --name <dedicated-hsm-name>

# Check VNet and delegated subnet
az network vnet subnet show \
  --resource-group DHSM-HSB-CLIENT-RG \
  --vnet-name dhsmclient-vnet \
  --name hsmSubnet
```

---

## Logging

Azure Dedicated HSM is a **bare-metal, single-tenant** device. It does **NOT** support Azure Monitor diagnostic settings, Log Analytics, or any Azure-native logging integration.

Logging is managed directly on the HSM appliance itself:

1. **Audit logging** — The Luna HSM records all administrative and cryptographic operations in its internal audit log.
2. **Syslog forwarding** — Configure the Luna client to forward audit events to an external syslog server (e.g., Splunk, rsyslog, Azure Monitor Agent on a VM).
3. **SNMP traps** — Enable SNMP on the HSM for operational alerts.

Refer to the [Thales Luna documentation](https://thalesdocs.com/gphsm/luna/7/docs/network/Content/Home_Luna.htm) for detailed logging configuration instructions.

---

## ExpressRoute Gateway

Azure Dedicated HSM requires an **ExpressRoute virtual network gateway** in the VNet so that the service can create a VNIC endpoint for HSM connectivity. The ExpressRoute circuit itself is created and managed internally by the Dedicated HSM service — this is transparent to the user.

The template deploys:

- A **GatewaySubnet** (`10.3.255.0/26`) within the client VNet
- A **Standard SKU ExpressRoute virtual network gateway** with a static public IP

No user action is required to create or link a circuit — the gateway simply needs to exist before the Dedicated HSM resource is provisioned.

See the [Azure Dedicated HSM tutorial](https://learn.microsoft.com/en-us/azure/dedicated-hsm/tutorial-deploy-hsm-powershell) for the full end-to-end walkthrough.

---

## VPN Gateway (Optional)

Add `-EnableVpnGateway` to the deploy command to provision a **Point-to-Site VPN Gateway** in the client VNet. This enables remote/WFH access directly into the HSM environment via OpenVPN.

> **Note:** Dedicated HSM already has an ExpressRoute GatewaySubnet. The P2S VPN Gateway coexists with the ExpressRoute gateway.

```powershell
.\deploy-hsm.ps1 -Platform AzureDedicatedHSM -SubscriptionId "<SUB_ID>" `
    -AdminPasswordOrKey (Read-Host -AsSecureString -Prompt "Admin password") `
    -AuthenticationType password `
    -EnableVpnGateway
```

After the gateway deploys (~20-45 min), generate certificates and download the VPN client config:

```powershell
& ".\vpngateway\P2S VPN Gateway\setup-vpn-certs.ps1" `
    -VpnGatewayName "dhsm-vpn-gateway" `
    -ResourceGroupName "DHSM-HSB-CLIENT-RG"
```

| Detail              | Value                  |
| ------------------- | ---------------------- |
| Gateway Name        | `dhsm-vpn-gateway`   |
| GatewaySubnet       | `10.3.255.0/26`      |
| Client RG           | `DHSM-HSB-CLIENT-RG` |
| Default Client Pool | `192.168.100.0/24`   |

To remove just the VPN Gateway without affecting the HSM deployment:

```powershell
.\..\uninstallhsm\vpngateway\uninstall-vpn-gateway.ps1 `
    -VpnGatewayName "dhsm-vpn-gateway" `
    -ResourceGroupName "DHSM-HSB-CLIENT-RG" -RemoveLocalCerts
```

See [`deployhsm/vpngateway/P2S VPN Gateway/README.md`](../vpngateway/P2S%20VPN%20Gateway/README.md) for full VPN documentation.

---

## Next Steps

Once deployment completes:

1. Install the **Thales Luna HSM Client** on the admin VM
2. Configure the Luna client to connect to the HSM's private IP in the delegated subnet
3. Initialize the HSM partition using the Luna `lunacm` and `vtl` tools
4. Your Azure Dedicated HSM environment is ready for testing

---

## Files in This Folder

| File                             | Description                                    |
| -------------------------------- | ---------------------------------------------- |
| `dedicatedhsm-deploy.json`     | ARM template (subscription-level deployment)   |
| `dedicatedhsm-parameters.json` | Parameter values — edit this before deploying |
| `README.md`                    | This file                                      |

The deployment scripts are in the parent `deployhsm/` directory:

| File                  | Description                                  |
| --------------------- | -------------------------------------------- |
| `../deploy-hsm.ps1` | Universal PowerShell deployment script       |
| `../deploy-hsm.sh`  | Universal Bash / Azure CLI deployment script |
