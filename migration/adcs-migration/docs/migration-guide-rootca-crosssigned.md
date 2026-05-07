# Azure Cloud HSM ADCS Migration: Root CA (Cross-Signed)

## Overview

This guide provides manual step-by-step instructions for migrating an Active Directory Certificate Services (AD CS) standalone Root CA from Azure Dedicated HSM (SafeNet/Thales Luna) to Azure Cloud HSM (Cavium). The migration uses the **cross-signing** method: the OLD Root CA cross-signs the NEW Root CA's certificate, creating a trust bridge so that relying parties who trust the old root automatically trust the new root without requiring pre-distribution.

This scenario involves two server roles:

| Role                  | Description                                                             |
| --------------------- | ----------------------------------------------------------------------- |
| **OLD Root CA** | The existing standalone Root CA running on Azure Dedicated HSM (source) |
| **NEW Root CA** | A clean Windows Server with Azure Cloud HSM SDK installed (target)      |

## Recommendation

For production migrations, we recommend using the **Migration Orchestrator** (`Invoke-CaMigration.ps1`) to automate this process end-to-end. The orchestrator handles all inter-server certificate transfers, cross-signing operations, trust store imports, timing, and PASS/FAIL reporting with zero interaction. The manual steps below are provided for environments where automation is not permitted or for operators who need to understand each step independently.

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
- [ ] **Generational suffix** chosen for the new CA name (e.g., `CHSM-RootCA-G2`) to prevent same-CN chain collision

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
6. Save the output and the exported certificate file.

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

Create the new standalone Root CA with the private key stored in the Cloud HSM. The Root CA self-signs its own certificate.

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
4. Export the new CA's self-signed certificate (needed for Step 4):

   ```powershell
   certutil -ca.cert C:\temp\NewRootCA-G2.cer
   ```

---

### Transfer: New Root CA Certificate to OLD Server

**Transfer** the file `NewRootCA-G2.cer` from the NEW server to the OLD server (e.g., `C:\temp\migration-certs\NewRootCA-G2.cer`). This certificate will be cross-signed by the OLD Root CA in Step 4.

---

### Step 4: Cross-Sign the New Root CA

**Run on:** OLD Root CA server (Dedicated HSM)

The OLD Root CA cross-signs the NEW Root CA's self-signed certificate. This creates a trust bridge: any relying party that trusts the old root automatically trusts the new root via the cross-certificate chain.

1. Ensure Certificate Services is running:

   ```powershell
   Start-Service certsvc
   certutil -ping
   ```
2. Submit the new Root CA's certificate as a signing request. The OLD CA's COM interface treats it like a subordinate CA request:

   ```powershell
   $OldCAConfig = "<OLD-CA-HOSTNAME>\<OLD-CA-NAME>"
   $NewCACertPath = "C:\temp\migration-certs\NewRootCA-G2.cer"

   $CertRequest = New-Object -ComObject CertificateAuthority.Request
   $certContent = Get-Content $NewCACertPath -Raw
   $disposition = $CertRequest.Submit(0x0, $certContent, "CommonName:CHSM-RootCA-G2", $OldCAConfig)
   $requestId = $CertRequest.GetRequestId()
   Write-Host "RequestId=$requestId, Disposition=$disposition"
   ```
3. If the disposition is 5 (Pending), approve and retrieve:

   ```powershell
   certutil -resubmit $requestId
   certreq -retrieve -f -config $OldCAConfig $requestId "C:\temp\migration-certs\CrossCert.cer"
   ```
4. If the disposition is 3 (Issued), the certificate is returned directly:

   ```powershell
   $certPem = $CertRequest.GetCertificate(0x0)
   Set-Content "C:\temp\migration-certs\CrossCert.cer" $certPem -Encoding ASCII
   ```
5. Verify the cross-certificate:

   ```powershell
   $cross = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new("C:\temp\migration-certs\CrossCert.cer")
   Write-Host "Subject: $($cross.Subject)"   # Should be CN=CHSM-RootCA-G2
   Write-Host "Issuer:  $($cross.Issuer)"    # Should be CN=DHSM-RootCA (the OLD CA)
   ```

   Confirm: Subject = NEW Root CA name, Issuer = OLD Root CA name.

---

### Transfer: Cross-Certificate and Old Root to NEW Server

**Transfer** the following files from the OLD server to the NEW server:

- `CrossCert.cer` (the cross-signed certificate from Step 4)
- `OldRootCA.cer` (the OLD Root CA's certificate from Step 1)

Place them in `C:\temp\migration-certs\` on the NEW server.

---

### Step 5: Publish Cross-Certificate

**Run on:** NEW Root CA server (Cloud HSM)

Install the cross-certificate and old root cert to complete the trust bridge.

1. Install the OLD Root CA cert into the Trusted Root store:

   ```powershell
   certutil -addstore Root "C:\temp\migration-certs\OldRootCA.cer"
   ```
2. Install the cross-certificate into the Intermediate CA store:

   ```powershell
   certutil -addstore CA "C:\temp\migration-certs\CrossCert.cer"
   ```
3. Publish the cross-certificate to the CA's AIA location:

   ```powershell
   # Add cross-cert to AIA store for chain building
   certutil -addstore CA "C:\temp\migration-certs\CrossCert.cer"
   ```
4. Verify chain building works (the new Root CA cert should chain to the old root via the cross-cert):

   ```powershell
   certutil -verify "C:\temp\migration-certs\CrossCert.cer"
   ```
5. Verify Certificate Services is running:

   ```powershell
   Get-Service certsvc
   certutil -ping
   ```

---

### Step 6: Validate Cross-Signed Root CA

**Run on:** NEW Root CA server (Cloud HSM)

Comprehensive validation of the cross-signed trust chain.

1. Verify the new Root CA cert is in the Personal store:

   ```powershell
   certutil -store My "CHSM-RootCA-G2"
   ```
2. Verify the cross-cert is in the Intermediate CA store:

   ```powershell
   certutil -store CA
   ```
3. Verify the old root is in the Trusted Root store:

   ```powershell
   certutil -store Root "DHSM-RootCA"
   ```
4. Verify CRL publication:

   ```powershell
   certutil -CRL
   Get-ChildItem C:\Windows\System32\CertSrv\CertEnroll\*.crl
   ```
5. Verify the Cavium KSP is in use:

   ```powershell
   certutil -getreg CA\CSP
   ```

---

### Step 7: Cross-Validate

**Run on:** BOTH servers

Final cross-validation between old and new Root CAs.

1. **On the NEW Root CA server:**

   ```powershell
   # Verify CA is responsive
   certutil -ping

   # Verify chain building
   certutil -ca.cert C:\temp\verify-newroot.cer
   certutil -verify C:\temp\verify-newroot.cer
   ```
2. **On the OLD Root CA server:**

   ```powershell
   # Verify the old CA is still operational
   certutil -cainfo name
   Get-Service certsvc
   ```

---

### Step 8: Decommission Assessment

**Run on:** OLD Root CA server (Dedicated HSM)

Assess whether the old Root CA is safe to decommission.

1. Check for Issuing CAs that chain to this root:

   ```powershell
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
   - Relying parties with the cross-certificate can chain to the NEW root without any further action.

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
     |   when certs expire      |         |   Self-signed + cross-cert|
     +---------------------------+         +---------------------------+
              |                                     |
              |               Cross-cert            |
              | (Step 4)  +-----------------+       |
              +---------->| Cross-Certificate|<-----+
              |  Signs    | Subject: G2      |  Published
              |           | Issuer: OldRoot  |  (Step 5)
              |           +-----------------+
              |                   |
              v                   v
     +-----------------------------------------------------+
     |              Relying Parties                         |
     |  Chain path 1: Leaf -> G2 (direct, if G2 trusted)   |
     |  Chain path 2: Leaf -> G2 -> CrossCert -> OldRoot    |
     |            (automatic, no pre-distribution needed)   |
     +-----------------------------------------------------+

Migration Flow:
  1. Capture old Root CA details (OLD)
  2. Validate new server (NEW)
  3. Build new self-signed Root CA with Cloud HSM key (NEW)
     Transfer: NEW Root CA cert -> OLD server
  4. Cross-sign: OLD Root CA signs NEW Root CA's cert (OLD)
     Transfer: Cross-cert + OLD Root cert -> NEW server
  5. Publish cross-cert on NEW server (NEW)
  6. Validate cross-signed Root CA (NEW)
  7. Cross-validate (BOTH)
  8. Decommission assessment (OLD)
```
