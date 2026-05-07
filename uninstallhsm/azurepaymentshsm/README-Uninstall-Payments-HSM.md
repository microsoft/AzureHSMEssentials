# Azure Payment HSM -- Uninstall Guide

## Overview

This guide covers the removal of Azure Payment HSM resources deployed by the HSM Scenario Builder ARM templates.

## Resource Groups to Delete

Delete in this order to ensure clean removal (admin VM first, then HSM, then networking, then logs):

| Order | Resource Group | Contents |
|---|---|---|
| 1 | `PHSM-HSB-ADMINVM-RG` | Admin VM, NIC, NSG, Public IP *(if deployed)* |
| 2 | `PHSM-HSB-HSM-RG` | Payment HSM (payShield 10K) |
| 3 | `PHSM-HSB-CLIENT-RG` | VNet, Subnets (default, hsmSubnet, hsmMgmtSubnet) |

## Uninstall Commands

### Azure CLI

```bash
# Delete in order
az group delete --name PHSM-HSB-ADMINVM-RG --yes --no-wait
az group delete --name PHSM-HSB-HSM-RG --yes --no-wait
az group delete --name PHSM-HSB-CLIENT-RG --yes --no-wait
```

### PowerShell

```powershell
Remove-AzResourceGroup -Name "PHSM-HSB-ADMINVM-RG" -Force -AsJob
Remove-AzResourceGroup -Name "PHSM-HSB-HSM-RG" -Force -AsJob
Remove-AzResourceGroup -Name "PHSM-HSB-CLIENT-RG" -Force -AsJob
```

### Using the Unified Script

```bash
# Bash
./uninstall-hsm.sh -p azurepaymentshsm

# PowerShell
./uninstall-hsm.ps1 -Platform AzurePaymentHSM
```

## Important Notes

- **Deletion order matters**: Delete the HSM resource group *before* the networking resource group, since the HSM has network dependencies on the delegated subnets.
- **Payment HSM deprovisioning**: Like Dedicated HSM, Payment HSM deallocation may take time as the physical hardware is returned to the resource pool.
- **Management subnet**: Payment HSM uses an additional management subnet (`hsmMgmtSubnet`) compared to Dedicated HSM. This is cleaned up automatically when the VNet resource group is deleted.
- **No soft-delete**: Payment HSM resources do not support soft-delete. Once deleted, the HSM and its keys are permanently removed.

## VPN Gateway

If the deployment included `-EnableVpnGateway`, the VPN Gateway and its public IP live in `PHSM-HSB-CLIENT-RG`. Running `uninstall-hsm.ps1` deletes the entire client RG (including the VPN Gateway) -- no extra steps needed. The uninstall will take ~30 minutes longer due to VPN Gateway deletion.

To remove **only** the VPN Gateway while keeping the Payment HSM deployment intact:

```powershell
.\vpngateway\uninstall-vpn-gateway.ps1 `
    -VpnGatewayName "phsm-vpn-gateway" `
    -ResourceGroupName "PHSM-HSB-CLIENT-RG" -RemoveLocalCerts
```
