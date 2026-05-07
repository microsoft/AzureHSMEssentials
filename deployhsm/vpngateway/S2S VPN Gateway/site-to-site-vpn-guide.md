# Site-to-Site VPN to Azure Cloud HSM -- Manual Configuration Guide

This guide walks through setting up a **Site-to-Site (S2S) IPsec/IKEv2 VPN** between an on-premises network (or simulated environment) and an Azure VNet hosting Azure Cloud HSM behind Private Link.

> **Note:** The HSM AI Guardian deployment uses **Point-to-Site (P2S)** VPN by default via `deploy-hsm.ps1 -EnableVpnGateway`. This guide is for organizations that need a **persistent site-to-site** connection from their on-premises network to the Azure HSM environment.

---

## Architecture

```
On-Premises / Simulated Site               Azure
┌──────────────────────────┐              ┌──────────────────────────────────┐
│  On-Prem Network         │   IPsec/     │  Client VNet (10.0.0.0/16)      │
│  172.16.0.0/16           │   IKEv2      │                                 │
│                          │   Tunnel     │  ┌── GatewaySubnet 10.0.255.0/26│
│  ┌────────────────────┐  │◄────────────►│  │   VPN Gateway (VpnGw1AZ)     │
│  │ VPN Device /       │  │              │  │                               │
│  │ Software Gateway   │  │              │  ├── default subnet 10.0.2.0/24 │
│  │ (Public IP)        │  │              │  │   Admin VM                    │
│  └────────────────────┘  │              │  │                               │
│                          │              │  └── Private Endpoint ──► Cloud  │
│  Workstations, Servers   │              │                          HSM    │
└──────────────────────────┘              └──────────────────────────────────┘
```

---

## Prerequisites

- An existing Azure Cloud HSM deployment with a VNet and GatewaySubnet
- An Azure VPN Gateway deployed in the VNet (the same one created by `-EnableVpnGateway`)
- One of the following on-premises VPN devices:
  - Hardware: Cisco ASA, Juniper SRX, Fortinet FortiGate, Palo Alto, F5 BIG-IP, etc.
  - Software: strongSwan (Linux), RRAS (Windows Server), pfSense, OPNsense

For supported devices, see: [Azure VPN Gateway validated devices](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpn-devices)

---

## Option A: On-Premises Device to Azure VPN Gateway

### Step 1 -- Create a Local Network Gateway

The Local Network Gateway represents your on-premises VPN device in Azure.

```powershell
# Replace with your on-premises public IP and address space
$onPremPublicIp    = "203.0.113.1"           # Your on-prem VPN device public IP
$onPremAddrSpace   = @("172.16.0.0/16")      # Your on-prem network CIDR(s)
$resourceGroup     = "CHSM-HAG-CLIENT-RG"
$location          = "eastus2euap"            # Must match your VNet region

New-AzLocalNetworkGateway `
    -Name "onprem-local-gateway" `
    -ResourceGroupName $resourceGroup `
    -Location $location `
    -GatewayIpAddress $onPremPublicIp `
    -AddressPrefix $onPremAddrSpace
```

### Step 2 -- Create the S2S VPN Connection

```powershell
$vpnGateway    = Get-AzVirtualNetworkGateway -Name "chsm-vpn-gateway" -ResourceGroupName $resourceGroup
$localGateway  = Get-AzLocalNetworkGateway -Name "onprem-local-gateway" -ResourceGroupName $resourceGroup

# Use a strong shared key (PSK) -- both sides must match
$sharedKey = "YourStrongPreSharedKey123!"

New-AzVirtualNetworkGatewayConnection `
    -Name "s2s-to-onprem" `
    -ResourceGroupName $resourceGroup `
    -Location $location `
    -VirtualNetworkGateway1 $vpnGateway `
    -LocalNetworkGateway2 $localGateway `
    -ConnectionType IPsec `
    -SharedKey $sharedKey `
    -ConnectionProtocol IKEv2
```

### Step 3 -- Configure the On-Premises VPN Device

Configure your device with these settings:

| Setting | Value |
|---------|-------|
| Remote Gateway IP | Azure VPN Gateway public IP (from deployment output) |
| Pre-Shared Key | Same `$sharedKey` used above |
| IKE Version | IKEv2 |
| IPsec Encryption | AES256 |
| IPsec Integrity | SHA256 |
| DH Group | DHGroup14 (2048-bit) |
| SA Lifetime | 28800 seconds (IKE) / 3600 seconds (IPsec) |
| Remote Network | `10.0.0.0/16` (Azure VNet address space) |
| Local Network | `172.16.0.0/16` (your on-prem address space) |

> For device-specific configuration scripts, download from the Azure Portal:
> **VPN Gateway → Connections → s2s-to-onprem → Download configuration**

### Step 4 -- Verify the Connection

```powershell
Get-AzVirtualNetworkGatewayConnection `
    -Name "s2s-to-onprem" `
    -ResourceGroupName $resourceGroup

# Status should show: ConnectionStatus = Connected
```

From an on-premises machine, verify you can reach the HSM Private Endpoint:

```bash
# Resolve the Cloud HSM FQDN (should return 10.0.2.x private IP)
nslookup <your-hsm-name>.privatelink.cloudhsm.azure.net

# Test connectivity
Test-NetConnection -ComputerName <private-ip> -Port 2225
```

---

## Option B: Azure-to-Azure VNet-to-VNet (Simulated S2S)

Use this to validate S2S VPN without on-premises hardware. Deploys a second VNet + VPN Gateway in Azure that acts as a simulated on-prem site. Azure uses identical IPsec/IKEv2 tunnels for VNet-to-VNet connections.

### Step 1 -- Create the Simulated On-Prem Environment

```powershell
$resourceGroup  = "CHSM-HAG-SIMSITE-RG"
$location       = "eastus2"   # Can be any region
$sharedKey      = "YourStrongPreSharedKey123!"

# Create resource group
New-AzResourceGroup -Name $resourceGroup -Location $location

# Create "on-prem" VNet
$simSubnet = New-AzVirtualNetworkSubnetConfig -Name "default" -AddressPrefix "172.16.1.0/24"
$gwSubnet  = New-AzVirtualNetworkSubnetConfig -Name "GatewaySubnet" -AddressPrefix "172.16.255.0/26"
$simVnet   = New-AzVirtualNetwork `
    -Name "onprem-sim-vnet" `
    -ResourceGroupName $resourceGroup `
    -Location $location `
    -AddressPrefix "172.16.0.0/16" `
    -Subnet $simSubnet, $gwSubnet

# Create public IP for simulated gateway
$simPip = New-AzPublicIpAddress `
    -Name "onprem-sim-vpn-pip" `
    -ResourceGroupName $resourceGroup `
    -Location $location `
    -AllocationMethod Static `
    -Sku Standard `
    -Zone 1, 2, 3

# Create VPN Gateway (takes 20-45 minutes)
$gwSubnetRef = Get-AzVirtualNetworkSubnetConfig -Name "GatewaySubnet" -VirtualNetwork $simVnet
$gwIpConfig  = New-AzVirtualNetworkGatewayIpConfig -Name "default" -SubnetId $gwSubnetRef.Id -PublicIpAddressId $simPip.Id

New-AzVirtualNetworkGateway `
    -Name "onprem-sim-vpn-gateway" `
    -ResourceGroupName $resourceGroup `
    -Location $location `
    -GatewayType Vpn `
    -VpnType RouteBased `
    -VpnGatewayGeneration Generation2 `
    -GatewaySku VpnGw1AZ `
    -IpConfigurations $gwIpConfig `
    -EnableBgp $false
```

### Step 2 -- Create Connections in Both Directions

VNet-to-VNet requires a connection resource on each side:

```powershell
$hsmRg = "CHSM-HAG-CLIENT-RG"

# Get both gateways
$hsmGw    = Get-AzVirtualNetworkGateway -Name "chsm-vpn-gateway"       -ResourceGroupName $hsmRg
$simGw    = Get-AzVirtualNetworkGateway -Name "onprem-sim-vpn-gateway" -ResourceGroupName $resourceGroup

# HSM side → Simulated on-prem
New-AzVirtualNetworkGatewayConnection `
    -Name "hsm-to-onprem-sim" `
    -ResourceGroupName $hsmRg `
    -Location "eastus2euap" `
    -VirtualNetworkGateway1 $hsmGw `
    -VirtualNetworkGateway2 $simGw `
    -ConnectionType Vnet2Vnet `
    -SharedKey $sharedKey `
    -ConnectionProtocol IKEv2

# Simulated on-prem → HSM side
New-AzVirtualNetworkGatewayConnection `
    -Name "onprem-sim-to-hsm" `
    -ResourceGroupName $resourceGroup `
    -Location $location `
    -VirtualNetworkGateway1 $simGw `
    -VirtualNetworkGateway2 $hsmGw `
    -ConnectionType Vnet2Vnet `
    -SharedKey $sharedKey `
    -ConnectionProtocol IKEv2
```

### Step 3 -- Verify the Connection

```powershell
# Check from HSM side
Get-AzVirtualNetworkGatewayConnection -Name "hsm-to-onprem-sim" -ResourceGroupName $hsmRg | Select-Object Name, ConnectionStatus

# Check from simulated side
Get-AzVirtualNetworkGatewayConnection -Name "onprem-sim-to-hsm" -ResourceGroupName $resourceGroup | Select-Object Name, ConnectionStatus

# Both should show: ConnectionStatus = Connected
```

### Step 4 -- Test Connectivity (Optional VM in Simulated VNet)

Deploy a small VM in the simulated on-prem VNet to test end-to-end HSM access over the S2S tunnel:

```powershell
# From the simulated on-prem VM:
nslookup <your-hsm-name>.privatelink.cloudhsm.azure.net
Test-NetConnection -ComputerName <private-ip> -Port 2225
```

> **Important:** For DNS resolution of Private Link FQDNs from the simulated on-prem VNet, you need to either:
> - Link the private DNS zone (`privatelink.cloudhsm.azure.net`) to the simulated VNet, or
> - Configure a DNS forwarder that resolves against Azure DNS (168.63.129.16)

---

## Cleanup (Simulated S2S)

```powershell
# Remove connections
Remove-AzVirtualNetworkGatewayConnection -Name "hsm-to-onprem-sim" -ResourceGroupName "CHSM-HAG-CLIENT-RG" -Force
Remove-AzVirtualNetworkGatewayConnection -Name "onprem-sim-to-hsm" -ResourceGroupName "CHSM-HAG-SIMSITE-RG" -Force

# Remove simulated environment (gateway deletion takes ~10 min)
Remove-AzVirtualNetworkGateway -Name "onprem-sim-vpn-gateway" -ResourceGroupName "CHSM-HAG-SIMSITE-RG" -Force
Remove-AzPublicIpAddress -Name "onprem-sim-vpn-pip" -ResourceGroupName "CHSM-HAG-SIMSITE-RG" -Force
Remove-AzVirtualNetwork -Name "onprem-sim-vnet" -ResourceGroupName "CHSM-HAG-SIMSITE-RG" -Force
Remove-AzResourceGroup -Name "CHSM-HAG-SIMSITE-RG" -Force
```

---

## Security Considerations for HSM S2S VPN

| Consideration | Recommendation |
|---------------|----------------|
| **Pre-Shared Key** | Use a 64+ character random string; rotate periodically |
| **IKE Version** | IKEv2 only (IKEv1 is deprecated) |
| **IPsec Policy** | Use custom policy: AES256-GCM + SHA384 + DHGroup24 for FIPS compliance |
| **NSG Rules** | Restrict VNet access to only necessary ports (2225 for Cloud HSM) |
| **BGP** | Enable for dynamic routing in production multi-site scenarios |
| **Forced Tunneling** | Consider if all HSM traffic must route through on-prem security appliances |
| **Connection Monitoring** | Use Azure Network Watcher + Connection Monitor to alert on tunnel drops |

---

## Custom IPsec Policy (FIPS-Compliant)

For HSM environments requiring FIPS 140-2 compliance on the VPN tunnel:

```powershell
$ipsecPolicy = New-AzIpsecPolicy `
    -IkeEncryption AES256 `
    -IkeIntegrity SHA384 `
    -DhGroup DHGroup24 `
    -IpsecEncryption GCMAES256 `
    -IpsecIntegrity GCMAES256 `
    -PfsGroup PFS24 `
    -SALifeTimeSeconds 3600 `
    -SADataSizeKilobytes 102400000

# Apply to connection
Set-AzVirtualNetworkGatewayConnection `
    -VirtualNetworkGatewayConnection (Get-AzVirtualNetworkGatewayConnection -Name "s2s-to-onprem" -ResourceGroupName "CHSM-HAG-CLIENT-RG") `
    -IpsecPolicies $ipsecPolicy `
    -Force
```

---

## References

- [Azure VPN Gateway documentation](https://learn.microsoft.com/en-us/azure/vpn-gateway/)
- [Create a S2S VPN connection](https://learn.microsoft.com/en-us/azure/vpn-gateway/tutorial-site-to-site-portal)
- [VNet-to-VNet VPN connection](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-howto-vnet-vnet-resource-manager-portal)
- [Validated VPN devices](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpn-devices)
- [Custom IPsec/IKE policy](https://learn.microsoft.com/en-us/azure/vpn-gateway/ipsec-ike-policy-howto)
- [Azure Cloud HSM Onboarding Guide](https://github.com/microsoft/MicrosoftAzureCloudHSM/blob/main/OnboardingGuides/Azure%20Cloud%20HSM%20Onboarding.pdf)
