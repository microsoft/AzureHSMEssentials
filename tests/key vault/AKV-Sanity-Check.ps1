<#
.SYNOPSIS
    Azure Key Vault sanity check -- validates Standard or Premium (HSM-backed)
    deployment by exercising a sign/verify round trip against the Key Vault REST API.

.DESCRIPTION
    Confirms that an Azure Key Vault deployed by hsm-scenario-builder is correctly
    configured and reachable, that RBAC is granting the caller crypto permissions,
    and that the SKU advertised by ARM matches the key type that can actually be
    created and used.

    Steps performed:
      1. Read vault metadata (SKU, RBAC flag, soft-delete, purge protection, URI)
      2. Acquire an Entra ID access token for the Key Vault data plane
      3. Create a test key via REST  (Premium -> RSA-HSM, Standard -> RSA)
      4. Read the key back and confirm the key type returned by the service
      5. Sign a SHA-256 digest with RS256 via the /sign REST endpoint
      6. Verify the signature with the /verify REST endpoint
      7. Optionally delete (and purge if allowed) the test key

    Authentication uses the Azure CLI context. Run 'az login' first.

.PARAMETER VaultName
    Name of the Key Vault to validate (the short name, not the full URI).

.PARAMETER ExpectedSku
    Expected SKU: Premium (HSM-backed keys, default) or Standard (software keys).
    The script picks the correct key type for the SKU and fails if the live SKU
    does not match.

.PARAMETER KeyName
    Name of the test key to create (default: akv-sanity-<timestamp>).

.PARAMETER SkipCleanup
    Keep the test key after the check. By default, the key is soft-deleted, and
    purged if purge protection is disabled.

.PARAMETER VaultUri
    Override the data-plane URI. Defaults to https://<VaultName>.vault.azure.net.
    Use this only for sovereign clouds.

.EXAMPLE
    .\AKV-Sanity-Check.ps1 -VaultName mykv-prem-001

.EXAMPLE
    .\AKV-Sanity-Check.ps1 -VaultName mykv-std-001 -ExpectedSku Standard

.EXAMPLE
    .\AKV-Sanity-Check.ps1 -VaultName mykv-prem-001 -SkipCleanup
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VaultName,

    [ValidateSet("Premium", "Standard")]
    [string]$ExpectedSku = "Premium",

    [string]$KeyName,

    [switch]$SkipCleanup,

    [string]$VaultUri
)

$ErrorActionPreference = "Stop"

function Write-Step  { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host "    [!!] $m" -ForegroundColor Yellow }
function Write-Fail  { param($m) Write-Host "    [XX] $m" -ForegroundColor Red }

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function ConvertFrom-Base64Url {
    param([string]$Text)
    $pad = 4 - ($Text.Length % 4)
    if ($pad -lt 4) { $Text = $Text + ('=' * $pad) }
    [Convert]::FromBase64String($Text.Replace('-','+').Replace('_','/'))
}

if (-not $KeyName) {
    $KeyName = "akv-sanity-{0}" -f (Get-Date -Format "yyyyMMddHHmmss")
}

if (-not $VaultUri) {
    $VaultUri = "https://$VaultName.vault.azure.net"
}

# ---------------------------------------------------------------------------
# 1. Verify Az CLI is available and logged in
# ---------------------------------------------------------------------------
Write-Step "Checking Azure CLI session"
$azCmd = Get-Command az -ErrorAction SilentlyContinue
if (-not $azCmd) {
    Write-Fail "Azure CLI ('az') not found on PATH. Install it from https://aka.ms/installazurecli."
    exit 1
}

try {
    $account = az account show --output json 2>$null | ConvertFrom-Json
    if (-not $account) { throw "no account" }
    Write-Ok ("Signed in as {0} (subscription {1})" -f $account.user.name, $account.name)
} catch {
    Write-Fail "Not signed in. Run 'az login' first."
    exit 1
}

# ---------------------------------------------------------------------------
# 2. Read vault metadata via ARM
# ---------------------------------------------------------------------------
Write-Step "Reading Key Vault control-plane metadata"
$vaultJson = az keyvault show --name $VaultName --output json 2>$null
if (-not $vaultJson) {
    Write-Fail "Key Vault '$VaultName' not found in the current subscription, or you lack Reader access."
    exit 1
}
$vault = $vaultJson | ConvertFrom-Json
$liveSku             = $vault.properties.sku.name        # 'standard' or 'premium'
$rbacEnabled         = [bool]$vault.properties.enableRbacAuthorization
$softDelete          = [bool]$vault.properties.enableSoftDelete
$purgeProtection     = [bool]$vault.properties.enablePurgeProtection
$softDeleteRetention = $vault.properties.softDeleteRetentionInDays
$networkDefault      = $vault.properties.networkAcls.defaultAction

Write-Host ("    Vault URI            : {0}" -f $vault.properties.vaultUri)
Write-Host ("    Live SKU             : {0}" -f $liveSku)
Write-Host ("    RBAC auth enabled    : {0}" -f $rbacEnabled)
Write-Host ("    Soft delete          : {0} ({1} days)" -f $softDelete, $softDeleteRetention)
Write-Host ("    Purge protection     : {0}" -f $purgeProtection)
Write-Host ("    Network default rule : {0}" -f $networkDefault)

if ($liveSku -ne $ExpectedSku.ToLower()) {
    Write-Fail ("Live SKU '{0}' does not match -ExpectedSku '{1}'." -f $liveSku, $ExpectedSku)
    exit 1
}
Write-Ok "Live SKU matches expectation."

if (-not $rbacEnabled) {
    Write-Warn2 "RBAC authorization is OFF. hsm-scenario-builder deployments expect RBAC-only auth."
}

# Premium uses RSA-HSM (FIPS 140-2 Level 2 HSM-backed); Standard uses software RSA.
$keyType = if ($ExpectedSku -eq "Premium") { "RSA-HSM" } else { "RSA" }
Write-Host ("    Test key type        : {0}" -f $keyType)

# ---------------------------------------------------------------------------
# 3. Acquire a data-plane access token
# ---------------------------------------------------------------------------
Write-Step "Acquiring access token for $VaultUri"
try {
    $tokenJson = az account get-access-token --resource "https://vault.azure.net" --output json
    $token = ($tokenJson | ConvertFrom-Json).accessToken
    Write-Ok "Token acquired."
} catch {
    Write-Fail "Failed to acquire access token: $_"
    exit 1
}

$headers = @{
    Authorization = "Bearer $token"
    "Content-Type" = "application/json"
}
$apiVersion = "7.4"

# ---------------------------------------------------------------------------
# 4. Create a test key via REST
# ---------------------------------------------------------------------------
Write-Step "Creating test key '$KeyName' ($keyType, 2048-bit) via REST"
$createUri = "$VaultUri/keys/$KeyName/create?api-version=$apiVersion"
$createBody = @{
    kty     = $keyType
    key_size = 2048
    key_ops = @("sign","verify")
} | ConvertTo-Json -Compress

try {
    $createResp = Invoke-RestMethod -Method POST -Uri $createUri -Headers $headers -Body $createBody
} catch {
    Write-Fail "Key create failed: $($_.Exception.Message)"
    if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor DarkRed }
    Write-Host ""
    Write-Host "Common causes:" -ForegroundColor Yellow
    Write-Host "  - Caller lacks 'Key Vault Crypto Officer' (or equivalent) RBAC role on the vault."
    Write-Host "  - Network firewall is blocking your client IP (default action is '$networkDefault')."
    Write-Host "  - On Standard SKU you cannot create RSA-HSM keys (use -ExpectedSku Standard)."
    exit 1
}

$kid = $createResp.key.kid
$liveKty = $createResp.key.kty
Write-Ok ("Key created. kid = {0}" -f $kid)
Write-Ok ("Service-reported kty = {0}" -f $liveKty)

if ($liveKty -ne $keyType) {
    Write-Fail ("Service returned kty '{0}' but expected '{1}'." -f $liveKty, $keyType)
    exit 1
}

# ---------------------------------------------------------------------------
# 5. Sign a SHA-256 digest with RS256 via REST
# ---------------------------------------------------------------------------
Write-Step "Signing a SHA-256 digest with RS256 via /sign"
$plaintext = "hsm-scenario-builder sanity check at $(Get-Date -Format o)"
$digest = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
    [Text.Encoding]::UTF8.GetBytes($plaintext))
$digestB64 = ConvertTo-Base64Url -Bytes $digest

$signUri = "$kid/sign?api-version=$apiVersion"
$signBody = @{ alg = "RS256"; value = $digestB64 } | ConvertTo-Json -Compress

try {
    $signResp = Invoke-RestMethod -Method POST -Uri $signUri -Headers $headers -Body $signBody
} catch {
    Write-Fail "Sign failed: $($_.Exception.Message)"
    if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor DarkRed }
    exit 1
}

$signature = $signResp.value
Write-Ok ("Signature returned ({0} chars base64url)." -f $signature.Length)

# ---------------------------------------------------------------------------
# 6. Verify the signature via REST
# ---------------------------------------------------------------------------
Write-Step "Verifying the signature via /verify"
$verifyUri = "$kid/verify?api-version=$apiVersion"
$verifyBody = @{
    alg       = "RS256"
    digest    = $digestB64
    value     = $signature
} | ConvertTo-Json -Compress

try {
    $verifyResp = Invoke-RestMethod -Method POST -Uri $verifyUri -Headers $headers -Body $verifyBody
} catch {
    Write-Fail "Verify call failed: $($_.Exception.Message)"
    if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor DarkRed }
    exit 1
}

if ($verifyResp.value -eq $true) {
    Write-Ok "Signature verified by Key Vault."
} else {
    Write-Fail "Key Vault reported signature INVALID."
    exit 1
}

# ---------------------------------------------------------------------------
# 7. Cleanup
# ---------------------------------------------------------------------------
if ($SkipCleanup) {
    Write-Step "Cleanup skipped (-SkipCleanup). Key '$KeyName' left in vault."
} else {
    Write-Step "Cleaning up test key '$KeyName'"
    try {
        az keyvault key delete --vault-name $VaultName --name $KeyName --output none
        Write-Ok "Soft-deleted."
        if (-not $purgeProtection) {
            try {
                az keyvault key purge --vault-name $VaultName --name $KeyName --output none
                Write-Ok "Purged."
            } catch {
                Write-Warn2 "Purge failed (caller may lack 'Key Vault Crypto Officer' purge permission): $_"
            }
        } else {
            Write-Warn2 "Purge protection is ON -- key remains in soft-delete state for $softDeleteRetention days."
        }
    } catch {
        Write-Warn2 "Cleanup failed: $_"
    }
}

Write-Host ""
Write-Host ("Sanity check PASSED for vault '{0}' (SKU={1})." -f $VaultName, $liveSku) -ForegroundColor Green
if ($ExpectedSku -eq "Premium") {
    Write-Host "RSA-HSM key was created and used for sign/verify -- HSM-backed crypto path is healthy." -ForegroundColor Green
} else {
    Write-Host "RSA software key was created and used for sign/verify -- software crypto path is healthy." -ForegroundColor Green
}
