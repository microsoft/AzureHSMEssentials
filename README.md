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

**One-command deployment of fully configured Azure HSM platforms for evaluation, proof-of-concept, and production reference architectures.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## Overview

Setting up Azure HSM environments manually is time-consuming and error-prone -- VNets, private endpoints, DNS zones, subnets, firewalls, diagnostic logging, admin VMs, and more. **HSM Scenario Builder** automates all of that into a single deploy command.

Give it to PMs, engineers, or field teams so they can spin up a fully-configured HSM platform in minutes, run their tests or partner demos, and tear it down cleanly when done.

### Supported Platforms

| Platform                      | Description                                                   | Key Features                                                                                        |
| ----------------------------- | ------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| **Azure Cloud HSM**     | FIPS 140-3 Level 3 HSM Cluster (Standard_B1)                  | Private endpoint, DNS zone, VNet, diagnostic logging, optional admin VM                             |
| **Azure Dedicated HSM** | Thales SafeNet Luna A790 (bare-metal)                         | VNet injection, ExpressRoute gateway, delegated hsmSubnet, optional admin VM                        |
| **Azure Key Vault**     | Premium SKU with HSM-backed keys                              | Private endpoint, DNS zone, VNet, Entra ID RBAC, diagnostic logging, optional admin VM              |
| **Azure Managed HSM**   | FIPS 140-3 Level 3, Entra ID RBAC-only HSM Pool (Standard_B1) | Private endpoint, DNS zone, VNet, security domain activation, diagnostic logging, optional admin VM |
| **Azure Payment HSM**   | Thales payShield 10K for payment processing (bare-metal)      | VNet injection, separate data/management subnets, optional admin VM                                 |

### What Gets Deployed

Each platform deployment creates isolated resource groups with production-grade networking and security:

- **Networking** -- VNet, subnets, private endpoint (or VNet injection), private DNS zone, DNS-VNet link
- **HSM resource** -- The HSM platform itself, fully configured
- **Diagnostic logging** -- Storage Account + Log Analytics Workspace with audit log routing (where supported)
- **Admin VM** *(optional)* -- Ubuntu 24.04 LTS jumpbox connected to the HSM VNet for administration
- **P2S VPN Gateway** *(optional)* -- Point-to-Site VPN for remote/WFH access into the HSM VNet via OpenVPN
- **Clean teardown** -- Matching uninstall scripts delete all resource groups in the correct dependency order

---

## Architecture

```
                    ┌──────────────────────────────────────┐
                    │       HSM Scenario Builder           │
                    │                                      │
                    │   deploy-hsm.ps1  /  deploy-hsm.sh   │
                    │  uninstall-hsm.ps1 / uninstall-hsm.sh│
                    └──────────────┬───────────────────────┘
                                   │
              ┌────────────────────┼────────────────────┐
              ▼                    ▼                    ▼
   ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
   │  ARM Template   │  │  ARM Template   │  │  ARM Template   │
   │  + Parameters   │  │  + Parameters   │  │  + Parameters   │
   └────────┬────────┘  └────────┬────────┘  └────────┬────────┘
            ▼                    ▼                    ▼
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
   │  OpenVPN P2S for remote/WFH access           │
   │  Deployed into the CLIENT-RG VNet            │
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
├── migration/                                # Migration toolkits (HSM-to-HSM, on-prem-to-HSM)
│   └── adcs-migration/                       # Active Directory Certificate Services CA migration
│       ├── docs/                             # Per-scenario migration guides
│       ├── scripts/                          # Step1-Step8 orchestration per scenario
│       │   ├── Invoke-CaMigration.ps1        # Top-level migration orchestrator
│       │   ├── Reset-MigrationEnvironment.ps1
│       │   ├── migration-params.template.json
│       │   ├── root-ca-migration/            # Root CA scenarios (chain-pre-distributed, cross-signed)
│       │   └── intermediate-issuing-ca-migration/  # Issuing CA scenarios
│       └── tests/                            # Live-migration validation harness
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
| Dedicated HSM | `DHSM-HSB-CLIENT-RG` | `DHSM-HSB-HSM-RG` | `DHSM-HSB-ADMINVM-RG` | n/a                  |
| Key Vault     | `AKV-HSB-CLIENT-RG`  | `AKV-HSB-HSM-RG`  | `AKV-HSB-ADMINVM-RG`  | `AKV-HSB-LOGS-RG`  |
| Managed HSM   | `MHSM-HSB-CLIENT-RG` | `MHSM-HSB-HSM-RG` | `MHSM-HSB-ADMINVM-RG` | `MHSM-HSB-LOGS-RG` |
| Payment HSM   | `PHSM-HSB-CLIENT-RG` | `PHSM-HSB-HSM-RG` | `PHSM-HSB-ADMINVM-RG` | n/a                  |

> **Note:** Dedicated HSM and Payment HSM are bare-metal devices and do not support Azure Monitor/Log Analytics, so no logs resource group is created.

### Customization

Edit the platform's `*-parameters.json` file before deploying to customize resource group names, locations, networking CIDRs, SKUs, and other settings. See each platform's README for the full parameter reference.

---

## Migration Toolkits

In addition to greenfield HSM deployments (covered above), this repository ships migration toolkits for cutting over Azure Dedicated HSM to Azure Cloud HSM for ADCS workloads. Because Azure Dedicated HSM private keys are non-exportable by design, these migrations stand up a parallel CA on the target HSM and establish trust between the existing and new CAs during a controlled cutover window. The existing CA, its private key, and all previously issued certificates remain in place and valid throughout the process. Each toolkit is scenario-driven, parameter-file controlled, and broken into discrete validated steps so you can pause, audit, and resume between phases.

### `migration/adcs-migration/` -- Active Directory Certificate Services

Migrates an existing Active Directory Certificate Services CA from Azure Dedicated HSM to Azure Cloud HSM, preserving CA identity, certificate validity, and existing issued-cert chains. The primary scenario is **Azure Dedicated HSM (Thales Luna KSP) to Azure Cloud HSM (Cavium / Marvell LiquidSecurity KSP)**. The same toolkit also applies to other HSM-to-HSM CA migrations where the source and target both expose a Windows KSP/CSP provider (for example, on-premises Luna to Azure Cloud HSM).

Because HSM private keys are non-exportable by design, the toolkit takes a **parallel-CA** approach rather than a key-export-and-import. A new CA is provisioned on the target HSM with its own key pair, and trust is established between the existing CA and the new CA using one of two cutover strategies. The existing CA continues to operate untouched; previously issued certificates remain valid until their natural expiry. It supports both Root CA and Issuing/Intermediate CA tiers:

| Tier                 | Strategy        | When to use                                                                                       |
| -------------------- | --------------- | ------------------------------------------------------------------------------------------------- |
| **Root CA**    | Pre-distributed | Greenfield trust rollout. New root cert is distributed and trusted before any cutover.            |
| **Root CA**    | Cross-signed    | Existing trust must be preserved. Old root cross-signs new root; both validate during transition. |
| **Issuing CA** | Pre-distributed | New issuing CA is published before old CA stops issuing. Workloads switch in a planned window.    |
| **Issuing CA** | Cross-signed    | Old issuing CA cross-signs the new one for seamless chain bridging during phased rollout.         |

Each scenario is delivered as 8 numbered PowerShell steps (`Step1-CaptureExistingCA.ps1` through `Step8-DecommissionChecks.ps1`) plus a top-level orchestrator (`Invoke-CaMigration.ps1`) and a JSON parameter file describing source server, target server, parent CA, and cryptographic settings.

**Start here:** [`migration/adcs-migration/docs/_README_migration.md`](migration/adcs-migration/docs/_README_migration.md)

---

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for the contribution process, CLA requirements, and style guidelines.

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Commit changes (`git commit -am 'Add my feature'`)
4. Push to branch (`git push origin feature/my-feature`)
5. Open a Pull Request

---

## Security

If you discover a security vulnerability, please follow the private disclosure process described in [SECURITY.md](SECURITY.md). Do not open a public issue.

---

## Code of Conduct

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/). For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

---

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft trademarks or logos is subject to and must follow [Microsoft&#39;s Trademark &amp; Brand Guidelines](https://www.microsoft.com/legal/intellectualproperty/trademarks/usage/general). Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship. Any use of third-party trademarks or logos is subject to those third-party's policies.

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
