# ADCS Scenario -- Root CA with HSM-Backed Keys

Deploy and configure an **Active Directory Certificate Services (ADCS) Root CA** with keys stored in an HSM via either **Azure Cloud HSM** (Cavium KSP) or **Azure Dedicated HSM** (SafeNet KSP).

This scenario automates the full ADCS wizard workflow in two scripted steps, plus a manual HSM provider installation step between them:

| Step | Script / Action | Purpose |
|------|-----------------|---------|
| **1** | `deploy-adcs-vm.ps1` | Deploy a Windows Server 2022 VM into the HSM platform VNet |
| **2** | Manual -- install HSM provider | Install the platform SDK/client and register the KSP on the ADCS VM |
| **3** | `configure-adcs.ps1` | Configure the Root CA with the HSM-backed KSP |

> **Uninstall:** See [README-uninstall.md](README-uninstall.md) for teardown instructions.

---

## Prerequisites

- **HSM platform base deployment** must already exist (VNet, subnet, HSM resource)
- **HSM activated** -- for Dedicated HSM, the Luna HSM must be initialized with a partition (see [Activate-DedicatedHSM.md](../../deployhsm/azuredededicatedhsm/Activate-DedicatedHSM.md))
- **Az PowerShell module** installed and authenticated (`Connect-AzAccount`)
- **Azure subscription** with Cloud HSM or Dedicated HSM provisioned

---

## Step 1: Deploy the ADCS VM

```powershell
.\deploy-adcs-vm.ps1 -Platform <PLATFORM> -SubscriptionId "<YOUR_SUBSCRIPTION_ID>"
```

| `<PLATFORM>` | Resource Group | Description |
|--------------|---------------|-------------|
| `AzureCloudHSM` | CHSM-HSB-ADCS-VM | Deploy into the Cloud HSM VNet |
| `AzureDedicatedHSM` | DHSM-HSB-ADCS-VM | Deploy into the Dedicated HSM VNet |

This creates a Windows Server 2022 VM in its own resource group, connected to the existing HSM VNet.

---

## Step 2: Install the HSM Provider (manual step)

RDP into the ADCS VM and install the HSM provider software. Follow the section for your platform:

| Platform | Software | KSP Provider Name |
|----------|----------|--------------------|
| AzureCloudHSM | Azure Cloud HSM SDK | `Cavium Key Storage Provider` |
| AzureDedicatedHSM | Thales Luna Client v10.9.2 | `SafeNet Key Storage Provider` |

### Step 2a: Azure Cloud HSM

1. **Download and install** the Azure Cloud HSM SDK from the [Cloud HSM Onboarding Guide](https://github.com/microsoft/MicrosoftAzureCloudHSM/tree/main/OnboardingGuides).

2. **Verify the configuration file** exists:

   ```powershell
   Test-Path "C:\Program Files\Microsoft Azure Cloud HSM Client SDK\utils\azcloudhsm_util\azcloudhsm_application.cfg"
   ```

3. **Start the client service** (the MSI installs it but leaves it stopped):

   ```powershell
   Start-Service azcloudhsm_client
   Get-Service azcloudhsm_client   # Confirm: Running
   ```

4. **Verify the KSP is registered:**

   ```powershell
   certutil -csplist | Select-String "Cavium"
   ```

   Expected: `Cavium Key Storage Provider` listed with no errors.

### Step 2b: Azure Dedicated HSM (Thales Luna Client)

The ADCS VM needs the Thales Luna Client for Windows installed, the HSM server certificate trusted, a client certificate registered with the HSM, and the SafeNet KSP configured. This is the Windows equivalent of Phases 1 and 3 from the [Activate-DedicatedHSM.md](../../deployhsm/azuredededicatedhsm/Activate-DedicatedHSM.md) guide (which covers the Linux Admin VM).

> **Prerequisite:** The HSM partition must already exist **and** the Crypto Officer (CO) role must be initialized. The CO role is required for ADCS key generation. See [Activate-DedicatedHSM.md -- Step 12](../../deployhsm/azuredededicatedhsm/Activate-DedicatedHSM.md#step-12-initialize-partition-roles-po-and-co).

> **Package:** `610-000396-016_SW_Windows_Luna_Client_V10.9.2_RevA.zip`
> Download from the [Thales Support Portal](https://supportportal.thalesgroup.com/csm?id=kb_article_view&sysparm_article=KB0030276).

#### NTLS Certificate and Configuration Files

After completing Steps 2b-1 through 2b-9, the following files must exist on the ADCS VM for NTLS communication with the HSM:

| File | Path on ADCS VM | Purpose |
|------|-----------------|---------|
| Client private key | `C:\Program Files\SafeNet\LunaClient\cert\client\dhsm-adcs-vmKey.pem` | PKCS#1 RSA key for NTLS authentication (must start with `BEGIN RSA PRIVATE KEY`) |
| Client certificate | `C:\Program Files\SafeNet\LunaClient\cert\client\dhsm-adcs-vm.pem` | Self-signed cert presented to HSM during NTLS handshake |
| HSM server certificate | `C:\Program Files\SafeNet\LunaClient\cert\server\CAFile.pem` | HSM's server cert (added by `vtl addServer`; trusts the HSM endpoint) |
| Crystoki config | `C:\Program Files\SafeNet\LunaClient\crystoki.ini` | Luna Client configuration (server IPs, cert paths, slot config) |

> **Note:** The client cert (`dhsm-adcs-vm.pem`) must also be registered on the HSM side via `client register` (Step 2b-7) and the ADCS VM's private IP mapped (Step 2b-8). Without both sides configured, NTLS will fail silently.

#### 2b-1. Copy the installer to the ADCS VM

Copy the ZIP to the ADCS VM (via RDP drag-and-drop, shared drive, or Azure Blob).

#### 2b-2. Extract and install the Luna Client

1. Extract the ZIP. Inside you will find the installer and EULA files.
2. Run **LunaHSMClient.exe** as Administrator.
3. When prompted for components, install at minimum:
   - **Network** (under Luna Devices)
   - **CSP (CAPI) / KSP (CNG)** (under Features)
4. Accept defaults for install path: `C:\Program Files\SafeNet\LunaClient`.

#### 2b-3. Create a client certificate

> **Warning (Linux only):** On Linux, `vtl createCert` (Luna Client v10.9.2) encrypts the private key with AES-256-CBC by default, which breaks NTLS authentication. On **Windows**, `vtl createCert` generates PKCS#1 keys correctly.

Open an **elevated PowerShell** or Command Prompt in the Luna Client directory:

```powershell
cd "C:\Program Files\SafeNet\LunaClient"
vtl createCert -n dhsm-adcs-vm
```

Expected output:

```
Private Key created and written to: C:\Program Files\SafeNet\LunaClient\cert\client\dhsm-adcs-vmKey.pem
Certificate created and written to: C:\Program Files\SafeNet\LunaClient\cert\client\dhsm-adcs-vm.pem
```

Verify the key is PKCS#1 format:

```powershell
Get-Content "C:\Program Files\SafeNet\LunaClient\cert\client\dhsm-adcs-vmKey.pem" -First 1
# Must show: -----BEGIN RSA PRIVATE KEY-----
# If it shows BEGIN PRIVATE KEY (PKCS#8), NTLS will fail silently.
```

> **Important:** `vtl createCert` restricts the private key file to the creating user only. The ADCS service (CertSvc) runs as `NT AUTHORITY\SYSTEM` and needs read access to establish the NTLS connection. Grant it now:
>
> ```powershell
> icacls "C:\Program Files\SafeNet\LunaClient\cert\client\dhsm-adcs-vmKey.pem" /grant "NT AUTHORITY\SYSTEM:(R)"
> ```
>
> Without this, CertSvc will fail with `NTE_PROVIDER_DLL_FAIL` because SYSTEM cannot open the NTLS session to the HSM.

#### 2b-4. Download the HSM server certificate

> **Note:** SCP directly to/from the Luna HSM appliance does not work (`subsystem request failed`). Copy the server cert from the **Admin VM** instead.

On the **Admin VM** (Linux), display the HSM server cert:

```bash
cat /usr/safenet/lunaclient/cert/server/CAFile.pem
```

Copy the output. On the **ADCS VM**, save it:

```powershell
notepad "C:\Program Files\SafeNet\LunaClient\server.pem"
# Paste the certificate contents and save
```

Alternatively, if the Admin VM can reach the ADCS VM via SCP:

```bash
# From Admin VM
scp /usr/safenet/lunaclient/cert/server/CAFile.pem dhsmVMAdmin@<ADCS-VM-IP>:"C:/Program Files/SafeNet/LunaClient/server.pem"
```

#### 2b-5. Register the HSM server with the Luna client

```powershell
cd "C:\Program Files\SafeNet\LunaClient"
vtl addServer -n <HSM-PRIVATE-IP> -c server.pem
```

Expected: `New server <HSM-PRIVATE-IP> successfully added to server list.`

#### 2b-6. Copy the client certificate to the HSM

> **Note:** SCP directly to the HSM appliance does not work from Windows. Use the Admin VM as a relay.

On the **ADCS VM**, display the client cert:

```powershell
Get-Content "C:\Program Files\SafeNet\LunaClient\cert\client\dhsm-adcs-vm.pem"
```

On the **Admin VM**, paste into a temp file and SCP to the HSM:

```bash
cat > /tmp/dhsm-adcs-vm.pem << 'EOF'
<paste certificate here>
EOF
scp /tmp/dhsm-adcs-vm.pem tenantadmin@<HSM-PRIVATE-IP>:
```

#### 2b-7. Register the ADCS VM as a client on the HSM

SSH to the HSM (from the ADCS VM or the Admin VM):

```
ssh tenantadmin@<HSM-PRIVATE-IP>
```

In LunaSH:

```
lunash:> client register -client dhsm-adcs-vm -hostname dhsm-adcs-vm
lunash:> client list
```

Expected: `registered client: dhsm-adcs-vm`

#### 2b-8. Map the ADCS VM private IP and assign the partition

> **Important:** Use the ADCS VM's actual private IP in the HSM VNet. Verify with `ipconfig` on the VM -- do not assume it matches the deployment template.

```
lunash:> client hostip map -client dhsm-adcs-vm -ip <ADCS-VM-PRIVATE-IP>
lunash:> client assignPartition -client dhsm-adcs-vm -partition <PARTITION-NAME>
lunash:> service restart ntls
lunash:> exit
```

#### 2b-9. Verify NTLS connectivity

Back on the ADCS VM in an elevated Command Prompt:

```cmd
cd "C:\Program Files\SafeNet\LunaClient"
vtl verify
```

Expected output:

```
Slot    Serial #                Label
====    ================        =====
   0       <serial>             <partition-name>
```

If you see a slot, the ADCS VM can communicate with the HSM.

#### 2b-10. Register the SafeNet KSP

Register the PKCS#11 security library with the KSP:

```powershell
& "C:\Program Files\SafeNet\LunaClient\KSP\kspcmd.exe" library "C:\Program Files\SafeNet\LunaClient\cryptoki.dll"
```

Register the HSM slot for the current user and for `NT AUTHORITY\SYSTEM` (required for the CertSvc service):

```powershell
# Current user (for interactive testing)
& "C:\Program Files\SafeNet\LunaClient\KSP\kspcmd.exe" password /s prod-adcs /c <CO-password>

# SYSTEM account (for ADCS CertSvc service)
& "C:\Program Files\SafeNet\LunaClient\KSP\kspcmd.exe" password /s prod-adcs /u SYSTEM /d "NT AUTHORITY" /c <CO-password>
```

Verify the slot is registered:

```powershell
& "C:\Program Files\SafeNet\LunaClient\KSP\kspcmd.exe" viewSlots
```

> **Note:** `KspConfig.exe` (GUI) is also available in the KSP directory but can be unreliable. The `kspcmd.exe` CLI is the recommended approach.

#### 2b-11. Verify the KSP is registered

```powershell
certutil -csp "SafeNet Key Storage Provider" -key
```

Expected: `CertUtil: -key command completed successfully.` (no keys listed yet is normal).

---

## Step 3: Configure the Root CA

### Azure Cloud HSM

```powershell
.\configure-adcs.ps1 -CACommonName "HSB-RootCA" `
    -HsmUsername "cu1" `
    -HsmPassword (ConvertTo-SecureString "user1234" -AsPlainText -Force)
```

The `-HsmUsername` and `-HsmPassword` parameters set the Cloud HSM environment variables (`azcloudhsm_username` and `azcloudhsm_password`) required by the Cavium KSP. If omitted, the script checks for existing environment variables or prompts interactively.

### Azure Dedicated HSM

```powershell
.\configure-adcs.ps1 -CACommonName "HSB-RootCA" -Platform AzureDedicatedHSM
```

No HSM credentials are needed -- the SafeNet KSP authenticates via the registered slot and NTLS client certificate.

---

## What configure-adcs.ps1 Does

The script executes 6 steps that mirror the ADCS configuration wizard:

| Step | Action |
|------|--------|
| **0** | Platform setup: Cloud HSM sets environment variables; Dedicated HSM confirms slot connectivity |
| **1/6** | Validates prerequisites (admin, OS, platform-specific SDK/client checks, KSP registered, no existing CA) |
| **2/6** | Creates `C:\Windows\CAPolicy.inf` (must exist before role configuration) |
| **3/6** | Installs the ADCS-Cert-Authority Windows feature |
| **4/6** | Runs `Install-AdcsCertificationAuthority` with a **new key** in the HSM |
| **5/6** | Validates CA is operational -- cert, KSP, private key, CRL, CAPolicy.inf |
| **6/6** | Registry hardening (admin interaction, audit, InterfaceFlags 0x641, CRLEditFlags +EDITF_ENABLEAKIKEYID, ForceTeletex UTF8) + CA backup |

Platform-specific prerequisite checks in Step 1:

| Check | AzureCloudHSM | AzureDedicatedHSM |
|-------|--------------|-------------------|
| SDK/Client | Cloud HSM SDK path + `azcloudhsm_application.cfg` | Luna Client at `C:\Program Files\SafeNet\LunaClient` |
| Config | SDK dirs added to system PATH | `crystoki.ini` present |
| Service | `azcloudhsm_client` service running | No service required (NTLS via cryptoki) |
| KSP | `Cavium Key Storage Provider` in certutil -csplist | `SafeNet Key Storage Provider` via `certutil -csp "SafeNet Key Storage Provider" -key` |

---

## Provider Selection (Key Algorithm)

In the ADCS wizard, each algorithm appears as a separate provider entry. The script models this via the `-KeyAlgorithm` parameter. The `-Platform` parameter selects the KSP.

### Azure Cloud HSM (Cavium Key Storage Provider)

| `-KeyAlgorithm` | ADCS Wizard Provider | Key Length |
|-----------------|----------------------|------------|
| `RSA` (default) | `RSA#Cavium Key Storage Provider` | 2048, 3072, or 4096 |
| `ECDSA_P256` | `ECDSA_P256#Cavium Key Storage Provider` | 256 (fixed) |
| `ECDSA_P384` | `ECDSA_P384#Cavium Key Storage Provider` | 384 (fixed) |
| `ECDSA_P521` | `ECDSA_P521#Cavium Key Storage Provider` | 521 (fixed) |

### Azure Dedicated HSM (SafeNet Key Storage Provider)

| `-KeyAlgorithm` | ADCS Wizard Provider | Key Length |
|-----------------|----------------------|------------|
| `RSA` (default) | `RSA#SafeNet Key Storage Provider` | 2048, 3072, or 4096 |
| `ECDSA_P256` | `ECDSA_P256#SafeNet Key Storage Provider` | 256 (fixed) |
| `ECDSA_P384` | `ECDSA_P384#SafeNet Key Storage Provider` | 384 (fixed) |
| `ECDSA_P521` | `ECDSA_P521#SafeNet Key Storage Provider` | 521 (fixed) |

For ECDSA curves, the key length is automatically set to the curve's native size.

---

## Parameters -- deploy-adcs-vm.ps1

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-Platform` | Yes | -- | `AzureCloudHSM` or `AzureDedicatedHSM` |
| `-SubscriptionId` | Yes | -- | Azure subscription ID |
| `-Location` | No | From parameters file | Azure region override |
| `-AdminPassword` | No | Prompted | VM admin account password |
| `-AdminUsername` | No | `azureuser` | VM admin username |
| `-ParameterFile` | No | Auto-detected | Path to ARM parameters file |

## Parameters -- configure-adcs.ps1

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-CACommonName` | Yes | -- | Common Name for the Root CA (e.g. `HSB-RootCA`) |
| `-Platform` | No | `AzureCloudHSM` | `AzureCloudHSM` or `AzureDedicatedHSM` |
| `-CAType` | No | `StandaloneRootCA` | `StandaloneRootCA` or `EnterpriseRootCA` |
| `-KeyAlgorithm` | No | `RSA` | `RSA`, `ECDSA_P256`, `ECDSA_P384`, or `ECDSA_P521` |
| `-KeyLength` | No | `2048` | RSA: 2048/3072/4096. ECDSA: auto-set |
| `-HashAlgorithm` | No | `SHA256` | `SHA256`, `SHA384`, or `SHA512` |
| `-ValidityYears` | No | `20` | Root CA certificate validity (years) |
| `-CADistinguishedNameSuffix` | No | -- | DN suffix (e.g. `O=Contoso,C=US`) |
| `-CACredential` | No | Current user | PSCredential for CA config |
| `-AllowAdminInteraction` | No | `$true` | Enable admin interaction for HSM key access |
| `-CRLPeriod` | No | `Weeks` | CRL publication period unit |
| `-CRLPeriodUnits` | No | `1` | CRL period count |
| `-CRLDeltaPeriod` | No | `Days` | Delta CRL period unit |
| `-CRLDeltaPeriodUnits` | No | `0` | Delta CRL count (`0` = disabled) |
| `-CRLOverlapPeriod` | No | `Hours` | CRL overlap period unit |
| `-CRLOverlapUnits` | No | `0` | CRL overlap count |
| `-CRLDeltaOverlapPeriod` | No | `Minutes` | Delta CRL overlap period unit |
| `-CRLDeltaOverlapUnits` | No | `0` | Delta CRL overlap count |
| `-IssuedCertValidityYears` | No | `1` | Default validity for certs issued by this CA (years) |
| `-PathLength` | No | `None` | Basic Constraints path length (`None` = no restriction) |
| `-DatabaseDirectory` | No | `C:\Windows\system32\CertLog` | CA database path |
| `-LogDirectory` | No | `C:\Windows\system32\CertLog` | CA log path |
| `-HsmUsername` | No | -- | Cloud HSM only. CU username (e.g. `cu1`). Sets `azcloudhsm_username` |
| `-HsmPassword` | No | -- | Cloud HSM only. CU password as SecureString. Sets `azcloudhsm_password` |
| `-OverwriteExisting` | No | -- | Replace existing CA configuration |
| `-DisableBackup` | No | -- | Skip post-config CA backup |
| `-SkipConfirmation` | No | -- | Skip interactive confirmation |

---

## Examples

### Azure Cloud HSM

> **`-HsmUsername` / `-HsmPassword`** supply the Crypto User (CU) credentials for the Cloud HSM cluster. The script sets `azcloudhsm_username` and `azcloudhsm_password` system environment variables that the Cavium KSP reads at runtime. If already set on the VM, omit both parameters.

#### RSA Root CA (defaults: 2048-bit, SHA256, 20 years)

```powershell
.\configure-adcs.ps1 -CACommonName "HSB-RootCA" `
    -HsmUsername "cu1" `
    -HsmPassword (ConvertTo-SecureString "user1234" -AsPlainText -Force)
```

#### ECDSA P384 Root CA

```powershell
.\configure-adcs.ps1 -CACommonName "HSB-RootCA" -KeyAlgorithm ECDSA_P384 `
    -HsmUsername "cu1" `
    -HsmPassword (ConvertTo-SecureString "user1234" -AsPlainText -Force)
```

#### With existing environment variables

```powershell
.\configure-adcs.ps1 -CACommonName "HSB-RootCA"
```

#### Full example with DN suffix

```powershell
.\configure-adcs.ps1 -CACommonName "HSB-RootCA" `
    -CADistinguishedNameSuffix "O=Contoso,C=US" `
    -KeyAlgorithm RSA -KeyLength 4096 `
    -HashAlgorithm SHA384 -ValidityYears 25 `
    -HsmUsername "cu1" `
    -HsmPassword (ConvertTo-SecureString "user1234" -AsPlainText -Force)
```

### Azure Dedicated HSM

> No `-HsmUsername` / `-HsmPassword` needed. The SafeNet KSP authenticates via the registered NTLS slot.

#### RSA Root CA (defaults: 2048-bit, SHA256, 20 years)

```powershell
.\configure-adcs.ps1 -CACommonName "HSB-RootCA" -Platform AzureDedicatedHSM
```

#### RSA 4096-bit Root CA

```powershell
.\configure-adcs.ps1 -CACommonName "HSB-RootCA" -Platform AzureDedicatedHSM `
    -KeyLength 4096
```

#### ECDSA P384 Root CA

```powershell
.\configure-adcs.ps1 -CACommonName "HSB-RootCA" -Platform AzureDedicatedHSM `
    -KeyAlgorithm ECDSA_P384
```

#### Enterprise Root CA with DN suffix

```powershell
.\configure-adcs.ps1 -CACommonName "HSB-RootCA" -Platform AzureDedicatedHSM `
    -CAType EnterpriseRootCA `
    -CADistinguishedNameSuffix "O=Contoso,C=US" `
    -KeyLength 4096 -HashAlgorithm SHA384 -ValidityYears 25
```

### Common to Both Platforms

#### With explicit CA credentials

```powershell
$cred = Get-Credential "dhsm-adcs-vm\dhsmVMAdmin"
.\configure-adcs.ps1 -CACommonName "HSB-RootCA" -Platform AzureDedicatedHSM `
    -CACredential $cred
```

#### Skip confirmation (non-interactive)

```powershell
.\configure-adcs.ps1 -CACommonName "HSB-RootCA" -Platform AzureDedicatedHSM `
    -SkipConfirmation
```

---

## Post-Configuration Verification

After the script completes, verify the CA on the ADCS VM:

```powershell
certutil -ca.cert RootCA.cer       # Export CA certificate
certutil -dump RootCA.cer           # View certificate details
certutil -getreg CA\CSP             # Confirm KSP binding (Cavium or SafeNet)
certutil -verifykeys                # Verify HSM key binding
certutil -getreg CA\CSP\Interactive # Confirm admin interaction enabled
certutil -getreg CA\InterfaceFlags  # Confirm 0x641 hardening
certutil -getreg CA\ForceTeletex     # Confirm 0x12 (AUTO+UTF8)
certutil -getreg CA\CRLEditFlags     # Confirm EDITF_ENABLEAKIKEYID
```

---

## Troubleshooting -- Dedicated HSM

| Symptom | Cause | Fix |
|---------|-------|-----|
| `vtl verify` shows no slots | Client cert not registered or partition not assigned | Re-run Steps 2b-7 through 2b-8 on the HSM |
| `vtl verify` no slots (errno=104) | HSM clock behind cert Not Before | Fix HSM clock: `sysconf time HH:MM YYYYMMDD`, restart NTLS |
| `certutil -csplist` missing SafeNet | KSP not registered | Re-run KspConfig.exe (Step 2b-10) |
| configure-adcs.ps1 fails at Step 4 | KSP can't reach HSM | Verify `vtl verify` shows a slot first |
| `vtl addServer` fails | Wrong server.pem or HSM cert regenerated | Re-download server.pem from HSM |
| NTLS connection refused | NTLS not running or not bound | SSH to HSM: `ntls bind eth0`, `service restart ntls` |
| `vtl createCert` key unusable | v10.9.2 encrypts keys (AES-256-CBC) | Use `openssl genrsa` + `openssl req` instead (Step 2b-3) |
| Wrong VM private IP mapped | DHCP assigned different IP | Check `ipconfig` on VM, remap with `client hostip` |

---

## File Layout

```
scenarios/adcs/
├── README-Install-ADCS.md                 <-- This file
├── README-uninstall.md                    <-- Uninstall documentation
├── deploy-adcs-vm.ps1                     <-- Step 1: Deploy ADCS VM
├── configure-adcs.ps1                     <-- Step 3: Configure Root CA
├── uninstall-adcs-vm.ps1                  <-- Teardown ADCS VM
├── adcs-vm-deploy.json                    <-- ARM template for VM
├── adcs-vm-parameters-cloudhsm.json       <-- Cloud HSM platform params
└── adcs-vm-parameters-dedicatedhsm.json   <-- Dedicated HSM platform params
```

---

## Supported Platforms

| Platform | Resource Group | VM Name | Region |
|----------|---------------|---------|--------|
| AzureCloudHSM | CHSM-HSB-ADCS-VM | chsm-adcs-vm | UK West |
| AzureDedicatedHSM | DHSM-HSB-ADCS-VM | dhsm-adcs-vm | Australia East |
