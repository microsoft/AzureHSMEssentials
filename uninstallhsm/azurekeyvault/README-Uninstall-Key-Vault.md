# Azure Key Vault Uninstall — HSM Scenario Builder

Removes all Azure resource groups created by the Azure Key Vault deployment.

> **Warning:** This permanently deletes the Key Vault, networking, and admin VM resources.
> Soft-deleted vaults can be recovered within the retention period unless purged.

---

## Quick Uninstall

### PowerShell

```powershell
.\uninstall-hsm.ps1 -Platform AzureKeyVault `
    -SubscriptionId "<YOUR_SUBSCRIPTION_ID>" `
    -SkipConfirmation
```

### Bash

```bash
./uninstall-hsm.sh --platform azurekeyvault \
    --subscription-id "<YOUR_SUBSCRIPTION_ID>" \
    --yes
```

---

## Script Options

| Option (PowerShell)   | Option (Bash)             | Required | Description |
|-----------------------|---------------------------|----------|-------------|
| `-Platform`           | `--platform`, `-t`        | Yes      | Set to `AzureKeyVault` (PS) or `azurekeyvault` (bash) |
| `-SubscriptionId`     | `--subscription-id`, `-s` | Yes      | Azure subscription ID |
| `-ParameterFile`      | `--parameter-file`, `-p`  | No       | Custom parameters file (to read RG names) |
| `-SkipConfirmation`   | `--yes`, `-y`             | No       | Skip confirmation prompt |
| `-VerboseOutput`      | `--verbose`, `-v`         | No       | Show full error stack traces |

---

## Deletion Order

Resource groups are deleted in this order to avoid dependency conflicts:

1. **AKV-HSB-ADMINVM-RG** — Admin VM (NIC references subnet in client VNet)
2. **AKV-HSB-CLIENT-RG** — Networking (VNet, private endpoint, DNS)
3. **AKV-HSB-HSM-RG** — Key Vault
4. **AKV-HSB-LOGS-RG** — Storage Account, Log Analytics Workspace (deleted last to preserve diagnostic data longest)

---

## Purge Soft-Deleted Key Vault

After deleting the resource group, the Key Vault enters a soft-deleted state. To fully remove it:

```bash
# List soft-deleted vaults
az keyvault list-deleted --output table

# Purge a specific vault (permanent — cannot be undone)
az keyvault purge --name <VAULT_NAME> --location "<LOCATION>"
```

> **Note:** Purge is only possible if `enablePurgeProtection` was set to `false` during deployment.
> If purge protection is enabled (default), the vault will be automatically purged after the
> soft-delete retention period (default: 90 days).

---

## VPN Gateway

If the deployment included `-EnableVpnGateway`, the VPN Gateway and its public IP live in `AKV-HSB-CLIENT-RG`. Running `uninstall-hsm.ps1` deletes the entire client RG (including the VPN Gateway) — no extra steps needed. The uninstall will take ~30 minutes longer due to VPN Gateway deletion.

To remove **only** the VPN Gateway while keeping the Key Vault deployment intact:

```powershell
.\vpngateway\uninstall-vpn-gateway.ps1 `
    -VpnGatewayName "akv-vpn-gateway" `
    -ResourceGroupName "AKV-HSB-CLIENT-RG" -RemoveLocalCerts
```
