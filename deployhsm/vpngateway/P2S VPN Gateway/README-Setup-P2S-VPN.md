# Point-to-Site VPN Gateway for HSM Scenario Builder

Adds a **Point-to-Site (P2S) VPN Gateway** to any HSM platform VNet, enabling remote/VPN access from your workstation directly into the HSM environment. Useful when working from home or on-prem without direct Azure connectivity.

---

## Architecture

```
Your Workstation                       Azure
┌─────────────┐    OpenVPN tunnel    ┌──────────────────────────────┐
│  Azure VPN  │◄────────────────────►│  VPN Gateway (VpnGw1AZ)       │
│  Client     │   192.168.100.x      │  GatewaySubnet 10.x.255.0/26│
│  P2SChild   │                      │                              │
│  Cert       │                      │  Client VNet (10.x.0.0/16)  │
└─────────────┘                      │  ├── default subnet          │
                                     │  ├── Admin VM                │
                                     │  └── HSM (PE / delegated)    │
                                     └──────────────────────────────┘
```

## Quick Start (3 Commands)

### 1. Deploy the HSM with VPN Gateway

```powershell
# From the deployhsm/ directory -- add -EnableVpnGateway to any platform:
.\deploy-hsm.ps1 -Platform AzureCloudHSM `
    -SubscriptionId "<YOUR_SUBSCRIPTION_ID>" `
    -AdminPasswordOrKey (Read-Host -AsSecureString -Prompt "Admin password") `
    -AuthenticationType password `
    -EnableVpnGateway
```

This deploys the HSM infrastructure as normal, then chains a second deployment for the VPN Gateway. The VPN Gateway takes **20-45 minutes** to provision.

### 2. Generate Certificates & Configure Gateway

```powershell
# From the deployhsm/vpngateway/P2S VPN Gateway/ directory:
.\setup-vpn-certs.ps1 `
    -VpnGatewayName "chsm-vpn-gateway" `
    -ResourceGroupName "CHSM-HSB-CLIENT-RG"
```

If you run it from `deployhsm`, use:

```powershell
& ".\vpngateway\P2S VPN Gateway\setup-vpn-certs.ps1" `
    -VpnGatewayName "chsm-vpn-gateway" `
    -ResourceGroupName "CHSM-HSB-CLIENT-RG"
```

This:
- Creates a self-signed root cert (`P2SRootCert`) and client cert (`P2SChildCert`) in your local certificate store
- Uploads the root cert to the VPN Gateway
- Downloads the VPN client configuration zip

### 3. Connect with Azure VPN Client

1. Install the [Azure VPN Client](https://aka.ms/azvpnclientdownload)
2. Extract `vpnclientconfiguration.zip`
3. Import `azurevpnconfig.xml` into Azure VPN Client
4. Select `P2SChildCert` when prompted for a certificate
5. Connect!

Your workstation gets a `192.168.100.x` address with direct access to the HSM VNet.

---

## Platform Gateway Names

| Platform | VPN Gateway Name | GatewaySubnet | Client RG |
|---|---|---|---|
| AzureCloudHSM | `chsm-vpn-gateway` | `10.0.255.0/26` | `CHSM-HSB-CLIENT-RG` |
| AzureDedicatedHSM | `dhsm-vpn-gateway` | `10.3.255.0/26` | `DHSM-HSB-CLIENT-RG` |
| AzureKeyVault | `akv-vpn-gateway` | `10.2.255.0/26` | `AKV-HSB-CLIENT-RG` |
| AzureManagedHSM | `mhsm-vpn-gateway` | `10.1.255.0/26` | `MHSM-HSB-CLIENT-RG` |
| AzurePaymentHSM | `phsm-vpn-gateway` | `10.4.255.0/26` | `PHSM-HSB-CLIENT-RG` |

---

## Custom VPN Client Address Pool

The default client address pool is `192.168.100.0/24`. Override with:

```powershell
.\deploy-hsm.ps1 -Platform AzureCloudHSM `
    -SubscriptionId "<ID>" `
    -EnableVpnGateway `
    -VpnClientAddressPool "172.16.0.0/24"
```

When connected, your workstation's VPN adapter shows:

```
PPP adapter chsmclient-vnet:
   IPv4 Address. . . . . . . . . . . : 192.168.100.3
   Subnet Mask . . . . . . . . . . . : 255.255.255.255
   Default Gateway . . . . . . . . . :
```

---

## Uninstall

### Remove VPN Gateway Only (keep HSM deployment)

```powershell
# From the uninstallhsm/vpngateway/ directory:
.\uninstall-vpn-gateway.ps1 `
    -VpnGatewayName "chsm-vpn-gateway" `
    -ResourceGroupName "CHSM-HSB-CLIENT-RG" `
    -RemoveLocalCerts
```

This deletes the VPN Gateway and public IP (takes 15-30 min), and optionally removes the P2S certificates from your local store. The VNet, Admin VM, and HSM are **not** affected.

### Full Platform Uninstall

`uninstall-hsm.ps1` deletes the entire client RG which includes the VPN Gateway. No extra steps needed -- just be aware the uninstall will take longer (~30 min extra) if a VPN Gateway is present.

---

## Files

| File | Description |
|---|---|
| `deployhsm/vpngateway/P2S VPN Gateway/vpngw-deploy.json` | ARM template -- GatewaySubnet, public IP, VPN Gateway |
| `deployhsm/vpngateway/P2S VPN Gateway/setup-vpn-certs.ps1` | Generates P2S certs, uploads root cert, downloads VPN client config |
| `uninstallhsm/vpngateway/uninstall-vpn-gateway.ps1` | Removes VPN Gateway, public IP, and optionally local certs |

---

## Troubleshooting

| Issue | Solution |
|---|---|
| VPN Gateway deployment takes too long | Normal -- VPN Gateways take 20-45 minutes to provision. The main HSM deployment is already complete. |
| `ResourceGroupBeingDeleted` on redeploy | Wait 2-5 minutes after uninstall for Azure to finish deprovisioning, then retry. |
| Certificate not found in Azure VPN Client | Run `setup-vpn-certs.ps1` again -- it checks for existing certs and re-uploads if needed. |
| `P2SChildCert` not showing in VPN client | Ensure the cert is in `CurrentUser\My`. Open `certmgr.msc` > Personal > Certificates to verify. |
| Dedicated HSM already has GatewaySubnet | The ARM template updates the existing subnet. The VPN Gateway coexists with the ExpressRoute gateway. |

---

## Azure VPN Client Setup Guide

Full Microsoft documentation:
https://learn.microsoft.com/en-us/azure/vpn-gateway/point-to-site-vpn-client-certificate-windows-azure-vpn-client
