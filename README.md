```
  ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
   _  _  ___  __  __
  | || |/ __||  \/  |
  | __ |\__ \| |\/| | SCENARIO
  |_||_||___/|_|  |_| BUILDER

  ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
  # SHALL WE DEPLOY A HSM? 
```

# HSM Scenario Builder

**One-command deployment of fully configured Azure HSM platforms for testing, demos, and partner conversations.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## Overview

Setting up Azure HSM environments manually is time-consuming and error-prone — VNets, private endpoints, DNS zones, subnets, firewalls, diagnostic logging, admin VMs, and more. **HSM Scenario Builder** automates all of that into a single deploy command.

Give it to PMs, engineers, or field teams so they can spin up a fully-configured HSM platform in minutes, run their tests or partner demos, and tear it down cleanly when done.

### Supported Platforms

| Platform                      | Description                                 | Key Features                                                                                        |
| ----------------------------- | ------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| **Azure Cloud HSM**     | Thales Luna Network HSM 7 (cloud-managed)   | Private endpoint, DNS zone, VNet, diagnostic logging, optional admin VM                             |
| **Azure Dedicated HSM** | Thales SafeNet Luna A790 (bare-metal)       | VNet injection, ExpressRoute gateway, delegated hsmSubnet, optional admin VM                        |
| **Azure Key Vault**     | Premium SKU with HSM-backed keys            | Private endpoint, DNS zone, VNet, Entra ID RBAC, diagnostic logging, optional admin VM              |
| **Azure Managed HSM**   | FIPS 140-2 Level 3, Entra ID RBAC-only      | Private endpoint, DNS zone, VNet, security domain activation, diagnostic logging, optional admin VM |
| **Azure Payment HSM**   | Thales payShield 10K for payment processing | VNet injection, separate data/management subnets, optional admin VM                                 |

### What Gets Deployed

Each platform deployment creates isolated resource groups with production-grade networking and security:

- **Networking** — VNet, subnets, private endpoint (or VNet injection), private DNS zone, DNS-VNet link
- **HSM resource** — The HSM platform itself, fully configured
- **Diagnostic logging** — Storage Account + Log Analytics Workspace with audit log routing (where supported)
- **Admin VM** *(optional)* — Ubuntu 24.04 LTS jumpbox connected to the HSM VNet for administration
- **P2S VPN Gateway** *(optional)* — Point-to-Site VPN for remote/WFH access into the HSM VNet via OpenVPN
- **Clean teardown** — Matching uninstall scripts delete all resource groups in the correct dependency order

---

## Architecture

```
                    ┌──────────────────────────────────────┐
                    │        HSM Scenario Builder           │
                    │                                      │
                    │   deploy-hsm.ps1  /  deploy-hsm.sh   │
                    │   uninstall-hsm.ps1 / uninstall-hsm.sh│
                    └──────────────┬───────────────────────┘
                                   │
              ┌────────────────────┼────────────────────┐
              ▼                    ▼                     ▼
   ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
   │  ARM Template    │  │  ARM Template    │  │  ARM Template    │
   │  + Parameters    │  │  + Parameters    │  │  + Parameters    │
   └────────┬────────┘  └────────┬────────┘  └────────┬────────┘
            ▼                    ▼                     ▼
   ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
   │ Azure Cloud HSM │  │ Azure Key Vault │  │ Azure Managed   │
   │ Azure Dedicated │  │                 │  │ HSM             │
   │ HSM             │  │                 │  │ Azure Payment   │
   │                 │  │                 │  │ HSM             │
   └─────────────────┘  └─────────────────┘  └─────────────────┘

   Each deployment creates:
   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
   │ *-HSB-CLIENT │  │ *-HSB-HSM-RG │  │ *-HSB-LOGS   │  │ *-HSB-ADMIN  │
   │ -RG          │  │              │  │ -RG          │  │ VM-RG        │
   │              │  │              │  │              │  │ (optional)   │
   │ VNet, PE,    │  │ HSM resource │  │ Storage,     │  │ Ubuntu VM,   │
   │ DNS zone     │  │              │  │ Log Analytics│  │ NIC, NSG,PIP │
   └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘

   Optional VPN Gateway (-EnableVpnGateway):
   ┌──────────────────────────────────────────────┐
   │  VPN Gateway (VpnGw1) + GatewaySubnet        │
   │  OpenVPN P2S for remote/WFH access            │
   │  Deployed into the CLIENT-RG VNet             │
   └──────────────────────────────────────────────┘
```

---

## Quick Start

### Prerequisites

- Azure subscription with permissions to create resource groups and HSM resources
- **PowerShell**: Az PowerShell module (`Install-Module -Name Az -Scope CurrentUser`)
- **Bash**: Azure CLI (`az`) installed and authenticated

### 1. Clone

```bash
git clone https://github.com/YOUR_ORG/hsm-scenario-builder.git
cd hsm-scenario-builder
```

### 2. Deploy

**PowerShell:**

```powershell
# Deploy Azure Cloud HSM
.\deployhsm\deploy-hsm.ps1 -Platform AzureCloudHSM -SubscriptionId "<SUB_ID>"

# Deploy Azure Key Vault
.\deployhsm\deploy-hsm.ps1 -Platform AzureKeyVault -SubscriptionId "<SUB_ID>"

# Deploy Azure Managed HSM
.\deployhsm\deploy-hsm.ps1 -Platform AzureManagedHSM -SubscriptionId "<SUB_ID>"

# Deploy Azure Dedicated HSM
.\deployhsm\deploy-hsm.ps1 -Platform AzureDedicatedHSM -SubscriptionId "<SUB_ID>"

# Deploy Azure Payment HSM
.\deployhsm\deploy-hsm.ps1 -Platform AzurePaymentHSM -SubscriptionId "<SUB_ID>"
```

**Bash:**

```bash
# Deploy Azure Cloud HSM
./deployhsm/deploy-hsm.sh --platform azurecloudhsm --subscription-id "<SUB_ID>"

# Deploy Azure Managed HSM with location override
./deployhsm/deploy-hsm.sh --platform azuremanagedhsm --subscription-id "<SUB_ID>" --location "East US"
```

**With optional admin VM:**

```powershell
.\deployhsm\deploy-hsm.ps1 -Platform AzureCloudHSM -SubscriptionId "<SUB_ID>" `
    -AdminPasswordOrKey (Read-Host -AsSecureString -Prompt "SSH key or password") `
    -AdminUsername "myadmin" -AuthenticationType password
```

**With optional P2S VPN Gateway (remote/WFH access):**

```powershell
.\deployhsm\deploy-hsm.ps1 -Platform AzureCloudHSM -SubscriptionId "<SUB_ID>" `
    -AdminPasswordOrKey (Read-Host -AsSecureString -Prompt "Admin password") `
    -AuthenticationType password `
    -EnableVpnGateway
```

After the VPN Gateway deploys, run the cert setup to complete P2S configuration:

```powershell
& ".\deployhsm\vpngateway\P2S VPN Gateway\setup-vpn-certs.ps1" `
    -VpnGatewayName "chsm-vpn-gateway" `
    -ResourceGroupName "CHSM-HSB-CLIENT-RG"
```

See [deployhsm/vpngateway/P2S VPN Gateway/README.md](deployhsm/vpngateway/P2S%20VPN%20Gateway/README.md) for full VPN documentation.

### 3. Tear Down

```powershell
# Remove all resources for a platform
.\uninstallhsm\uninstall-hsm.ps1 -Platform AzureCloudHSM -SubscriptionId "<SUB_ID>"
```

```bash
./uninstallhsm/uninstall-hsm.sh --platform azurecloudhsm --subscription-id "<SUB_ID>"
```

---

## Project Structure

```
hsm-scenario-builder/
├── README.md
├── LICENSE
├── deployhsm/                                # Deploy scripts & ARM templates
│   ├── deploy-hsm.ps1                        # Universal PowerShell deploy script
│   ├── deploy-hsm.sh                         # Universal Bash deploy script
│   ├── azurecloudhsm/                        # Cloud HSM ARM template + params
│   │   ├── cloudhsm-deploy.json
│   │   ├── cloudhsm-parameters.json
│   │   └── README.md
│   ├── azuredededicatedhsm/                  # Dedicated HSM ARM template + params
│   │   ├── dedicatedhsm-deploy.json
│   │   ├── dedicatedhsm-parameters.json
│   │   └── README.md
│   ├── azurekeyvault/                        # Key Vault ARM template + params
│   │   ├── keyvault-deploy.json
│   │   ├── keyvault-parameters.json
│   │   └── README.md
│   ├── azuremanagedhsm/                      # Managed HSM ARM template + params
│   │   ├── managedhsm-deploy.json
│   │   ├── managedhsm-parameters.json
│   │   ├── activate-mhsm.sh
│   │   └── README.md
│   ├── azurepaymentshsm/                    # Payment HSM ARM template + params
│   │   ├── paymentshsm-deploy.json
│   │   ├── paymentshsm-parameters.json
│   │   └── README.md
│   └── vpngateway/                           # Optional P2S VPN Gateway
│       ├── vpngw-deploy.json                 # ARM template (resource-group level)
│       ├── setup-vpn-certs.ps1               # Generate certs, upload to gateway, download config
│       └── README.md
├── uninstallhsm/                             # Uninstall scripts & docs
│   ├── uninstall-hsm.ps1                     # Universal PowerShell uninstall script
│   ├── uninstall-hsm.sh                      # Universal Bash uninstall script
│   ├── azurecloudhsm/README.md
│   ├── azuredededicatedhsm/README.md
│   ├── azurekeyvault/README.md
│   ├── azuremanagedhsm/README.md
│   ├── azurepaymentshsm/README.md
│   └── vpngateway/                           # VPN Gateway removal
│       └── uninstall-vpn-gateway.ps1
├── tests/                                    # Test suite
└── azure_functions/                          # Optional Azure Functions
```

---

## Platform Details

### Resource Group Naming Convention

Each platform creates isolated resource groups using the pattern `<PREFIX>-HSB-<PURPOSE>-RG`:

| Platform      | Client/Networking      | HSM Resource        | Admin VM                | Logs                 |
| ------------- | ---------------------- | ------------------- | ----------------------- | -------------------- |
| Cloud HSM     | `CHSM-HSB-CLIENT-RG` | `CHSM-HSB-HSM-RG` | `CHSM-HSB-ADMINVM-RG` | `CHSM-HSB-LOGS-RG` |
| Dedicated HSM | `DHSM-HSB-CLIENT-RG` | `DHSM-HSB-HSM-RG` | `DHSM-HSB-ADMINVM-RG` | —                   |
| Key Vault     | `AKV-HSB-CLIENT-RG`  | `AKV-HSB-HSM-RG`  | `AKV-HSB-ADMINVM-RG`  | `AKV-HSB-LOGS-RG`  |
| Managed HSM   | `MHSM-HSB-CLIENT-RG` | `MHSM-HSB-HSM-RG` | `MHSM-HSB-ADMINVM-RG` | `MHSM-HSB-LOGS-RG` |
| Payment HSM   | `PHSM-HSB-CLIENT-RG` | `PHSM-HSB-HSM-RG` | `PHSM-HSB-ADMINVM-RG` | —                   |

> **Note:** Dedicated HSM and Payment HSM are bare-metal devices and do not support Azure Monitor/Log Analytics, so no logs resource group is created.

### Customization

Edit the platform's `*-parameters.json` file before deploying to customize resource group names, locations, networking CIDRs, SKUs, and other settings. See each platform's README for the full parameter reference.

---

## Contributing

Contributions are welcome!

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Commit changes (`git commit -am 'Add my feature'`)
4. Push to branch (`git push origin feature/my-feature`)
5. Open a Pull Request

---

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE) for details.
