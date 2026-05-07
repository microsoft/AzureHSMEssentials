# Azure Payment HSM -- ARM Deployment Template

## Overview

This ARM template deploys an **Azure Payment HSM** (Thales payShield 10K) using VNet injection via a delegated subnet, along with an optional admin virtual machine.

Azure Payment HSM is a bare-metal, single-tenant service designed for **payment processing workloads** -- cryptographic key operations such as PIN processing, payment credential issuing, transaction authorization, and payment data protection. It uses the same Azure resource provider as Azure Dedicated HSM (`Microsoft.HardwareSecurityModules/dedicatedHSMs`) but with `payShield10K` SKUs.

> **Note:** Azure Payment HSM is a bare-metal device and does **NOT** support Azure Monitor diagnostic settings or Log Analytics. Logging is managed directly on the HSM appliance via the payShield Manager console.

## Prerequisites

> **Important:** Azure Payment HSM is a **limited-availability service**. Deployment is gated by Microsoft and requires a sponsored business case before a subscription can provision the resource.

Before attempting to deploy with this template:

1. **Engage your Microsoft account team.** Contact your Microsoft Account Manager and Cloud Solution Architect (CSA) to discuss your payment processing scenario, expected transaction volume, regulatory requirements (PCI DSS, PCI PIN, regional compliance), and target deployment region.

2. **Submit a business case for approval.** Your account team will sponsor and submit your subscription for Payment HSM enablement through the official Microsoft Payment HSM onboarding process. Approval is not self-service and requires a documented business justification.

3. **Confirm subscription enablement before deploying.** You will be notified once your subscription has been approved and the required platform enablements are in place. Attempting to deploy before approval completes will result in `InvalidResourceType` errors during ARM provisioning.

4. **Plan your network architecture.** Payment HSM uses VNet injection with two delegated subnets (data plane and management plane). Review the [Network Architecture](#network-architecture) section below and confirm your VNet address space, subnet CIDRs, and connectivity patterns (ExpressRoute, VPN, peered hub VNets) before deployment.

5. **Choose your region carefully.** Payment HSM is available in a limited set of Azure regions. Confirm regional availability with your account team during the qualification conversation -- the SKU and region must both be approved as part of your business case.

For an overview of the service, supported regions, and SKUs, see the [Azure Payment HSM documentation](https://learn.microsoft.com/azure/payment-hsm/overview).

## What Gets Deployed

| Resource Group | Resources |
|---|---|
| `PHSM-HSB-CLIENT-RG` | VNet with 3 subnets: `default` (admin VM), `hsmSubnet` (delegated -- HSM data), `hsmMgmtSubnet` (delegated -- HSM management) |
| `PHSM-HSB-HSM-RG` | Payment HSM resource (payShield 10K) |
| `PHSM-HSB-ADMINVM-RG` | Admin VM + NIC + NSG + Public IP *(conditional -- only if `adminPasswordOrKey` is provided)* |

## SKU Options

| SKU Name | LMK Type | Crypto Ops/Sec |
|---|---|---|
| `payShield10K_LMK1_CPS60` | LMK1 (legacy) | 60 |
| `payShield10K_LMK1_CPS250` | LMK1 (legacy) | 250 |
| `payShield10K_LMK1_CPS2500` | LMK1 (legacy) | 2,500 |
| `payShield10K_LMK2_CPS60` | LMK2 (AES-256) | 60 |
| `payShield10K_LMK2_CPS250` | LMK2 (AES-256) | 250 |
| `payShield10K_LMK2_CPS2500` | LMK2 (AES-256) | 2,500 |

- **LMK1**: Legacy Local Master Key type (3DES-based) -- for existing payShield deployments
- **LMK2**: Modern Local Master Key type (AES-256-based) -- recommended for new deployments
- **CPS**: Cryptographic operations per second -- select based on transaction volume requirements

## Network Architecture

Azure Payment HSM uses **VNet injection** (not private endpoints). The HSM is deployed into a subnet delegated to `Microsoft.HardwareSecurityModules/dedicatedHSMs`. Unlike Dedicated HSM, Payment HSM also requires a **management subnet** for the host management port.

```
VNet (10.4.0.0/16)
├── default          (10.4.0.0/24) -- Admin VM, general resources
├── hsmSubnet        (10.4.1.0/24) -- Delegated to dedicatedHSMs (data plane)
└── hsmMgmtSubnet    (10.4.2.0/24) -- Delegated to dedicatedHSMs (management plane)
```

## Deployment

### Azure CLI

```bash
az deployment sub create \
  --location "East US" \
  --template-file paymentshsm-deploy.json \
  --parameters @paymentshsm-parameters.json
```

### PowerShell

```powershell
New-AzSubscriptionDeployment `
  -Location "East US" `
  -TemplateFile paymentshsm-deploy.json `
  -TemplateParameterFile paymentshsm-parameters.json
```

### Using the Unified Script

```bash
# Bash
./deploy-hsm.sh -p azurepaymentshsm

# PowerShell
./deploy-hsm.ps1 -Platform AzurePaymentHSM
```

## Key Differences: Payment HSM vs Dedicated HSM

| Feature | Azure Payment HSM | Azure Dedicated HSM |
|---|---|---|
| **Hardware** | Thales payShield 10K | Thales SafeNet Luna Network HSM A790 |
| **Use Cases** | PIN processing, payment credential issuing, transaction authorization | General-purpose key storage, TLS offloading, code signing |
| **Certification** | PCI HSM v3, PCI DSS, PCI 3DS | FIPS 140-2 Level 3 |
| **SKUs** | payShield10K (6 variants) | SafeNet Luna A790 |
| **Management Subnet** | Required (separate delegated subnet) | Not required |
| **Resource Provider** | `Microsoft.HardwareSecurityModules/dedicatedHSMs` | Same |
| **API Version** | `2021-11-30` | Same |

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `location` | *(required)* | Azure region (must support Payment HSM) |
| `clientResourceGroupName` | *(required)* | RG for networking resources |
| `serverResourceGroupName` | *(required)* | RG for the Payment HSM |
| `vnetName` | *(required)* | Virtual network name |
| `vnetAddressPrefix` | *(required)* | VNet address space (e.g., `10.4.0.0/16`) |
| `subnetName` | *(required)* | General-purpose subnet name |
| `subnetAddressPrefix` | *(required)* | General-purpose subnet prefix |
| `hsmSubnetName` | `hsmSubnet` | Delegated subnet for HSM data traffic |
| `hsmSubnetAddressPrefix` | *(required)* | HSM subnet prefix (min /24) |
| `managementSubnetName` | `hsmMgmtSubnet` | Delegated subnet for HSM management traffic |
| `managementSubnetAddressPrefix` | *(required)* | Management subnet prefix (min /24) |
| `paymentHsmName` | *(auto-generated)* | Payment HSM resource name |
| `hsmSkuName` | `payShield10K_LMK1_CPS60` | Payment HSM SKU |
| `stampId` | `stamp1` | Availability zone stamp |
| `adminPasswordOrKey` | *(empty -- no VM)* | SSH key or password to deploy admin VM |

---

## VPN Gateway (Optional)

Add `-EnableVpnGateway` to the deploy command to provision a **Point-to-Site VPN Gateway** in the client VNet. This enables remote/WFH access directly into the HSM environment via OpenVPN.

```powershell
.\deploy-hsm.ps1 -Platform AzurePaymentHSM -SubscriptionId "<SUB_ID>" `
    -AdminPasswordOrKey (Read-Host -AsSecureString -Prompt "Admin password") `
    -AuthenticationType password `
    -EnableVpnGateway
```

After the gateway deploys (~20-45 min), generate certificates and download the VPN client config:

```powershell
& ".\vpngateway\P2S VPN Gateway\setup-vpn-certs.ps1" `
    -VpnGatewayName "phsm-vpn-gateway" `
    -ResourceGroupName "PHSM-HSB-CLIENT-RG"
```

| Detail | Value |
|---|---|
| Gateway Name | `phsm-vpn-gateway` |
| GatewaySubnet | `10.4.255.0/26` |
| Client RG | `PHSM-HSB-CLIENT-RG` |
| Default Client Pool | `192.168.100.0/24` |

To remove just the VPN Gateway without affecting the Payment HSM deployment:

```powershell
.\..\uninstallhsm\vpngateway\uninstall-vpn-gateway.ps1 `
    -VpnGatewayName "phsm-vpn-gateway" `
    -ResourceGroupName "PHSM-HSB-CLIENT-RG" -RemoveLocalCerts
```

See [`deployhsm/vpngateway/P2S VPN Gateway/README.md`](../vpngateway/P2S%20VPN%20Gateway/README.md) for full VPN documentation.
