# SPEC-036 IMPL — Round-1 BUILD audit (3 codex lanes) + fixes

**Date:** 2026-08-06
**Reviewed:** full IMPL diff `1d0904bf..HEAD` (`internal/computeintegrity/**`).
**Method:** three independent codex lanes (code-correctness, security/money-path,
architecture/spec-fidelity). Prompts + raw artifacts in this directory / `.omc/artifacts/ask/`.

## Round-1 result

| Lane | C | H | M | L |
|---|---:|---:|---:|---:|
| codex code-correctness | 3 | 3 | 2 | 1 |
| codex security / money-path | 0 | 3 | 2 | 0 |
| codex architecture / spec-fidelity | 0 | 3 | 2 | 0 |

All three lanes independently validated the architecture (ApplyGate AND-gate correct;
never promotes/relaxes; the pure/in-memory default-off scoping is sound; JCS
duplication acceptable). The findings were precision defects in the settlement-bearing
key algebra and fail-closed edges — exactly the high-value target of the audit.

## Fixes (all C/H/M addressed; the consolidated de-duplicated set)

1. **WindowKey missing `stable_provider_identity`** (code-C1, arch-H1): a provider
   could resolve against another provider's verified window. Added
   `StableProviderIdentity` to `WindowKey` + `Window()` projection; added a
   cross-provider isolation test.
2. **Unknown captured mode fail-open** (code-C2, security-H3): a malformed
   `ComputeIntegrityPolicyMode` was treated as non-enforce, passing a fresh verified
   row through payable. Added `Mode.Known()`; `Evaluate` now fails closed
   `compute_integrity_unreadable` for an unknown mode while SPEC-022 enforces.
3. **SwapLaunderingScope too wide** (code-C3, security-H1, arch-H3): scope included
   hash/tokenizer/sampler, so a hash change escaped the block. Reduced swap-laundering
   scope to `(stable_provider_identity, model_id)`; introduced a separate
   `TombstoneScope` (stable, model, hash, tokenizer, sampler) for lineage tombstones;
   added a cross-hash span test.
4. **Origin hard-coded `enforce_preserved`** (code-H1, security-M4, arch-H2): a
   quarantine met under observe/warn-only was wrongly money-blocking. Threaded
   `Spec022EffectiveEnforce` into `ResolveInput`; added `deriveOrigin(mode, spec022)`;
   swap-laundering block inherits origin from the source risk (enforce_preserved only
   when derived from an enforce_preserved provider overlay). Added telemetry-origin test.
5. **Reference covered-key / position-set binding** (code-H2, security-H2): admissibility
   didn't verify references bound the same covered key or identical position set, and
   permitted empty positions (→ zero TV → admissible). Added `CoveredKey` input,
   per-reference covered-key match, non-empty positions, and a `PositionSetDigest`
   equality check. Added mismatch/empty tests.
6. **OverlayKey wrongly included `hardware_runtime_class`** (code-H3): a class change
   would shed accumulators/quarantine. Removed it from Window/Overlay keys (a per-key
   policy invariant per FR-8); ThresholdKey retains the 8-tuple with class.
7. **`windowMeetsQuarantine` used all canaries, not the eligible window** (code-M1):
   filtered to canaries within `window_size_days`.
8. **Stale positive TTL resolved as `pending`, not `expired`** (code-M2): now returns
   `expired` / `window_ttl_expired`; fixed the test that asserted the wrong behavior.
9. **Sampler-stage wire value** (arch-M4): changed to `post_sampler_probabilities`
   (SPEC-036 v0.1 value); kept the SPEC-030 capture point as a separate internal mapping.
10. **Policy digest over a partial object** (arch-M5): now digests the full policy —
    cadence, auto-downgrade, nested circuit-breaker/flapping objects, identity-authority
    and cost-model flags.
11. **Probe request validation** (security-M5): added nonce-length (≥128 bits), RFC3339
    expiry parse + a `ValidateProbeExpiry` ≤120s-after-issuance check, and the
    K=256-requires-`retry_of_probe_id` binding.
12. **Reference top-K validation** (code-L1): validate each reference top-K length/dedup;
    simplified the support-length check (the exact-union equality already bounds it).

## Post-fix state

`go build ./...`, `go vet`, and `golangci-lint` (depguard AC-16 config) all green;
all 17 AC fixtures pass. Round-2 re-audit of all three lanes recorded separately.
