# VPN Gateway Uninstall -- HSM Scenario Builder

Removes the Point-to-Site VPN Gateway and related resources from any HSM platform VNet,
without affecting the base HSM deployment, Admin VM, or client VNet.

> **Note:** VPN Gateway deletion typically takes 15–30 minutes.

---

## Quick Uninstall

```powershell
.\vpngateway\uninstall-vpn-gateway.ps1 `
    -VpnGatewayName "<VPN_GATEWAY_NAME>" `
    -ResourceGroupName "<CLIENT_RG>"
```

### Platform Examples

| Platform        | Gateway Name           | Resource Group         |
|-----------------|------------------------|------------------------|
| Cloud HSM       | `chsm-vpn-gateway`    | `CHSM-HSB-CLIENT-RG`  |
| Managed HSM     | `mhsm-vpn-gateway`    | `MHSM-HSB-CLIENT-RG`  |
| Key Vault       | `akv-vpn-gateway`     | `AKV-HSB-CLIENT-RG`   |
| Dedicated HSM   | `dhsm-vpn-gateway`    | `DHSM-HSB-CLIENT-RG`  |
| Payment HSM     | `phsm-vpn-gateway`    | `PHSM-HSB-CLIENT-RG`  |

```powershell
# Example: Remove Cloud HSM VPN Gateway and local certs
.\vpngateway\uninstall-vpn-gateway.ps1 `
    -VpnGatewayName "chsm-vpn-gateway" `
    -ResourceGroupName "CHSM-HSB-CLIENT-RG" `
    -RemoveLocalCerts
```

---

## Script Options

| Option              | Required | Description |
|---------------------|----------|-------------|
| `-VpnGatewayName`   | Yes      | Name of the VPN Gateway to remove |
| `-ResourceGroupName`| Yes      | Resource group containing the VPN Gateway (the client RG) |
| `-SubscriptionId`   | No       | Azure subscription ID (defaults to current Az context) |
| `-RemoveLocalCerts` | No       | Also remove P2SRootCert and P2SChildCert from the local certificate store |
| `-SkipConfirmation` | No       | Skip the interactive `DELETE` confirmation prompt |
| `-VerboseOutput`    | No       | Show full error details and stack traces |

---

## What Gets Deleted

| Resource               | Deleted? |
|------------------------|----------|
| VPN Gateway            | Yes      |
| Public IP (Static)     | Yes      |
| Local P2S certificates | Only with `-RemoveLocalCerts` |
| GatewaySubnet          | No -- remains in VNet (empty, no cost) |
| VNet / other subnets   | No       |
| HSM resources          | No       |
| Admin VM               | No       |

---

## Full Platform Uninstall

If you are removing the entire HSM deployment (not just the VPN Gateway),
use `uninstall-hsm.ps1` instead -- it deletes all resource groups including
the client RG that contains the VPN Gateway:

```powershell
.\uninstall-hsm.ps1 -Platform <PLATFORM> `
    -SubscriptionId "<YOUR_SUBSCRIPTION_ID>" `
    -SkipConfirmation
```

No separate VPN removal step is needed; the full uninstall handles it automatically
(though it will take ~15–30 minutes longer due to VPN Gateway deletion).

---

## Re-deploying After Removal

To add the VPN Gateway back after removal:

```powershell
.\deploy-hsm.ps1 -Platform <PLATFORM> `
    -SubscriptionId "<YOUR_SUBSCRIPTION_ID>" `
    -EnableVpnGateway
```

The GatewaySubnet is preserved after uninstall, so redeployment will reuse it.
