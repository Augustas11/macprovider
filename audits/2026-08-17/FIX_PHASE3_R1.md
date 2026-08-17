# Phase 3 R1 — Fix record

**Worktree:** `/Users/augstar/macprovider-attest-phase3-audit`  
**Branch:** `audit/phase3-live-mda`  
**Date:** 2026-08-17  
**Source:** `audits/2026-08-17/AUDIT_PHASE3_R1_FINDINGS.md`

Target: **0 CRITICAL / 0 HIGH / 0 MEDIUM**.

| Finding | Severity | Fix |
|---------|----------|-----|
| **CODE-H1** | HIGH | `resolveEnv()` now calls `resolveEnvValue("tier2.mdm.api_token", …)`. When `live_mda_enabled`, Load fail-closes if `api_url` or resolved `api_token` is empty. Tests: resolve success + unset env / empty token. |
| **SEC-M1** | MEDIUM | Same as CODE-H1; `NewLiveMDAService` also refuses construction when enabled but `APIURL`/`APIToken` empty (defense in depth). |
| **CODE-M1** | MEDIUM | `MigrateMDAProofFrom` + call from `RegisterAtDetailed` when replacing same `ProviderID` with matching SE key / bound hash. Reconnect unit test. |
| **ARCH-M1** | MEDIUM | Same migration; `RequestAndMaybeUpgrade` still runs `tryUpgradeFromCache` first so migrated proof is reused without enqueue. |
| **CODE-M2** | MEDIUM | `VerifyMDACertChainWithSEKey` calls `verifyMDADeviceProperties`; tests for missing vs present property. |
| **CODE-M3** | MEDIUM | String/base64 path in `extractDeviceAttestationCerts` uses `x509.ParseCertificates` to split concatenated DER; test with two-cert blob. |
| **SEC-H1** | HIGH | Pending map on `LiveMDAService` keyed by UDID (`providerID`, `assignedID`, `expectedSerial`, `seKeyHash`). Enqueue records pending. Webhook extracts MDA serial via `tier2.ExtractMDASerialNumber` (OID `1.2.840.113635.100.8.9.1`) and requires case-insensitive match before `SetMDAProof`. |
| **ARCH-M2** | MEDIUM | `tryUpgradeFromCache` calls `ClearMDAProof` (hardware→self_signed) on age expiry and failed re-verify. |
| **ARCH-M3** | MEDIUM | `HandleMDACommandWebhook` closed-loop ingest; mounted at `/internal/mdm/command-webhook` on provider mux; loopback or `X-MDM-Webhook-Secret`. Runbook + yaml.example document MicroMDM `-command-webhook-url`. Webhook happy-path + serial-mismatch tests. |
| **SEC-M2** | MEDIUM | `phase4-coordinator/go.mod` toolchain bumped to **Go 1.26.6**. |
| **LOW** (cheap) | — | Nil-guard on `UpgradeFromParsedAttestation`; refresh interval: unset/0 → 168, values 1..23 floored to **24** (not jumped to 168). |

## Verification

```bash
cd phase4-coordinator
go test ./internal/tier2 ./internal/mdm ./internal/pool ./internal/config -count=1
go build -o /dev/null ./cmd/coordinator
```

Local commit only — no push / PR.
