# #1690 M3 SPEC audit round 1: resolution

Base `b4c06e21`; the findings files are in this directory. SPEC versions are unchanged, because the M3 amendments are still unmerged.

## SPEC lane (0C/1H/4M/2L)
- H1 disputed labels conflict: fixed. The SPEC-042-R006 labels-only "settle underlying usage" sentence now excepts external-runtime attempts, which condition 5 settles at zero billable and never credits.
- M2 HF GGUF tuple allowed and rejected: fixed. The digest equality in SPEC-023 R004 and AC-CAT-16 is scoped to `ollama_library_tag`. AC-CAT-16 gains a valid `huggingface_revision` case (no digest, `file_path`, LFS-oid check at generation). The runbook matrix in `catalog-artifact-feed-release.md` is updated.
- M3 exception missing from restatements: fixed. SPEC-022 R-5.6 and AC-022-63 now apply the R-12 exception, and new AC-022-65 tests both outcomes. SPEC-015 §N.10 (verified-outcome bullet) and AC-51 are qualified.
- M4 "no verifier change": fixed. SPEC-015 §N.12 item 3 now says the tuple and wire are unchanged but the verifier source handling changes. SPEC-022 R-12.4 assigns the change to `tupleUsageMatchesLedger` (`settlement_verifier.go:340-346`) and ingestion (`settlement_receipts.go:182`), gated on the snapshot satisfying R-12.3.
- M5 missing AUTHORITY edge: fixed. SPEC-023 is added to the `network-model-admission` consumers.
- L6 pending anchors: fixed. The SPEC-015 §N.2 R012 members and the §N.12 parser are marked pending implementation. The stale heartbeat citation now points to `ModelRuntime.swift` `loadedWeightsManifestSHA256` (line 1203).
- L7 untestable SHOULD: fixed. §N.12 item 5 is now informative, with no conformance obligation, and keeps its MUST NOT on changing usage or signing.

## SECURITY lane (0C/0H/1M/1L)
- M1 allowlist trusts the hello `runtime_source`: fixed with one design, in SPEC-042-R004 ("Coordinator-recorded runtime class").
  - The allowlist is checked against a coordinator-derived class: the bound candidate's offer-recorded `runtime_source`, which must agree with the format of the verified member (GGUF means loopback; snapshot-manifest means `mlx_cache`).
  - A session with a GGUF pair is never treated as native. A differing hello value removes the session from every pool.
  - The snapshot records the derived class.
  - A new paragraph separates what administrative trust covers (executing process, loaded weights, token counts) from what the coordinator enforces.
  - The buyer promise is qualified as control over declared, recorded identity (SPEC-042 R004 and R013, SPEC-047 pool clause, SPEC-043-R013).
  - A native-claiming GGUF session is added to the R013 fail-closed tests.
- L2 reusable `pool_runtime_authorization`: fixed. The member now also binds `request_id`, `attempt_n`, `provider_id`, and `route_snapshot_digest`. The CLI compares them with the request being served and its own id. AC-12b covers a copied authorization.

## ARCH lane (0C/1H/3M/0L)
- H1 verifier contract contradiction: fixed. This is the same change as SPEC M4 (SPEC-022 R-12.4, SPEC-015 §N.12 item 3).
- M2 omitted shared gates: fixed. SPEC-042-R005 and the SPEC-047 pool clause now name five route-time sites:
  - `filter.go:311`
  - the `RoutingEligible` sandbox exclusion (`pool/provider.go:565-578`), handled through a separate pool-scoped predicate, with the global answer and flag unchanged
  - `byomRouteSnapshotBinding` (`model_admission.go:307`), which accepts `catalog_priced` for pool routes only
  - the `byomBoundMemberMatchesSession` loopback rejection (`:363`), kept for global routes
  - `billing_recorder.go:747-757`

  The admission bar and hello sandbox stay unlifted.
- M3 settlement cannot reconstruct eligibility: fixed. External-runtime snapshots carry the digested `pool_generation` and `pool_operator_account_id` (SPEC-022 R-12.1, SPEC-015 §N.2). SPEC-042-R006 conditions 2 and 4 and the derivation sentence re-evaluate from those values plus durable, append-only records (membership and revocation events, pool-creation record, SPEC-003 identity), never live state.
- M4 AC-CAT-16 rejects the new tuple: fixed. This is the same change as SPEC M2.
