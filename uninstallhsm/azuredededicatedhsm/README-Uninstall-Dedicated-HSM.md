# Uninstall Azure Dedicated HSM & HSM Scenario Builder Resources

This folder contains scripts to **completely remove** all Azure resources deployed by HSM Scenario Builder for the Dedicated HSM platform, including the Dedicated HSM, networking (VNet with delegated subnet), and optional admin VM.

> **Warning:** These scripts permanently delete resource groups and all resources within them. This action cannot be undone. Ensure you have exported any data (HSM partition backups, alerts, trained models, logs) before running.

> **Important:** Azure Dedicated HSM is a single-tenant physical device. Once deleted, the HSM is deprovisioned and returned to the pool. Any keys or partitions on the device are permanently lost.

> **Important:** If the Dedicated HSM has been activated (initialized with a partition and Security Officer credentials), you **must zeroize** the HSM before deleting it. Azure Dedicated HSM does not expose the `hsm factoryReset` or `hsm zeroize` commands. To force a zeroize:
>
> 1. SSH into the Dedicated HSM as `tenantadmin` (e.g., `ssh tenantadmin@<HSM_PRIVATE_IP>`)
> 2. At the `lunash:>` prompt, run `hsm login`
> 3. Enter the **Administrator password incorrectly 3 times**
>
> On the final attempt, Luna will warn you and require you to type `proceed` before continuing:
>
> ```
> [local_host] lunash:>hsm login
>
> Caution:  This is your LAST available HSM Admin login attempt.
>           If the wrong HSM Admin password is provided the HSM will
>           be ZEROIZED!!!
>
>           Type 'proceed' if you are certain you have the right
>           HSM Admin login credentials or 'quit' to quit now.
>           > proceed
>
>   Please enter the HSM Administrators' password:
>   > **************
>
>
> Error:  'hsm login' failed. (30000F : LUNA_RET_SO_LOGIN_FAILURE_THRESHOLD)
>
> Error:    The HSM is in the factory reset (zeroized) state.
>
>
> Command Result : 0 (Success)
> ```
>
> Once you see `The HSM is in the factory reset (zeroized) state`, the HSM has been zeroized and you can proceed with deletion. Attempting to delete an activated HSM without zeroizing it first will fail.

---

## What Gets Deleted

Resources are removed in this order to respect dependencies:

| Step | Resource Group | Resources Deleted |
|---|---|---|
| 1 | DHSM-HSB-ADMINVM-RG | Admin VM, public IP, NSG, NIC (if deployed) -- must be deleted first because the NIC references the client VNet subnet |
| 2 | DHSM-HSB-HSM-RG | Dedicated HSM (Thales Luna Network HSM A790) |
| 3 | DHSM-HSB-CLIENT-RG | VNet (with default subnet, delegated hsmSubnet, and GatewaySubnet), ExpressRoute VNet Gateway, Public IP |
| 4 | *(Optional)* | Any additional resources deployed in separate resource groups |

Deleting a resource group removes **everything** inside it.

---

## Quick Uninstall (One Command)

### PowerShell

```powershell
# From the uninstallhsm/ directory:
.\uninstall-hsm.ps1 -Platform AzureDedicatedHSM -SubscriptionId "<YOUR_SUBSCRIPTION_ID>"
```

### Bash / Azure CLI

```bash
# From the uninstallhsm/ directory:
./uninstall-hsm.sh --platform azuredededicatedhsm --subscription-id "<YOUR_SUBSCRIPTION_ID>"
```

Both scripts will:
1. Prompt for confirmation before deleting anything
2. Delete the admin VM resource group first (its NIC references the client VNet subnet)
3. Delete the server resource group (Dedicated HSM)
4. Delete the client resource group (networking — VNet with delegated subnet + ExpressRoute Gateway)

---

## Manual Uninstall

### Azure CLI

```bash
az account set --subscription "<YOUR_SUBSCRIPTION_ID>"

# Step 1: Delete admin VM (NIC references client VNet subnet)
az group delete --name DHSM-HSB-ADMINVM-RG --yes --no-wait

# Step 2: Delete Dedicated HSM
az group delete --name DHSM-HSB-HSM-RG --yes --no-wait

# Step 3: Delete networking (VNet + delegated subnet + ExpressRoute Gateway)
az group delete --name DHSM-HSB-CLIENT-RG --yes --no-wait
```

### PowerShell

```powershell
Set-AzContext -SubscriptionId "<YOUR_SUBSCRIPTION_ID>"

# Step 1: Delete admin VM (NIC references client VNet subnet)
Remove-AzResourceGroup -Name "DHSM-HSB-ADMINVM-RG" -Force

# Step 2: Delete Dedicated HSM
Remove-AzResourceGroup -Name "DHSM-HSB-HSM-RG" -Force

# Step 3: Delete networking (VNet + delegated subnet + ExpressRoute Gateway)
Remove-AzResourceGroup -Name "DHSM-HSB-CLIENT-RG" -Force
```

### Azure Portal

1. Navigate to **Resource groups**
2. Select `DHSM-HSB-ADMINVM-RG` → **Delete resource group** → confirm (if it exists)
3. Select `DHSM-HSB-HSM-RG` → **Delete resource group** → confirm
4. Select `DHSM-HSB-CLIENT-RG` → **Delete resource group** → confirm

---

## Options

Both scripts accept these parameters:

| Parameter | Required | Description |
|---|---|---|
| `Platform` / `--platform` | Yes | Set to `AzureDedicatedHSM` (PS) or `azuredededicatedhsm` (bash) |
| `SubscriptionId` / `--subscription-id` | Yes | Azure subscription ID |
| `ParameterFile` / `--parameter-file` | No | Path to ARM parameters file (reads RG names from it). Defaults to `../../deployhsm/azuredededicatedhsm/dedicatedhsm-parameters.json` |
| `SkipConfirmation` / `--yes` | No | Skip the interactive confirmation prompt |
| `VerboseOutput` / `--verbose` | No | Show full error details (stack traces, inner exceptions) for debugging |

### Custom Resource Group Names

If you used custom resource group names during deployment, the scripts read them from the parameters file automatically. Or pass your own parameters file:

```powershell
.\uninstall-hsm.ps1 -Platform AzureDedicatedHSM -SubscriptionId "xxx" -ParameterFile "C:\path\to\dedicatedhsm-parameters.json"
```

---

## VPN Gateway

If the deployment included `-EnableVpnGateway`, the VPN Gateway and its public IP live in `DHSM-HSB-CLIENT-RG`. Running `uninstall-hsm.ps1` deletes the entire client RG (including the VPN Gateway) — no extra steps needed. The uninstall will take ~30 minutes longer due to VPN Gateway deletion.

To remove **only** the VPN Gateway while keeping the HSM deployment intact:

```powershell
.\vpngateway\uninstall-vpn-gateway.ps1 `
    -VpnGatewayName "dhsm-vpn-gateway" `
    -ResourceGroupName "DHSM-HSB-CLIENT-RG" -RemoveLocalCerts
```

---

## Files in This Folder

| File | Description |
|---|---|
| `README.md` | This file |

The uninstall scripts are in the parent `uninstallhsm/` directory:

| File | Description |
|---|---|
| `../uninstall-hsm.ps1` | Universal PowerShell uninstall script |
| `../uninstall-hsm.sh` | Universal Bash / Azure CLI uninstall script |
