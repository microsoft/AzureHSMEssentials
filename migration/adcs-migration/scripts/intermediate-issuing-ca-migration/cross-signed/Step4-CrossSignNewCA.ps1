<#
.SYNOPSIS
    Step 4: Cross-sign the new Issuing CA's certificate using the OLD Issuing CA.

.DESCRIPTION
    Takes the new Issuing CA's root-signed certificate (after Root CA signed
    the CSR from Step 3) and creates a cross-certificate signed by the OLD
    Issuing CA's private key.

    The cross-certificate has:
      Subject = CN=<NewICA>  (same as the new ICA's root-signed cert)
      Issuer  = CN=<OldICA>  (the old Issuing CA)
      Public Key = same as the new ICA's root-signed cert

    This bridges trust: clients that trust the OLD ICA chain automatically
    trust the NEW ICA via the cross-cert:
      Leaf -> New ICA (root-signed, direct chain to Root) OR
      Leaf -> New ICA (cross-cert, Issuer=OldICA) -> Old ICA -> Root

    The cross-signing uses .NET CNG with ASN.1/DER construction,
    which works reliably in headless Session 0 environments.
    Supports both RSA and ECDSA key algorithms.

    RUN ON: OLD ADCS Server (current Issuing CA)

.PARAMETER NewCACertPath
    Path to the new Issuing CA's root-signed certificate (.cer) from Step 3
    (after the Root CA signed the CSR).

.PARAMETER ValidityYears
    Validity period for the cross-signed certificate. Defaults to 10.

.PARAMETER OutputDir
    Directory to save the cross-signed certificate. Defaults to a timestamped subfolder.

.EXAMPLE
    .\Step4-CrossSignNewCA.ps1 -NewCACertPath "C:\temp\NewIssuingCA-Signed.cer"

.EXAMPLE
    .\Step4-CrossSignNewCA.ps1 -NewCACertPath "C:\temp\NewIssuingCA-Signed.cer" -ValidityYears 15
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$NewCACertPath,

    [Parameter(Mandatory = $false)]
    [int]$ValidityYears = 10,

    [Parameter(Mandatory = $false)]
    [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Banner ------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ICA Migration (Cross-Signed) - Step 4: Cross-Sign" -ForegroundColor Cyan
Write-Host "  Run on: OLD ADCS Server (current Issuing CA)" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# -- Output directory ---------------------------------------------------------
if (-not $OutputDir) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputDir = Join-Path $env:USERPROFILE "ica-crosssign-step4-$timestamp"
}
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}
Write-Host "[INFO] Output directory: $OutputDir" -ForegroundColor Gray

# -- 1: Verify OLD ICA is active and running ----------------------------------
Write-Host ""
Write-Host "[1/5] Verifying OLD Issuing CA is active..." -ForegroundColor White

try { $activeCA = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -EA Stop).Active } catch { $activeCA = $null }
if (-not $activeCA) {
    Write-Host "[ERROR] No active CA found on this server." -ForegroundColor Red
    Write-Host "        Step 4 must run on the OLD Issuing CA server." -ForegroundColor Red
    exit 1
}

$caConfig = "$env:COMPUTERNAME\$activeCA"
Write-Host "       Active CA:  $activeCA" -ForegroundColor Green
Write-Host "       CA Config:  $caConfig" -ForegroundColor Gray

try {
    $svc = Get-Service -Name certsvc -ErrorAction Stop
    if ($svc.Status -ne 'Running') {
        Write-Host "       certsvc is $($svc.Status). Starting..." -ForegroundColor Yellow
        Start-Service certsvc -ErrorAction Stop
        $retries = 0
        do {
            Start-Sleep -Seconds 2
            $svc = Get-Service -Name certsvc -ErrorAction Stop
            $retries++
        } while ($svc.Status -ne 'Running' -and $retries -lt 10)
    }
    Write-Host "       certsvc:    $($svc.Status)" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Certificate Services not available: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Ensure Interactive=0 for headless HSM key access (Session 0 safety)
$interactivePath = 'HKLM:\SOFTWARE\SafeNet\LunaClient'
if (Test-Path $interactivePath) {
    $interactiveVal = (Get-ItemProperty -Path $interactivePath -Name 'Interactive' -ErrorAction SilentlyContinue).Interactive
    if ($interactiveVal -ne 0) {
        Write-Host "       [FIX] Setting Interactive=0 for headless HSM access" -ForegroundColor Yellow
        Set-ItemProperty -Path $interactivePath -Name 'Interactive' -Value 0
    }
}

# Verify HSM key access
$verifyKeysOutput = certutil -verifykeys 2>&1
$verifyKeysText = $verifyKeysOutput -join "`n"
$keysOk = ($verifyKeysText -match 'completed successfully') -or ($verifyKeysText -match 'PASS') -or ($verifyKeysText -match 'Signature test passed')
if ($keysOk) {
    Write-Host "       HSM keys:   Accessible" -ForegroundColor Green
} else {
    Write-Host "       [WARN] certutil -verifykeys did not confirm HSM key access." -ForegroundColor Yellow
}

# Get old ICA cert for cross-signing (find cert with matching CN + BasicConstraints CA)
$oldCACert = $null
foreach ($cert in (Get-ChildItem Cert:\LocalMachine\My)) {
    if ($cert.Subject -notmatch [regex]::Escape($activeCA)) { continue }
    foreach ($ext in $cert.Extensions) {
        if ($ext.Oid.FriendlyName -eq 'Basic Constraints') {
            $oldCACert = $cert
            break
        }
    }
    if ($oldCACert) { break }
}

if ($oldCACert) {
    Write-Host ""
    Write-Host "  OLD Issuing CA Certificate:" -ForegroundColor White
    Write-Host "    Subject:     $($oldCACert.Subject)" -ForegroundColor Gray
    Write-Host "    Issuer:      $($oldCACert.Issuer)" -ForegroundColor Gray
    Write-Host "    Thumbprint:  $($oldCACert.Thumbprint)" -ForegroundColor Gray
    Write-Host "    Not After:   $($oldCACert.NotAfter)" -ForegroundColor Gray

    # Note: ICA cert is NOT self-signed (signed by Root CA)
    if ($oldCACert.Subject -ne $oldCACert.Issuer) {
        Write-Host "    Type:        Subordinate CA (signed by Root)" -ForegroundColor Gray
    } else {
        Write-Host "    Type:        Self-signed (test/standalone CA)" -ForegroundColor Yellow
    }
} else {
    Write-Host "[ERROR] Cannot find CA certificate for '$activeCA' in MY store." -ForegroundColor Red
    exit 1
}

# -- 2: Validate new ICA certificate -----------------------------------------
Write-Host ""
Write-Host "[2/5] Validating new ICA certificate..." -ForegroundColor White

if (-not (Test-Path $NewCACertPath)) {
    Write-Host "[ERROR] New ICA certificate not found: $NewCACertPath" -ForegroundColor Red
    Write-Host "        After Step 3 generates the CSR, submit it to the Root CA," -ForegroundColor Red
    Write-Host "        then copy the root-signed certificate to this server." -ForegroundColor Red
    exit 1
}

$newCACert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($NewCACertPath)

# Must have Basic Constraints CA:TRUE
$isCA = $false
foreach ($ext in $newCACert.Extensions) {
    if ($ext.Oid.FriendlyName -eq 'Basic Constraints') {
        $bcExt = [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]$ext
        $isCA = $bcExt.CertificateAuthority
    }
}
if (-not $isCA) {
    Write-Host "[ERROR] Certificate does not have Basic Constraints CA:TRUE." -ForegroundColor Red
    exit 1
}

Write-Host "       Subject:      $($newCACert.Subject)" -ForegroundColor Green
Write-Host "       Issuer:       $($newCACert.Issuer)" -ForegroundColor Green
Write-Host "       CA cert:      Yes (Basic Constraints CA:TRUE)" -ForegroundColor Green
Write-Host "       Thumbprint:   $($newCACert.Thumbprint)" -ForegroundColor Gray
Write-Host "       Key Length:   $(if ($newCACert.PublicKey.Key) { $newCACert.PublicKey.Key.KeySize } else { 'N/A' })" -ForegroundColor Gray

if ($newCACert.Subject -eq $newCACert.Issuer) {
    Write-Host "       Self-signed:  Yes (Phase 8a test mode)" -ForegroundColor Yellow
} else {
    Write-Host "       Root-signed:  Yes (subordinate CA cert)" -ForegroundColor Green
}

# -- 3: Cross-sign via .NET signing (ASN.1/DER construction) -----------------
Write-Host ""
Write-Host "[3/5] Creating cross-certificate via .NET signing..." -ForegroundColor White
Write-Host ""
Write-Host "  The OLD ICA ($activeCA) will sign a new certificate for" -ForegroundColor Yellow
Write-Host "  the NEW ICA, creating a trust bridge (cross-certificate)." -ForegroundColor Yellow
Write-Host ""
Write-Host "  Method: Direct .NET CNG signing with manual ASN.1/DER" -ForegroundColor Yellow
Write-Host "  construction. Works in headless sessions (Session 0)," -ForegroundColor Yellow
Write-Host "  bypassing certutil/certreq UI prompt limitations." -ForegroundColor Yellow
Write-Host ""

#region ASN.1 DER helpers
function DerWrite([byte]$tag, [byte[]]$content) {
    $len = $content.Length
    if ($len -lt 128) {
        return [byte[]]@($tag, $len) + $content
    } elseif ($len -lt 256) {
        return [byte[]]@($tag, 0x81, $len) + $content
    } elseif ($len -lt 65536) {
        return [byte[]]@($tag, 0x82, [byte]($len -shr 8), [byte]($len -band 0xFF)) + $content
    } else {
        return [byte[]]@($tag, 0x83, [byte]($len -shr 16), [byte](($len -shr 8) -band 0xFF), [byte]($len -band 0xFF)) + $content
    }
}

function DerRead([byte[]]$data, [int]$offset) {
    $tag = $data[$offset]
    $lenByte = $data[$offset + 1]
    $headerLen = 2
    $contentLen = 0
    if ($lenByte -lt 128) {
        $contentLen = $lenByte
    } elseif ($lenByte -eq 0x81) {
        $contentLen = $data[$offset + 2]; $headerLen = 3
    } elseif ($lenByte -eq 0x82) {
        $contentLen = ([int]$data[$offset + 2] -shl 8) + $data[$offset + 3]; $headerLen = 4
    } elseif ($lenByte -eq 0x83) {
        $contentLen = ([int]$data[$offset + 2] -shl 16) + ([int]$data[$offset + 3] -shl 8) + $data[$offset + 4]; $headerLen = 5
    }
    $totalLen = $headerLen + $contentLen
    $rawBytes = New-Object byte[] $totalLen
    [Array]::Copy($data, $offset, $rawBytes, 0, $totalLen)
    return @{ Tag = $tag; HeaderLen = $headerLen; ContentLen = $contentLen; TotalLen = $totalLen; Raw = $rawBytes }
}

function DerReadSequenceFields([byte[]]$data, [int]$offset, [int]$count) {
    $pos = $offset
    $fields = @()
    for ($i = 0; $i -lt $count; $i++) {
        $elem = DerRead $data $pos
        $fields += $elem
        $pos += $elem.TotalLen
    }
    return $fields
}

function DerWriteUtcTime([DateTime]$dt) {
    $s = $dt.ToString("yyMMddHHmmss") + "Z"
    return DerWrite 0x17 ([System.Text.Encoding]::ASCII.GetBytes($s))
}

function DerWriteGeneralizedTime([DateTime]$dt) {
    $s = $dt.ToString("yyyyMMddHHmmss") + "Z"
    return DerWrite 0x18 ([System.Text.Encoding]::ASCII.GetBytes($s))
}
#endregion

# Parse new certificate TBS fields
Write-Host "       Parsing new ICA certificate ASN.1 structure..." -ForegroundColor Gray
$newCertBytes = $newCACert.RawData
$outerSeq = DerRead $newCertBytes 0
$tbsElem = DerRead $newCertBytes $outerSeq.HeaderLen
$tbsFields = DerReadSequenceFields $newCertBytes ($tbsElem.HeaderLen + $outerSeq.HeaderLen) 8

$versionRaw    = $tbsFields[0].Raw   # version [0] EXPLICIT
$serialRaw     = $tbsFields[1].Raw   # serial number
$subjectRaw    = $tbsFields[5].Raw   # subject Name
$spkiRaw       = $tbsFields[6].Raw   # subjectPublicKeyInfo
$extensionsRaw = $tbsFields[7].Raw   # extensions [3] EXPLICIT

Write-Host "       Parsed: ver=$($versionRaw.Length)B ser=$($serialRaw.Length)B subj=$($subjectRaw.Length)B pk=$($spkiRaw.Length)B ext=$($extensionsRaw.Length)B" -ForegroundColor Gray

# Parse old ICA certificate to extract Subject DN (becomes the cross-cert Issuer)
Write-Host "       Extracting old ICA subject DN for cross-cert issuer..." -ForegroundColor Gray
$oldCertBytes = $oldCACert.RawData
$oldOuterSeq = DerRead $oldCertBytes 0
$oldTbsElem = DerRead $oldCertBytes $oldOuterSeq.HeaderLen
$oldTbsFields = DerReadSequenceFields $oldCertBytes ($oldTbsElem.HeaderLen + $oldOuterSeq.HeaderLen) 6
$oldIssuerSubjectRaw = $oldTbsFields[5].Raw   # old ICA's Subject = cross-cert Issuer

Write-Host "       Old ICA subject: $($oldIssuerSubjectRaw.Length) bytes" -ForegroundColor Gray

# Build new validity period
$notBefore = [DateTime]::UtcNow
$notAfter  = $notBefore.AddYears($ValidityYears)

$notBeforeBytes = if ($notBefore.Year -lt 2050) { DerWriteUtcTime $notBefore } else { DerWriteGeneralizedTime $notBefore }
$notAfterBytes  = if ($notAfter.Year -lt 2050)  { DerWriteUtcTime $notAfter }  else { DerWriteGeneralizedTime $notAfter }
$validityBytes  = DerWrite 0x30 ($notBeforeBytes + $notAfterBytes)

Write-Host "       Validity: $($notBefore.ToString('yyyy-MM-dd')) to $($notAfter.ToString('yyyy-MM-dd'))" -ForegroundColor Gray

# Detect old CA key algorithm and select signing parameters
$oldKeyAlgo = $oldCACert.PublicKey.Oid.FriendlyName
Write-Host "       Old CA key algorithm: $oldKeyAlgo" -ForegroundColor Gray

if ($oldKeyAlgo -match 'ECC|ECDSA') {
    # ECDSAWithSHA256 AlgorithmIdentifier (OID 1.2.840.10045.4.3.2)
    $signAlgId = [byte[]]@(0x30, 0x0A, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02)
    $sigAlgoName = "ECDSA-SHA256"
} else {
    # SHA256WithRSA AlgorithmIdentifier (OID 1.2.840.113549.1.1.11)
    $signAlgId = [byte[]]@(0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B, 0x05, 0x00)
    $sigAlgoName = "RSA-SHA256"
}

# Construct new TBS Certificate
$tbsContent = $versionRaw + $serialRaw + $signAlgId + $oldIssuerSubjectRaw + $validityBytes + $subjectRaw + $spkiRaw + $extensionsRaw
$newTBS = DerWrite 0x30 $tbsContent

Write-Host "       TBS constructed: $($newTBS.Length) bytes" -ForegroundColor Gray

# Sign TBS with old ICA's private key
Write-Host ""
Write-Host "       Signing TBS with old ICA private key ($sigAlgoName)..." -ForegroundColor White

if ($oldKeyAlgo -match 'ECC|ECDSA') {
    $ecdsaPrivateKey = [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPrivateKey($oldCACert)
    if (-not $ecdsaPrivateKey) {
        Write-Host "[ERROR] Cannot access old ICA's ECDSA private key." -ForegroundColor Red
        Write-Host "        Ensure the CA certificate has an associated private key in the HSM." -ForegroundColor Red
        exit 1
    }
    Write-Host "       ECDSA key type: $($ecdsaPrivateKey.GetType().FullName)" -ForegroundColor Gray
    Write-Host "       Key size:       $($ecdsaPrivateKey.KeySize) bits" -ForegroundColor Gray

    $signature = $ecdsaPrivateKey.SignData(
        $newTBS,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256
    )
    Write-Host "       Signature:      $($signature.Length) bytes (DER-encoded)" -ForegroundColor Gray
} else {
    $rsaPrivateKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($oldCACert)
    if (-not $rsaPrivateKey) {
        Write-Host "[ERROR] Cannot access old ICA's RSA private key." -ForegroundColor Red
        Write-Host "        Ensure the CA certificate has an associated private key in the HSM." -ForegroundColor Red
        exit 1
    }
    Write-Host "       RSA key type: $($rsaPrivateKey.GetType().FullName)" -ForegroundColor Gray
    Write-Host "       Key size:     $($rsaPrivateKey.KeySize) bits" -ForegroundColor Gray

    $signature = $rsaPrivateKey.SignData(
        $newTBS,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
    )
    Write-Host "       Signature:    $($signature.Length) bytes" -ForegroundColor Gray
}

# Assemble final certificate DER
$sigBitString = DerWrite 0x03 ([byte[]]@(0x00) + $signature)
$certDER = DerWrite 0x30 ($newTBS + $signAlgId + $sigBitString)

# -- 4: Save cross-signed certificate ----------------------------------------
Write-Host ""
Write-Host "[4/5] Saving cross-signed certificate..." -ForegroundColor White

$crossCertFile = Join-Path $OutputDir "NewICA-CrossSigned.cer"
[IO.File]::WriteAllBytes($crossCertFile, $certDER)
Write-Host "       Saved: $crossCertFile ($($certDER.Length) bytes)" -ForegroundColor Green

# Also save PEM format
$pemB64 = [Convert]::ToBase64String($certDER, 'InsertLineBreaks')
$pemContent = "-----BEGIN CERTIFICATE-----`r`n$pemB64`r`n-----END CERTIFICATE-----"
$pemFile = Join-Path $OutputDir "NewICA-CrossSigned.pem"
[IO.File]::WriteAllText($pemFile, $pemContent)
Write-Host "       PEM:   $pemFile" -ForegroundColor Gray

# Verify the cross-cert is loadable
$crossCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($crossCertFile)
if (-not $crossCert) {
    Write-Host "[ERROR] Cross-cert DER is invalid (cannot load as X509Certificate2)" -ForegroundColor Red
    exit 1
}

# Verify signature using old ICA's public key
if ($oldKeyAlgo -match 'ECC|ECDSA') {
    $ecdsaPublicKey = [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPublicKey($oldCACert)
    $sigValid = $ecdsaPublicKey.VerifyData(
        $newTBS, $signature,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256
    )
} else {
    $rsaPublicKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($oldCACert)
    $sigValid = $rsaPublicKey.VerifyData(
        $newTBS, $signature,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
    )
}
if (-not $sigValid) {
    Write-Host "[ERROR] Signature verification FAILED." -ForegroundColor Red
    exit 1
}
Write-Host "       [PASS] Signature verified" -ForegroundColor Green

Write-Host ""
Write-Host "  Cross-Signed Certificate:" -ForegroundColor White
Write-Host "    Subject:     $($crossCert.Subject)" -ForegroundColor White
Write-Host "    Issuer:      $($crossCert.Issuer)" -ForegroundColor White
Write-Host "    Thumbprint:  $($crossCert.Thumbprint)" -ForegroundColor Gray
Write-Host "    Serial:      $($crossCert.SerialNumber)" -ForegroundColor Gray
Write-Host "    Not Before:  $($crossCert.NotBefore)" -ForegroundColor White
Write-Host "    Not After:   $($crossCert.NotAfter)" -ForegroundColor White
Write-Host ""

# -- 5: Validate the cross-certificate ---------------------------------------
Write-Host ""
Write-Host "[5/5] Validating cross-certificate..." -ForegroundColor White

# Must be cross-signed (Subject != Issuer)
if ($crossCert.Subject -eq $crossCert.Issuer) {
    Write-Host "[ERROR] Certificate is self-signed! Cross-signing failed." -ForegroundColor Red
    exit 1
}
Write-Host "       [PASS] Cross-signed (Subject != Issuer)" -ForegroundColor Green

# Issuer should be old ICA
if ($oldCACert) {
    if ($crossCert.Issuer -eq $oldCACert.Subject) {
        Write-Host "       [PASS] Issuer matches old ICA: $($oldCACert.Subject)" -ForegroundColor Green
    } else {
        Write-Host "       [WARN] Issuer: $($crossCert.Issuer) (expected: $($oldCACert.Subject))" -ForegroundColor Yellow
    }
}

# Subject should match new ICA cert
if ($crossCert.Subject -eq $newCACert.Subject) {
    Write-Host "       [PASS] Subject matches new ICA cert" -ForegroundColor Green
} else {
    Write-Host "       [WARN] Subject mismatch: $($crossCert.Subject) vs $($newCACert.Subject)" -ForegroundColor Yellow
}

# Export base64 for easy transfer
$crossB64File = Join-Path $OutputDir "NewICA-CrossSigned.b64"
$crossB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($crossCertFile))
$crossB64 | Out-File -FilePath $crossB64File -Encoding ASCII -Force

# Also export old ICA cert for Step 5
$oldICAFile = Join-Path $OutputDir "OldIssuingCA.cer"
if ($oldCACert) {
    $oldBytes = $oldCACert.Export('Cert')
    [IO.File]::WriteAllBytes($oldICAFile, $oldBytes)
    Write-Host "       Old ICA cert exported: $oldICAFile" -ForegroundColor Gray
}

# -- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Step 4 Complete: Cross-certificate created" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Cross-Certificate:" -ForegroundColor White
Write-Host "    Subject:     $($crossCert.Subject)" -ForegroundColor White
Write-Host "    Issuer:      $($crossCert.Issuer)" -ForegroundColor White
Write-Host "    Thumbprint:  $($crossCert.Thumbprint)" -ForegroundColor White
Write-Host ""
Write-Host "  Files to transfer to NEW server:" -ForegroundColor Yellow
Write-Host "    1. $crossCertFile (cross-certificate)" -ForegroundColor Yellow
Write-Host "    2. $oldICAFile (old ICA cert for trust store)" -ForegroundColor Yellow
Write-Host "    3. The root-signed NewIssuingCA.cer (ICA identity cert)" -ForegroundColor Yellow
Write-Host ""
Write-Host "  NEXT: Transfer all files to the NEW server," -ForegroundColor Yellow
Write-Host "        then run Step5-PublishCrossCert.ps1 on the NEW server." -ForegroundColor Yellow
Write-Host ""
