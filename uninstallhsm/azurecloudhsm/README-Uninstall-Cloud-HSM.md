# Uninstall Azure Cloud HSM & HSM Scenario Builder Resources

This folder contains scripts to **completely remove** all Azure resources deployed by HSM Scenario Builder, including the Cloud HSM cluster, networking, and private endpoint.

> **⚠️ Warning:** These scripts permanently delete resource groups and all resources within them. This action cannot be undone. Ensure you have exported any data (alerts, trained models, logs) before running.

---

## What Gets Deleted

Resources are removed in this order to respect dependencies:

| Step | Resource Group | Resources Deleted |
|---|---|---|
| 1 | CHSM-HSB-ADMINVM-RG | Admin VM, public IP, NSG, NIC (if deployed) -- must be deleted first because the NIC references the client VNet subnet |
| 2 | CHSM-HSB-CLIENT-RG | Private endpoint, DNS zone group, private DNS zone, VNet link, VNet + subnet |
| 3 | CHSM-HSB-HSM-RG | Cloud HSM cluster |
| 4 | CHSM-HSB-LOGS-RG | Storage Account, Log Analytics Workspace (deleted last to preserve diagnostic data longest) |
| 5 | *(Optional)* | Any additional resources deployed in separate resource groups |

Deleting a resource group removes **everything** inside it.

---

## Quick Uninstall (One Command)

### PowerShell

```powershell
# From the uninstallhsm/ directory:
.\uninstall-hsm.ps1 -Platform AzureCloudHSM -SubscriptionId "<YOUR_SUBSCRIPTION_ID>"
```

### Bash / Azure CLI

```bash
# From the uninstallhsm/ directory:
../uninstall-hsm.sh --platform azurecloudhsm --subscription-id "<YOUR_SUBSCRIPTION_ID>"
```

Both scripts will:
1. Prompt for confirmation before deleting anything
2. Delete the admin VM resource group first (its NIC references the client VNet subnet)
3. Delete the client resource group (networking + private endpoint)
4. Delete the server resource group (Cloud HSM cluster)
5. Delete the logs resource group last (preserves diagnostic data longest)

---

## Manual Uninstall

### Azure CLI

```bash
az account set --subscription "<YOUR_SUBSCRIPTION_ID>"

# Step 1: Delete admin VM (NIC references client VNet subnet)
az group delete --name CHSM-HSB-ADMINVM-RG --yes --no-wait

# Step 2: Delete networking + private endpoint
az group delete --name CHSM-HSB-CLIENT-RG --yes --no-wait

# Step 3: Delete Cloud HSM cluster
az group delete --name CHSM-HSB-HSM-RG --yes --no-wait

# Step 4: Delete diagnostic logging resources
az group delete --name CHSM-HSB-LOGS-RG --yes --no-wait
```

### PowerShell

```powershell
Set-AzContext -SubscriptionId "<YOUR_SUBSCRIPTION_ID>"

# Step 1: Delete admin VM (NIC references client VNet subnet)
Remove-AzResourceGroup -Name "CHSM-HSB-ADMINVM-RG" -Force

# Step 2: Delete networking + private endpoint
Remove-AzResourceGroup -Name "CHSM-HSB-CLIENT-RG" -Force

# Step 3: Delete Cloud HSM cluster
Remove-AzResourceGroup -Name "CHSM-HSB-HSM-RG" -Force

# Step 4: Delete diagnostic logging resources
Remove-AzResourceGroup -Name "CHSM-HSB-LOGS-RG" -Force
```

### Azure Portal

1. Navigate to **Resource groups**
2. Select `CHSM-HSB-ADMINVM-RG` → **Delete resource group** → confirm (if it exists)
3. Select `CHSM-HSB-CLIENT-RG` → **Delete resource group** → confirm
4. Select `CHSM-HSB-HSM-RG` → **Delete resource group** → confirm
5. Select `CHSM-HSB-LOGS-RG` → **Delete resource group** → confirm

---

## Options

Both scripts accept these parameters:

| Parameter | Required | Description |
|---|---|---|
| `Platform` / `--platform` | Yes | HSM platform to uninstall: `AzureCloudHSM`, `AzureKeyVault`, `AzureManagedHSM` |
| `SubscriptionId` / `--subscription-id` | Yes | Azure subscription ID |
| `ParameterFile` / `--parameter-file` | No | Path to ARM parameters file (reads RG names from it). Defaults to `../../deployhsm/azurecloudhsm/cloudhsm-parameters.json` |
| `SkipConfirmation` / `--yes` | No | Skip the interactive confirmation prompt |
| `VerboseOutput` / `--verbose` | No | Show full error details (stack traces, inner exceptions) for debugging |

### Custom Resource Group Names

If you used custom resource group names during deployment, the scripts read them from the parameters file automatically. Or pass your own parameters file:

```powershell
..\uninstall-hsm.ps1 -Platform AzureCloudHSM -SubscriptionId "xxx" -ParameterFile "C:\path\to\cloudhsm-parameters.json"
```

---

## VPN Gateway

If the deployment included `-EnableVpnGateway`, the VPN Gateway and its public IP live in `CHSM-HSB-CLIENT-RG`. Running `uninstall-hsm.ps1` deletes the entire client RG (including the VPN Gateway) -- no extra steps needed. The uninstall will take ~30 minutes longer due to VPN Gateway deletion.

To remove **only** the VPN Gateway while keeping the HSM deployment intact:

```powershell
.\vpngateway\uninstall-vpn-gateway.ps1 `
    -VpnGatewayName "chsm-vpn-gateway" `
    -ResourceGroupName "CHSM-HSB-CLIENT-RG" -RemoveLocalCerts
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
