# ADCS Manual Validation -- Both HSM Platforms

Use these steps to manually validate that your HSM-backed Root CA is issuing certificates correctly. The automated version of this is [`ADCS-Sanity-Check.ps1`](ADCS-Sanity-Check.ps1).

---

## Prerequisites

| Check | Command | Expected |
|-------|---------|----------|
| CertSvc running | `Get-Service certsvc` | Status: Running |
| HSM key pair intact | `certutil -verifykeys` | `CertUtil: -verifykeys command completed successfully.` |
| KSP accessible | `certutil -csp "<ProviderName>" -key` | Lists key containers |

**Provider names:**
- **Cloud HSM:** `Cavium Key Storage Provider`
- **Dedicated HSM:** `SafeNet Key Storage Provider`

---

## Step 1 -- Create a Request INF

Create a file `C:\temp\test-request.inf` with the content below.

### Cloud HSM (Cavium KSP)

```ini
[Version]
Signature="$Windows NT$"

[NewRequest]
Subject = "CN=Manual-Sanity-Test, OU=ADCS-Test, O=HSM-Scenario-Builder"
KeySpec = 2
KeyLength = 2048
ProviderName = "Cavium Key Storage Provider"
ProviderType = 32
RequestType = PKCS10
HashAlgorithm = SHA256
```

### Dedicated HSM (SafeNet KSP)

```ini
[Version]
Signature="$Windows NT$"

[NewRequest]
Subject = "CN=Manual-Sanity-Test, OU=ADCS-Test, O=HSM-Scenario-Builder"
KeySpec = 2
KeyLength = 2048
ProviderName = "SafeNet Key Storage Provider"
ProviderType = 0
RequestType = PKCS10
HashAlgorithm = SHA256
```

> **Note:** SafeNet KSP is a CNG provider; `ProviderType = 0` is standard for CNG. If `certreq -new` fails with `ProviderType = 0`, try omitting the `ProviderType` line entirely -- CNG providers may not require it.

---

## Step 2 -- Generate the CSR

```powershell
certreq -new C:\temp\test-request.inf C:\temp\test-request.req
```

Expected: `CertReq: Request Created`

---

## Step 3 -- Verify the CSR

```powershell
certutil -dump C:\temp\test-request.req
```

Confirm:
- **Subject** shows `CN=Manual-Sanity-Test`
- **Provider** shows the correct KSP name for your platform

---

## Step 4 -- Submit the CSR to the CA

### Option A: certreq (recommended for automation)

```powershell
certreq -submit -config "SERVERNAME\CANAME" C:\temp\test-request.req C:\temp\test-cert.cer
```

Replace `SERVERNAME\CANAME` with your CA configuration string. To find it:

```powershell
certutil -getreg CA\CommonName
```

Then use `COMPUTERNAME\<CommonName>`.

If the CA is a **standalone root** (the default in this project), the request may be auto-approved and the cert will be saved directly. If it goes pending, note the **RequestId** and continue to Step 5.

### Option B: MMC (manual GUI)

1. Open `certsrv.msc`
2. Right-click the CA → **All Tasks** → **Submit new request...**
3. Browse to `C:\temp\test-request.req`
4. If pending: expand **Pending Requests**, right-click the request → **All Tasks** → **Issue**
5. Expand **Issued Certificates**, double-click the cert → **Details** → **Copy to File...**
6. Save as `C:\temp\test-cert.cer` (DER or Base64)

---

## Step 5 -- Approve a Pending Request (if needed)

If Step 4 showed `Certificate request is pending: Taken Under Submission` with a **RequestId**:

```powershell
certutil -resubmit <RequestId>
```

Then retrieve:

```powershell
certreq -retrieve -config "SERVERNAME\CANAME" <RequestId> C:\temp\test-cert.cer
```

---

## Step 6 -- Verify the Issued Certificate

```powershell
certutil -dump C:\temp\test-cert.cer
```

Confirm:
- **Subject:** `CN=Manual-Sanity-Test`
- **Issuer:** Your Root CA common name (e.g., `CN=HSB-RootCA`)
- **Signature Algorithm:** `sha256RSA` (or your configured algorithm)
- **Public Key Length:** `2048 bits`
- **NotBefore / NotAfter:** Valid date range

---

## Step 7 -- Verify HSM Key Handles (Platform-Specific)

### Cloud HSM -- Cavium SDK

```powershell
# List all keys on the HSM
& "C:\Program Files\Cavium\Tools\findKey.exe"
```

You should see the key handle for your CA key plus the new test key. Note: the test key from `certreq -new` also lives on the HSM.

### Dedicated HSM -- SafeNet LunaCM

From the Windows ADCS VM (not the Admin VM):

```powershell
& "C:\Program Files\SafeNet\LunaClient\LunaCM.exe"
```

Inside LunaCM:

```
lunacm:> slot set -slot 0
lunacm:> role login -name co
lunacm:> partition contents
```

> You must log in as Crypto Officer (CO) to see key objects. The partition only shows public-session objects otherwise. CO is the operating role for ADCS -- CU is not required.

You should see the CA's RSA key object plus the test key.

---

## Step 8 -- Cleanup

Remove the test certificate from the user's personal store (certreq adds it there):

```powershell
Get-ChildItem Cert:\CurrentUser\My |
    Where-Object { $_.Subject -match "Manual-Sanity-Test" } |
    Remove-Item
```

Delete the test files:

```powershell
Remove-Item C:\temp\test-request.inf, C:\temp\test-request.req, C:\temp\test-cert.cer -ErrorAction SilentlyContinue
```

---

## Expected Results Summary

| Check | Expected |
|-------|----------|
| CSR generated | `CertReq: Request Created` |
| CSR dump shows HSM provider | Provider = `Cavium Key Storage Provider` or `SafeNet Key Storage Provider` |
| Cert issued | RequestId returned, cert saved |
| Cert issuer | `CN=<Your-CA-CommonName>` |
| Signature algorithm | `sha256RSA` |
| Key length | 2048 bits |

If all checks pass, your HSM-backed ADCS Root CA is fully operational and issuing certificates correctly.
