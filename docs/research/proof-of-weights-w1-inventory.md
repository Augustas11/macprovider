# Proof of Weights — W1 catalog artifact bind inventory

**Date:** 2026-07-08  
**Runbook:** `ops/runbooks/proof-of-weights-implementation.md` §3  
**Scope:** Session B W1 audit only (implementation hardening tracked separately)

---

## Seam map (confirmed in tree)

| Component | Path | Role |
|-----------|------|------|
| Provider manifest hash | `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` `modelWeightArtifactManifestHash` | SHA-256 over safetensors manifest at load |
| Coordinator catalog verify | `phase4-coordinator/internal/tier2/catalog.go` `VerifyProviderHash` | Five-state hash enum at hello + heartbeat |
| WS admission hash stamp | `phase4-coordinator/internal/ws/server.go` `prepareProviderAdmission` | Sets `pool.Provider.HashStatus` at connect |
| Buyer routing exclusion | `phase4-coordinator/internal/buyer/server.go` `Tier2Decision` + `routing/filter.go` | `ReasonTier2HashMismatch` / `ReasonTier2HashRequired` |
| Warm-swap re-verify | `phase4-coordinator/internal/pool/provider.go` `ApplyHeartbeat` SPEC-011 path | Re-runs heartbeat hash verifier on model/hash drift |
| Settlement bind | SPEC-015 v0.4 `expected_catalog_model_hash` in receipt + coordinator settlement verifier | Quarantine on mismatch |
| Buyer observe field | `phase3-binary/.../InferenceRelay.swift` `macprovider_model_hash_observed` | Audit trail, not gating |
| Explorer / quarantine visibility | `phase4-coordinator/internal/billing/endpoints.go` settlement reason filters | `model_hash_mismatch`, `expected_catalog_model_hash_mismatch` |

---

## Audit: hash mismatch → routing exclude

**Finding: no allow path for mismatch when tier2 model hash is active.**

- `tier2.IsHashPredicateFailure` returns true for `hash_mismatch` and `hash_invalid` unconditionally (`catalog.go:682-687`).
- Buyer `Tier2Decision` maps those to `ReasonTier2HashMismatch` (`buyer/server.go:6195-6197`).
- `routing.EligibleCandidates` excludes mismatched providers; mismatch vector surfaced in `HashMismatches` for observability (`routing/filter.go`).
- `/poolz` tier2 eligibility uses the same predicate (`ws/server.go:3042`).
- Tier2 audit log emits `decision=exclude` for mismatch (`catalog.go:705-706`).

**Gap (LOW):** optional coordinator metric `model_hash_mismatch_total` from runbook §3.1 not yet present — routing exclusion works without it.

---

## Audit: settlement quarantine on hash mismatch

**Finding: phase7-verify + coordinator settlement path quarantine mismatches.**

- Verifier reason `model_hash_mismatch` when receipt hash ≠ catalog sha256 (`phase7-verify/internal/verify/catalog_check.go`).
- v0.4 settlement adds `expected_catalog_model_hash_mismatch` when pinned catalog body diverges (`settlement_verifier.go`, `phase7-verify/internal/verify/settlement.go`).
- Explorer SQL surfaces both reasons in quarantine views (`billing/endpoints.go:936`).
- Fixture coverage: `TestCatalogCheckModelHashMismatch`, v0.4 negative fixtures `negative_receipt_model_hash_mismatch`.

---

## Operator catalog pin workflow (documented)

1. Edit signed tier-2 catalog JSON + rate-card model rows in git (operator PR).
2. Deploy coordinator with updated `tier2.catalog_path` / hot-reload (SIGHUP).
3. Providers run `macprovider-cli autotune --recommend --apply` so `model_catalog_*` + `model_artifact_sha256` match the pinned row.
4. Hello carries `model_hash` from live manifest; coordinator verifies against catalog via `VerifyProviderHash`.
5. Mismatch → no buyer traffic; settlement receipts quarantine if hash diverges at payout time.

---

## W1 success criteria status

| Criterion | Status |
|-----------|--------|
| Mismatch provider never receives buyer traffic for pinned catalog row | ✅ Enforced via tier2 routing predicate |
| Quarantined receipts visible in operator explorer | ✅ Settlement reason filters present |
| Optional mismatch metric | ⬜ Not implemented (carry LOW) |

---

## Handoff to W2

W1 seams are wired; W2 adds **capacity ceiling** via verified autotune hardware-evidence at WS hello (`internal/autotune` hello gate). W3 adds **runtime model-class probes** via `pool.model_class_challenges` with optional `max_ttft_ms` / `min_sustained_tps` gates on the existing canary path (`internal/ws/canary_probe.go`), exporting `model_class_opoi_pass` on `/poolz`.
