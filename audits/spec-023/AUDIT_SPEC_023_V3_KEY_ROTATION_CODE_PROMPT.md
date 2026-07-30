# AUDIT: SPEC-023 v3 keypair rotation + catalog re-sign — CODE lens

## Change under audit

Branch: `fix/spec023-catalog-v3-resign` on top of `origin/main` (v1.7.9 + install.sh AMFI retry).

Read the DIFF with:

```
git -C /Users/augstar/macprovider-catalog-v3 diff origin/main
```

Files touched:

- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`
  - `keyID` v2 → v3
  - `publicKeyName` `autotune_static_json_ed25519_v2` → `_v3`
  - New v3 base64 pubkey
  - Baked catalog + demand-rank + rate-card version strings v2 → v3
  - Baked catalog `min_sustained_tps` cuts on 4 rows
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
  - `binaryVersion` `"1.7.9"` → `"1.7.10"`
- `phase3-binary/dist/static/autotune-candidates.json` — v3 catalog with lowered TPS
- `phase3-binary/dist/static/autotune-candidates.json.sig` — v3 signature
- `phase3-binary/dist/static/demand-rank.json` — v3 version bump (content unchanged)
- `phase3-binary/dist/static/demand-rank.json.sig` — v3 signature
- `phase3-binary/dist/static/keys/autotune-static-v3.public.base64` — new public key file
- `phase3-binary/dist/static/keys/README.md` — trust model + rotation docs
- `scripts/resign-autotune-static.sh` — new resign script (reads private key from `~/.config/macprovider/keys/` or `$AUTOTUNE_STATIC_V3_PRIVATE_KEY_PATH`)
- `phase3-binary/Tests/macprovider-cliTests/*.swift` — v2 → v3 test constant updates + v1.7.9 test's TPS value updated from 20 → 15 to remain below the new gate (20)
- `specs/SPEC-023-installer-autotune-recommend.md` — v0.1 → v0.2 amendment

## Context — what and why

Backdrop: on Apple M5 32 GB (Tier C) providers, the pre-v1.7.9 catalog's
`min_sustained_tps` gates were calibrated for M-Pro/M-Max hardware.
Every candidate had positive net income but was hard-blocked at the
eligibility check. v1.7.9 (PR #335) turned TPS + TTFT gates into soft
signals — providers stay online, `.tps_below_gate` / `.ttft_above_gate`
warnings emit when the benchmark misses the target.

This PR (v1.7.10) is the follow-on: catalog re-published with
M-Base-realistic advisory values so the warnings become the exception
rather than the norm. That requires a signature — the catalog is
Ed25519-signed. Rotating v2 → v3 gives a clean cut-over point that's
easy to audit in git.

## CODE lens — what to audit

Focus strictly on CODE correctness. SECURITY audits the trust model
separately; ARCHITECT audits scope + naming + long-term maintenance.

1. **Sig round-trip.** Confirm that the sigfiles at
   `phase3-binary/dist/static/*.json.sig` genuinely verify against the
   new baked pubkey `1qzXegR2OEu0TaQNWjUkN4PamQAHdpvBcYW/pJ4h6oE=` when
   parsed by the client's exact code path
   (`AutotuneStaticInputs.defaultSignatureVerifier` +
   `sidecarIsValid`). One way: run `swift -e` with CryptoKit and check
   `Curve25519.Signing.PublicKey(rawRepresentation: <pubkey>)
   .isValidSignature(<sigBytes>, for: <catalogBytes>)` returns `true`
   for both files.
2. **`sidecarIsValid` still passes for v3 sigs.** The sidecar validator
   at `AutotuneRecommend.swift` checks `key_id == keyID` (which now
   equals `"streamvc-autotune-static-v3"`), `alg == "ed25519"`,
   signature parses as base64, and rejects sidecars with extra fields.
   Confirm the new `.sig` files exactly match that shape.
3. **Baked catalog freshness monotonicity.** The freshness check at
   `loadSignedStatic` compares `fetchedGeneratedAt >= bakedGeneratedAt`.
   Both baked strings jumped v2 (2026-07-02) → v3 (2026-07-03). Confirm
   the fetched catalog's `generated_at` (2026-07-03T08:00:00Z) is
   `>=` the baked's (2026-07-03T00:00:00Z), i.e. the fetched date is
   at least the baked date. Also confirm no tests use a fixed clock
   before 2026-07-03 that would now fail freshness (I've swept
   `ServeCommandTests` — CoordinatorJoin tests bumped from 2026-07-02
   to 2026-07-03).
4. **`AutotuneRecommendTests` v2 → v3 test replacement.** The
   `.replacingOccurrences(of: "baked-2026-07-02", with: ...)` fixtures
   at lines 393 and 421 previously started from the v2 baked date to
   simulate a "fetched newer than baked" scenario. After my sweep
   these read `.replacingOccurrences(of: "baked-2026-07-03", with:
   "fetched-2026-07-10")` — argue whether the semantic is preserved
   (the CURRENT baked string is now v3, so replacing v3 → fetched-v4
   still simulates the "fetched newer than baked" case correctly).
5. **`testStatusFreshnessUsesConfiguredProviderIDIdentity`** (line
   1085) — a stored `LastRecommendationState` fixture at line 1100
   pins `rate_card_version` and `candidate_catalog_version` to
   `baked-2026-07-03`. Baked demand-rank + rate-card + candidate
   catalog all bumped to `baked-2026-07-03` in the source file.
   Confirm the fixture aligns.
6. **TPS test at line 1214** —
   `testTPSBelowGateNoLongerBlocksEligibilityButEmitsWarning` now
   sets `sustainedTPS = 15` to be below the new baked qwen3-coder gate
   of `20`. Confirm the net-earnings check still fires (test expects
   `.recommendedModel` to equal `modelKey`, meaning it must not be
   blocked by the paidThreshold either). Given the rate-card gross
   * (1 - platform_fee_share) at 15 TPS for qwen3-coder, is the
   expected net still above $0.005/hr?
7. **`binaryVersion` sync.** `CoordinatorClient.binaryVersion` was
   `"1.7.9"` → `"1.7.10"`. Corresponding
   `CoordinatorClientTests.testBinaryVersion` expects `"1.7.10"` on
   all four assertions. Also `MacProviderCLI.configuration.version`
   must match. Find and confirm.
8. **`resign-autotune-static.sh` correctness.** Read the whole script.
   Confirm:
   - Reads private key from env or default path (`$HOME/.config/...`).
   - Refuses to run if key file is world-readable (mode > 0600).
   - Passes private-key base64 + input path via env vars into
     `swift -e` (does NOT interpolate the key into shell). Env
     variables are safer than args (not visible in `ps`).
   - Writes the sig sidecar with `key_id: "streamvc-autotune-static-v3"`.
   - Signs the exact on-disk bytes (no re-serialization).
9. **`resign-autotune-static.sh` shellcheck.** Run shellcheck; report
   any new warnings introduced by this PR.
10. **v1.7.9- clients graceful fallback.** For a v1.7.9 client running
    unchanged in the field, they will fetch the new v3-signed feed but
    their baked pubkey is still v2. `sidecarIsValid` would reject
    because `key_id == "streamvc-autotune-static-v3"` doesn't match
    the v1.7.9-baked constant `"streamvc-autotune-static-v2"`. The
    client falls back to its baked catalog, emits
    `candidate_catalog_fallback_used`. Confirm this fallback path
    already works in the v1.7.9 code (no code changes needed on the
    client side; only shipping v1.7.10 buys the new pubkey).

## Bar

Report CRITICAL / HIGH / MEDIUM / LOW / INFO findings. LOW / INFO may
ship with PR-body documentation. Fixes required for CRITICAL / HIGH /
MEDIUM.

Return structured; no speculative findings without a concrete failure
scenario.
