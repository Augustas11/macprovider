Freeze verdict: **REJECT**. The complete campaign diff has six HIGH and five MEDIUM security defects, primarily in settlement fencing, receipt identity, and pricing immutability.

Validation was read-only: complete diff review, cross-contract source inspection, six security/audit lanes, `git diff --check`, and a private-key marker scan. Resource-intensive tests were not run on this Mac per the repository’s CI boundary.

## HIGH

1. **HIGH — NEW — Final receipt settlement bypasses the durable post-route revocation fence.**
   Files: [hotpath.go:256](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/billing/hotpath.go:256), [settlement_receipts.go:315](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/billing/settlement_receipts.go:315), [pool_operator_attestation.go:317](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/billing/pool_operator_attestation.go:317), [recovery.go:450](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/billing/recovery.go:450).
   **Defect:** The hot path checks `PoolRouteFenceHolds`, but the later transaction that verifies the receipt and synchronizes final credit does not. Its preliminary eligibility check replays only the route-time generation, and native routes bypass it. Recovery may reconcile an existing credit before current billability is checked.
   **Scenario:** Request routes and receives provisional credit; membership/delegation/R016 authority is then revoked or the pool is frozen/retired; a delayed valid receipt closes `verified`, leaving positive provider credit and buyer-final debit.
   **Fix:** Inside the same SQL transaction that writes the terminal verdict and credit, call `PoolRouteFenceHolds` for every pool route. A decided revocation must quarantine and zero/refund; transient reads remain pending. Apply the same ordering to recovery.

2. **HIGH — NEW — Native pool attempts settle despite disputed or unverifiable pool labels.**
   Files: [settlement_receipts.go:228](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/billing/settlement_receipts.go:228), [pool_operator_attestation.go:317](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/billing/pool_operator_attestation.go:317), [settlement_pool_labels.go:12](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/billing/settlement_pool_labels.go:12), [settlement_receipt_recovery.go:71](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/buyer/settlement_receipt_recovery.go:71).
   **Defect:** `coordinator_observed` usage is automatically cross-checked. Pool labels are recorded only after settlement, and `label_disputed`/`unverified` deliberately do not change settlement. This contradicts SPEC-005-R015’s no-debit/no-credit rule.
   **Scenario:** A native attempt’s settlement view has an earlier generation, same version with another digest, wrong pool, or wrong route digest. The receipt still becomes `verified` and payable; only afterward is it marked `label_disputed`.
   **Fix:** Verify exact labels, route digest, and `PoolManifestRouteEligible` atomically before the terminal verdict. Disputed/unverified labels must quarantine, zero credit, and refund.

3. **HIGH — PRE-EXISTING — A provider-signed receipt can replace byte-bounded usage with an inflated completion count.**
   Files: [server.go:3306](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/buyer/server.go:3306), [billing_recorder.go:925](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/buyer/billing_recorder.go:925), [settlement_receipts.go:465](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/billing/settlement_receipts.go:465), [settlement_receipts.go:553](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/billing/settlement_receipts.go:553).
   **Defect:** Initial accounting independently clamps provider-reported completion usage, but final receipt synchronization accepts the raw signed completion count and overwrites ledger economics. Receipt verification proves tuple consistency, not consistency with delivered bytes.
   **Scenario:** Provider returns two output bytes but reports and signs `completion_tokens=10,000,000`. Initial credit is safely clamped; final verification replaces it with the ten-million-token charge.
   **Fix:** Never let final receipt usage exceed the independent ledger/delivered-byte ceiling. Quarantine an excessive receipt or use the lower independently bounded value.

4. **HIGH — NEW — A blocked artifact-feed identity can be laundered into a paid pool entry.**
   Files: [artifact_identity_index.go:77](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/buyer/artifact_identity_index.go:77), [model_admission_pool_manifest.go:119](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/ws/model_admission_pool_manifest.go:119), [model_admission_pool_manifest.go:410](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/ws/model_admission_pool_manifest.go:410), [SPEC-042:380](/Users/augstar/macprovider-1816-pool-models/specs/SPEC-042-pool-control-plane.md:380).
   **Defect:** The artifact identity index drops `blocked` rows. Direct classification covers only snapshot-manifest primary hashes, so blocked GGUF and non-primary artifacts disappear from the deny decision. Acceptance, rebind, revocation, and hello exemption can then treat them as non-catalog pool artifacts.
   **Scenario:** A verified GGUF pair is pool-bound, then its catalog row becomes blocked. The release index drops the pair, the binding is not revoked, and the safety-blocked artifact remains pool-routable and payable. A new manifest can also readmit it.
   **Fix:** Maintain an authenticated release-bound deny/tombstone index that retains blocked artifact pairs independently of the usable index, and consult it at acceptance, binding, rebind, sweep, and hello admission.

5. **HIGH — NEW — Preaccepted future manifests can retroactively zero-bill current R016 traffic.**
   Files: [pool_operator_attestation.go:54](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/trustpool/pool_operator_attestation.go:54), [pool_operator_attestation.go:72](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/trustpool/pool_operator_attestation.go:72), [SPEC-042:140](/Users/augstar/macprovider-1816-pool-models/specs/SPEC-042-pool-control-plane.md:140).
   **Defect:** The fence treats every higher manifest version omitting an R016 account as a post-route revocation, without checking whether that acceptance event occurred after the route generation. Future-dated cores may already be accepted while inactive.
   **Scenario:** Active v2 attests member A. The creator preaccepts inactive future v3 without A. A later request legitimately routes under v2, but settlement sees v3 and zero-bills it. A vertically integrated buyer/creator can use this to obtain free service and deny member payout.
   **Fix:** Apply removal only for events whose durable ordinal is after the route generation. If activation should revoke, persist an explicit activation/revocation event.

6. **HIGH — NEW — Pool route snapshots silently changed the v1 digest and cannot be independently verified.**
   Files: [route_snapshot.go:33](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/billing/route_snapshot.go:33), [route_snapshot.go:213](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/billing/route_snapshot.go:213), [settlement.go:157](/Users/augstar/macprovider-1816-pool-models/phase7-verify/internal/verify/settlement.go:157), [settlement.go:650](/Users/augstar/macprovider-1816-pool-models/phase7-verify/internal/verify/settlement.go:650), [SPEC-015:4007](/Users/augstar/macprovider-1816-pool-models/specs/SPEC-015-receipts.md:4007).
   **Defect:** The coordinator adds pool provenance and pricing fields to `route_snapshot_v1` while retaining `spec022-prereq-v1`. The standalone verifier lacks those fields and recomputes the legacy digest. SPEC-015 explicitly requires a v2 carrier for additional validity fields.
   **Scenario:** A valid pool receipt is signed over the coordinator’s extended digest; `phase7-verify` ignores the new JSON fields and reports `route_snapshot_digest_mismatch`. Paid pool receipts therefore cannot be independently verified.
   **Fix:** Introduce `route_snapshot_v2` and a new policy version, update SPEC-015, schemas, phase7 structures/JCS, and fixtures, while preserving byte-identical v1 handling.

## MEDIUM

1. **MEDIUM — NEW — Pool price-bound configuration accepts missing, unknown, and arithmetic-unsafe values.**
   Files: [config.go:1300](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/config/config.go:1300), [config.go:2069](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/config/config.go:2069), [config.go:3310](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/config/config.go:3310), [formula.go:268](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/billing/formula.go:268).
   **Defect:** Missing keys become zero, unknown YAML keys are ignored, and validation only checks nonnegative ordered ranges. Maxima that necessarily overflow the formula are accepted.
   **Scenario:** A misspelled minimum silently broadens the floor, or a creator chooses an accepted near-`MaxInt64` rate that makes ordinary usage overflow to zero billing.
   **Fix:** Use closed decoding with required-key tracking and validate worst-case prompt/cache/completion arithmetic against `maxBillableTokens`, multiplier, and provider share.

2. **MEDIUM — NEW — Pool routes do not freeze multiplier/share/config generation at dispatch.**
   Files: [pool_model_route.go:257](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/buyer/pool_model_route.go:257), [billing_recorder.go:470](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/buyer/billing_recorder.go:470), [billing_recorder.go:520](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/buyer/billing_recorder.go:520), [SPEC-005:1522](/Users/augstar/macprovider-1816-pool-models/specs/SPEC-005-billing.md:1522).
   **Defect:** Route snapshots persist entry rates and a bounds digest, but not the default multiplier, provider share, or rate-card/config generation. Those values are resolved again after inference.
   **Scenario:** Request dispatches at multiplier 1.0/share 90%; a reload changes them to 2.0/95% before response recording; the attempt settles under the new economics.
   **Fix:** Capture all five price values plus rate-card/config generation and digest at reservation, and use only that immutable snapshot through hotpath, receipt settlement, and recovery.

3. **MEDIUM — NEW — Receipt identity uses the provider-local model label instead of `pool_model_id`.**
   Files: [pool_model_route.go:266](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/buyer/pool_model_route.go:266), [pool_model_route.go:289](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/buyer/pool_model_route.go:289), [SPEC-022:1385](/Users/augstar/macprovider-1816-pool-models/specs/SPEC-022-verified-model-settlement.md:1385).
   **Defect:** The snapshot’s `model_id` is `provider.ModelID`; R13.3 requires it to be the pool-scoped `pool_model_id`.
   **Scenario:** An uncatalogued pool artifact is locally served under `mlx-community/Popular-Model`. Its paid receipt and ledger now attribute the pool-attested hash to that catalog-looking/global label, and two pools may collide on the same local name.
   **Fix:** Use `entry.PoolModelID` in settlement/receipt identity and keep the provider-local execution label only in relay rewrite metadata.

4. **MEDIUM — NEW — The Pearl “live_verified” proof is forgeable by a malicious canary user.**
   Files: [catalog-canary-proof.py:160](/Users/augstar/macprovider-1816-pool-models/ops/pearl-updater/catalog-canary-proof.py:160), [catalog-canary-proof.py:206](/Users/augstar/macprovider-1816-pool-models/ops/pearl-updater/catalog-canary-proof.py:206), [macprovider-pearl-update:5513](/Users/augstar/macprovider-1816-pool-models/ops/pearl-updater/macprovider-pearl-update:5513), [deploy-pearl-vps.sh:4801](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/dist/deploy-pearl-vps.sh:4801).
   **Defect:** Proof establishes only a same-UID executable path/vnode and trusts unauthenticated loopback status. The coordinator leg reports provider-asserted catalog evidence. No expected binary hash, signing identity, nonce, or cryptographic binding proves which catalog bytes were loaded.
   **Scenario:** An attacker controlling the canary account replaces the CLI with a same-UID executable at the expected path, serves fabricated status, and opens a matching coordinator session. Every new canary check passes without validating the candidate catalog or model.
   **Fix:** Pin binary SHA-256 and code-sign/notarization identity, and use a fresh challenge bound cryptographically to the process, coordinator session, release, row, and artifact identity.

5. **MEDIUM — PRE-EXISTING — Rolling back the entire SQLite store defeats manifest and revocation monotonicity.**
   Files: [durable_store.go:728](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/trustpool/durable_store.go:728), [durable_store.go:1462](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/trustpool/durable_store.go:1462), [SPEC-042:321](/Users/augstar/macprovider-1816-pool-models/specs/SPEC-042-pool-control-plane.md:321).
   **Defect:** Events, projections, and high-water records occupy the same rollback domain; verification proves only internal consistency. The SPEC acknowledges tamper-evident rollback protection as a launch blocker.
   **Scenario:** After a member or model entry is revoked, an older internally consistent database snapshot is restored. Its lower event history and matching high-water record pass verification, resurrecting route/payment authority.
   **Fix:** Anchor event roots and per-pool high-water state outside the database rollback domain—such as WORM/transparency storage or an independent monotonic witness—and fail closed on regression.

## LOW

1. **LOW — NEW — Pool model capacity counts loopback members that R016 routing rejects.**
   File: [pool_model_route.go:453](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/buyer/pool_model_route.go:453).
   **Scenario:** A delegated loopback member loses its R016 attestation but still inflates `/v1/models` provider and slot counts; actual routing rejects it.
   **Fix:** Reuse `poolModelCandidate` or the complete creator-owned-or-R016 route predicate for listing.

2. **LOW — NEW — Lapsed native hello-gate exemption sessions remain connected.**
   Files: [server.go:3604](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/ws/server.go:3604), [model_admission_pool_manifest.go:547](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/ws/model_admission_pool_manifest.go:547), [SPEC-032:470](/Users/augstar/macprovider-1816-pool-models/specs/SPEC-032-proof-of-weights-hello-gate.md:470).
   **Scenario:** A native pool entry or membership is removed; paid routing fails closed, but the exempt uncatalogued session remains connected indefinitely instead of closing with `autotune_model_uncatalogued`.
   **Fix:** Re-evaluate live `pool_entry` sessions on manifest/membership/release revision and disconnect any lapsed match.

3. **LOW — NEW — A blank first duplicate selector downgrades pool `/v1/models` to the global view.**
   Files: [server.go:371](/Users/augstar/macprovider-1816-pool-models/phase5-gateway/internal/router/server.go:371), [pool_selection.go:82](/Users/augstar/macprovider-1816-pool-models/phase5-gateway/internal/router/pool_selection.go:82).
   **Scenario:** Headers contain an initial blank value and a later valid pool selector. `Header.Get` skips resolution, while the resolver itself would have found the pool, so the global list is returned.
   **Fix:** Always invoke the canonical selector resolver and let it decide whether selection is absent.

4. **LOW — NEW — Gateway pool-model sanitization does not bind the embedded pool ID or validate numeric semantics.**
   File: [server.go:546](/Users/augstar/macprovider-1816-pool-models/phase5-gateway/internal/router/server.go:546).
   **Scenario:** A malformed coordinator response selects pool A but carries `pool/B/...`, an invalid algorithm, negative prices, fractional values, or cache rate above prompt rate; the gateway republishes it as pool A data.
   **Fix:** Strictly parse the pool model ID and require its embedded pool to match; validate algorithm/runtime pairings and integer, nonnegative, bounded price/context semantics.

5. **LOW — NEW — Case-variant reserved pool names can appear as global models.**
   Files: [server.go:2205](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/buyer/server.go:2205), [server.go:470](/Users/augstar/macprovider-1816-pool-models/phase5-gateway/internal/router/server.go:470).
   **Scenario:** A globally eligible provider advertises `Pool/<id>/slug`; the case-sensitive `pool/` filter treats it as ordinary global identity, creating a pool-looking globally visible/routable label.
   **Fix:** Reserve the namespace through the canonical case-insensitive pool-model parser at both coordinator aggregation and gateway sanitization.

6. **LOW — NEW — Pool-list authorization failures become a distinguishable gateway error.**
   File: [server.go:404](/Users/augstar/macprovider-1816-pool-models/phase5-gateway/internal/router/server.go:404).
   **Scenario:** Gateway authorization is stale while the coordinator has retired or revoked the pool. The response changes from generic `pool_unavailable` to `502 coordinator_models_error`, revealing lifecycle disagreement.
   **Fix:** Collapse all pool-selected upstream denials and malformed responses to the generic pool-unavailable response.

7. **LOW — NEW — Catalog content-release canary checks source but not exact trust state.**
   Files: [catalog-canary-proof.py:221](/Users/augstar/macprovider-1816-pool-models/ops/pearl-updater/catalog-canary-proof.py:221), [catalog-content-release.sh:1566](/Users/augstar/macprovider-1816-pool-models/scripts/catalog-content-release.sh:1566).
   **Scenario:** The helper returns matching release/source/session fields while the catalog state is not `live_verified`; the content-release path checks only `source=coordinator` and can activate.
   **Fix:** Enforce both `state == live_verified` and `source == coordinator` inside the shared proof helper and every caller.

No request-routing escape to another pool or exact lower-case pool identity was found in the core route predicate. Gateway settle/refund mapping is correct when coordinator finality is correct; HIGH findings 1–2 cause the coordinator to emit incorrect finality. No private-key marker or committed signing-key material was found in the diff, and reviewed catalog/reissue paths use operator-local or secret-provided signing inputs. No bearer token, private key, or raw secret logging defect was found; reviewed new logs contain identifiers and public digests only.

TOTALS: C=0 H=6 M=5 L=7 I=0