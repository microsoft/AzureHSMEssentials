# Azure Cloud HSM ADCS Migration: Root CA (Chain Pre-Distributed)

## Overview

This guide provides manual step-by-step instructions for migrating an Active Directory Certificate Services (AD CS) standalone Root CA from Azure Dedicated HSM (SafeNet/Thales Luna) to Azure Cloud HSM (Cavium). The migration uses the **chain pre-distribution** method: the new Root CA certificate is distributed to relying parties before cutover, ensuring seamless trust continuity.

This scenario involves two server roles:

| Role                  | Description                                                             |
| --------------------- | ----------------------------------------------------------------------- |
| **OLD Root CA** | The existing standalone Root CA running on Azure Dedicated HSM (source) |
| **NEW Root CA** | A clean Windows Server with Azure Cloud HSM SDK installed (target)      |

## Recommendation

For production migrations, we recommend using the **Migration Orchestrator** (`Invoke-CaMigration.ps1`) to automate this process end-to-end. The orchestrator handles all inter-server certificate transfers, trust store imports, timing, and PASS/FAIL reporting with zero interaction. The manual steps below are provided for environments where automation is not permitted or for operators who need to understand each step independently.

## Prerequisites

Before beginning the migration, confirm the following:

- [ ] **OLD Root CA server** is running and Certificate Services (`certsvc`) is operational
- [ ] **NEW Root CA server** is provisioned with Windows Server 2019 or later
- [ ] **Azure Cloud HSM SDK** is installed on the NEW server
- [ ] **Cavium Key Storage Provider** is enumerated (verify with `certutil -csplist`)
- [ ] **Cloud HSM credentials** are configured (`azcloudhsm_username` / `azcloudhsm_password` environment variables set at system level, VM rebooted after setting)
- [ ] **ADCS role** is installed on the NEW server (`Install-WindowsFeature ADCS-Cert-Authority`)
- [ ] **Network connectivity** from the NEW server to the Cloud HSM cluster is confirmed
- [ ] **File transfer method** is established between servers (e.g., `az vm run-command`, shared storage, USB)
- [ ] **Backup** of the OLD Root CA configuration and database has been taken
- [ ] **Generational suffix** chosen for the new CA name (e.g., `CHSM-RootCA-G2`) to prevent same-CN chain collision when both roots coexist in trust stores

## Migration Steps

### Step 1: Capture Existing Root CA Details

**Run on:** OLD Root CA server (Dedicated HSM)

Export the current Root CA certificate details to establish the baseline.

1. Open an elevated PowerShell prompt on the OLD Root CA server.
2. Identify the active CA name:

   ```powershell
   certutil -cainfo name
   ```
3. Export the CA certificate:

   ```powershell
   certutil -ca.cert C:\temp\OldRootCA.cer
   ```
4. Record the CA configuration details:

   ```powershell
   certutil -getreg CA\CSP
   certutil -getreg CA\HashAlgorithm
   certutil -getreg CA\CRLFlags
   certutil -getreg CA\ValidityPeriod
   certutil -getreg CA\ValidityPeriodUnits
   ```
5. Capture the certificate properties (subject, key length, extensions, validity):

   ```powershell
   certutil -dump C:\temp\OldRootCA.cer
   ```
6. Record the certificate thumbprint (needed for trust validation later):

   ```powershell
   $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new("C:\temp\OldRootCA.cer")
   Write-Host "Thumbprint: $($cert.Thumbprint)"
   ```
7. Save the output and the exported certificate file.

---

### Step 2: Validate New Root CA Server

**Run on:** NEW Root CA server (Cloud HSM)

Verify the NEW server is ready for Cloud HSM-backed Root CA installation.

1. Confirm the ADCS role is installed:

   ```powershell
   Get-WindowsFeature ADCS-Cert-Authority
   ```
2. Verify the Cavium KSP is available:

   ```powershell
   certutil -csplist | Select-String "Cavium"
   ```

   Expected output should include `Cavium Key Storage Provider`.
3. Verify Cloud HSM connectivity:

   ```powershell
   & "C:\Program Files\Microsoft Azure Cloud HSM Client SDK\utils\azcloudhsm_util\azcloudhsm_util.exe" loginHSM -username $env:azcloudhsm_username -password $env:azcloudhsm_password
   ```
4. Confirm no existing CA is configured:

   ```powershell
   $active = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA SilentlyContinue).Active
   if ($active) { Write-Warning "Existing CA found: $active" } else { Write-Host "No existing CA - ready to proceed" }
   ```

---

### Step 3: Build New Root CA

**Run on:** NEW Root CA server (Cloud HSM)

Create the new standalone Root CA with the private key stored in the Cloud HSM. Unlike an Issuing CA (which generates a CSR for a parent to sign), a Root CA self-signs its own certificate.

1. Create `C:\Windows\CAPolicy.inf` with the Root CA policy settings:

   ```ini
   [Version]
   Signature="$Windows NT$"

   [Certsrv_Server]
   RenewalKeyLength=2048
   RenewalValidityPeriod=Years
   RenewalValidityPeriodUnits=20
   CRLPeriod=Years
   CRLPeriodUnits=1
   CRLDeltaPeriod=Days
   CRLDeltaPeriodUnits=0
   ```
2. Install the CA role with **RSA** (self-signed Root CA with Cloud HSM key):

   ```powershell
   Install-AdcsCertificationAuthority `
       -CAType StandaloneRootCA `
       -CACommonName "CHSM-RootCA-G2" `
       -KeyLength 2048 `
       -HashAlgorithmName SHA256 `
       -ValidityPeriod Years `
       -ValidityPeriodUnits 20 `
       -CryptoProviderName "RSA#Cavium Key Storage Provider" `
       -OverwriteExistingKey `
       -Force
   ```

   > **Note:** The example uses RSA 2048. For RSA 3072, set `-KeyLength 3072`. For RSA 4096, set `-KeyLength 4096`. Update `RenewalKeyLength` in `CAPolicy.inf` to match.

2b. **Alternatively**, install the CA role with **ECDSA** (use this if the existing CA uses ECDSA):

   Update `C:\Windows\CAPolicy.inf` to use the ECDSA key length:

```ini
   [Version]
   Signature="$Windows NT$"

   [Certsrv_Server]
   RenewalKeyLength=256
   RenewalValidityPeriod=Years
   RenewalValidityPeriodUnits=20
   CRLPeriod=Years
   CRLPeriodUnits=1
   CRLDeltaPeriod=Days
   CRLDeltaPeriodUnits=0
```

   Then install:

```powershell
   Install-AdcsCertificationAuthority `
       -CAType StandaloneRootCA `
       -CACommonName "CHSM-RootCA-G2" `
       -KeyLength 256 `
       -HashAlgorithmName SHA256 `
       -ValidityPeriod Years `
       -ValidityPeriodUnits 20 `
       -CryptoProviderName "ECDSA_P256#Cavium Key Storage Provider" `
       -OverwriteExistingKey `
       -Force
```

> **Note:** For ECDSA P384 use `-KeyLength 384` and `"ECDSA_P384#Cavium Key Storage Provider"`. For P521 use `-KeyLength 521` and `"ECDSA_P521#Cavium Key Storage Provider"`. Set `RenewalKeyLength` in CAPolicy.inf to match.

3. Verify Certificate Services is running:

   ```powershell
   Get-Service certsvc
   certutil -cainfo name
   ```
4. Set headless HSM mode (prevents PIN prompts in non-interactive sessions):

   ```powershell
   # Only needed if SafeNet Luna registry key exists from a previous install
   $lunaPath = 'HKLM:\SOFTWARE\SafeNet\LunaClient'
   if (Test-Path $lunaPath) {
       Set-ItemProperty -Path $lunaPath -Name 'Interactive' -Value 0
   }
   ```

---

### Step 4: Validate New Root CA Certificate

**Run on:** NEW Root CA server (Cloud HSM)

Verify the self-signed Root CA certificate is correct.

1. Export the new CA certificate:

   ```powershell
   certutil -ca.cert C:\temp\NewRootCA-G2.cer
   ```
2. Inspect the certificate:

   ```powershell
   $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new("C:\temp\NewRootCA-G2.cer")
   Write-Host "Subject:    $($cert.Subject)"
   Write-Host "Issuer:     $($cert.Issuer)"
   Write-Host "Thumbprint: $($cert.Thumbprint)"
   Write-Host "NotBefore:  $($cert.NotBefore)"
   Write-Host "NotAfter:   $($cert.NotAfter)"
   Write-Host "KeySize:    $($cert.PublicKey.Key.KeySize)"
   ```
3. Confirm:

   - Subject and Issuer are identical (self-signed)
   - Subject contains the generational suffix (e.g., `CN=CHSM-RootCA-G2`)
   - Key size matches the requested value
   - Validity period is correct
4. Verify the CSP is Cavium:

   ```powershell
   certutil -getreg CA\CSP
   ```

---

### Step 5: Pre-Distribute New Root CA Certificate

**Run on:** NEW Root CA server or Domain Controller

Distribute the new Root CA certificate to all relying parties **before** decommissioning the old Root CA. This is the critical step that ensures seamless trust.

1. Export the new Root CA certificate (if not already done):

   ```powershell
   certutil -ca.cert C:\temp\NewRootCA-G2.cer
   ```
2. **Active Directory (domain-joined environments):**

   ```powershell
   certutil -dspublish C:\temp\NewRootCA-G2.cer RootCA
   ```
3. **Standalone / non-domain environments:** Manually distribute `NewRootCA-G2.cer` to relying parties and install into the Trusted Root Certification Authorities store:

   ```powershell
   # Run on each relying party or distribute via GPO
   certutil -addstore Root C:\temp\NewRootCA-G2.cer
   ```
4. **Import to OLD Root CA server** (for bidirectional trust validation):

   ```powershell
   # Run on OLD Root CA server
   certutil -addstore Root C:\temp\NewRootCA-G2.cer
   ```
5. **Import OLD root to NEW server** (for trust validation in Step 6):

   ```powershell
   # Run on NEW Root CA server
   certutil -addstore Root C:\temp\OldRootCA.cer
   ```
6. **Allow propagation time.** For AD-published certs, wait for Group Policy replication (default 90 minutes, or force with `gpupdate /force`). For manual distribution, confirm all target systems have been updated.

> **Do not decommission the old Root CA until all relying parties have the new root in their trust stores.**

---

### Step 6: Validate Trust

**Run on:** BOTH servers

Verify bidirectional trust between old and new Root CAs.

1. **On the NEW Root CA server:**

   ```powershell
   # Verify new root is in My store
   certutil -store My "CHSM-RootCA-G2"

   # Verify old root is in Root store
   certutil -store Root "DHSM-RootCA"

   # Verify CRL is published
   Get-ChildItem C:\Windows\System32\CertSrv\CertEnroll\*.crl
   ```
2. **On the OLD Root CA server:**

   ```powershell
   # Verify new root is in Root store
   certutil -store Root "CHSM-RootCA-G2"

   # Verify old root is still active
   certutil -cainfo name
   Get-Service certsvc
   ```
3. Both servers should show the other's Root CA certificate in their Trusted Root store.

---

### Step 7: Cross-Validate

**Run on:** NEW Root CA server (Cloud HSM)

Perform final validation of the new Root CA.

1. Confirm Certificate Services is running and responsive:

   ```powershell
   Get-Service certsvc
   certutil -ping
   ```
2. Verify the key provider is Cavium:

   ```powershell
   certutil -getreg CA\CSP
   ```
3. Check CRL publication:

   ```powershell
   certutil -CRL
   Get-ChildItem C:\Windows\System32\CertSrv\CertEnroll\*.crl
   ```
4. Verify the CA certificate is in the Personal store:

   ```powershell
   certutil -store My "CHSM-RootCA-G2"
   ```

---

### Step 8: Decommission Assessment

**Run on:** OLD Root CA server (Dedicated HSM)

Assess whether the old Root CA is safe to decommission.

1. Check for Issuing CAs that chain to this root:

   ```powershell
   # If this root has signed any subordinate CA certs, they must be migrated first
   certutil -view -restrict "Disposition=20" -out "RequestID,CommonName,NotAfter" | Select-Object -First 30
   ```
2. Check for pending requests:

   ```powershell
   certutil -view -restrict "Disposition=9" -out "RequestID,CommonName,SubmittedWhen"
   ```
3. Verify Certificate Services status:

   ```powershell
   Get-Service certsvc | Select-Object Name, Status, StartType
   ```
4. Review the decommission readiness:

   - If no subordinate CAs chain to this root (or they have been migrated), the CA can be decommissioned.
   - If subordinate CAs exist, keep the root's CRL publishing active until all subordinate CA certificates expire.

> **Do NOT revoke the old Root CA certificate.** Let it expire naturally. Revoking it (or stopping CRL publication) will invalidate all certificates in its chain. Decommission the service, not the trust.

---

## Architecture Diagram

```
     +---------------------------+         +---------------------------+
     |      OLD Root CA          |         |       NEW Root CA         |
     |   (Azure Dedicated HSM)  |         |    (Azure Cloud HSM)      |
     |   CN=DHSM-RootCA          |         |   CN=CHSM-RootCA-G2       |
     |   SafeNet KSP            |         |   Cavium KSP             |
     |                          |         |                           |
     |   Status: Decommission   |         |   Status: Active          |
     |   when certs expire      |         |   Signing new certs       |
     +---------------------------+         +---------------------------+
              |                                     |
              | Trust pre-distributed               | Trust pre-distributed
              | (Step 5: new root added to          | (Step 5: old root added to
              |  OLD server's Root store)           |  NEW server's Root store)
              v                                     v
     +-----------------------------------------------------+
     |              Relying Parties                         |
     |  Both roots trusted during transition window.        |
     |  New certs issued by G2. Old certs remain valid      |
     |  until they expire.                                  |
     +-----------------------------------------------------+

Migration Flow:
  1. Capture old Root CA details (OLD)
  2. Validate new server (NEW)
  3. Build new self-signed Root CA with Cloud HSM key (NEW)
  4. Validate new Root CA certificate (NEW)
  5. Pre-distribute new root cert to relying parties + bidirectional trust
  6. Validate trust on both servers (OLD + NEW)
  7. Cross-validate new Root CA (NEW)
  8. Decommission assessment (OLD)
```
