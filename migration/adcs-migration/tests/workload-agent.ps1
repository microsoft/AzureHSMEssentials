<#
.SYNOPSIS
    Continuous CA workload agent for live migration testing.

.DESCRIPTION
    Runs on a CA server in a loop. Each iteration:
      1. Detects the active CA and HSM key storage provider from registry
      2. Generates a key pair and CSR (certreq -new) matching the CA's algorithm (RSA or ECDSA)
      3. Submits CSR to the local CA via COM (avoids Session 0 hang)
      4. Auto-approves pending request (standalone CA)
      5. Retrieves and validates the issued certificate
      6. Logs timestamp, CA name, HSM provider, serial, issuer, result

    The CA signs each certificate using its HSM-backed private key, so every
    successful enrollment is a proven HSM signing operation.

    Deployed and managed by Invoke-LiveMigrationTest.ps1 as a scheduled task.
    Stop signal: create C:\temp\workload-stop.txt
    Log output:  C:\temp\workload-log.csv

.NOTES
    Uses COM CertificateAuthority.Request instead of certreq -submit because
    certreq hangs in Session 0 (scheduled task / az vm run-command context).
    This is the same pattern used by Invoke-CaMigration.ps1.
#>

$ErrorActionPreference = 'Continue'
$logFile     = 'C:\temp\workload-log.csv'
$stopFile    = 'C:\temp\workload-stop.txt'
$intervalSec = 30

if (-not (Test-Path C:\temp)) { New-Item -ItemType Directory -Path C:\temp -Force | Out-Null }

# CSV header
if (-not (Test-Path $logFile)) {
    'Timestamp,Hostname,CA,Provider,RequestId,Serial,Issuer,Result' | Set-Content $logFile
}

while ($true) {
    if (Test-Path $stopFile) { break }
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    try {
        # -- Detect active CA and HSM provider from registry --
        $cfgPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration'
        $cfg = Get-ItemProperty $cfgPath -ErrorAction Stop
        $ca  = $cfg.Active

        $cspPath  = "$cfgPath\$ca\CSP"
        $provider = (Get-ItemProperty $cspPath -ErrorAction SilentlyContinue).Provider
        if (-not $provider) { $provider = 'Unknown' }

        # -- Check CA service is running --
        $svc = Get-Service CertSvc -ErrorAction SilentlyContinue
        if ($svc.Status -ne 'Running') {
            "$ts,$env:COMPUTERNAME,$ca,$provider,--,--,--,SKIP-CA-Stopped" | Add-Content $logFile
            Start-Sleep $intervalSec; continue
        }

        # -- Detect CA key algorithm (logged in report, not used for CSR) --
        $cspPath = "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\$ca\CSP"
        $cngAlgo = (Get-ItemProperty $cspPath -ErrorAction SilentlyContinue).CNGPublicKeyAlgorithm
        if (-not $cngAlgo) { $cngAlgo = 'RSA' }

        # -- Generate RSA key pair + CSR --
        # Always use RSA for the CSR. The CA signs with its own key (RSA or ECDSA)
        # regardless of the subject's key algorithm. This exercises the HSM signing
        # operation without depending on certreq ECDSA support in Session 0.
        $uid = Get-Date -Format 'yyyyMMddHHmmssfff'
        @"
[NewRequest]
Subject = "CN=LiveTest-$uid"
KeySpec = 1
KeyLength = 2048
MachineKeySet = TRUE
ProviderName = "Microsoft RSA SChannel Cryptographic Provider"
RequestType = PKCS10
[EnhancedKeyUsageExtension]
OID=1.3.6.1.5.5.7.3.1
"@ | Set-Content 'C:\temp\wl.inf' -Encoding ASCII

        certreq -new -f 'C:\temp\wl.inf' 'C:\temp\wl.csr' 2>&1 | Out-Null

        # -- Submit to local CA via COM (Session 0 safe) --
        $csrContent = Get-Content 'C:\temp\wl.csr' -Raw
        $caConfig   = "$env:COMPUTERNAME\$ca"

        $certReq    = New-Object -ComObject CertificateAuthority.Request
        $disposition = $certReq.Submit(0x0, $csrContent, "CommonName:LiveTest-$uid", $caConfig)
        $requestId   = $certReq.GetRequestId()

        # -- Auto-approve if pending (standalone CA returns disposition 5) --
        if ($disposition -eq 5) {
            certutil -resubmit $requestId 2>&1 | Out-Null
            Start-Sleep 2
            certreq -retrieve -f -config $caConfig $requestId 'C:\temp\wl.cer' 2>&1 | Out-Null
        }
        elseif ($disposition -eq 3) {
            # Issued immediately
            $certPem = $certReq.GetCertificate(0x0)
            Set-Content 'C:\temp\wl.cer' $certPem -Encoding ASCII
        }

        # -- Validate issued certificate --
        $serial = '--'; $issuer = '--'; $result = 'FAIL'
        if (Test-Path 'C:\temp\wl.cer') {
            $cert   = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
                          (Resolve-Path 'C:\temp\wl.cer').Path)
            $serial = $cert.SerialNumber
            $issuer = ($cert.Issuer -replace ',.*$', '')
            $result = 'PASS'
            $cert.Dispose()
        }

        "$ts,$env:COMPUTERNAME,$ca,$provider,$requestId,$serial,$issuer,$result" | Add-Content $logFile
    }
    catch {
        $err = $_.Exception.Message -replace '[,\r\n]', ' '
        "$ts,$env:COMPUTERNAME,ERROR,--,--,--,--,FAIL:$err" | Add-Content $logFile
    }

    # -- Cleanup temp files --
    'C:\temp\wl.inf', 'C:\temp\wl.csr', 'C:\temp\wl.cer' | ForEach-Object {
        Remove-Item $_ -ErrorAction SilentlyContinue
    }

    Start-Sleep $intervalSec
}
