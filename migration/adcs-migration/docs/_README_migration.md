# Azure Dedicated HSM to Azure Cloud HSM Migration

**Last Updated:** April 24, 2026

This document covers the automated migration of AD CS Certificate Authorities from Azure Dedicated HSM (SafeNet Luna KSP) to Azure Cloud HSM (Cavium KSP). The migration orchestrator (`Invoke-CaMigration.ps1`) safely transitions CA private keys, trust chains, and certificate services between HSM platforms with a single command per scenario -- eliminating the manual, error-prone steps typically required for CA key migration.

Four migration scenarios are supported, covering the two most common CA tiers and two industry-standard trust transition methods:

| Scenario                          | Description                                                                                | Result                                                        |
| --------------------------------- | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------- |
| Root CA, Chain Pre-Distributed    | Migrate a standalone Root CA with trust pre-distribution to all relying parties            | Fully automated, zero manual intervention                     |
| Root CA, Cross-Signed             | Migrate a standalone Root CA using cross-signing for seamless trust bridging               | Fully automated, zero manual intervention                     |
| Issuing CA, Chain Pre-Distributed | Migrate a subordinate Issuing CA with parent-signed certificate and trust pre-distribution | Automated with one manual RDP step (Cloud HSM KSP limitation) |
| Issuing CA, Cross-Signed          | Migrate a subordinate Issuing CA using cross-signing for immediate dual-chain trust        | Automated with one manual RDP step (Cloud HSM KSP limitation) |

All 4 scenarios validated with both **RSA 2048** and **ECDSA P256** key algorithms.

**For step-by-step manual migration procedures, see the individual migration guides:**

- [Root CA, Chain Pre-Distributed](migration-guide-rootca-predistributed.md)
- [Root CA, Cross-Signed](migration-guide-rootca-crosssigned.md)
- [Issuing CA, Chain Pre-Distributed](migration-guide-issuingca-predistributed.md)
- [Issuing CA, Cross-Signed](migration-guide-issuingca-crosssigned.md)

**What this document provides:**

- **Orchestrator automation** -- How the single-command orchestrator drives each migration scenario end-to-end, including JSON parameter configuration, inter-VM certificate transfers, and automated validation.
- **Live migration testing** -- Workload continuity proof using a certificate enrollment agent that runs throughout the migration, demonstrating zero-downtime HSM transition.
- **Production guidance** -- Per-step timing data, architecture decisions, known constraints (Cavium KSP session requirements), and decommission readiness assessment criteria.
- **Complete test audit trail** -- Every test run, failure, root cause, and fix logged chronologically with exact error messages, code changes, and validation results.

### Migration Orchestrator (`Invoke-CaMigration.ps1`)

The master orchestrator that drives the entire 8-step migration for any scenario. It reads a JSON parameter file specifying the OLD CA, NEW CA, migration option (Pre-Distributed or Cross-Signed), and key algorithm, then executes all 8 steps sequentially -- handling inter-VM certificate transfers, wrapper script generation, and validation between steps.

**Usage:**

```powershell
# Run a single scenario
.\Invoke-CaMigration.ps1 -ParamsFile .\scripts\migration-params.hsb-rootca-predist.json

# Run with environment reset first (recommended between scenarios)
.\Invoke-CaMigration.ps1 -ParamsFile .\scripts\migration-params.hsb-issuingca-crosssigned.json -ResetFirst
```

Each run produces a timestamped report directory with per-step output logs, timing data, and a migration summary.

### Live Migration Test (`Invoke-LiveMigrationTest.ps1`)

End-to-end test harness that validates workload continuity during migration. It deploys a workload agent to the OLD CA VM, collects a baseline of certificate enrollments, runs `Invoke-CaMigration.ps1` (with `-ResetFirst`), deploys the agent to the NEW CA VM, collects post-migration enrollments, and generates a continuity report proving zero-downtime HSM transition.

**Usage:**

```powershell
# Run full live migration test for a scenario
.\Invoke-LiveMigrationTest.ps1 -ParamsFile .\scripts\migration-params.hsb-rootca-predist.json
```

### Workload Agent (`workload-agent.ps1`)

A lightweight certificate enrollment agent deployed by `Invoke-LiveMigrationTest.ps1` as a scheduled task on each CA VM. The agent enrolls a test certificate every 30 seconds via COM `CertificateAuthority.Request`, detecting the active CA and HSM provider from registry. Each enrollment is logged with timestamp, CA name, KSP, serial number, and PASS/FAIL. The agent always generates RSA CSRs regardless of the CA's key algorithm -- the CA signs each certificate using its own HSM-backed key (RSA or ECDSA), which exercises the HSM signing operation without depending on `certreq` ECDSA support.

---

## Key Differences by Scenario

### Migration Times

| Scenario                    | RSA Duration | ECDSA Duration |
| --------------------------- | ------------ | -------------- |
| Root CA, Pre-Distributed    | 11.3m        | 11.8m          |
| Root CA, Cross-Signed       | 11.7m        | 10.6m          |
| Issuing CA, Pre-Distributed | 14.6m        | 25.8m          |
| Issuing CA, Cross-Signed    | 21.9m        | 25.6m          |

All 4 scenarios can run back-to-back with `-ResetFirst` between each other.

### Orchestrator Migration Steps

The orchestrator executes an 8-step migration lifecycle for each scenario:

| Step | Purpose                                            | Runs On |
| ---- | -------------------------------------------------- | ------- |
| 1    | Capture existing CA details                        | OLD CA  |
| 2    | Validate new server prerequisites                  | NEW CA  |
| 3    | Generate CSR / configure new CA                    | NEW CA  |
| 4    | Sign or cross-sign the new CA certificate          | OLD CA  |
| 5    | Pre-distribute trust or publish cross-cert         | NEW CA  |
| 6    | Activate new CA (install cert, start certsvc)      | NEW CA  |
| 7    | Validate cutover (service, registry, chain checks) | NEW CA  |
| 8    | Decommission readiness assessment                  | OLD CA  |

### PKI Chain Relationship

```
Root CA (self-signed, offline, trust anchor)
  └── Intermediate CA (signed by Root, delegation layer -- often offline)
        └── Issuing CA (signed by Intermediate, online, issues end-entity certs)
```

| Tier                      | Signs certificates for                           | Signed by               | Typically                 |
| ------------------------- | ------------------------------------------------ | ----------------------- | ------------------------- |
| **Root CA**         | Intermediate CAs, Issuing CAs                    | Self (self-signed)      | Offline, air-gapped       |
| **Intermediate CA** | Other Intermediate CAs, Issuing CAs              | Root CA                 | Offline or limited-access |
| **Issuing CA**      | End entities (users, devices, servers, services) | Intermediate or Root CA | Online, enterprise-joined |

> **Note:** From an ADCS installation perspective, Intermediate CAs and Issuing CAs are both Subordinate CAs (`StandaloneSubordinateCA` or `EnterpriseSubordinateCA`). The distinction is architectural enforced by `pathLenConstraint` in the parent CA's issuance policy, not by the install process itself.

### Scenario A: Root CA Migration

- **Option 1:** You can't pre-distribute a chain (there IS no chain above a root). Instead you pre-distribute the **new root certificate itself** to all trust stores. Zero downtime if you distribute before cutover and keep the old root valid.
- **Option 2:** Old Root cross-signs New Root. Leaf → New Root (cross-signed) → Old Root (already trusted). Zero downtime without touching every client trust store.

### Scenario B: Intermediate / Issuing CA Migration

- Covers customers who maintain their Root CA on-prem but move their Intermediate CA and/or Issuing CA to Azure with Cloud HSM.
- **Option 1:** CSR signed by existing offline root → pre-distribute new ICA cert → activate new CA. Standard PKI rekey flow.
- **Option 2:** Old ICA cross-signs New ICA → dual trust chains → clients trust both CAs immediately during transition.

### Supported Algorithms

| Algorithm  | KeyLength | CryptoProviderName Format                  |
| ---------- | --------- | ------------------------------------------ |
| RSA        | 2048      | `RSA#Cavium Key Storage Provider`        |
| RSA        | 3072      | `RSA#Cavium Key Storage Provider`        |
| RSA        | 4096      | `RSA#Cavium Key Storage Provider`        |
| ECDSA_P256 | 256       | `ECDSA_P256#Cavium Key Storage Provider` |
| ECDSA_P384 | 384       | `ECDSA_P384#Cavium Key Storage Provider` |
| ECDSA_P521 | 521       | `ECDSA_P521#Cavium Key Storage Provider` |

All four scenarios support both RSA and ECDSA. The migration scripts auto-detect the old CA's key algorithm and configure the new CA accordingly, or accept an explicit `keyAlgorithm` override in the JSON parameter file.

---

## Known Issues and Constraints

### ARM Provisioning State Deadlock -- Concurrent RunCommand Operations Wedge VM

**Constraint:** Azure Resource Manager enforces exclusive resource-level locks on VM RunCommand operations. Only one RunCommand can execute against a VM at a time. Issuing concurrent or rapid sequential RunCommand calls to the same VM causes ARM's provisioningState to become stuck at "Updating" with no automatic timeout or self-healing.

**Date Discovered:** April 17, 2026
**Confirmed by:** Microsoft Support (root cause acknowledged as by-design concurrency conflict)
**Component:** Azure Resource Manager / Microsoft.Compute/virtualMachines/runCommands

**Microsoft Support Statement:**

> "The issue was caused by a conflict between concurrent requests. When multiple requests
> are made simultaneously, they can sometimes interfere with each other, leading to a conflict."

This is by-design behavior -- ARM's exclusive lock model does not support overlapping RunCommand operations on the same VM. Our initial orchestrator and reset scripts issued rapid sequential `az vm run-command invoke` calls without waiting for lock release between calls, which triggered the deadlock.

**Two observed variants:**

| Variant                           | Trigger                                                                | Severity           | Recovery                                                                            |
| --------------------------------- | ---------------------------------------------------------------------- | ------------------ | ----------------------------------------------------------------------------------- |
| **v1 invoke lock**          | Rapid sequential `az vm run-command invoke` calls on same VM         | Medium             | `az vm deallocate` + `az vm start` (full reboot cycle)                          |
| **v2 child resource stuck** | `az vm run-command create` resource enters terminal "Deleting" state | **Critical** | **No CLI recovery** -- all approaches fail, requires portal or support ticket |

**v1 variant (recoverable):** Observed during Issuing CA Pre-Dist Attempt 4 (April 17). Our reset script
executed 4+ `az vm run-command invoke` calls on dhsm-adcs-rca in rapid succession, followed
immediately by the orchestrator's Step 1. ARM locks did not fully release between calls.
VM entered "Updating" -- all subsequent run-commands returned HTTP 409 Conflict. Recovery
via `az vm deallocate` + `az vm start` worked but added ~69 minutes of wall clock overhead.

**v2 variant (unrecoverable):** Observed April 17-18. A managed RunCommand resource
(`TestAlive`) entered "Deleting" provisioningState and never completed. This wedged the
parent VM's provisioningState at "Updating" for 24+ hours with no CLI recovery path.

**Impact (v2 variant -- worst case):**

- VM is physically running but ARM considers it "not running" -- all management operations blocked
- `az vm restart` -- grayed out in portal, fails in CLI
- `az vm deallocate` -- accepted but never completed
- `az vm reapply` -- timed out
- `az vm run-command delete` -- "Cannot modify extensions in the VM when the VM is not running"
- `az rest --method DELETE` with `forceDeletion=true` -- same error
- `az resource delete` (different ARM codepath) -- "Some resources failed to be deleted"
- `Remove-AzVMRunCommand` (Az PowerShell module) -- same "VM not running" error
- Portal: Restart grayed out, only Stop available

**Recovery Approaches Attempted for v2 Variant (All Failed via CLI):**

1. `az vm restart` -- no effect on wedge
2. `az vm deallocate` (×2) -- accepted but never completed
3. `az vm reapply` -- timed out
4. `az vm run-command delete --name TestAlive --yes --no-wait` → OperationNotAllowed
5. `az rest --method DELETE` with `forceDeletion=true` → OperationNotAllowed
6. `az resource delete` → "Some resources failed to be deleted"
7. `Remove-AzVMRunCommand` (Az PowerShell) → same OperationNotAllowed
8. PS Remoting HTTP/HTTPS → connection errors
9. SSH → timeout
10. Portal Stop + Start -- eventually cleared the wedge (April 18)

**Fixes applied in our orchestrator:**

- **Never use v2 managed RunCommands** (`az vm run-command create`) -- use v1 `invoke` only
- **Serialize all RunCommand calls** -- never issue concurrent/overlapping calls to the same VM
- **Check provisioningState before each call** -- abort if VM is not in "Succeeded" state
- **Add inter-command delays** -- our reset script and orchestrator now wait between sequential calls
- **Validate ARM readiness** -- confirm `provisioningState eq 'Succeeded'` after each operation before proceeding

---

## APPENDIX

### Change Log

#### April 9

- Fixed `configure-adcs.ps1`: changed `$AllowAdminInteraction` default from `$true` to `$false` -- both platforms now set Interactive=0
- Added Interactive=0 validation check (4b) to `Step2-ValidateNewCAServer.ps1`
- Added Interactive=0 enforcement (step 3b) to `Step6-ActivateNewCA.ps1` -- auto-fixes to 0 if found as 1
- Discovered same-CN root collision breaks Option 1 pre-distribution -- adopted G2 naming convention for new Root CAs

#### April 10

- Fixed StrictMode `.Active` crash in all 8 root CA migration scripts -- changed to `try { ... -EA Stop } catch { $null }` pattern
- Fixed StrictMode `.Count` crash in Steps 2, 4, 6, 7 -- wrapped filter results in `@()` array subexpression
- Fixed missing `RSA#` algorithm prefix in Step 3 `CryptoProviderName` for `Install-AdcsCertificationAuthority`
- Fixed `Reset-MigrationEnvironment.ps1` and `Step3-BuildNewCA.ps1`: `certutil -key`/`-delkey` now uses HSM-specific KSP instead of default software KSP

#### April 14

- Created `Invoke-CaMigration.ps1` master orchestrator -- single-command migration with JSON params, wrapper generation, automated cert transfers, and abort-on-failure
- Created `migration-params.template.json` (customer template with `_help` fields)
- Created `migration-params.hsb-rootca-predist.json` and `migration-params.hsb-rootca-crosssigned.json` (lab examples)
- Renamed 32 migration scripts to standardized names (e.g., `CaptureExistingRootCA` to `CaptureExistingCA`)
- Updated 22+ internal cross-references and 14 orchestrator label strings for renamed scripts

#### April 14-16

- Discovered subordinate CA `certutil -installcert` has synchronous CRL chain validation that hangs when parent CA's CRL DP is network-unreachable
- Proved CRL pre-cache + `certutil -f -installcert` solution bypasses the hang
- Documented 7 failed approaches (timeout wrappers, registry flags, Import-Certificate fallback, network adapter disable, etc.)

#### April 17

- `Invoke-CaMigration.ps1`: `New-Wrapper` now parses source script param blocks and preserves defaults instead of blanking unspecified params to `""`
- `Invoke-CaMigration.ps1`: Step 3 wrapper explicitly passes `KeyLength` and `HashAlgorithm` from JSON config
- `Invoke-CaMigration.ps1`: added CRL pre-cache block (~120 lines) -- fetches root CA cert+CRL from parent VM, installs on ICA VM
- `Invoke-CaMigration.ps1`: Step 6 wrapper uses `certutil -f -installcert` to suppress GUI revocation dialog
- `Step8-DecommissionChecks.ps1`: initialized `$caSubject` and `$notAfter` before conditional block (StrictMode fix)
- Cross-Sign `Step1-CaptureExistingCA.ps1`: added Root store + My store fallbacks, `Remove-Item` before each export attempt
- Cross-Sign `Step3-GenerateCSR.ps1`: added `-f` flag to `certreq -new`
- Cross-Sign `Step5-PublishCrossCert.ps1`: added `-f` flag to `certutil -installcert`
- `Reset-MigrationEnvironment.ps1`: broadened HSM key regex to include `tq-*` (Cavium) and `ADCS-*` patterns
- `Reset-MigrationEnvironment.ps1`: added REQUEST store cleanup on both NEW and OLD VMs
- `Reset-MigrationEnvironment.ps1`: added `ica-crosssign-step*` and `ica-predist-step*` dir cleanup patterns
- `Reset-MigrationEnvironment.ps1`: My store cleanup now unconditional with `IncludeArchived` flag for archived cert removal
- `Reset-MigrationEnvironment.ps1`: broadened cross-cert cleanup regex to `HSB|CHSM|DHSM|IssuingCA|Migration`

#### April 20

- `Invoke-CaMigration.ps1`: added `SubjectName = "CN=$caName"` to ICA Step 3 wrappers -- fixes wrong CSR subject (was using parent CA's CN instead of intended subordinate CA name)
- `Invoke-CaMigration.ps1`: added `[FAIL]` to `Invoke-RemoteScript` failure detection regex (was only checking `[ERROR]`)
- Both ICA `Step3-GenerateCSR.ps1` scripts: full rewrite from `certreq -new` to `Install-AdcsCertificationAuthority -OutputCertRequestFile` (configures CA in pending state)
- Both ICA `Step2-ValidateNewCAServer.ps1` scripts: added Azure Cloud HSM SDK path, initialized `$caConfigured`, fixed Interactive check condition
- `Step6-ActivateNewCA.ps1` (chain-pre-dist): added root cert self-healing search, `CRLF_REVCHECK_IGNORE_OFFLINE` before certsvc start
- `Step5-PublishCrossCert.ps1` (cross-signed): added root cert pre-check, `CRLF_REVCHECK_IGNORE_OFFLINE`
- `Invoke-CaMigration.ps1`: CRL pre-cache -- added `certutil -store Root` fallback, fixed here-string concatenation parser bug
- Added `vmAdminUsername` field to all JSON param files and template
- `Wait-VmReady`: fixed JMESPath parse errors, backtick interpolation, em-dash replacements

#### April 21

- `Step6-ActivateNewCA.ps1` and `Step5-PublishCrossCert.ps1`: removed S4U workaround (Cavium KSP requires interactive session, not just user context), added SYSTEM fail-fast detection
- `Step7-ValidateIssuance.ps1` (chain-pre-dist): full rewrite -- removed all HSM-touching checks (certutil -ca.cert, certreq -submit, certutil -CRL), kept service/registry/store checks only
- `Invoke-CaMigration.ps1`: Issuing CA Pre-Dist Step 6 replaced with manual RDP guide + proceed prompt + automated verify script
- `Invoke-CaMigration.ps1`: Issuing CA Cross-Sign Step 5 replaced with script upload + RDP guide + proceed prompt
- `Invoke-CaMigration.ps1`: added post-migration test issuance block for Scenario B (after 8/8 PASS)
- `Invoke-CaMigration.ps1`: `Wait-VmReady` updated to test run-command on running VM before attempting deallocate cycle

#### April 22

- Cross-Sign `Step7-CrossValidate.ps1`: rewritten to 6 non-HSM cutover checks
- Cross-Sign `Step6-ValidateCrossSignedCA.ps1`: removed `certutil -verifykeys` check (hangs under SYSTEM with Cavium KSP)
- `Step8-DecommissionChecks.ps1`: initialized `$pendingCount = 0` before try block (StrictMode fix)

#### April 22

- Fixed all 4 JSON param files: updated stale VM reference from deleted `chsm-adcs-rca` to `chsm-adcs-ica`
- Root CA Pre-Dist orchestrator: added old root cert export/import to NEW VM before Step 6
- Fixed 18 em dash occurrences in script strings -- replaced with `--` to prevent PowerShell parse errors

#### April 23

- Added ECDSA support to all 4 `Step3-GenerateCSR.ps1` scripts -- auto-detect `keyAlgorithm` from JSON params, ECDSA uses `ECDSA_P256#` or `ECDSA_P384#` KSP prefix
- Added ECDSA support to `Invoke-CaMigration.ps1` and `Invoke-LiveMigrationTest.ps1`
- `Invoke-CaMigration.ps1`: fixed StrictMode `PropertyNotFoundStrict` on `$p.newCA.keyAlgorithm` -- uses `PSObject.Properties['keyAlgorithm']` safe access
- `Invoke-LiveMigrationTest.ps1`: fixed StrictMode `.Count` on non-array result (`@()` wrapper), fixed null-check before `.CA` and `.Provider` access
- Removed hardcoded `caThumbprint` from all 4 JSON param files and template -- orchestrator now auto-detects via `Export-CertFromVM -FindBy "ActiveCA"` at runtime
- Both `Step4-CrossSignNewCA.ps1` scripts: replaced hardcoded RSA signing with algorithm auto-detect -- ECDSA uses `GetECDsaPrivateKey()` + ECDSAWithSHA256 OID, RSA uses existing `GetRSAPrivateKey()` + SHA256WithRSA OID
- `Reset-MigrationEnvironment.ps1`: added archived cert cleanup on OLD VM (`OpenFlags 'ReadWrite,IncludeArchived'` + remove `$_.Archived` certs)

#### April 24

- No code changes -- validation only. Phase 3b ECDSA live migration: 4/4 PASS (143 ops, 0 failures). Phase 3d RSA regression live migration: 4/4 PASS (140 ops, 0 failures). Phase 3 complete: 16/16 runs PASS (8 ECDSA + 8 RSA), 283 total operations, 0 failures.
