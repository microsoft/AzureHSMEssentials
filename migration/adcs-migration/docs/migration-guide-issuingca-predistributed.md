# Azure Cloud HSM ADCS Migration: Issuing CA (Chain Pre-Distributed)

## Overview

This guide provides manual step-by-step instructions for migrating an Active Directory Certificate Services (AD CS) Intermediate/Issuing CA from Azure Dedicated HSM (SafeNet/Thales Luna) to Azure Cloud HSM (Cavium). The migration uses the **chain pre-distribution** method: the new Issuing CA certificate is distributed to relying parties before cutover, ensuring seamless trust continuity.

This scenario involves three server roles:

| Role                | Description                                                                              |
| ------------------- | ---------------------------------------------------------------------------------------- |
| **OLD CA**    | The existing Issuing CA running on Azure Dedicated HSM (source)                          |
| **NEW CA**    | A clean Windows Server with Azure Cloud HSM SDK installed (target)                       |
| **Parent CA** | The Root CA that signs the new Issuing CA certificate (may be the same server as OLD CA) |

## Recommendation

For production migrations, we recommend using the **Migration Orchestrator** (`Invoke-CaMigration.ps1`) to automate this process end-to-end. The orchestrator handles all inter-server certificate transfers, wrapper generation, CRL pre-caching, and PASS/FAIL reporting with zero interaction (except Step 6 which requires RDP due to a Cloud HSM constraint). The manual steps below are provided for environments where automation is not permitted or for operators who need to understand each step independently.

## Prerequisites

Before beginning the migration, confirm the following:

- [ ] **OLD CA server** is running and Certificate Services (`certsvc`) is operational
- [ ] **NEW CA server** is provisioned with Windows Server 2019 or later
- [ ] **Azure Cloud HSM SDK** is installed on the NEW CA server
- [ ] **Cavium Key Storage Provider** is enumerated (verify with `certutil -csplist`)
- [ ] **Cloud HSM credentials** are configured (`azcloudhsm_username` / `azcloudhsm_password` environment variables set at system level, VM rebooted after setting)
- [ ] **ADCS role** is installed on the NEW CA server (`Install-WindowsFeature ADCS-Cert-Authority`)
- [ ] **Parent Root CA** is accessible and `certsvc` is running
- [ ] **Network connectivity** from the NEW CA server to the Cloud HSM cluster is confirmed
- [ ] **File transfer method** is established between servers (e.g., `az vm run-command`, shared storage, USB)
- [ ] **Backup** of the OLD CA configuration and database has been taken

## Migration Steps

### Step 1: Capture Existing CA Details

**Run on:** OLD CA server (Dedicated HSM)

Export the current Issuing CA certificate details to establish the baseline for the new CA configuration.

1. Open an elevated PowerShell prompt on the OLD CA server.
2. Identify the active CA name:

   ```powershell
   certutil -cainfo name
   ```
3. Export the CA certificate:

   ```powershell
   certutil -ca.cert C:\temp\OldIssuingCA.cer
   ```
4. Record the CA configuration details:

   ```powershell
   certutil -getreg CA\CSP
   certutil -getreg CA\HashAlgorithm
   certutil -getreg CA\CRLFlags
   ```
5. Capture the certificate properties (subject, key length, extensions, validity):

   ```powershell
   certutil -dump C:\temp\OldIssuingCA.cer
   ```
6. Save the output and the exported certificate file. These will be referenced during CSR generation on the NEW CA server.

**What to transfer to Step 3:** The old CA's Common Name, key length, hash algorithm, and the exported CA certificate file (`OldIssuingCA.cer`).

---

### Step 2: Validate New CA Server

**Run on:** NEW CA server (Cloud HSM)

Verify the NEW CA server is ready for Cloud HSM-backed CA installation.

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

### Step 3: Generate CSR on New CA Server

**Run on:** NEW CA server (Cloud HSM)

Configure the subordinate CA role and generate a Certificate Signing Request with the private key stored in the Cloud HSM.

1. Copy the old CA certificate (`OldIssuingCA.cer`) from Step 1 to the NEW CA server (e.g., `C:\temp\OldIssuingCA.cer`).
2. Install the ADCS CA role with **RSA** and a CSR output. Replace the values below with your environment:

   ```powershell
   Install-AdcsCertificationAuthority `
       -CAType StandaloneSubordinateCA `
       -CACommonName "CHSM-IssuingCA" `
       -KeyLength 2048 `
       -HashAlgorithmName SHA256 `
       -CryptoProviderName "RSA#Cavium Key Storage Provider" `
       -OutputCertRequestFile "C:\temp\NewCA.req" `
       -OverwriteExistingKey `
       -Force
   ```

   This generates the RSA key pair inside the Cloud HSM and produces a CSR file.

   > **Note:** The example uses RSA 2048. For RSA 3072, set `-KeyLength 3072`. For RSA 4096, set `-KeyLength 4096`.

2b. **Alternatively**, install the ADCS CA role with **ECDSA** (use this if the existing CA uses ECDSA):

```powershell
   Install-AdcsCertificationAuthority `
       -CAType StandaloneSubordinateCA `
       -CACommonName "CHSM-IssuingCA" `
       -KeyLength 256 `
       -HashAlgorithmName SHA256 `
       -CryptoProviderName "ECDSA_P256#Cavium Key Storage Provider" `
       -OutputCertRequestFile "C:\temp\NewCA.req" `
       -OverwriteExistingKey `
       -Force
```

   This generates the ECDSA P256 key pair inside the Cloud HSM and produces a CSR file.

> **Note:** For ECDSA P384 use `-KeyLength 384` and `"ECDSA_P384#Cavium Key Storage Provider"`. For P521 use `-KeyLength 521` and `"ECDSA_P521#Cavium Key Storage Provider"`.

3. Verify the CSR was created:
   ```powershell
   certutil -dump C:\temp\NewCA.req
   ```

   Confirm the CSR contains the correct subject name and key length.

**What to transfer to Step 3.5:** The CSR file (`NewCA.req`) to the Parent Root CA server.

---

### Step 3.5: Submit CSR to Parent Root CA

**Run on:** Parent Root CA server

Submit the CSR from the NEW CA to the Root CA for signing.

1. Copy the CSR file (`NewCA.req`) to the Parent Root CA server (e.g., `C:\temp\NewCA.req`).
2. Submit the CSR to the Root CA:

   ```powershell
   certreq -submit -config "YOURSERVER\YourRootCAName" C:\temp\NewCA.req C:\temp\NewCA-signed.cer
   ```

   For a Standalone Root CA, the request will be marked **Pending**.
3. If the request is pending, approve it:

   ```powershell
   # Replace <RequestId> with the number returned by certreq -submit
   certutil -resubmit <RequestId>
   ```
4. Retrieve the signed certificate:

   ```powershell
   certreq -retrieve -config "YOURSERVER\YourRootCAName" <RequestId> C:\temp\NewCA-signed.cer
   ```
5. Verify the signed certificate:

   ```powershell
   certutil -dump C:\temp\NewCA-signed.cer
   ```

   Confirm the subject matches the CSR and the issuer is the Root CA.

**What to transfer to Step 4:** The signed Issuing CA certificate (`NewCA-signed.cer`) back to the NEW CA server.

---

### Step 4: Validate Signed Certificate

**Run on:** NEW CA server (Cloud HSM)

Validate the signed Issuing CA certificate before installation.

1. Copy the signed certificate (`NewCA-signed.cer`) to the NEW CA server (e.g., `C:\temp\NewCA-signed.cer`).
2. Verify the certificate chain:

   ```powershell
   certutil -verify C:\temp\NewCA-signed.cer
   ```
3. Confirm the certificate properties:

   ```powershell
   $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new("C:\temp\NewCA-signed.cer")
   Write-Host "Subject:  $($cert.Subject)"
   Write-Host "Issuer:   $($cert.Issuer)"
   Write-Host "Serial:   $($cert.SerialNumber)"
   Write-Host "NotBefore: $($cert.NotBefore)"
   Write-Host "NotAfter:  $($cert.NotAfter)"
   Write-Host "KeySize:  $($cert.PublicKey.Key.KeySize)"
   ```
4. Verify the issuer matches the Root CA and the subject matches your new CA name.

---

### Step 5: Pre-Distribute New CA Certificate

**Run on:** NEW CA server or Domain Controller

Distribute the new Issuing CA certificate to relying parties **before** activating the new CA. This is the critical step that ensures seamless trust.

1. **Active Directory (domain-joined environments):**

   ```powershell
   certutil -dspublish C:\temp\NewCA-signed.cer SubCA
   ```

   This publishes the new ICA cert to AD so that domain-joined machines will auto-trust it.
2. **Standalone / non-domain environments:** Manually distribute `NewCA-signed.cer` to relying parties and install it into their Intermediate Certification Authorities trust store:

   ```powershell
   # Run on each relying party or distribute via GPO
   certutil -addstore CA C:\temp\NewCA-signed.cer
   ```
3. **Verification:** On a relying party, confirm the new ICA cert is trusted:

   ```powershell
   certutil -store CA "CHSM-IssuingCA"
   ```
4. **Allow propagation time.** For AD-published certs, wait for Group Policy replication (default 90 minutes, or force with `gpupdate /force` on clients). For manual distribution, confirm all target systems have been updated.

> **Do not proceed to Step 6 until pre-distribution is complete.** Activating the new CA before relying parties trust it will cause certificate validation failures.

---

### Step 6: Activate New CA

**Run on:** NEW CA server (Cloud HSM) -- **Requires interactive RDP session**

> **Important:** The Cavium Key Storage Provider requires an interactive Windows logon session for `certutil -installcert`. This command will hang or fail if run via `az vm run-command`, scheduled tasks, or any non-interactive method. You must RDP into the server.

1. RDP into the NEW CA server.
2. Open an elevated PowerShell prompt.
3. Pre-cache the Root CA CRL locally (required if the CRL Distribution Point is on a network-isolated server):

   ```powershell
   # Import the Root CA cert to the trust store (if not already present)
   certutil -addstore Root C:\temp\RootCA.cer

   # Copy the Root CA CRL to a local path and set up a localhost redirect
   # so file:// CRL DPs resolve locally instead of across the network
   mkdir C:\CertEnroll -Force
   copy C:\temp\RootCA.crl C:\CertEnroll\
   New-SmbShare -Name CertEnroll -Path C:\CertEnroll -ReadAccess Everyone

   # Add hosts file redirect for the Root CA server hostname
   Add-Content C:\Windows\System32\drivers\etc\hosts "127.0.0.1 OLD-CA-HOSTNAME"
   ```
4. Install the signed certificate:

   ```powershell
   certutil -f -installcert "C:\temp\NewCA-signed.cer"
   ```

   If a revocation check warning dialog appears, click OK to proceed.
5. Set CRL flags to ignore offline revocation (standalone/isolated environments):

   ```powershell
   certutil -setreg CA\CRLFlags +CRLF_REVCHECK_IGNORE_OFFLINE
   ```
6. Start Certificate Services:

   ```powershell
   net start certsvc
   ```
7. Verify the CA is operational:

   ```powershell
   certutil -cainfo name
   ```

   Should return the new CA name (e.g., `CHSM-IssuingCA`).
8. Publish an initial CRL:

   ```powershell
   certutil -CRL
   ```

---

### Step 7: Validate Cutover

**Run on:** NEW CA server (Cloud HSM)

Verify the new CA is fully operational.

1. Confirm Certificate Services is running:

   ```powershell
   Get-Service certsvc
   ```
2. Verify the active CA configuration:

   ```powershell
   (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active).Active
   ```
3. Verify the key provider is Cavium:

   ```powershell
   certutil -getreg CA\CSP
   ```

   Should include `Cavium Key Storage Provider`.
4. Check CRL was published:

   ```powershell
   Get-ChildItem C:\Windows\System32\CertSrv\CertEnroll\*.crl
   ```
5. Verify the CA certificate is in the Personal store:

   ```powershell
   certutil -store My "CHSM-IssuingCA"
   ```
6. **Test certificate issuance** (confirms the Cloud HSM key is operational):

   ```powershell
   # Generate a test CSR
   @("[NewRequest]",'Subject = "CN=Migration-Validation-Test"',"KeyLength = 2048","RequestType = PKCS10") |
       Out-File C:\temp\test.inf -Encoding ASCII
   certreq -new C:\temp\test.inf C:\temp\test.req
   certreq -submit C:\temp\test.req C:\temp\test.cer

   # Approve if pending (standalone CA)
   certutil -resubmit <RequestId>
   certreq -retrieve <RequestId> C:\temp\test.cer
   ```

   A successfully issued certificate confirms the new CA is signing with the Cloud HSM key.

---

### Step 8: Decommission Assessment

**Run on:** OLD CA server (Dedicated HSM)

Assess whether the old CA is safe to decommission.

1. Check for remaining valid (non-expired) certificates:

   ```powershell
   certutil -view -restrict "NotAfter>now,Disposition=20" -out "RequestID,CommonName,NotAfter" | Select-Object -First 30
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

   - If no valid certificates remain and no pending requests exist, the CA can be decommissioned.
   - If valid certificates exist, keep the CA running (or at minimum, keep its CRL publishing) until all issued certificates expire.

> **Do NOT revoke the old Issuing CA certificate.** Let it expire naturally. Revoking it will invalidate all certificates it ever issued. Decommission the service, not the trust.

---

## Architecture Diagram

```
                  +---------------------------+
                  |      Parent Root CA       |
                  |   (Azure Dedicated HSM)   |
                  |   CN=DHSM-RootCA           |
                  |   SafeNet KSP             |
                  +------+----------+---------+
                         |          |
              Signed     |          |     Signs new
              (existing) |          |     ICA cert
                         |          |
          +--------------v--+    +--v-----------------+
          |  OLD Issuing CA |    |   NEW Issuing CA   |
          |  (Dedicated HSM)|    |   (Cloud HSM)      |
          |  CN=Old-ICA     |    |   CN=CHSM-ICA      |
          |  SafeNet KSP    |    |   Cavium KSP       |
          |                 |    |                     |
          |  Decommission   |    |   Active            |
          |  when certs     |    |   Issuing new certs |
          |  expire         |    |                     |
          +-----------------+    +---------------------+

Migration Flow:
  1. Capture old CA details (OLD)
  2. Validate new server (NEW)
  3. Generate CSR with Cloud HSM key (NEW)
  3.5 Submit CSR to Root CA (PARENT) --> signed cert returned
  4. Validate signed cert (NEW)
  5. Pre-distribute new ICA cert to relying parties
  6. Install cert + activate CA (NEW, requires RDP)
  7. Validate cutover (NEW)
  8. Decommission assessment (OLD)
```
