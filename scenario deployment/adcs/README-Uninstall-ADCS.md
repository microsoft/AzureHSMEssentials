# Uninstall ADCS VM — Azure Cloud HSM & Dedicated HSM

This folder contains `uninstall-adcs-vm.ps1` which **removes the ADCS scenario VM** and all its resources for a given HSM platform.

> **⚠️ Warning:** This permanently deletes the ADCS VM resource group and everything in it. This action cannot be undone.

---

## What Gets Deleted

| Platform | Resource Group | Resources Deleted |
|---|---|---|
| AzureCloudHSM | CHSM-HSB-ADCS-VM | ADCS VM, NIC, NSG, public IP, OS disk |
| AzureDedicatedHSM | DHSM-HSB-ADCS-VM | ADCS VM, NIC, NSG, public IP, OS disk |

The **base HSM deployment** (Admin VM, VNet, HSM cluster, etc.) is **NOT** affected.

---

## Quick Uninstall

### Cloud HSM ADCS VM

```powershell
.\uninstall-adcs-vm.ps1 -Platform AzureCloudHSM -SubscriptionId "<YOUR_SUBSCRIPTION_ID>"
```

### Dedicated HSM ADCS VM

```powershell
.\uninstall-adcs-vm.ps1 -Platform AzureDedicatedHSM -SubscriptionId "<YOUR_SUBSCRIPTION_ID>"
```

### Skip Confirmation (automation)

```powershell
.\uninstall-adcs-vm.ps1 -Platform AzureCloudHSM -SubscriptionId "<YOUR_SUBSCRIPTION_ID>" -SkipConfirmation
```

---

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-Platform` | Yes | `AzureCloudHSM` or `AzureDedicatedHSM` |
| `-SubscriptionId` | Yes | Azure subscription ID containing the resources |
| `-ParameterFile` | No | Custom path to the ADCS parameters file (defaults to `adcs-vm-parameters-<platform>.json`) |
| `-SkipConfirmation` | No | Skip the `DELETE` confirmation prompt |
| `-VerboseOutput` | No | Show full error details and stack traces |

---

## What It Does

1. Reads the resource group name from the platform-specific ADCS parameters file
2. Prompts for confirmation (type `DELETE` to proceed)
3. Connects to Azure and sets the subscription context
4. Deletes the ADCS VM resource group and all resources within it
5. Shows the command to remove the base HSM deployment if you want to clean up everything

---

## Removing Everything

To also remove the base HSM deployment (Admin VM, VNet, HSM cluster, logs), run the platform uninstall afterwards:

```powershell
# From the uninstallhsm/ directory:
.\uninstall-hsm.ps1 -Platform AzureCloudHSM -SubscriptionId "<YOUR_SUBSCRIPTION_ID>"
```
