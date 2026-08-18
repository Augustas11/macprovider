# SPEC-015 — Verifiable inference receipts

**Version:** 0.4.5 (2026-08-18, remaining SPEC-015 conformance unit IDs; LOCKED settlement-capable receipt profile for SPEC-022 otherwise unchanged)
**Depends on:** SPEC-001 v1.6, SPEC-002 v1.4 (v1.5 candidate `GET /v1/receipt-keys/<provider_id>` buyer-safe pubkey resolver; v1.6 candidate `/poolz` catalog fields + `/catalog/<catalog_id>` + `/catalog/pubkey` per §M.4), SPEC-005 v0.3 (settlement/accounting semantics; v0.4+ chargeability successor expected for terminal-state rows), SPEC-006 v0.9, SPEC-008 v0.3 (hard — §5.3-5.6 model-hash semantics; §5.5 hash_status enum), SPEC-010 v1.5, SPEC-011 v0.5 (hard — §3.3.1 heartbeat `model_hash`; §3.2 warm-swap state machine; §3.3.0 opt-in gating), SPEC-013 v0.3, SPEC-022 v0.1.4 (hard — settlement-capable receipt profile consumer)

**Change log v0.4.5 (2026-08-18, issue #1023 — remaining conformance unit IDs):**
- Registers `SPEC-015-R002`..`SPEC-015-R005` in `specs/CONFORMANCE.json` as
  pending anchors for historical v0.1–v0.3 verification, receipt-key
  lifecycle, pubkey trust root, and ingest/storage redaction. Buyer
  retrieval remains SPEC-022-R006. No receipt tuple, wire, or verifier
  behavior change. `requirement_id_migration` remains `pending`. Do not
  promote.

**Change log v0.4.4 (2026-08-17, issue #1010 — compute-integrity digest binding decision):**
- Closes the SPEC-015 side of #1010. Request-start compute-integrity state
  digests remain outside the v0.4 signed tuple and strict `usage` object. If
  externally reviewable compute-integrity binding is needed, it belongs in a
  separate SPEC-036 audit artifact keyed to the same request attempt and
  receipt tuple. A future SPEC-015 successor may reference that artifact only by
  defining a new `receipt_version`; v0.4 MUST NOT gain optional digest fields.

**Change log v0.4.3 (2026-08-17, issue #614 — preliminary paid-path conformance unit ID):**
- Registers `SPEC-015-R001` in `specs/CONFORMANCE.json` as a pending
  preliminary conformance anchor for the paid buyer-path #614 slice. The ID
  groups the existing v0.4 settlement-capable receipt issuance/ingestion
  obligations without changing them. Remaining SPEC-015 clause migration is
  issue #1023. No receipt tuple, wire, or verifier behavior change.

**Change log v0.4.2 (2026-06-30):**
- Round-2 code audit fix pass: pins v0.4 non-streaming and streaming
  `output_hash` to the same `settlement_output_v1` JCS object, and
  aligns `attempt_n` with the existing zero-based SPEC-002/SPEC-005
  request-attempt identity.

**Change log v0.4.1-draft (2026-06-30):**
- Round-1 SPEC audit fix pass: pins canonical `usage` schema,
  canonical route-snapshot object/digest input, receipt-key fingerprint
  algorithm, streaming output-prefix hashing/range rules, deterministic
  terminal-state chargeability, exact terminal timestamp authority, and
  v0.4 redaction compatibility for receipt-key rotation audit rows.

**Change log v0.4.0-draft (2026-06-30):**
- Adds §N, a settlement-capable receipt profile with
  `receipt_version: "4"`. v0.4 is the first SPEC-015 profile
  eligible to unblock SPEC-022 enforce mode.
- Extends the signed tuple from v0.3's nine-field model-hash
  tuple to a strict settlement tuple that binds account scope,
  request id, monotonic route-attempt id, provider id,
  provider receipt-key identity, non-null model hash, terminal
  state, terminal-state timestamp, route-time verification
  snapshot, catalog identity/body digest, expected catalog hash,
  prompt/output hashes, and canonical usage.
- Defines streaming receipt issuance through coordinator-internal
  channels that preserve OpenAI-compatible SSE framing: no extra
  non-standard `data:` receipt event is required for clients.
- Defines terminal states and chargeability mapping for
  `normal_done`, `provider_error`, `buyer_cancel`,
  `gateway_timeout`, and `upstream_transport_disconnect`.
- Adds settlement-verifier outcome mapping into SPEC-022
  `pending`, `verified`, `quarantined`, and `zero_settled`.
- Adds coordinator ingestion/storage rules for raw receipt
  segregation, audit redaction, idempotency, replay rejection,
  first-terminal selection, late receipt quarantine, and internal
  verification APIs.
- Keeps v0.1/v0.2/v0.3 verification semantics unchanged for
  historical receipts. v0.3 verifiers continue to classify
  `receipt_version: "4"` as `inconclusive:
  unknown_receipt_version`.

**Lock state v0.4:** Round-3 code audit returned `READY` on
2026-06-30 after round-2 closure fixes. Security round 2, architect
round 1, Claude adversarial round 1, and Claude product round 1 were
already `READY`. The required SPEC-015 v0.4 audit loop reached
0 CRITICAL / 0 HIGH / 0 MEDIUM across all required lanes; see
`specs/SPEC-015-v0-4-audit.md`. SPEC-022 enforce-mode buyer debit and
provider-positive settlement MUST NOT be wired against SPEC-015 v0.3
receipts.

**Change log v0.3.4 (2026-06-26, additive — issue #128):**
- §10.4.2 `warnings[]` enum gains `non_default_tls_trust` kind with
  `ca_file_path` (string) field. Verifiers MUST emit this warning
  when the `MACPROVIDER_VERIFY_TLS_CA_FILE` env var is honored and
  successfully augments the TLS trust pool — surfaces silent trust
  widening that previously produced a `valid` result with no
  visible indicator. Schema enum updated at
  `phase7-verify/schemas/output.schema.json` (all three result
  contexts). Preserves wire shape: pre-v0.3.4 consumers that ignore
  unknown `kind` values are unaffected; this is strictly additive.

**Lock state v0.3:** Round-3 codex audit returned `READY TO LOCK` across all three lenses (code, security, architect) on 2026-06-24 — see `specs/SPEC-015-v0-3-audit.md`. Three-round audit history captured 3 CRITICAL + 11 MAJOR + 4 MINOR + 1 QUESTION findings; all CRITICAL / MAJOR resolved across v0.3.1 (round-1 fix pass) and v0.3.2 (round-2 fix pass). One round-3 MINOR (stale "four new flags" wording in staged IMPL prompt) fixed in v0.3.3. v0.3 changes the wire shape (7-field tuple → 9-field tuple, adding `model_hash` and `receipt_version`) and per [[feedback-bundle-spec-impl-one-pr]] EXCEPTION rule ships SPEC-only (no bundled IMPL) because it is a major version bump with a downstream implementer; the BUILD prompt for IMPL is staged at `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md` for the next session.

**Lock state v0.2 (preserved for history):** Round-5 codex audit returned `READY TO LOCK` 0/0/0/0 across all three lenses (code, security, architect) on 2026-06-23 — see `specs/SPEC-015-v0-2-audit.md`. Five-round audit history captured 5 CRITICAL + 11 MAJOR + 6 MINOR findings, all resolved. CF6 confirmed round-1 CRITICALs (CF1 trust-root architecture, CF2 time-window validity, CF3 schema strictness) structurally closed, not papered over.

**Change log v0.3.3:**
- Round-3 codex audit returned `READY TO LOCK` across all three
  lenses on 2026-06-24 (CODE 0/0/0/0; SECURITY 0/0/0/0;
  ARCHITECT 0/0/1/0). One round-3 MINOR (A6-R3 — staged IMPL
  prompt had two stale "four new flags" mentions on top-level
  summary lines after round-2 promoted the verifier flag set
  to five) fixed in `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md`
  lines 29 and 286. SPEC text itself unchanged; v0.3.3 is the
  lock entry.
- Three-round audit history rollup:
  - Round 1: 3 CRITICAL + 9 MAJOR + 4 MINOR + 1 QUESTION
    (v0.3.0 → v0.3.1 fix pass)
  - Round 2: 0 CRITICAL + 2 MAJOR + 0 MINOR + 0 QUESTION
    (v0.3.1 → v0.3.2 fix pass)
  - Round 3: 0 CRITICAL + 0 MAJOR + 1 MINOR + 0 QUESTION
    (v0.3.2 → v0.3.3 lock)
- v0.3.3 LOCKED. Ships as the SPEC-only PR per the
  [[feedback-bundle-spec-impl-one-pr]] EXCEPTION rule for major
  version bumps with downstream implementers.

**Change log v0.3.2:**
- Round-2 codex audit fix pass against
  `specs/SPEC-015-v0-3-audit.md` round-2 sections. Round 2
  returned 0 CRITICAL + 2 MAJOR + 0 MINOR across the three
  lenses (SECURITY: READY TO LOCK 0/0/0/0; CODE: READY WITH
  FIX PASS, single MAJOR C9; ARCHITECT: READY WITH FIX PASS,
  single MAJOR A6). Both fixes applied:
  - **C9 (MAJOR — §M.4 `catalog_pubkey_url` field paragraph
    carried stale 44-char / lowercase wording):** the §M.4
    `catalog_pubkey_url` bullet was rewritten to match the
    detailed endpoint block — `{"pubkey": "<43-char
    base64url-unpadded ed25519 pubkey>", "alg": "Ed25519"}` —
    closing the interop split a coordinator implementer
    reading §M.4 top-down could have introduced.
  - **A6 (MAJOR — staged IMPL prompt still instructed pre-fix
    behaviour):**
    `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md`
    refreshed in three locations to match v0.3.1 controlling
    clauses: Step 2 `GET /catalog/pubkey` response shape now
    pins 43-char base64url-unpadded + `"Ed25519"` (closing C2);
    Step 4 catalog `Lookup` now applies `catalogModelKey`
    case-fold + trim transform (closing A1); Step 4 catalog
    `signature.alg` test now expects `"Ed25519"` capital E
    (closing C1); Step 5 CLI surface promoted to FIVE flags
    including `--require-model-hash` per §M.3.1.2 (closing
    S2); Step 5 result-schema fields point at §M.3.2.1
    (closing C4). The IMPL prompt now reflects the round-1 +
    round-2 controlling clauses end-to-end.

v0.3.2 is the round-3 LOCK candidate. If round 3 returns
0 CRITICAL / 0 MAJOR across all three lenses, v0.3.x ships into
the SPEC-only PR per [[feedback-bundle-spec-impl-one-pr]] major-
version-bump exception.

**Change log v0.3.1:**
- Round-1 codex audit fix pass against
  `specs/SPEC-015-v0-3-audit.md` round-1 sections. Round 1
  returned 3 CRITICAL + 9 MAJOR + 4 MINOR + 1 QUESTION; all
  three lenses verdict READY WITH FIX PASS. Findings resolved
  below.
  - **C1 (CRITICAL — `signature.alg` casing):** §M.3.2 step 4
    and §M.5 AC-35 now require `signature.alg = "Ed25519"`
    (capital E, matching the existing
    `scripts/sign-catalog.go:142-145` emitter and
    `phase4-coordinator/internal/tier2/catalog.go:470`
    validator). The v0.3.0 lowercase `"ed25519"` would have
    rejected every catalog the existing signer produces.
  - **C2 (CRITICAL — catalog pubkey encoding):** §M.3.1 flag
    table, §M.3.2 step 4, §M.4 `GET /catalog/pubkey` response,
    and §M.5 AC-32/AC-33/AC-37 all now require
    `base64.RawURLEncoding` (base64url-unpadded), exactly 43
    ASCII characters, NOT standard padded base64. This matches
    `scripts/sign-catalog.go:90,316-328` and SPEC-008 §5.2.1's
    locked Ed25519-pubkey encoding. v0.3.0's 44-char standard-
    padded encoding would have rejected every catalog pubkey
    produced by the existing tool.
  - **S1 (CRITICAL — AC-40 routing semantics):** AC-40
    rewritten so that with `RequireHashVerified: false`, the
    coordinator continues routing to providers whose hash status
    is `uncatalogued` OR `catalog_unavailable` only — NOT
    `hash_mismatch` or `hash_invalid`. SPEC-008 §5.6 (lines
    746-760) and `phase4-coordinator/internal/tier2/catalog.go:599-604`
    (`IsHashPredicateFailure`) make mismatch / invalid
    fail-closed at both flag settings; v0.3.0 AC-40's broader
    claim would have silently demanded a SPEC-008 amendment and
    contradicted Entry 80. v0.3 receipts still BIND whatever
    the provider reports; the AC-40 normative change is only
    about routing.
  - **C3 (MAJOR — §10.4.4 flag matrix not extended):** New
    §M.3.1.1 "v0.3 catalog flag matrix" sub-table covers every
    combination of `{--catalog, --catalog-url, --catalog-pubkey,
    --catalog-pubkey-url}` against
    `{--offline, --coordinator, --pubkey, --json, header+hashes
    mode, bundle mode, stdin mode}`. The matrix names the
    expected exit code or behavior for each combination.
    Pattern follows the v0.2.4 §10.4.4 `--provider-id` matrix.
  - **C4 (MAJOR — JSON schema amendment for v0.3):** New
    §M.3.2.1 "v0.3 result schema amendment" pins:
    `model_hash_verified` is a tri-state JSON field —
    `true` (catalog check ran AND hash matched), `false`
    (catalog check ran AND hash mismatched — this path also
    sets `result: "invalid"`), or `null` (catalog check did
    not run for any reason: no catalog flags, null hash,
    legacy receipt, unknown version, catalog fetch failed).
    The field is REQUIRED in all v0.3 JSON output (always
    present, never absent). `details` becomes legal on
    `inconclusive` results when the named §M reasons fire
    (`unknown_receipt_version` carries `details.receipt_version`;
    `model_id_not_in_catalog` carries `details.model_id`;
    `catalog_expired` carries `details.catalog_id` and
    `details.expires_at`). The v0.2.4 §10.4.2 "details only on
    invalid" rule is SUPERSEDED for these v0.3-named inconclusive
    cases ONLY; otherwise §10.4.2 remains authoritative.
  - **C5 (MAJOR — wrong `/poolz` top-level key):** §M.4
    example response key changed from the v0.3.0 fictitious
    `"providers": [...]` to the SPEC-002 v1.4 §FR-O2 actual
    `"pool": [...]` (and `"summary": {...}` preserved). The
    SPEC-002 v1.6 candidate annotation now adds ONLY the three
    catalog fields at top level, leaving every existing key
    byte-identical.
  - **C6 (MAJOR — AC-29 introspection command):** AC-29
    rewritten to use the heartbeat-reported hash route (the
    existing observability surface visible at Pearl journald
    `model_hash_verified` events; SPEC-011 §3.3.1 wire) rather
    than a non-existent `macprovider-cli models inspect`
    subcommand. v0.3 does NOT demand a new introspection
    CLI; if implementations want one for ergonomics, that's
    a future SPEC-001 extension, not a v0.3 prereq.
  - **S2 (MAJOR — null-hash buyer policy knob):** New
    §M.3.1.2 "Null-hash policy flag" introduces a v0.3 OPTIONAL
    CLI flag `--require-model-hash` (boolean) that lets a
    buyer fail-closed when the receipt's `model_hash` is JSON
    null AND catalog arguments were supplied. With the flag
    SET and a null-hash receipt: result becomes `invalid` with
    `reason: "model_hash_required"`; without the flag (default):
    result is `valid` per §M.2.3 + AC-32 with the
    `catalog_skipped_null_hash` warning. This preserves the
    "default warm-swap-disabled providers still verify clean"
    posture for backward compatibility but gives buyers a
    first-class fail-closed knob, eliminating the
    deployment-specific wrapper anti-pattern. AC-32a NEW
    captures the flag-set path.
  - **S3 (MAJOR — AC-42 mid-swap clause vs. §M.2.2 construction):**
    AC-42 rewritten to align with §M.2.2's construction proof.
    A normal in-flight request that began on the old container
    and finishes during `loading` / `draining` MUST still emit
    a receipt with the request-start hash per §M.2.2 (not a
    `receipt_omitted`). The `receipt_omitted:
    model_swap_violation` row fires ONLY in the defence-in-
    depth case where the runtime CANNOT identify the
    request-start container/hash — which under SPEC-011
    R-3.4.1 + R-3.2.2 is unreachable by construction in
    correct implementations. The AC test becomes "synthesized
    state where the request-start container is genuinely
    unknown" (a defensive harness, not a normal swap).
  - **A1 (MAJOR — catalog model_id case-folding divergence):**
    §M.3.2 step 6 rewritten. Catalog model_id lookup is
    case-folded (lowercase + trim whitespace) to match
    `phase4-coordinator/internal/tier2/catalog.go:559-560`
    `catalogModelKey` semantics. The buyer-side verifier MUST
    mirror the coordinator-side check, NOT diverge from it.
    v0.3.0's "case-sensitive" rule would have let a coordinator
    accept a model the verifier rejected, and vice versa.
  - **A2 + S4 (MAJOR + MINOR — `/poolz` catalog-field presence
    consistency):** §M.4 prose now matches AC-39: catalog
    fields appear iff (a) `Tier2Config.CatalogPath` is set
    AND (b) the catalog loaded cleanly AND (c) its signature
    verified. The "configured" wording is removed; all three
    presence conditions are pinned. `GET /catalog/<id>` and
    `GET /catalog/pubkey` return 404 when ANY of the three
    conditions fails. This is the single source of truth for
    the SPEC-002 v1.6 candidate absorption.
  - **A3 (MAJOR — staged IMPL prompt now exists):**
    `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md` was
    written in the same audit-loop session (v0.3.0 had it as a
    forward reference, v0.3.1 confirms it is staged). Lock-
    state language updated to reflect this.
  - **A4 (QUESTION — SPEC-011 header drift):** Acknowledged but
    out of scope for v0.3. SPEC-011 v0.5 status header polish
    is tracked separately; v0.3 cites SPEC-011 v0.5 per
    DECISION_CRITERIA Entry 55 which is authoritative.
  - **A5 (MINOR — stale §16.2 SPEC-011 reference):** Updated
    the inherited §16 SPEC-011 v0.5 §3.3.1 + §3.8 bullet to
    cite §3.2 (state machine), §3.3 (heartbeat), §3.4 (drain)
    — the sections v0.3 §M.2 actually rests on.
  - **C7 (MINOR — §3.4 v0.3 size projection):** v0.3 envelope
    recomputed including the signature segment:
    `<base64(JCS(T))>.<base64(SIG)>` = ~936 bytes (700-byte
    JCS, 4/3 base64) + 1 (`.`) + 88 (base64 of 64-byte sig) =
    ≤ ~1025 bytes. The 4096-byte nginx headroom requirement is
    unchanged.
  - **C8 (MINOR — cache TTL boundary language):** §M.3.4 now
    uses explicit interval notation for the three TTL bands:
    `[6h+1s, ∞)` → 6h cache; `[60s+1s, 6h]` → `expires_at -
    now() - 60s` cache; `(-∞, 60s]` (including catalogs
    accepted only via the §M.3.2 step 5 60s skew grace) →
    no cache.

v0.3.1 is the round-2 LOCK candidate. If round 2 returns
0 CRITICAL / 0 MAJOR across all three lenses, v0.3.x ships into
the SPEC-only PR per [[feedback-bundle-spec-impl-one-pr]] major-
version-bump exception.

**Change log v0.3.0:**
- **Receipt tuple wire shape changes: 7 fields → 9 fields.** v0.3
  extends the receipt tuple per the new §M.0 by adding two NEW
  fields. JCS canonical order (UTF-16 code-unit lexicographic per
  RFC 8785 §3.2.3) places them as:
  `model_hash`, `model_id`, `output_hash`, `prompt_hash`,
  `provider_pubkey`, `receipt_version`, `tokens_out`, `ttft_ms`,
  `unix_ts` — so the new fields land at index 0 and index 5 in
  the emitted byte order, not at "the end."
  - **`model_hash`** (string of 64 lowercase hex chars OR JSON
    null) — the provider's SHA-256 of the loaded MLX container
    at receipt-generation time, sourced from the SPEC-011 v0.5
    R-3.3.1 heartbeat state. Per §M.2 provenance, this is the
    post-swap in-memory container — what the buyer actually
    consumed. `null` is permitted for providers running default
    `--enable-warm-swap=false` (SPEC-011 R-3.3.0) and required
    in that mode per §M.2.3.
  - **`receipt_version`** (string, value `"3"` in this revision)
    — explicit wire-shape discriminant. v0.1/v0.2 receipts had no
    `receipt_version` field; v0.3 verifiers detect those as
    `receipt_version="1"` by absence per §M.1.1. String-typed
    (not int-typed) to avoid JSON-number canonicalization edge
    cases.
- **Forward/backward compatibility (NORMATIVE per §M.1).** v0.3
  verifiers MUST accept v0.1/v0.2 receipts (back-compat: report
  `valid` per the legacy §3.1 7-key path, skip catalog check).
  v0.1/v0.2 verifiers reading a v0.3 receipt MUST report
  `invalid` per their existing "EXACTLY these seven keys" rule —
  the locked v0.1.3 / v0.2.4 releases are not amended. v0.4+
  verifiers SHOULD report unknown `receipt_version` values as
  `inconclusive: unknown_receipt_version` per §M.1.4 so a future
  v0.4 receipt against a v0.3 verifier degrades to `inconclusive`
  rather than `invalid`.
- **New §M (top-level) "Model-hash binding (v0.3 NORMATIVE)"**
  inserted between §10 and §11, with six subsections:
  - §M.0 — v0.3 receipt tuple (the normative 9-key shape and
    JCS byte order)
  - §M.1 — Wire and version compatibility (back-compat,
    forward-incompat, unknown-version semantics, no `RFC8785JCS.swift`
    amendments)
  - §M.2 — `model_hash` provenance (heartbeat lag, mid-response
    swap REFUSED, absent-hash semantics for warm-swap-disabled
    providers)
  - §M.3 — Catalog-based verification (verify CLI extension: four
    new flags, the algorithm, trust-boundary update, cache TTL)
  - §M.4 — Coordinator `/poolz` extension (SPEC-002 v1.6
    candidate annotation — `catalog_id`, `catalog_url`,
    `catalog_pubkey_url`, `GET /catalog/<catalog_id>`,
    `GET /catalog/pubkey`)
  - §M.5 — Acceptance criteria (AC-28 through AC-42, extending
    the v0.1/v0.2 AC-1 through AC-27 set)
  - §M.6 — What v0.3 explicitly DOES NOT change (records
    `RequireHashVerified` Entry-80 orthogonality, streaming
    deferral, multi-hash receipts deferred to v0.4+, federation,
    on-chain anchoring, quantization, soft model identity, JCS
    amendments)
- **§3.1 update — wire shape pointer.** The v0.1.3 sentence "A
  receipt object MUST contain EXACTLY these seven keys" is
  RETAINED for v0.1/v0.2 receipts (in-the-wild back-compat) and
  is SUPERSEDED for v0.3 receipts by §M.0's normative nine-key
  shape. §3.1's field-table heading carries a pointer to §M.0.
- **§3.4 update — wire size envelope.** The v0.1.3 ≤ ~830-byte
  projection for the `X-MacProvider-Receipt` header is updated to
  account for the two new fields. v0.3 budget: `model_hash` adds
  ≤ 80 bytes (`"model_hash":"<64 hex>"`), `receipt_version` adds
  ≤ 22 bytes (`"receipt_version":"3"`). New `JCS(T)` ceiling is
  ≤ ~700 bytes; the header value after base64 expansion is
  ≤ ~960 ASCII bytes. The 4096-byte nginx headroom requirement
  is unchanged — v0.3 still fits comfortably.
- **§7.6 update — null-usage / error receipts.** Error receipts
  (e.g. `error_model_not_loaded`) MUST set `model_hash` per §M.2
  — i.e. the heartbeat-reported hash for the loaded container at
  the time the error fired. The error did not invalidate the
  in-memory container; the buyer is still entitled to know which
  weights the provider had warm. v0.1.3 AC-12 is preserved
  unchanged for the v0.1/v0.2 wire shape; new AC-31 pins the
  v0.3 wire shape.
- **§10 update — verify CLI extension.** §10.4 gains four CLI
  flags (`--catalog <path>`, `--catalog-pubkey <base64>`,
  `--catalog-pubkey-url <url>`, `--catalog-url <url>`); §10.4.2
  result schema gains `model_hash_verified` (bool, present iff
  catalog was provided AND receipt `model_hash` was non-null)
  and the `reason` enum gains `model_hash_mismatch`,
  `model_id_not_in_catalog`, `catalog_signature_invalid`,
  `catalog_unreachable`, `catalog_expired`, `catalog_format_invalid`,
  `unknown_receipt_version`, `extra_field` (for v0.1/v0.2 verifiers
  rejecting v0.3 receipts and for v0.3 verifiers rejecting receipts
  whose `receipt_version: "3"` tuple has missing/extra keys);
  §10.4.3 exit-code table is UNCHANGED (0/1/2/64/65). §10.4.4
  flag-interaction matrix gains rows for the four new flags and
  their mutual-exclusivity rules per §M.3.1.
- **§10.6 trust boundary update — supersession.** The v0.2 §10.6
  "DOES NOT prove that the response was generated by the model
  named in `model_id`" bullet is SUPERSEDED for v0.3 `valid`
  results that carry non-null `model_hash` AND were verified with
  a fresh, signature-valid, non-expired catalog. The remaining
  v0.2 §10.6 disclaimers (timestamp honesty, no-other-observer,
  pubkey-trust-root operator-mutability, no-buyer-correlator,
  no-uniqueness) are PRESERVED. §M.3.3 is the v0.3 trust-boundary
  authority for valid-with-catalog; §10.6 remains authoritative
  for valid-without-catalog (v0.1/v0.2 receipts; v0.3 receipts
  with null hash or no-catalog invocation).
- **§11 update — audit categories.** The `receipt_omitted`
  `reason` enum gains `model_swap_violation` as a v0.3-specific
  defined case (a swap was in progress at receipt-time per
  §M.2.2; the receipt was refused). v0.1/v0.2 §11 already
  listed this string as a placeholder; v0.3 promotes it from
  placeholder to defined semantics.
- **§15 Q6 update — RESOLVED.** v0.1.3 / v0.2 §15 Q6 (model-hash
  binding as a SPEC-011 cross-cut, gated on catalog-signing
  readiness) is closed by §M. The Q6 paragraph is REWRITTEN to
  point at §M and to note explicitly that `RequireHashVerified`
  enforcement at the coordinator is ORTHOGONAL to v0.3 and
  unchanged per `beta/DECISION_CRITERIA.md` Entry 80
  (2026-06-22). New **§15 Q7** captures the deferred question of
  multi-hash receipts (i.e. a single receipt binding two model
  hashes for a swap-spanning streaming response); v0.3 §M.2.2
  forbids the shape, v0.4+ may design it.
- **§16 update — references.** New cites for
  `scripts/sign-catalog.go`,
  `phase4-coordinator/internal/tier2/catalog.go`,
  `phase4-coordinator/internal/config/config.go:142,335`
  (`RequireHashVerified` default flag),
  `beta/DECISION_CRITERIA.md` Entry 80, SPEC-008 v0.3 §5.3-5.6
  Pillar A semantics, SPEC-010 v1.5
  `supported_models[]` / `publishes_supported_models`, SPEC-011
  v0.5 §3.3 heartbeat extension + §3.2 warm-swap state machine.
- **Depends-on line 4 update — SPEC-011 v0.5 promotion to HARD
  dependency.** v0.1/v0.2 referenced SPEC-011 v0.5 only for §7.4
  (drain semantics during reconnect-based rotation). v0.3
  promotes SPEC-011 v0.5 to a HARD dependency for receipt
  issuance because the receipt now reads `model_hash` from the
  provider's local SPEC-011 R-3.3.1 hash-tracking state.
  SPEC-008 v0.3 §5.3-5.6 is similarly promoted to HARD because
  the verifier's catalog-check path consumes a SPEC-008-compatible
  signed catalog. SPEC-010 v1.5 (`supported_models[]`) is added
  as a SOFT dependency (informs which providers participate in
  hash attestation; orthogonal to receipt issuance per §M.2.3).
- **Live infrastructure citation.** As of 2026-06-24 the
  coordinator at `coordinator.malibu.tech` runs SPEC-011 v0.5
  observation mode against catalog
  `macprovider-tier2-model-catalog-2026-05-31`; Pearl journald
  shows 342+ `model_hash_verified` events over the last 7 days
  for air5, all `decision:"allow", reason:"hash_match"`. v0.3
  composes on that production infrastructure rather than
  introducing it. Reproduction command in `specs/BUILD_SPEC_015_RECEIPTS_v0_3_MODELHASH_PROMPT.md` §"Files you should read".

v0.3.0 is the LOCK CANDIDATE. Codex audit rounds pending. On a
clean 0-CRITICAL / 0-MAJOR round across all three lenses, v0.3.x
ships as the SPEC-only PR; IMPL follows in a separate PR per the
[[feedback-bundle-spec-impl-one-pr]] EXCEPTION rule for major
version bumps with downstream implementers.

**Change log v0.2.4:**
- Round-4 codex audit fix pass (round 4 verdicts: security
  **READY TO LOCK** maintained; code + architect READY WITH FIX
  PASS, single convergent finding **CF8** flagging two
  stale-wording spots that v0.2.3 missed when adopting the
  strict-CLI contract):
  - **CF8 / C13 / A10 (stale provider-id wording in §10.4.1
    bundle field description and §10.1 HTTP 404 reason):**
    - §10.4.1 `provider_id` field description rewritten to
      align with the §10.4 "Provider-id requirements" strict
      contract — absent bundle `provider_id` falls back to
      `--provider-id` then single-match cache; if neither yields
      a value AND no `--pubkey` is supplied, exit `64` (not
      `inconclusive`). The "MAY produce `inconclusive` if no
      other identification path applies" phrasing is REMOVED.
    - §10.1 HTTP 404 paragraph updated to use `reason:
      "provider_id_not_in_pool"` per the §10.4.2 enum, not the
      now-warning-only `provider_id_unresolvable`.
- All three codex lenses now project to READY TO LOCK on round 5.
  v0.2.4 ships into the combined SPEC + IMPL PR per the
  [[feedback-bundle-spec-impl-one-pr]] convention if round 5
  confirms 0 CRITICAL / 0 MAJOR across all lenses.

**Change log v0.2.3:**
- Round-3 codex audit fix pass against
  `specs/SPEC-015-v0-2-audit.md` round-3 sections (round 3:
  security lens **READY TO LOCK** 0/0/0/0; code + architect
  READY WITH FIX PASS with 3 MAJOR + 1 MINOR converging on a
  single root cause CF7). Findings resolved:
  - **CF7 / C10 / A9 (provider-id absence is BOTH a usage error
    AND an inconclusive result — internal contradiction):** §10.4
    normalized around the strict CLI contract (Option A from the
    round-3 reading). Missing `--provider-id` in header+hashes
    mode without `--pubkey` is now exit code `64` (usage error)
    everywhere — at §10.4 input shapes, §10.4 "Provider-id
    requirements", §10.4.4 flag matrix, and the §10.4.3 exit-code
    table. The `inconclusive` matrix row for that combination is
    replaced with USAGE ERROR. Rationale: the verifier was
    misinvoked (missing essential argument), not failed at
    runtime; this matches the convention for missing `--receipt`
    / `--bundle`. `inconclusive` remains reserved for trust-root
    failures the verifier discovered during execution.
  - **C11 (`live_check_skipped.reason` enum incomplete):** the
    enum in §10.4.2 is extended with `provider_id_unresolvable`
    — emitted when explicit `--pubkey` was supplied AND no
    provider id is recoverable (the verifier can produce `valid`
    against the explicit key but the live divergence check is
    skipped because the resolver cannot be addressed). The
    enum is now `offline_flag` / `network_unreachable` /
    `provider_id_unresolvable`.
  - **C12 (§10.0 algorithm step 5 still pubkey-byte-oriented):**
    §10.0 step 5 rewritten to read "Resolve the trusted pubkey
    for the resolved `provider_id` per §10.2" instead of "for the
    receipt's provider_pubkey bytes." Aligns the algorithm summary
    with the §10.2 no-scan rule.

v0.2.3 is the LOCK candidate. Round 4 pending — target READY TO
LOCK across all three lenses (security is already there). On
clean round 4, v0.2 locks and bundles into the combined SPEC +
IMPL PR per [[feedback-bundle-spec-impl-one-pr]].

**Change log v0.2.2:**
- Round-2 codex audit fix pass against
  `specs/SPEC-015-v0-2-audit.md` round-2 sections (round 2 = 0
  CRITICAL, 4 MAJOR, 3 MINOR across code/security/architect
  lenses; verdict READY WITH FIX PASS on every lens). Findings
  resolved:
  - **CF4 / C7 / S6 (stale `/poolz` wording in §10.1 + AC-18;
    §10.1 ↔ §10.2.1 no-match semantics conflict):** §10.1
    rewritten to (a) eliminate `/poolz` references, (b) reserve
    `inconclusive` for fetch failure / provider_id unresolvable /
    no authoritative resolver answer, and (c) require `invalid`
    when the resolver returns an authoritative provider record
    whose current/previous keys do not match the receipt's
    `provider_pubkey`. AC-18 rewritten to reference
    `/v1/receipt-keys/<provider_id>` and the §10.2.1 grace-window
    semantics.
  - **CF5 / C8 / A7 (`--provider-id` is load-bearing but not
    first-class CLI input):** §10.4 expanded to make
    `--provider-id <id>` a first-class CLI input across all three
    input modes (header+hashes, bundle, stdin). §10.4.4 flag
    matrix gains explicit `--provider-id` rows covering required-
    vs-optional disposition per mode. §10.2 rule on no-provider-id
    `inconclusive` reframed as a normative escape hatch rather
    than an under-specified edge case.
  - **C9 (timestamp format split between Unix seconds and
    RFC3339):** §10.2 cache fields normalized — `fetched_at`,
    `rotated_at`, `expires_at` are stored as RFC3339 UTC strings
    in the cache to match the §10.7 wire shape. The receipt
    `unix_ts` remains Unix seconds (v0.1 wire contract — locked).
    Conversion happens once at the cache-write boundary.
  - **S7 (positive trust-boundary sentence reads like timestamp
    attestation):** §10.6 opening sentence reworded from "signed
    this tuple at the claimed `unix_ts`" to "signed a tuple
    containing the claimed `unix_ts`" to eliminate the
    quotability-out-of-context risk.
  - **A8 (`valid` does not disclaim receipt uniqueness):** §10.6
    "DOES NOT prove" list extended with a sixth bullet — `valid`
    does not prove that no other receipt was issued for the same
    response, or that this was the only provider-side attestation.
    Locks the surface against the same "narrow proof" misreading
    the §10.6 audit surfaces in round 1.

v0.2.2 is the LOCK candidate. If round 3 returns 0 CRITICAL / 0
MAJOR across all three lenses, v0.2.2 ships into the combined
SPEC + IMPL PR per the [[feedback-bundle-spec-impl-one-pr]]
convention.

**Change log v0.2.1:**
- Round-1 codex audit fix pass against
  `specs/SPEC-015-v0-2-audit.md` (round 1 = 6 CRITICAL, 8 MAJOR,
  3 MINOR across code/security/architect lenses; verdict DESIGN
  ROUND NEEDED). Findings resolved:
  - **CF1 / S1 / A1 / C2 (live `/poolz` is operator-only — buyer
    cannot use it as default trust root):** SPEC-015 v0.2.1
    introduces a **SPEC-002 v1.5 candidate annotation** for
    `GET /v1/receipt-keys/<provider_id>` — a public,
    unauthenticated, rate-limited endpoint exposing ONLY the
    receipt-key tuple `(provider_id, receipt_pubkey,
    receipt_pubkey_prev, rotated_at, expires_at)`. §10.2 rewritten
    to make this the default live source instead of operator-only
    `/poolz`. The new endpoint is pinned in §10.7 as a candidate
    annotation following the same parser-optional / additive /
    non-breaking pattern v0.1's three candidates used.
  - **CF2 / S2 (grace-window check missing on
    `receipt_pubkey_prev`):** §10.2.1 rewritten to require the
    receipt `unix_ts` to fall within `[rotated_at - 60s,
    expires_at]` — matching v0.1 AC-11's pre-existing invariant.
    A previous-key match outside the grace window is now `invalid`,
    not `valid`.
  - **CF2 / S3 (stale-cache fallback validates retired keys via
    provider-reported `unix_ts`):** §10.2 stale-cache rule
    rewritten. A stale entry (older than the 7-day TTL) MUST NOT
    produce `valid` — the result is `inconclusive` regardless of
    receipt `unix_ts`. The provider-reported timestamp is no longer
    load-bearing for trust-root validity per §10.6's existing
    posture that timestamp honesty is not proven.
  - **CF3 / C1 / A2 (bundle mode rejects ordinary OpenAI
    captures):** §10.4.1 rewritten to require `request` as the raw
    OpenAI request body as captured by the buyer. Absent §4.2
    optional fields canonicalize as JSON `null` per the locked
    v0.1 §4.2 rule. The "16-field minimum" requirement is
    REMOVED.
  - **C4 (`bundle_version` exit-code contradiction):** §10.4.1 +
    §10.4.3 + AC-25 now agree: unsupported `bundle_version` →
    exit `65` (input format error). §10.4.1 wording corrected.
  - **C3 (JSON output schema is examples, not contract):**
    §10.4.2 now pins a normative field table covering `valid`,
    `invalid`, and `inconclusive`, with required/optional
    disposition, enum values for `result`, `reason`, `details.field`,
    and `trust_source`, and a normative `warnings[]` array for
    explicit-vs-live divergence and non-default-coordinator signals.
  - **C5 (flag interaction matrix under-specified):** new §10.4.4
    pins a flag-interaction matrix covering `--offline`,
    `--quiet`, `--pubkey`, `--coordinator`, `--json`, `--explain`,
    `MACPROVIDER_COORDINATOR`.
  - **S4 (non-default coordinator trust hidden):** §10.4.2
    `trust_source` enum now carries a `coordinator_host` companion
    field whenever the source is live or cache-derived. JSON output
    includes the host explicitly.
  - **S5 (divergence warnings can disappear under `--quiet`):**
    §10.2 + §10.4.2 now require the explicit-vs-live divergence
    check to happen in ALL modes (including `--quiet`) and to be
    recorded in the JSON `warnings[]` array; `--quiet` suppresses
    only stderr emission, not the warning record itself.
  - **C6 (bundle `receipt` placeholder mislabeled):** §10.4.1
    example string corrected to reflect the
    `<base64(JCS(T))>.<base64(SIG)>` wire shape.
  - **A3 (per-provider `/poolz` variant undefined):** removed from
    §10.2; the new `/v1/receipt-keys/<provider_id>` endpoint
    replaces it.
  - **A4 (cache keys lose provider identity):** §10.2 cache now
    keyed by `(coordinator_host, provider_id, receipt_pubkey)`,
    not bare pubkey bytes.
  - **A5 (dep header candidate-only wording):** line 4 deps
    updated to reflect SPEC-002 v1.4 and SPEC-006 v0.9 absorbed
    locked status; new SPEC-002 v1.5 candidate annotation called
    out explicitly.
  - **A6 (AC-24 leaks "IMPL repo" boundary):** AC-24 rephrased to
    name the verifier implementation test suite and release
    artifacts, leaving repository layout to the BUILD prompt.

**Change log v0.2.0:**
- Promotes §10 from "informative; v0.2 normative" to NORMATIVE and
  expands it into six subsections covering the buyer-side
  `macprovider-verify` CLI contract.
  - **§10.1 Result semantics:** pins a three-valued result
    (`valid` / `invalid` / `inconclusive`). `inconclusive` is a
    first-class result; a verifier that collapses it into either
    of the others is non-conforming.
  - **§10.2 Pubkey resolution:** priority-ordered sources
    (explicit `--pubkey` → local cache → `/poolz`), 7-day cache TTL
    matching §7.5.2 rotation grace, explicit-vs-live divergence
    warning, and §10.2.1 rotation-grace behavior covering
    `receipt_pubkey_prev`.
  - **§10.3 Canonicalization parity:** bit-identical to the §3.2 /
    §4 / §5 provider-side rules; explicitly forbids a "lenient"
    verifier mode; mandates a Swift↔Go JCS parity CI gate.
  - **§10.4 Inputs, outputs, exit codes:** header+hashes / bundle /
    stdin input modes; bundle JSON shape pinned in §10.4.1
    (strict-mode rejection of unknown keys, `bundle_version` for
    future evolution); JSON-mode output schema in §10.4.2; exit
    codes 0/1/2/64/65 in §10.4.3 (per `sysexits.h`).
  - **§10.5 Network behavior:** verifier MUST NOT make any network
    call beyond `/poolz`; no telemetry / no analytics / no
    version-check beacon; single GET, 5-second timeout, no retries,
    no redirects beyond operator-named coordinator host.
  - **§10.6 Trust boundary:** uncompromising statement of what
    `valid` does and does not prove. Specifically: NOT model
    attestation (SPEC-011 / v0.3+), NOT timestamp honesty
    (Q4 / v0.3+), NOT privacy properties (SPEC-008), NOT pubkey
    trustworthiness (Q1 / v0.3+). Recommends `--explain` flag
    that prints §10.6 verbatim after a `valid` result.
- Extends §14 acceptance criteria with **AC-18 through AC-27**
  covering: `valid` path on fresh receipts, three tamper-detection
  `invalid` paths (output / prompt / timestamp), `inconclusive` on
  `/poolz` unreachable, offline `--pubkey` path with zero network,
  JSON-mode schema conformance, exit-code reachability, cache-TTL
  refresh, and rotation-grace `receipt_pubkey_prev` acceptance.
- Updates §15 Q4 (timestamp trust): partially addressed by §10.6
  (out of scope for `valid` result); full normative skew-check
  remains v0.3+ candidate.
- v0.1.x §§1-9, §11-13, §14 AC-1..AC-17, §16 README compatibility
  table are UNCHANGED. v0.1.3 issuance contract is preserved
  bit-identically. v0.2 adds the verifier contract on top.

**Change log v0.1.3:**
- Round-3 codex audit fix pass against `specs/SPEC-015-audit.md`
  (round 3 = 0 CRITICAL, 1 MAJOR, 3 MINOR; verdict READY WITH FIX
  PASS). Findings resolved:
  - **M1 (residual streaming normative clauses):** §5.2, §5.3, §5.4
    streaming/cancellation paragraphs and §12 streaming rows are
    now explicitly informative forward-compatibility guidance for
    v0.2+; v0.1.x emits NO receipt on any streaming path
    (regardless of finish_reason). Buyer-disconnect post-completion
    on a non-streaming response continues to receive a receipt
    with normal `finish_reason=stop` semantics — that is not a
    streaming case.
  - **m1 (§8.1 "one new field"):** corrected to "two new fields"
    matching §1.3.
  - **m2 (AC-11 stale "control frame" wording):** rewritten to
    reference reconnect-based rotation acceptance.
  - **m3 (v0.1.1 labels in v0.1.2 prose):** replaced with v0.1.3
    where the clause describes the current contract; v0.1 / v0.1.1
    / v0.1.2 retained only inside changelog and historical-design
    discussion.

**Change log v0.1.2:**
- Round-2 codex audit fix pass against `specs/SPEC-015-audit.md`
  (4 CRITICAL, 4 MAJOR, 2 MINOR; verdict DESIGN ROUND NEEDED).
  Findings resolved:
  - **C1 (`X-MacProvider-Receipt-Pending` unauthorized 2nd X-MacProvider-*
    header):** The pending correlator header is REMOVED. v0.1.2 adds
    exactly ONE buyer-visible response header
    (`X-MacProvider-Receipt`) as the only SPEC-006 v0.9 candidate
    allowlist addition. §6.3 rewritten to be silent on the wire side
    for streaming.
  - **C2 (rotation control frame outside SPEC-001 candidate):**
    The `provider_receipt_public_key_rotate` WS control frame is
    REMOVED. v0.1.2 rotation is via reconnect: the binary closes the
    current WS, generates a fresh keypair, reconnects with the new
    `provider_receipt_public_key` in the existing v2 `auth_request`
    initial-stage frame. The coordinator infers rotation by
    comparing the new pubkey against the previously-known one for
    this `provider_id`. §7.5 rewritten; §7.5.1 (rotate frame schema)
    deleted.
  - **C3 (streaming deferral drifts from BUILD prompt):** v0.1.2
    explicitly narrows the SPEC-015 v0.1.x mission to
    **non-streaming responses only**. Streaming receipts are NOT in
    v0.1.x; they are v0.2+ scope with explicit READMe/mission
    truth-in-advertising guidance. The BUILD prompt's "MUST be
    present, but where" question is answered as "not present in
    v0.1.x; v0.2+ design". §1.1, §1.2, §6, §15 Q5 rewritten.
  - **C4 (contradictory retention MUST/SHOULD):** The §6.3 SHOULD
    permitting bounded server-side retention is REMOVED. v0.1.2
    pins server-side receipt-body persistence as PROHIBITED. A v0.2+
    streaming-receipt design will name its own retention contract
    or use buyer-held-only delivery.
  - **M1 (`/poolz` candidate field count):** §1.3 now explicitly
    names the two SPEC-002 v1.4 candidate fields:
    `receipt_pubkey` and `receipt_pubkey_prev`.
  - **M2 (AC-9 non-executable):** AC-9 dropped from the normative
    list; the byte-equivalence invariant moves to §5.5 informative.
    ACs renumbered 1–17.
  - **M3 (`model_id` verbatim + NFC):** `model_id` is now pinned as
    ASCII-only per SPEC-001 v1.5 §6.4 (which is already
    ASCII-oriented), so NFC normalization is a no-op for
    `model_id`. NFC normalization applies only to natural-language
    strings in messages/output. §3.1, §3.2, §4.2 wording aligned.
  - **M4 (rotation Keychain write race):** v0.1.2 rotation writes
    the new key to Keychain only AFTER coordinator acceptance via
    successful reconnect auth. If the reconnect fails, the binary
    keeps the previous key active. §7.5 rewritten.
  - **m1 (v0.1 changelog mentions SSE):** added a parenthetical
    note on the v0.1 change-log entry that v0.1.1+ supersedes the
    SSE delivery design.
  - **m2 (SPEC-011 §3.8 citation):** corrected to SPEC-011 v0.5
    R-3.8.3 drain semantics.

**Change log v0.1.1:**
- Round-1 codex audit fix pass against `specs/SPEC-015-audit.md`
  (3 CRITICAL, 8 MAJOR, 4 MINOR, 2 QUESTIONS). Findings resolved:
  - **C1 (streaming SDK incompat):** Streaming receipt delivery is
    deferred to v0.x pending a verified OpenAI-SDK-compatible
    encoding. v0.1.1 emits `X-MacProvider-Receipt` on non-streaming
    responses ONLY. Streaming responses are accompanied by a
    `X-MacProvider-Receipt-Pending: <request_id>` response header for
    forward compatibility; the receipt body itself is NOT included in
    the SSE stream in v0.1.1. §6.3 rewritten; §15 Q5 expanded.
  - **C2 (proof-stage auth_request scope):** `provider_receipt_public_key`
    is restricted to the SPEC-001 v1.5 §6.7.1 initial-stage frame
    only. The proof-stage echo is dropped. §7.2 rewritten.
  - **C3 (coordinator ALTER TABLE):** v0.1.1 no longer prescribes
    SPEC-002 storage mechanics. The coordinator MUST surface the
    pubkey on `/poolz` (SPEC-002 v1.4 candidate, unchanged); the
    durable-storage mechanism is named by the future BUILD spec, not
    pinned here. §7.3 and §13 rewritten.
  - **M1 / q2 (prompt-hash field coverage):** the prompt canonical
    object expands from 10 to 16 keys, adding `presence_penalty`,
    `frequency_penalty`, `logit_bias`, `logprobs`, `top_logprobs`,
    `n`. §4.2 updated.
  - **M2 (JCS reuse mismatch):** v0.1.1 names two required additive
    extensions to `RFC8785JCS.swift` — RFC 8785 §3.2.2.3 float
    handling and an explicit NFC normalization step on string inputs.
    §3.2 rewritten.
  - **M3 (grace window mixed time+count):** v0.1.1 uses a single
    7-day time-based grace window; the request-count threshold is
    dropped. §7.5.2, AC-12 updated.
  - **M4 (AC-R8 byte-identity impossible):** AC-8 now requires the
    streaming response carries a pending request_id correlator, not
    byte-identity. AC-9 unchanged on `output_hash`.
  - **M5 (Keychain race):** §7.1 now requires atomic insert-or-load
    on `errSecDuplicateItem`.
  - **M6 (audit event field-list contradiction):** §11 names exact
    four fields once.
  - **M7 (CLI name drift):** the manual rotation flag is now
    `macprovider rotate-key`, matching the BUILD prompt.
  - **M8 (README schema divergence not explained):** new §16.1
    compatibility table.
  - **m1 (RFC 8895):** corrected to WHATWG HTML SSE.
  - **m2 (AC numbering):** AC-R1..R18 → AC-1..18.
  - **m3 (model_id wording):** clarified case-insensitive match,
    verbatim storage.
  - **m4 (README line range):** corrected to 117–128.
  - **q1 (provider_id in tuple):** RESOLVED. Provider identity in
    the receipt is the pubkey itself; `provider_id` remains
    out-of-band via `/poolz`. Rationale added to §3.1.

**Change log v0.1 (historical; SSE delivery design + AC numbering
superseded by v0.1.1/v0.1.2):**
- Initial draft following the design rationale captured in §2.
- Defines the per-response signed receipt: a base64 ed25519 signature
  over a JCS-canonicalized seven-field tuple (`model_id`, `prompt_hash`,
  `output_hash`, `provider_pubkey`, `ttft_ms`, `tokens_out`, `unix_ts`).
- Specifies prompt and output canonicalization, the
  `X-MacProvider-Receipt` wire header for both non-streaming and SSE
  responses, the provider ed25519 keypair lifecycle (Keychain storage,
  publication on the v2 `auth_request` initial-stage frame, manual
  rotation with a grace window), and the v0.1 pubkey trust root
  (`/poolz`).
- Defers model-hash binding to SPEC-011's domain (v0.3+ in this SPEC),
  buyer verification CLI to v0.2, on-chain anchoring outside scope,
  request_id replay binding to Open Q2, and cross-segment route binding
  to Open Q3.
- Acceptance criteria AC-1 through AC-18 are deterministic and
  implementer-verifiable.

---

## Preliminary conformance unit IDs

SPEC-015 v0.4.5 registers `SPEC-015-R001`..`SPEC-015-R005` in
`specs/CONFORMANCE.json`. R001 remains the v0.4 settlement-capable
issuance/ingestion unit. R002–R005 group additional existing obligation
areas without changing them:

- `SPEC-015-R001` — v0.4 settlement-capable receipt issuance and ingestion
  (§N).
- `SPEC-015-R002` — historical v0.1–v0.3 verification and forward-incompat
  with v0.4 (§10, §M).
- `SPEC-015-R003` — provider receipt-key lifecycle and buyer-safe pubkey
  resolver (§7).
- `SPEC-015-R004` — pubkey trust root (§8).
- `SPEC-015-R005` — coordinator receipt storage, ingest idempotency, and
  audit redaction (§13, §N). Buyer retrieval remains SPEC-022-R006.

`requirement_id_migration` remains `pending` until issue #1023 closes.
These IDs are not promoted from this registration.

## 0. Operator-paste invocation block

```
Implement SPEC-015 v0.1. As you work, maintain a running
phase3-binary/implementation-notes.html and (when coordinator/gateway
work begins) phase4-coordinator/implementation-notes.html and
phase5-gateway/implementation-notes.html that capture anything I
should know about how the implementation diverges from or interprets
the spec:

- Design decisions: choices made where the spec was ambiguous
- Deviations: places where you intentionally departed from the spec, and why
- Tradeoffs: alternatives considered and why you picked what you did
- Open questions: anything you'd want me to confirm or revise
```

---

## 1. Scope and mission

SPEC-015 defines **per-response signed receipts** for MacProvider
inference: a small, transport-attached, offline-verifiable proof that
binds the response a buyer received to the provider that produced it,
the prompt that requested it, and a small set of provider-reported
quality signals.

This is the v0.1 normative floor. It pins:

- The receipt tuple and its canonical encoding.
- The signature algorithm.
- The wire transport (HTTP response header on non-streaming
  responses only; streaming responses carry no v0.1.x receipt — see
  §6.3).
- The provider keypair lifecycle (generation, storage, publication,
  manual rotation).
- The v0.1 pubkey trust root.
- Behavior on receipt-issuance failure.

The `README.md` line 22 ("Every response will carry a signed receipt
binding (prompt, output, provider) — verifiable inference, without a
datacenter (planned, not yet implemented)") and the §"Roadmap"
schema block at `README.md:117-128` describe the product surface. As
of v0.1 LOCK, `grep -r receipt phase3-binary phase4-coordinator
phase5-gateway` returns zero implementation; this SPEC is the
contract that closes that gap.

### 1.1 In scope (v0.1.x)

v0.1.x covers **non-streaming chat completions only**. Streaming is
out of scope for v0.1.x; see §1.2 and §15 Q5 for the deferral.

- The receipt tuple and JCS canonical encoding.
- ed25519 signature algorithm and base64 encoding.
- Prompt canonicalization rules.
- Output canonicalization rules (for non-streaming responses; the
  byte-equivalence invariant in §5.5 is forward-compatibility
  guidance for the v0.2+ streaming design but is not testable in
  v0.1.x).
- Tool-call commitment inside `output_hash`.
- The `X-MacProvider-Receipt` HTTP response header value format.
- Receipt-emission preconditions and the explicit omission cases
  (non-streaming responses only).
- Provider keypair generation, macOS Keychain storage, and publication
  on the SPEC-001 v2 `auth_request` initial-stage frame via a new
  parser-optional `provider_receipt_public_key` field annotated as a
  SPEC-001 v1.6 candidate extension.
- Manual key rotation (`macprovider rotate-key`) performed via WS
  reconnect — no new control frames; the rotated pubkey is
  republished on the next `auth_request` initial-stage frame using
  the existing single-field SPEC-001 v1.6 candidate.
- Pubkey trust root: the coordinator's `/poolz` JSON gains exactly
  two per-provider fields: `receipt_pubkey` (current) and
  `receipt_pubkey_prev` (previous, populated for 7 days after
  rotation). This is the SPEC-002 v1.4 candidate annotation.
- Acceptance criteria implementers can mechanically verify.

### 1.2 Out of scope for v0.1.x

SPEC-015 v0.1.x does NOT specify:

- **Streaming chat completions.** Streaming `POST /v1/chat/completions`
  responses do NOT carry receipts in v0.1.x. The round-1 audit C1 + the
  round-2 audit C1/C3 surfaced that the OpenAI Python and JavaScript
  SDKs JSON-parse every non-`[DONE]` SSE `data:` payload and that
  v0.1's proposed terminal `event: receipt` block would raise on a
  base64 receipt string. v0.1.2 chose to narrow the v0.1.x mission
  to non-streaming receipts rather than introduce a second
  buyer-visible header (which would itself exceed the SPEC-006 v0.9
  candidate scope). Streaming receipts are v0.2+; the design space
  is summarized in §15 Q5. README and operator-facing copy MUST be
  honest that v0.1.x receipts only cover non-streaming requests.
- **Buyer verification CLI.** `macprovider verify <receipt.json>` is a
  separate work item tracked as v0.2. v0.1 issues receipts; v0.2
  verifies them. State of v0.2: not started; this SPEC will bump to
  v0.2 with the verifier surface once that work begins.
- **Model-hash binding.** Whether the receipt commits to which
  *weights* ran (sha256 of the loaded model) is SPEC-011's territory.
  SPEC-011 v0.5 §3.3.1 already specifies provider-reported
  `heartbeat.model_hash` (raw 64-character lowercase hex). Folding
  that into the receipt tuple — so a buyer can verify "which weights
  served me" — is deferred to SPEC-015 v0.3+ contingent on
  SPEC-011's catalog-signing posture (operator decision per
  `beta/DECISION_CRITERIA.md` Entry 80, Q3 tier-2 posture). v0.1
  binds *which name was requested* and *what content was produced*,
  not which weights served it.
- **On-chain anchoring.** Periodic Merkle roots of issued receipts
  posted anywhere durable (chain, AntFeed, ENS-published manifest) are
  gated on a Cluster D-tokens go/no-go decision the operator has not
  made. v0.1 says nothing about it.
- **Request-id binding for replay-style verification.** Whether the
  receipt commits to a `request_id` and where the buyer would obtain
  its expected `request_id` is unresolved in v0.1.x through v0.3.
  v0.4 resolves settlement replay binding in §N.1 and §N.3. See
  §15 Q2.
- **Multi-segment route binding.** Once Cluster F sharding lands a
  single response may have multiple provider segments; receipt-per-
  segment vs receipt-per-response with embedded route list is
  unresolved. See §15 Q3. v0.1 assumes one provider per response.
- **TUF-style trust-root signing of `/poolz`.** v0.1 acknowledges the
  trust root is operator-mutable (the coordinator publishes the
  pubkey list); strengthening it is v0.3+. See §15 Q1.

### 1.3 Relationship to locked specs

SPEC-001 v1.5 remains the authoritative provider binary and provider
WebSocket protocol. SPEC-015 v0.1 **MUST NOT** edit SPEC-001 v1.5
text; it ANNOTATES one additive, parser-optional field
(`provider_receipt_public_key`) on the v2 `auth_request` initial-stage
frame, marked here as a SPEC-001 v1.6 candidate extension. Until that
candidate field lands in SPEC-001 the field MUST NOT appear on the
wire from a v1.5 binary; the receipt-issuing path on the provider
side is enabled only by a binary at SPEC-001 v1.6 or later. This
mirrors SPEC-008's SPEC-001 v2.0 annotation pattern.

SPEC-002 v1.3.5 remains the authoritative coordinator router spec.
SPEC-015 v0.1.x ANNOTATES exactly two additive, optional response
fields on each `/poolz` provider object — `receipt_pubkey` (current
pubkey) and `receipt_pubkey_prev` (previous pubkey populated only
during the 7-day rotation grace window) — marked here as a single
SPEC-002 v1.4 candidate annotation pair. SPEC-002 §7 surfaces
(`/poolz` shape, internal forwarding) are otherwise unchanged.

SPEC-005 v0.3 remains the authoritative billing/settlement spec.
SPEC-015 v0.1 reuses SPEC-005's effective completion-token accounting
unmodified: `tokens_out` in the receipt is the same `int64` value the
billing path uses for `effective_completion_tokens` per
SPEC-005 §4 derivation. SPEC-015 v0.1 MUST NOT change SPEC-005's
formula, refund matrix, or null-usage error treatment.

SPEC-006 v0.8.3 remains the authoritative gateway buyer-API spec.
SPEC-015 v0.1 adds one buyer-visible response header
(`X-MacProvider-Receipt`) and registers it on the SPEC-006 §17
response-pass-through allowlist as a SPEC-006 v0.9 candidate
extension. SPEC-006 §17 header-strip rules (the gateway strips any
non-allowlisted `X-MacProvider-*` response header) otherwise apply
unchanged. The OpenAI SDK drop-in contract is preserved: the receipt
header is additive metadata; absence does not break SDK clients;
presence does not violate any OpenAI shape because OpenAI clients
ignore unknown response headers.

SPEC-008 v0.3 remains the authoritative Tier-2 trust layer. SPEC-015
v0.1 is orthogonal to SPEC-008. Specifically:

- Receipt issuance is independent of Pillar A model-hash verification
  (SPEC-008 §5.3). A receipt issued under v0.1 makes no claim about
  weight identity; SPEC-008 Pillar A makes that claim separately at
  admission and routing time.
- Receipt issuance is independent of Pillar B encrypted-leg AEAD
  (SPEC-008 §6). The receipt is computed over the cleartext request
  and response as observed at the provider; if the provider-leg is
  later AEAD-encrypted per Pillar B, the receipt is still computed
  over the same plaintext at the provider boundary before encryption.
- Receipt issuance is independent of Pillar C attestation. v0.1's
  trust root for the provider receipt pubkey is `/poolz`. If Pillar C
  is enabled, the attestation token does NOT bind the receipt key;
  v0.3+ MAY re-anchor receipt pubkeys to Pillar C attestations.
- Receipt field names MUST NOT collide with SPEC-008 wire fields.
  This SPEC uses `provider_receipt_public_key` to distinguish from
  SPEC-008 `provider_ecdh_public_key` (`auth_request` initial-stage
  per SPEC-001 v1.5 §6.7.1).

SPEC-011 v0.5 remains the authoritative warm-swap spec. Receipt
issuance MUST observe a model swap: a receipt MUST NOT be emitted for
a response whose model load changed mid-response (SPEC-011 v0.5
R-3.8.3 drain semantics already prevent this, but §7.4 below makes
the invariant explicit on the receipt side).

SPEC-013 v0.3 remains the authoritative `autotune` CLI subcommand
spec. SPEC-015 v0.1 reuses
`phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift` (added by
SPEC-013) for canonical encoding; no parallel canonicalizer is
permitted.

### 1.4 North-star requirement

A buyer who has fetched a provider's receipt pubkey from `/poolz` MUST
be able to verify, offline, that:

1. The response they hold came from a provider holding that pubkey,
2. The response was bound to a prompt they can canonicalize and hash
   themselves to compare against `prompt_hash`,
3. The output they hold canonicalizes to a digest matching
   `output_hash`,
4. The provider-reported `ttft_ms`, `tokens_out`, and `unix_ts` are
   committed to the signed tuple and cannot be silently revised after
   the fact.

If any of (1)–(4) fails for a verifier that follows §3 canonicalization
correctly, the receipt is invalid and the verifier MUST reject it.

A buyer who does NOT trust `/poolz` (operator-mutable list) MUST
explicitly acknowledge that the v0.1 trust root is the coordinator
operator. v0.3+ stronger roots are §15 Q1.

---

## 2. Design rationale (informative)

The "verifiable inference" tag in the README is the central
differentiator from operator-trusted inference networks. The bar is
not academic ZK-verifiable inference (covered in
`doc/internal/zk-verifiable-inference-design.md` as exploratory) — it
is the minimum mechanism that lets a buyer prove a specific provider
served a specific prompt-output pair.

v0.1's design choices and their justifications:

- **ed25519 over JCS-canonical JSON.** ed25519 keys are small (32-byte
  pubkey, 64-byte signature), signing is fast (~50 µs on Apple Silicon),
  and the algorithm is widely implemented. JCS (RFC 8785) gives an
  unambiguous canonical form for JSON that survives field-order
  permutations and floating-point representation; the in-house Swift
  implementation at
  `phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift` is
  battle-tested by SPEC-013.
- **Seven-field tuple.** The set was chosen to cover the four
  buyer-observable claims (model name, prompt content, output content,
  provider identity) plus three provider-reported quality signals
  (ttft, output token count, timestamp). It deliberately does NOT
  cover model-hash, request-id, or route — those are scoped to
  v0.3+, v0.2 verification, and Open Q3 respectively.
- **Response header transport.** A header is the lowest-friction
  surface that OpenAI clients tolerate unchanged. Body inclusion was
  rejected: it would force every buyer SDK to learn a new response
  shape and would break OpenAI SDK drop-in (SPEC-006 §C.1).
- **Streaming receipts deferred to v0.2+.** Two rejected designs
  (v0.1 terminal `event: receipt` SSE block and v0.1.1
  `X-MacProvider-Receipt-Pending` correlator header) demonstrated
  that an SDK-compatible streaming receipt transport needs its own
  design pass. v0.1.x explicitly carries no receipt on streaming
  responses; v0.2+ will design the streaming transport. See §6.3
  and §15 Q5.
- **Manual rotation with a time-based grace window.** Auto-rotation
  has operational hazards (key churn, in-flight verification
  failures); v0.1.1 defers it. Manual rotation is a CLI flag; the
  coordinator retains the previous pubkey for **7 days** after the
  new one is published, so receipts that left the provider under
  the old key remain verifiable while a buyer is still polling
  `/poolz`. The v0.1 draft mixed a time threshold with a
  request-count threshold; the round-1 audit M3 flagged the mix as
  unimplementable without a counter contract; v0.1.1 uses time
  only.

---

## 3. Receipt content and canonical encoding

### 3.1 The receipt tuple

**v0.3 wire shape supersedes this section for v0.3 receipts.**
The §3.1 seven-field shape below describes the v0.1 / v0.2 wire
contract and remains authoritative for receipts emitted by v1.6
binaries pre-v0.3, and for verifiers consuming such receipts.
For v0.3 receipts (those carrying `receipt_version: "3"`), the
normative tuple shape is §M.0's nine-field table. v0.3-emitting
providers MUST construct the §M.0 nine-field tuple; v0.3
verifiers MUST detect tuple version per the §M.1.1 / §M.1.4
rules (presence of `receipt_version` field) and apply either the
§3.1 7-key path (legacy back-compat) or the §M.0 9-key path
accordingly. The §3.2 JCS canonicalization rules and the §3.3
signature rules are UNCHANGED across both shapes.

Every v0.1 / v0.2 receipt is a JCS-canonicalized JSON object with EXACTLY the
following seven fields and no others:

| Field | Type | Definition |
|---|---|---|
| `model_id` | string | The buyer-requested model identifier. SPEC-001 v1.5 §6.4 model identifiers are ASCII-only and matched case-insensitively; v0.1.3 inherits this and requires `model_id` strings in the tuple to be ASCII-only. The receipt stores the original buyer-submitted `model` string verbatim (no case-fold). Because the string is ASCII-only, the §3.2 NFC normalization step is a no-op on this field; conformant verifiers MUST reject any receipt whose `model_id` contains a non-ASCII byte. |
| `prompt_hash` | string | Lowercase hex sha256 of the JCS-canonical encoding of the canonical prompt object defined in §4. 64 lowercase hex characters, no `sha256:` prefix. |
| `output_hash` | string | Lowercase hex sha256 of the JCS-canonical encoding of the canonical output object defined in §5. 64 lowercase hex characters, no `sha256:` prefix. |
| `provider_pubkey` | string | Base64 (standard, padded, no URL-safe substitution) of the provider's 32-byte ed25519 public key. Exactly 44 ASCII characters. |
| `ttft_ms` | int64 | Time-to-first-token in milliseconds, measured at the provider from request-accepted to first-output-byte-emitted. Non-negative. For non-streaming responses, this is the full generation latency. |
| `tokens_out` | int64 | Provider-reported output token count, the same `int64` value SPEC-005 §4 names `effective_completion_tokens`. Non-negative. See §7.6 for null-usage and error cases. |
| `unix_ts` | int64 | Provider's response-completion timestamp, Unix seconds UTC. Non-negative. Provider clock; see §15 Q4 for cross-check semantics. |

**Field omissions and extras.** A receipt object MUST contain
EXACTLY these seven keys. Verifiers MUST reject receipts with missing
or extra keys. There are no optional fields in v0.1.

**Why `provider_id` is NOT in the tuple (resolves audit q1).** The
buyer's cryptographic root of trust in the receipt is the
`provider_pubkey` field. The human/operator-facing `provider_id`
ULID is the coordinator's mutable label for that pubkey in `/poolz`
(§8). v0.1's design choice is to bind only the pubkey because:

1. The pubkey is the unforgeable identity for verification — a buyer
   who has fetched `(provider_id, receipt_pubkey)` from `/poolz`
   already trusts that mapping or does not.
2. Including `provider_id` would double-bind to an operator-mutable
   label without strengthening the cryptographic claim.
3. If `/poolz` later strengthens to a TUF-style signed root (§15 Q1),
   the trust upgrade lands on the `/poolz` side without re-signing
   historical receipts.

A v0.x+ MAY revisit this if §15 Q1 trust-root strengthening lands and
the operator wants the receipt to commit to a stable opaque
identifier independent of the pubkey.

**Types.** `model_id`, `prompt_hash`, `output_hash`, and
`provider_pubkey` are JSON strings. `ttft_ms`, `tokens_out`, and
`unix_ts` are JSON numbers that fit in int64. Implementations MUST
serialize them as JSON integers (no decimal point, no exponent) and
verifiers MUST reject any non-integer numeric encoding. JCS already
constrains numeric formatting to a canonical decimal representation;
v0.1 forbids fractional or exponential numerics for these three
fields explicitly.

### 3.2 Canonical encoding for signing

Let `T` be the receipt tuple object. The signing input MUST be
`JCS(T)` as defined by RFC 8785, with the additive profile pinned
below. The implementation reuses
`phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift` and MUST
extend it with two clearly-named additions:

1. **Object key order:** UTF-16 code-unit lexicographic, per
   RFC 8785 §3.2.3. Already implemented at
   `RFC8785JCS.swift:44-46`.
2. **String escape rules:** RFC 8785 §3.2.2.5. Already implemented
   at `RFC8785JCS.swift:48-75` for U+0000–U+001F, `"`, `\\`, and
   U+FFFD.
3. **NEW (extension required for v0.1.3): NFC normalization on
   natural-language strings.** Every JSON string value entering the
   canonical form that may contain non-ASCII bytes — specifically,
   prompt/output canonical-object string fields per §§4–5 — MUST be
   Unicode-normalized to NFC (Unicode 15.1) BEFORE escape.
   Implementations MUST extend `RFC8785JCS.swift` with a pre-escape
   NFC step using `String.precomposedStringWithCanonicalMapping`.
   Pre-normalized inputs (already NFC) are a no-op. Tuple-level
   string fields (`model_id`, `prompt_hash`, `output_hash`,
   `provider_pubkey`) are ASCII-only by their respective field
   definitions (§3.1), so NFC is a no-op on those fields by
   construction.
4. **NEW (extension required for v0.1.3): JSON number handling for
   floats.** RFC 8785 §3.2.2.3 specifies the canonical decimal
   representation for JSON numbers including IEEE 754 doubles.
   `RFC8785JCS.swift` v1 supports only `int`; v0.1.3 receipt
   implementations MUST extend `RFC8785JCS.swift`'s `Value` enum
   with a `double(Double)` case implementing RFC 8785 §3.2.2.3 (the
   ECMAScript `Number.prototype.toString` derived format). The
   prompt canonical object (§4) contains `temperature`, `top_p`,
   `presence_penalty`, `frequency_penalty` as floats and is the
   driver for this extension.
5. No whitespace, no insignificant separators, no trailing newline.

The signing input is the UTF-8 bytes of `JCS(T)`.

The receipt tuple itself (§3.1) contains only strings and integers,
so the receipt SIGNING step itself does not exercise the float
extension. Floats appear in the §4 prompt canonical object that
feeds `prompt_hash`. Both extensions are MANDATORY for a v0.1.3
conformant provider implementation; an implementation lacking either
MUST NOT emit receipts.

### 3.3 Signature

`SIG = ed25519_sign(provider_receipt_private_key, UTF-8(JCS(T)))`.

`SIG` is exactly 64 bytes. The on-wire encoding is base64 (standard,
padded; no URL-safe substitution) — exactly 88 ASCII characters.

### 3.4 Receipt object on the wire

The full receipt artifact transmitted on the wire is the
JCS-canonical tuple plus the signature. The `X-MacProvider-Receipt`
header value MUST be:

```
<base64(JCS(T))>.<base64(SIG)>
```

That is: standard padded base64 of the UTF-8 bytes of `JCS(T)`,
then a literal ASCII period (`0x2E`), then standard padded base64
of the 64-byte signature. No whitespace, no other delimiters, no
trailing characters.

The two base64 segments are independently decodable so a verifier
can reconstruct `JCS(T)` and check `ed25519_verify(provider_pubkey,
JCS(T), SIG)`. This format was chosen over JWS (compact serialization)
because v0.1 does not need a header (no algorithm agility, no key id
indirection — `provider_pubkey` is in the payload). A v0.x+ may
migrate to JWS once algorithm agility is needed; that migration is
NOT part of v0.1.

**Maximum size.** `JCS(T)` is bounded by the field sizes:
`model_id` ≤ 256 bytes (SPEC-001 v1.5 model-id constraint),
`prompt_hash`/`output_hash` = 64 hex chars each, `provider_pubkey` =
44 chars, three int64 numerals ≤ 20 chars each. With JSON
overhead, the v0.1/v0.2 `JCS(T)` ≤ 600 bytes; base64 expands by
4/3, so the v0.1/v0.2 header value is ≤ ~830 ASCII bytes.

**v0.3 wire size (NEW).** A v0.3 receipt adds `model_hash`
(≤ 80 bytes including key + quotes + colon: `"model_hash":"<64
hex>"`) and `receipt_version` (≤ 22 bytes: `"receipt_version":
"3"`). The v0.3 `JCS(T)` ceiling is ≤ ~700 bytes. The
`X-MacProvider-Receipt` header value is
`<base64(JCS(T))>.<base64(SIG)>`:
- `base64(JCS(T))` = ⌈700 × 4/3⌉ ≈ 936 bytes (standard padded
  base64).
- The literal period separator = 1 byte.
- `base64(SIG)` for a 64-byte ed25519 signature = 88 bytes
  (standard padded base64).
- Total v0.3 header value ≤ ~1025 ASCII bytes. v0.3 still
  fits comfortably within the 4096-byte budget below.

Implementations MUST permit a generous `X-MacProvider-Receipt`
header up to 4096 bytes to leave headroom for v0.3+ field
additions and to avoid edge-case nginx truncation.

---

## 4. Prompt canonicalization

The `prompt_hash` field commits to the buyer's request. The
canonicalization rule MUST be deterministic across implementations so
a verifier with the same request body produces the same hash.

### 4.1 Source of the prompt

The provider canonicalizes the **request body it received** at the
point of inference, NOT the buyer's original HTTP body. For the v0.1
single-provider routing case (one provider per response, see §1.2)
the gateway-to-coordinator-to-provider forwarding preserves the
relevant fields byte-for-byte; see §4.5 for the normative subset.

### 4.2 The canonical prompt object

The provider MUST construct the canonical prompt object as follows:

```
{
  "model": <request.model>,                          // verbatim string
  "messages": [<canonical_message>, ...],            // see §4.3
  "tools": [<canonical_tool>, ...] | null,           // see §4.4
  "temperature": <float|null>,
  "top_p": <float|null>,
  "max_tokens": <int|null>,
  "stop": <string|array<string>|null>,
  "seed": <int|null>,
  "response_format": <object|null>,
  "tool_choice": <string|object|null>,
  "presence_penalty": <float|null>,
  "frequency_penalty": <float|null>,
  "logit_bias": <object|null>,
  "logprobs": <bool|null>,
  "top_logprobs": <int|null>,
  "n": <int|null>
}
```

A field that is absent from the request body MUST be encoded as JSON
`null` in the canonical prompt object. The object MUST contain
EXACTLY these sixteen keys; no other request fields enter
`prompt_hash` in v0.1.

The sixteen keys are the union of OpenAI chat-completion fields the
provider observes and that materially affect the output distribution
or the response shape. The audit-driven expansion from v0.1's
ten-key list closed the "weak prompt binding" gap surfaced in the
round-1 audit M1: `presence_penalty`, `frequency_penalty`,
`logit_bias`, `logprobs`, `top_logprobs`, and `n` were missing in
v0.1 and could have let two responses differ on sampling while their
receipts hashed identical prompts.

Implementations MUST NOT include OpenAI fields outside this list
(`user`, `stream`, `stream_options`, `store`, `metadata`,
`function_call`, `functions`, etc.) even if the buyer sent them.
v0.1.3 deliberately excludes fields that are non-deterministic on
the provider side (`stream`, `stream_options`) or operationally
noisy (`user`, `metadata`), and excludes legacy aliases
(`function_call`, `functions`) in favor of `tools` and
`tool_choice`. A v0.2+ may widen the subset; verifiers built against
v0.1.3 MUST hash exactly these sixteen keys.

### 4.3 Canonical message object

Each message in `messages` MUST canonicalize to:

```
{
  "role": <string>,                                  // "system" | "user" | "assistant" | "tool"
  "content": <canonical_content>,                    // string or array; see §4.3.1
  "name": <string|null>,
  "tool_call_id": <string|null>,                     // for role:"tool" messages
  "tool_calls": [<canonical_tool_call>, ...] | null  // for role:"assistant" with tool calls
}
```

Each message MUST contain EXACTLY these five keys; fields absent from
the buyer-supplied message are encoded as JSON `null`.

#### 4.3.1 Canonical content

`content` is one of:

- A JSON string (the common case for text-only messages). The string
  MUST be Unicode-normalized to NFC (Unicode 15.1 stabilization). A
  request that contains pre-NFC content (decomposed sequences,
  legacy escapes) is normalized at the provider before hashing.
- A JSON array of content parts, used for OpenAI multimodal-style
  messages. Each part MUST canonicalize to one of:
  - `{"type":"text","text":<nfc-string>}`
  - `{"type":"image_url","image_url":{"url":<string>,"detail":<string|null>}}`
  - `{"type":"input_audio","input_audio":{"data":<string>,"format":<string>}}`
  Each part object MUST contain EXACTLY the keys named for its type.

If the buyer sent `content: null` (legacy OpenAI shape for
assistant tool-call messages), the canonical form is JSON `null`.

#### 4.3.2 Newline and whitespace handling

Within a content string:

- `\r\n` and bare `\r` MUST be normalized to `\n` before NFC.
- Trailing whitespace MUST NOT be stripped. Some prompts legitimately
  end with whitespace and a strip would silently change `prompt_hash`.
- Leading whitespace MUST NOT be stripped, same reason.
- Internal whitespace runs MUST NOT be collapsed.

### 4.4 Canonical tool object

Each tool in `tools` MUST canonicalize to:

```
{
  "type": "function",
  "function": {
    "name": <string>,
    "description": <string|null>,
    "parameters": <json-schema-object|null>
  }
}
```

`parameters` is a JSON Schema object as supplied; JCS canonicalizes
the object recursively. v0.1 does NOT reorder or normalize the
schema beyond JCS's standard sort.

### 4.5 The provider-observed request body

The §4.1–§4.4 fields MUST be passed end-to-end from buyer to provider
without modification. SPEC-006 v0.8.3 §17 already enforces this for
the OpenAI request body (gateway forwards the body verbatim);
SPEC-002 v1.3.5 §5 already enforces it on the coordinator. Receipts
issued under v0.1 inherit this invariant. If a future gateway or
coordinator change rewrites any of the §4.2 fields between buyer and
provider (e.g. coercing `temperature` defaults), receipts will fail
verification against the buyer's raw body — this is a deliberate
detection mechanism, not a bug.

---

## 5. Output canonicalization

The `output_hash` field commits to the output the provider produced.

### 5.1 The canonical output object

The provider MUST construct the canonical output object as follows:

```
{
  "content": <nfc-string>,                           // see §5.2
  "tool_calls": [<canonical_tool_call>, ...] | null, // see §5.3
  "finish_reason": <string>                          // v0.1.x non-streaming: "stop" | "length" | "tool_calls" | "content_filter" | "error" (v0.2+ streaming may add "cancelled")
}
```

The object MUST contain EXACTLY these three keys.

### 5.2 `content`

- For non-streaming responses (the only receipt-bearing path in
  v0.1.x): the full `choices[0].message.content` string as the
  provider produced it, NFC-normalized.
- For responses where the assistant message contains ONLY tool calls
  (no text content), `content` is the JSON empty string `""`.
- For responses with no content emitted at all (e.g., immediate
  error after token allocation), see §5.4.

*Informative forward-compatibility note (v0.2+):* a future
streaming receipt design will need to canonicalize the concatenated
`choices[0].delta.content` chunks. NFC normalization across chunk
boundaries is not associative, so a future v0.2+ design MUST NFC-
normalize the concatenated result once at end-of-stream, not
per-chunk. This guidance is not testable in v0.1.x and binds only
the v0.2+ streaming design.

`\r\n` → `\n` and bare `\r` → `\n` apply, identical to §4.3.2.
No whitespace stripping.

### 5.3 `tool_calls`

If the assistant emitted one or more tool calls, the receipt commits
to all of them inside `output_hash`, not as a separate field. Each
tool call MUST canonicalize to:

```
{
  "id": <string>,
  "type": "function",
  "function": {
    "name": <string>,
    "arguments": <string>      // the JSON-stringified argument blob the assistant emitted, byte-for-byte
  }
}
```

For non-streaming responses in v0.1.x, a single completed tool call
MUST appear with its full `arguments` string. Tool calls MUST appear
in `tool_calls` in the emission order the assistant produced them.

*Informative forward-compatibility note (v0.2+):* the OpenAI SSE
shape emits `choices[0].delta.tool_calls[].function.arguments` as a
partial string across many chunks. A v0.2+ streaming receipt design
MUST concatenate those deltas in emission order to match the
non-streaming `arguments` byte-for-byte. Not testable in v0.1.x.

The `arguments` field is a string, NOT a parsed JSON object. v0.1
deliberately commits to the byte-exact string the assistant emitted
so a verifier can rebuild it from streaming chunks without parsing
hazards. A v0.x+ may add a parsed-object commitment alongside, but
v0.1's `output_hash` covers the string form only.

### 5.4 `finish_reason`

`finish_reason` is the same value SPEC-005 §3 maps to billing
treatment. For v0.1.x non-streaming receipts, `finish_reason` is one
of `"stop"`, `"length"`, `"tool_calls"`, `"content_filter"`, or
`"error"`. When the provider returns SPEC-001 null-usage error
classes (`error_model_not_loaded`, `error_context_exceeded`,
`error_queue_full`, `error_internal`), `finish_reason` MUST be
`"error"` and `content` is the empty string. See §7.6 for the
emission rule in this case.

*Informative forward-compatibility note (v0.2+):* the OpenAI SDKs
treat a buyer disconnect on a streaming response as
`finish_reason="cancelled"`. v0.1.x streaming requests carry no
receipt regardless of `finish_reason`; a v0.2+ design that emits
streaming receipts will need to canonicalize the cancelled case.

### 5.5 The `output_hash` invariant (informative; forward-compat)

v0.1.x receipts cover non-streaming responses only (§6.3). The
canonical output object defined in §5.1–§5.3 is therefore exercised
only by non-streaming output.

For forward compatibility with successor streaming receipts: when a
successor design adds streaming receipts, identical output bytes
emitted in streaming and non-streaming modes MUST hash to the same
`output_hash`. v0.1.x §5.2's "concatenated output" guidance is
preserved to support that invariant; in v0.1.x it has no testable
consequence and is informative. v0.4's §N.5 makes this invariant
settlement-binding for the delivered streaming prefix.

---

## 6. Wire transport

### 6.1 Header name

The receipt is delivered in the HTTP response as:

```
X-MacProvider-Receipt: <base64(JCS(T))>.<base64(SIG)>
```

The header name `X-MacProvider-Receipt` is NEW in SPEC-015 v0.1.
SPEC-006 v0.8.3 §17 lists `X-MacProvider-Provider`,
`X-MacProvider-Route`, `X-MacProvider-Session`,
`X-MacProvider-Conversation`, `X-MacProvider-Internal-Conv`,
`X-MacProvider-Pref`, `X-MacProvider-Retry`. `X-MacProvider-Receipt`
does not collide. SPEC-006 v0.9 (candidate, deferred to SPEC-015 v0.1
+ SPEC-006 v0.9 absorption) MUST add `X-MacProvider-Receipt` to the
buyer-facing response-pass-through allowlist so the gateway does not
strip it on the buyer hop.

### 6.2 Non-streaming responses

For a non-streaming `POST /v1/chat/completions` (request body
`stream: false` or absent), the provider MUST emit
`X-MacProvider-Receipt` on the inference response. The header value
is set BEFORE the response body is written. The header is forwarded
by coordinator and gateway untouched.

### 6.3 Streaming responses (out of scope in v0.1.x)

v0.1.x DOES NOT issue receipts for streaming
`POST /v1/chat/completions` responses. Provider, coordinator, and
gateway MUST treat a streaming request as receipt-free: no
`X-MacProvider-Receipt` header is emitted; no SSE event is added;
no `data:` payload is altered. The SSE stream's wire shape is
exactly what SPEC-001 v1.5 and SPEC-006 v0.8.3 already specify.

This is a deliberate v0.1.x scope narrowing in response to round-1
audit C1 and round-2 audit C1/C3. Both rounds established that:

- The v0.1 plan to emit a terminal `event: receipt` SSE block is
  incompatible with the OpenAI Python and JavaScript SDKs' stream
  loops (Python: `openai/_streaming.py`; JavaScript:
  `openai-node/streaming.ts`).
- The v0.1.1 plan to emit an `X-MacProvider-Receipt-Pending`
  correlator header introduces a second buyer-visible
  `X-MacProvider-*` response header that exceeds the single-field
  SPEC-006 v0.9 candidate allowlist annotation.
- Embedding the receipt as an extra field on the final
  chat-completion chunk is unverified across SDK versions and
  needs its own SDK-compatibility study.

v0.4 §N.5 defines the settlement streaming receipt transport through
SDK-safe internal channels. Before v0.4 implementation, README and
operator-facing copy
MUST disclose that v0.1.x receipts cover non-streaming responses
only. A buyer who needs receipts for streaming traffic in v0.1.x
has two options:

1. Issue the same request non-streaming and verify against a
   pinned `seed` (idempotent if the model is deterministic).
2. Wait for v0.4 settlement-capable streaming receipt delivery.

§15 Q5 records the historical open design question and its v0.4
resolution.

### 6.4 Omission cases

For non-streaming responses, the receipt MUST be omitted (no
`X-MacProvider-Receipt` header) in the following cases:

1. The provider's receipt keypair has not yet been generated (first
   launch before Keychain setup completes). See §7.1.
2. The buyer disconnected before any token was emitted AND the
   provider has no committed `tokens_out` value (`tokens_out: 0` is
   committable; see §7.6).
3. The response was served by a SPEC-001 binary at version `< v1.6`
   (no `provider_receipt_public_key` published).
4. The model swap mid-response invariant is violated (see §7.4) — the
   provider MUST close the response with a 500-class error and MUST
   NOT emit a receipt.
5. The request was streaming. v0.1.x emits no receipts for streaming
   responses (§6.3).

When a receipt is omitted, the provider MUST NOT emit a placeholder,
empty value, or `X-MacProvider-Receipt: omitted` sentinel. Header
absence is the signal.

---

## 7. Provider keypair lifecycle

### 7.1 Generation

On first launch of `phase3-binary serve` at SPEC-001 v1.6 or later,
the binary MUST perform an atomic insert-or-load against macOS
Keychain to obtain its receipt private key:

1. Construct the Keychain query with:
   - `kSecClass = kSecClassGenericPassword`
   - `kSecAttrService = "com.malibu.provider.receipt-key"`
   - `kSecAttrAccount = <provider_id>`
   - `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
   - `kSecAttrSynchronizable = false`
2. Attempt `SecItemCopyMatching` with that query. If a record is
   present, decode the 32-byte raw private key from `kSecValueData`
   and skip to step 5.
3. If `SecItemCopyMatching` returns `errSecItemNotFound`, generate a
   fresh ed25519 keypair using
   `CryptoKit.Curve25519.Signing.PrivateKey.init()` and call
   `SecItemAdd` with the query plus
   `kSecValueData = privateKey.rawRepresentation`.
4. If `SecItemAdd` returns `errSecDuplicateItem`, another `serve`
   process won the race: discard the just-generated keypair, repeat
   step 2 to load the winning private key, then proceed. The binary
   MUST NOT cache the lost candidate.
5. Cache the loaded private key for the lifetime of the `serve`
   process. Refresh from Keychain on `SIGHUP` or process restart.

The atomic insert-or-load above closes the round-1 audit M5 race:
two simultaneous `serve` launches with the same `provider_id` MUST
converge to a single private key (the first SecItemAdd wins; the
loser falls back to load).

The pubkey is derivable from the private key; the binary MUST NOT
store the pubkey separately. The Keychain item is per-`provider_id`
so reinstalling the binary with a different `provider_id` produces a
different keypair.

### 7.2 Publication on WS auth

On the next v2 `auth_request` initial-stage frame (SPEC-001 v1.5
§6.7.1, candidate extension SPEC-001 v1.6), the binary MUST add the
optional field:

```
"provider_receipt_public_key": "<base64-32-byte-ed25519-public-key>"
```

The field name is `provider_receipt_public_key` to mirror the
existing SPEC-008 `provider_ecdh_public_key` field and to make the
key purpose unambiguous. Encoding is standard padded base64 (44
ASCII characters).

The field MUST be parser-optional on the coordinator side (a
pre-v1.6 binary that does NOT carry the field MUST still admit
successfully; the coordinator MUST treat that provider as
non-receipt-issuing and the gateway MUST NOT emit
`X-MacProvider-Receipt` for responses routed through that provider).

**The proof-stage frame (SPEC-001 v1.5 §6.7.2) is NOT modified by
v0.1.1.** The round-1 audit C2 surfaced that the v0.1 plan to echo
`provider_receipt_public_key` on the proof-stage frame exceeds the
single-field SPEC-001 v1.6 candidate boundary; SPEC-001 v1.5 R-6.7.6
limits proof-stage byte-identity rules to `supported_models[]` and
`publishes_supported_models`. v0.1.1 restricts the candidate
annotation to the initial-stage frame ONLY. A future SPEC-015
revision that needs proof-stage echo MUST file it as a separate
SPEC-001 candidate with its own compatibility analysis.

### 7.3 Coordinator receipt-pubkey surface

The coordinator stores `provider_receipt_public_key` on the in-memory
provider struct alongside the existing `provider_ecdh_public_key`
storage (see `phase4-coordinator/internal/pool/provider.go`,
SPEC-008 v0.3 §5.5). The field MUST be exposed on `/poolz` per §8
below; that exposure (with `receipt_pubkey` and
`receipt_pubkey_prev`) is the SPEC-002 v1.4 candidate annotation
v0.1.3 pins.

**Persistence across restart is an implementation concern, not a
v0.1.3 normative requirement.** The round-1 audit C3 surfaced that
the v0.1 plan to mandate
`ALTER TABLE providers ADD COLUMN receipt_pubkey TEXT` exceeds the
`/poolz` SPEC-002 v1.4 candidate boundary AND prescribes a schema
(`providers` table) that does not exist in the locked SPEC-002
v1.3.5 surface. v0.1.3 deliberately scopes the SPEC-002 candidate
annotation to the `/poolz` shape change and defers the
durable-storage mechanism to the implementation BUILD spec
(`BUILD_SPEC_015_IMPL_*_PROMPT.md`, not yet written).

The implementation BUILD spec MAY choose any of:

- In-memory only on the coordinator: providers republish their
  pubkey on every reconnect, the coordinator never persists. This
  is acceptable because reconnect is the existing recovery path
  (SPEC-002 v1.3.5 §4 admission semantics).
- Durable in a new SPEC-002 candidate column on the existing
  `provider_tokens` or admission audit table, named as a separate
  SPEC-002 candidate annotation.
- Durable in a v0.x dedicated `receipt_pubkeys` table.

v0.1.3 ACs 10–11 verify the runtime surface (the pubkey is exposed
on `/poolz`, the rotation grace window behavior holds) without
asserting a specific storage mechanism.

### 7.4 Rotation under model swap

A receipt MUST commit to a single provider running a single set of
weights for the duration of the response. If a SPEC-011 v0.5 warm
swap is initiated mid-response, the in-flight response MUST drain
under the old `ModelRuntime` per SPEC-011 §3.8.4. The receipt is
emitted from the same `ModelRuntime` instance that produced the
output; no special handling is required for the receipt itself.

If a binary or coordinator bug causes a mid-response swap that
violates the drain invariant, the provider MUST close the response
with an HTTP 500 error envelope and MUST NOT emit a receipt. This is
a fail-closed default; the alternative (emit a receipt over partial
output) would silently weaken the binding.

### 7.5 Manual rotation (via reconnect)

v0.1.x defines manual rotation only. Auto-rotation is deferred to a
later version.

The binary MUST support the CLI flag:

```
macprovider rotate-key
```

Rotation is performed via WebSocket reconnect, NOT via a new control
frame. The round-2 audit C2 established that introducing a new
provider→coordinator WS frame would exceed the single-field
SPEC-001 v1.6 candidate annotation. The reconnect-based design
reuses the already-authorized initial-stage `auth_request` field.

When `macprovider rotate-key` is invoked:

1. The binary generates a fresh ed25519 keypair IN MEMORY ONLY. The
   new keypair is NOT yet written to Keychain.
2. The binary closes the current WS connection cleanly.
3. The binary opens a fresh WS connection and sends a v2
   `auth_request` initial-stage frame carrying the NEW
   `provider_receipt_public_key`.
4. If the coordinator accepts the auth and proof stages (returning
   `auth_response.accepted=true`), the binary atomically swaps
   Keychain:
   - Move the existing Keychain item at
     `(service=com.malibu.provider.receipt-key,
       account=<provider_id>)` to
     `(service=com.malibu.provider.receipt-key.prev,
       account=<provider_id>)`.
   - Add the new keypair at the original `(service, account)`.
   The `.prev` Keychain item is retained for a 7-day operator
   recovery window and is auto-deleted by the next `serve` launch
   that detects it older than 7 days.
5. If the reconnect fails (coordinator rejects auth, network down,
   timeout), the binary discards the in-memory new keypair, restores
   the WS connection using the OLD Keychain-resident key, and
   surfaces the rotation failure to the operator
   (`macprovider rotate-key` exits non-zero with a clear error
   message).
6. The coordinator infers rotation by comparing the new pubkey
   against the previously-known one for this `provider_id`. On
   detection:
   - The coordinator moves the prior pubkey to `receipt_pubkey_prev`
     with `rotated_at = now`.
   - Sets `receipt_pubkey` to the new value.
   - Updates `/poolz` accordingly (§8).
7. The binary signs all NEW receipts emitted after step 4 with the
   new private key. There is no in-flight rotation window for the
   PROVIDER side — by construction the old key is unreachable from
   the moment a new WS connection is established.

The previous-pubkey grace window described in §7.5.1 covers buyers
whose `/poolz` cache still points at the old key at rotation time.

#### 7.5.1 Grace window semantics

During the grace window, the coordinator's `/poolz` response carries
both pubkeys:

```
"receipt_pubkey": "<new-base64>",
"receipt_pubkey_prev": {
  "pubkey": "<old-base64>",
  "rotated_at": <unix-seconds>,
  "expires_at": <unix-seconds>
}
```

`expires_at` is `rotated_at + 7 * 86400`. After expiration the
coordinator removes the `receipt_pubkey_prev` block. v0.2 verifiers
MUST accept receipts signed under either `receipt_pubkey` or
`receipt_pubkey_prev` during the grace window.

The grace window is time-only in v0.1.3. A v0.x+ may add a
request-count-bounded short-circuit (e.g. "after the rotated
provider has signed 10000 receipts under the new key, the previous
key MAY be retired early"), but that requires a counter contract
v0.1.3 deliberately does not pin.

### 7.6 Null-usage / error receipts

When the provider returns a SPEC-001 null-usage error
(`error_model_not_loaded`, `error_context_exceeded`,
`error_queue_full`, `error_internal`) per SPEC-005 v0.3 §3 X-1 row:

- `tokens_out` MUST be `0`.
- `output_hash` MUST be the sha256 hex of the canonical output object
  with `content=""`, `tool_calls=null`, `finish_reason="error"`.
- `ttft_ms` MUST be the elapsed milliseconds from request-accepted
  to error-emitted (i.e. the "time to error", which is
  observationally useful for the buyer).
- `unix_ts` is set normally.

The receipt is emitted. This is deliberate: the buyer paying zero
under SPEC-005 X-1 still gets a signed acknowledgement that the
provider was reached and produced an error response. This closes a
SPEC-006 v0.8.2 ambiguity: the v0.8.2 X-1 row debited the buyer
zero quota but said nothing about whether the buyer learned what
the provider did.

If the provider was never reached (gateway-internal failure,
coordinator preflight rejection, no provider available), no receipt
is emitted because there is no provider to sign one. The error
envelope SPEC-006 §H normalizes the response shape; the absence of
`X-MacProvider-Receipt` distinguishes "provider never ran this" from
"provider ran and errored".

---

## 8. Pubkey trust root

### 8.1 v0.1 trust root: `/poolz`

Buyers retrieve the provider receipt pubkey from the coordinator's
`/poolz` endpoint (SPEC-002 v1.3.5 §7). v0.1.x ANNOTATES two new fields
per provider object, marked as SPEC-002 v1.4 candidate:

```
{
  "provider_id": "p_01HK4Z3VYE...",
  "state": "ready",
  "model": "...",
  ...
  "receipt_pubkey": "<base64-32-byte-ed25519>" | null,
  "receipt_pubkey_prev": null | { "pubkey": "...", "rotated_at": ..., "expires_at": ... }
}
```

`receipt_pubkey` is `null` for providers whose binary is at SPEC-001
< v1.6 (no key published). Such providers MUST NOT have
`X-MacProvider-Receipt` headers on responses they serve; the gateway
MUST omit the header if the upstream coordinator's chosen provider
has `receipt_pubkey: null`.

`receipt_pubkey_prev` is `null` outside the rotation grace window.

### 8.2 Buyer fetch ergonomics

Buyers SHOULD cache `/poolz` responses for short windows (≤ 60
seconds) to avoid hammering the endpoint on every verification.
SPEC-002 v1.3.5 already permits `/poolz` caching at this cadence per
§7.4.

### 8.3 Operator-mutability and the limits of v0.1's trust root

The coordinator operator can rewrite `/poolz` at any time; v0.1's
trust root is therefore "the coordinator operator does not lie about
which pubkey corresponds to which provider". This is consistent with
the rest of the MacProvider Tier-1 trust posture (SPEC-006 v0.8.3
§1.6) and is acknowledged in the README:

> Buyer prompts and provider responses are processed as plaintext on
> provider hardware … This is acceptable for cooperative deployments
> where buyer and provider have an established trust relationship; it
> is NOT a private-inference guarantee.

A stronger trust root — TUF-style operator-signed `/poolz`, an
external anchor at AntFeed, or a Cluster D-token-anchored registry —
is §15 Q1 and explicitly out of scope for v0.1. Implementers
documenting v0.1 to buyers MUST be honest about this limit; v0.1
receipts protect against provider misbehavior, NOT against
coordinator-operator misbehavior.

### 8.4 Future migration off `/poolz`

When a v0.3+ stronger root lands, the wire format of receipts
(§3.4) MUST be unchanged. Only `provider_pubkey` source-of-truth
changes. This forward-compatibility commitment is binding on v0.1
implementers: do NOT bake `/poolz`-specific assumptions into the
verification path; the verifier takes a `provider_pubkey` argument
out-of-band and verifies against it.

---

## 9. Receipt emission timeline

For a non-streaming response:

```
t0: provider receives request from coordinator
t1: provider begins inference (load model, accept prompt)
t2: first output token emitted             → ttft_ms = (t2 - t1) / ms
t3: last output token emitted, finish_reason set, tokens_out known
t4: provider canonicalizes prompt object → prompt_hash
t5: provider canonicalizes output object → output_hash
t6: provider builds tuple T with unix_ts = floor(t3 / second)
t7: provider computes SIG = ed25519_sign(privkey, JCS(T))
t8: provider writes X-MacProvider-Receipt header
t9: provider writes response body
```

Streaming responses are out of scope in v0.1.x (§6.3); no receipt
is emitted, no header is added, and steps t4–t9 do not run on the
streaming path.

---

## 10. Verification (v0.2 NORMATIVE)

v0.1 carried this section as a sketch (`informative; v0.2
normative`). v0.2 promotes it to normative: buyers MUST be able to
use the algorithm below — implemented by the v0.2 `macprovider-verify`
CLI (binary contract per §10.4) — to obtain a deterministic
verification result for any v0.1.3-shape receipt.

### 10.0 Core algorithm (preserved from v0.1)

A buyer with the receipt header value and a trusted provider pubkey
verifies as follows:

```
1. Split the header value on the first '.' → (b64_tuple, b64_sig).
2. Decode JCS_T = base64_decode(b64_tuple).
3. Decode SIG = base64_decode(b64_sig). Reject if len(SIG) != 64.
4. Parse JCS_T as JSON to confirm well-formed and contains exactly
   the seven SPEC-015 §3.1 keys.
5. Resolve the trusted pubkey for the resolved `provider_id` per
   §10.2 (sources: explicit `--pubkey` → cached entry → live
   `GET /v1/receipt-keys/<provider_id>`). The verifier MUST NOT
   resolve by scanning across providers for a matching
   `provider_pubkey`; `provider_id` is the resolver address. If
   the trust root cannot reach a verdict → `inconclusive`
   (§10.1).
6. ed25519_verify(trusted_pubkey, JCS_T, SIG). Reject on failure
   → `invalid` (§10.1).
7. Canonicalize the buyer's recorded request prompt per §4 →
   prompt_hash_local. If != receipt.prompt_hash → `invalid`.
8. Canonicalize the buyer's recorded response output per §5 →
   output_hash_local. If != receipt.output_hash → `invalid`.
9. → `valid` (§10.1).
```

The optional `unix_ts` skew check that appeared in v0.1's sketch is
removed from the v0.2 core algorithm. Per §10.6, the timestamp is
NOT proven by a `valid` result; cross-checking against buyer-side
received-at remains a v0.3+ candidate (§15 Q4). A v0.2 verifier MAY
emit an informational warning if `unix_ts` is wildly off (e.g.
> 24h skew vs. system clock), but MUST NOT downgrade the result to
`invalid` on skew alone.

### 10.1 Result semantics (the tri-state)

A verifier MUST return exactly one of three results for any
(receipt, request, response) input:

| Result | Meaning | Exit code |
|---|---|---|
| `valid` | Signature verifies, canonical hashes match, pubkey resolved to a trusted source | 0 |
| `invalid` | Signature fails OR a canonical hash mismatches OR pubkey is known-revoked | 1 |
| `inconclusive` | Pubkey could not be resolved AND no explicit pubkey was supplied | 2 |

A verifier MUST NOT collapse `inconclusive` into either of the other
results. In particular, a verifier MUST NOT report `valid` when the
pubkey is unresolved, even if a signature self-verifies against a
pubkey embedded in the receipt: an unrooted pubkey is unrooted,
regardless of the signature's internal consistency.

`inconclusive` is the correct result when ANY of the following
hold AND no explicit `--pubkey` was supplied AND the verifier
passed §10.4 input validation (i.e. `provider_id` was obtainable
at parse time per §10.4 "Provider-id requirements"):

- The configured coordinator's `GET /v1/receipt-keys/<provider_id>`
  endpoint (§10.7) is unreachable (network down, DNS failure, 5xx,
  timeout, rate-limited via 429) AND no fresh cached entry exists
  for `(coordinator_host, provider_id, receipt_pubkey)`, OR
- The §10.7 endpoint returns HTTP 404 for the `provider_id` — an
  authoritative "this provider is unknown to me" answer, treated
  as `inconclusive` with `reason: "provider_id_not_in_pool"`
  because the receipt itself may predate provider removal, OR
- The cache holds only a stale entry (older than the §10.2 7-day
  TTL) AND the live fetch fails.

The "provider_id is not addressable at all" case (no CLI arg, no
bundle field, no single-match cache) is NOT an `inconclusive`
case in v0.2 — it is an exit-64 usage error per §10.4. The
verifier rejects the invocation at parse time and never reaches
the result-determination algorithm. See §10.4 "Provider-id
requirements" for the exit-64 contract.

`invalid` (not `inconclusive`) is the correct result when ANY of
the following hold:

- The resolver returns an authoritative provider record for the
  resolved `provider_id` (HTTP 200, parseable response) whose
  `receipt_pubkey` and `receipt_pubkey_prev.pubkey` are BOTH
  different from the receipt's embedded `provider_pubkey` — the
  coordinator has explicitly named the keys it endorses for this
  provider and the receipt's key is not among them, OR
- The resolver returns a `receipt_pubkey_prev` match BUT the
  receipt's `unix_ts` falls outside the §10.2.1 grace window, OR
- The signature check fails against a successfully-resolved
  trusted pubkey, OR
- Either canonical hash mismatches.

The boundary between `inconclusive` and `invalid` is the
authoritative-resolver-answer test: if the trust root reached a
verdict ("no, I don't endorse this key for this provider"), the
receipt is `invalid`; if the trust root could not reach a verdict
(unreachable, identity unresolvable), the receipt is
`inconclusive`. A receipt MUST NOT be `inconclusive` when the
coordinator's authoritative response excludes its
`provider_pubkey` — that case is a coordinator-rejected forgery
(or retired key), not an environmental failure.

The HTTP 404 response from the §10.7 endpoint (provider not in
the current pool) is a degenerate case: it is authoritative
("this `provider_id` is unknown to me") but the receipt itself may
predate the provider's removal. v0.2 verifiers MUST treat 404 as
`inconclusive` with `reason: "provider_id_not_in_pool"` per the
§10.4.2 reason enum. v0.3+ MAY revisit this if the coordinator
gains a "retired but historic" state.

### 10.2 Pubkey resolution

A verifier MUST resolve the pubkey it trusts against, in this
priority order:

1. **Explicit:** A pubkey supplied by the caller via
   `--pubkey <44-char base64>`. Used for offline / air-gap
   verification. When supplied alongside `--provider-id`, the
   verifier MUST treat the pair as the trusted root regardless of
   live coordinator state. The explicit pubkey wins the
   verification result; live divergence is reported via
   `warnings[]` per §10.4.2, not via result downgrade.
2. **Cached:** A pubkey stored locally from a prior
   `GET /v1/receipt-keys/<provider_id>` fetch (§10.7), keyed by
   the tuple `(coordinator_host, provider_id, receipt_pubkey)`.
   Cache entries MUST carry a `fetched_at` timestamp, the
   `rotated_at` and `expires_at` timestamps as returned by the
   coordinator, and the corresponding `receipt_pubkey_prev`
   record (if any) for grace-window verification. All three
   timestamps MUST be stored as RFC3339 UTC strings matching the
   §10.7 wire shape; conversion from the receipt's Unix-seconds
   `unix_ts` to RFC3339 (or vice versa) happens at the cache
   boundary, not at every comparison. The receipt `unix_ts`
   itself remains Unix seconds per the locked v0.1 wire contract.
   - **Fresh entry** (cache `fetched_at` ≤ 7 days before `now()`):
     used directly.
   - **Stale entry** (cache `fetched_at` > 7 days before `now()`):
     MUST trigger a
     fresh live fetch. On fetch success, replace the entry. On
     fetch failure, the verifier MUST NOT use the stale entry to
     produce `valid` — the result is `inconclusive`. The
     provider-reported `unix_ts` MUST NOT be used to revalidate
     a stale cache entry (per §10.6, timestamp honesty is not
     proven; staleness is a coordinator-attested property, not a
     buyer-derivable one).
   - The 7-day TTL matches §7.5.2 rotation grace; a key that has
     not rotated within 7 days remains valid via fresh-fetch
     refresh.
3. **Live:** A fetch of `GET /v1/receipt-keys/<provider_id>`
   (§10.7 — SPEC-002 v1.5 candidate annotation, public /
   unauthenticated / rate-limited) on the coordinator named in
   the verifier's config (default: `coordinator.malibu.tech`).
   MUST be a single `GET` over HTTPS with a 5-second timeout and
   no retries. On success, the verifier MUST update its cache
   (write `fetched_at = now()`) before continuing. The verifier
   MUST NOT fall back to `GET /poolz`: that endpoint is
   operator-only per SPEC-002 v1.4 §FR-O2 and is not buyer-safe.

`provider_id` resolution: when the bundle provides `provider_id`,
the verifier uses it directly. When `provider_id` is absent, the
verifier MUST NOT scan all known providers. The fallback order is:
(1) explicit `--provider-id` CLI argument, (2) a single matching
cached entry's `provider_id` under the configured coordinator. If
neither yields a `provider_id` AND no `--pubkey` is supplied, the
verifier exits `64` per §10.4 "Provider-id requirements" — the
verifier MUST NOT emit `inconclusive` for missing-input cases.
Pubkey-byte scanning across providers re-introduces the
identity-loss problem audit A4 named.

**Explicit-vs-live divergence handling (S5):** Whenever an
explicit pubkey is supplied AND the verifier is not running with
`--offline`, the verifier MUST attempt the live `/v1/receipt-keys`
fetch in the background. If the live pubkey for the supplied
`provider_id` differs from the explicit one, the verifier MUST
record a `warnings[]` entry in JSON output with kind
`explicit_vs_live_divergence` and the differing live pubkey. The
explicit pubkey still wins for `result`; the warning is recorded
regardless of `--quiet` (which suppresses only stderr emission,
not the warning record itself). With `--offline`, the live check
is skipped and a `warnings[]` entry of kind `live_check_skipped`
is recorded for output transparency.

If sources (1), (2), and (3) all fail to yield a trusted pubkey
(no explicit, no fresh cached entry, `/v1/receipt-keys`
unreachable or returns no matching entry), the result is
`inconclusive`. A verifier MUST NOT fall back to "trust the
receipt's embedded `provider_pubkey` on faith."

#### 10.2.1 Rotation-grace behavior

A receipt issued under the previous key during the §7.5.2 rotation
grace window MUST verify `valid` ONLY when ALL of the following
hold:

1. The resolved `/v1/receipt-keys/<provider_id>` response (live or
   cached) contains a non-null `receipt_pubkey_prev` block with a
   `pubkey` field matching the receipt's `provider_pubkey`.
2. The receipt's `unix_ts` satisfies
   `rotated_at - 60s ≤ unix_ts ≤ expires_at`, where `rotated_at`
   and `expires_at` are taken from the `receipt_pubkey_prev`
   block.

The `-60s` slack matches the v0.1 AC-11 invariant and absorbs
provider-side clock skew within the rotation moment. A previous-
key match OUTSIDE this interval MUST verify `invalid`, NOT
`valid` or `inconclusive`: the coordinator has explicitly named the
window during which the previous key was endorsed, and a receipt
outside it is one of (a) a clock-cheating provider attempting to
extend the grace, (b) a stale receipt the buyer is presenting late
(out of contract), or (c) a forgery. None of these warrant
`valid`.

A receipt whose `provider_pubkey` matches neither `receipt_pubkey`
nor `receipt_pubkey_prev.pubkey` for the resolved `provider_id`
MUST be `invalid`, not `inconclusive`: the coordinator has
explicitly stated which keys it endorses for this provider, and
the receipt's key is not among them.

### 10.3 Canonicalization parity

The verifier MUST canonicalize the buyer-held prompt and response
using **bit-identical** rules to those §3.2 and §§4-5 pin for the
provider-side signing path. Specifically:

- JCS per RFC 8785, with the SPEC-015 v0.1.1 §3.2 extensions
  (RFC 8785 §3.2.2.3 float handling and explicit NFC normalization
  of natural-language strings).
- Prompt canonical object per §4.2 (16-key shape).
- Output canonical object per §5.1 (`content` / `tool_calls` /
  `finish_reason`).

A v0.2-compliant verifier that diverges from these rules is
non-conforming. A verifier MUST NOT add a "lenient" mode that
accepts non-canonical inputs: doing so destroys the cryptographic
property that makes verification meaningful.

If a buyer's tool has re-serialized or pretty-printed the response
JSON before passing it to `macprovider verify`, the canonicalization
step (which re-parses the response to its abstract value and
re-emits canonical bytes) MUST still reproduce the same
`output_hash` the provider signed. If it does not, the receipt is
`invalid`, not "verifier needs to be more lenient."

The Go port of `RFC8785JCS.swift` shipped with the v0.2 verify CLI
MUST include a parity test (`testdata/jcs_parity.json` — same
inputs, same canonical outputs across Swift and Go) wired as a CI
gate. Any drift between the two implementations MUST fail CI
before the verify binary can be released.

### 10.4 Inputs, outputs, exit codes

The verifier MUST accept these input shapes:

1. **Header + hashes mode:** `macprovider verify --receipt <base64>
   --prompt-hash <hex> --output-hash <hex> [--provider-id <id>]` —
   for callers who have already canonicalized and hashed the
   request/response. `--provider-id` is REQUIRED in this mode
   UNLESS `--pubkey` is also supplied (see §10.4 "Provider-id
   requirements" below); without it the live resolver cannot be
   addressed.
2. **Bundle mode:** `macprovider verify --bundle <path>
   [--provider-id <id>]` — bundle JSON shape pinned in §10.4.1.
   The bundle's `provider_id` field MAY be omitted; if so,
   `--provider-id` becomes REQUIRED for online verification.
   `--provider-id` (when supplied) MUST match the bundle's
   `provider_id` (when also present); a mismatch is a usage error
   (exit 64).
3. **Stdin mode:** `cat bundle.json | macprovider verify -
   [--provider-id <id>]` — same shape as bundle mode, read from
   stdin. Same `--provider-id` rules.

A verifier MAY accept additional input shapes (e.g. raw HTTP
response capture) as long as they reduce to one of the three above
before the §10.0 algorithm runs.

**Provider-id requirements (CF5 / CF7 normative):** The §10.7
resolver endpoint is addressed by `provider_id`. The verifier MUST
obtain `provider_id` from one of:

1. The `--provider-id <id>` CLI argument (first-class input).
2. The bundle's `provider_id` field (bundle/stdin modes only).
3. A single matching cached entry for `receipt_pubkey` under the
   configured coordinator (degenerate "I've seen exactly one of
   these before" path; verifier MUST NOT scan multiple cached
   entries).

**Without `--pubkey` (online verification path):** `provider_id`
MUST be obtained from (1)/(2)/(3) before the verifier runs. If
none of those sources yield a `provider_id`, the verifier MUST
reject the invocation with exit code `64` (usage error) and a
clear error message naming `--provider-id` as the missing input.
The verifier MUST NOT run to completion and emit `inconclusive` in
this case: the receipt may be perfectly valid, but the buyer has
not supplied enough information to reach the trust root. This is
a CLI contract violation, not a trust-root failure. Other
"missing required argument" cases (`--receipt`, `--bundle`) follow
the same exit-64 convention.

**With explicit `--pubkey`:** online verification does NOT require
`provider_id` to produce `valid` — the explicit pubkey serves as
the trust root. The verifier MUST still attempt to record
`provider_id` (from sources 1/2/3) for output reporting and the
live divergence-warning check (§10.2). If no `provider_id` is
recoverable AND the verifier is online, JSON output emits
`provider_id: null` and `warnings[]` gains a
`live_check_skipped` entry with `reason:
"provider_id_unresolvable"`. The verifier MUST NOT
fingerprint-scan across providers under any circumstance.

The verifier MUST NOT use `inconclusive` as a substitute for the
missing-provider-id exit-64 case: `inconclusive` is reserved for
trust-root failures the verifier discovered during execution, not
for CLI contract violations the verifier knows at parse time.

#### 10.4.1 Bundle JSON shape

```json
{
  "bundle_version": 1,
  "receipt": "<base64(JCS(T))>.<base64(SIG)>",
  "request": { "model": "...", "messages": [ ... ], ... },
  "response": { "id": "...", "choices": [ ... ], "usage": { ... } },
  "provider_id": "m1-anon"
}
```

- `bundle_version` (REQUIRED, integer): pinned to `1` in v0.2.x. A
  verifier MUST reject any other value as an **input format error**
  with exit code `65` per §10.4.3. (Unsupported `bundle_version` is
  data that the verifier cannot parse, not a CLI usage mistake.)
  v0.3+ MAY introduce `bundle_version: 2` for additive fields;
  v0.3+ verifiers MUST continue to accept `bundle_version: 1`.
- `receipt` (REQUIRED, string): the verbatim value of the
  `X-MacProvider-Receipt` response header, which per §3.4 has the
  shape `<base64(JCS(T))>.<base64(SIG)>` (two base64 segments
  separated by a literal `.`).
- `request` (REQUIRED, object): the OpenAI
  `/v1/chat/completions` request body as captured by the buyer.
  This is the raw request as the buyer's HTTP client saw it; the
  verifier MUST NOT require pre-canonicalization or pre-population
  of optional fields. Any §4.2 canonical-prompt field absent from
  the captured request canonicalizes as JSON `null` per the locked
  v0.1 §4.2 rule. Buyers who use the OpenAI SDK with only the
  required `model` + `messages` parameters MUST be able to bundle
  the SDK-sent request unchanged and have it verify.
- `response` (REQUIRED, object): the OpenAI completion response
  as captured by the buyer. Same rule: raw, no pre-canonicalization.
- `provider_id` (OPTIONAL, string): the provider identifier as
  surfaced by the coordinator. When present, this is used as the
  primary key for §10.2 step 2/3 pubkey resolution and §10.2.1
  rotation-grace lookup. When absent, the verifier follows the
  §10.4 "Provider-id requirements" fallback order (explicit
  `--provider-id`, then single-match cache); if neither yields a
  `provider_id` AND no `--pubkey` is supplied, the verifier exits
  `64` (usage error) before any verification runs. The verifier
  MUST NOT emit `inconclusive` for missing-input cases.

A v0.2 verifier MUST reject unknown top-level keys with exit code
`65` (input format error per §10.4.3). This prevents future
ambiguity about field semantics and forces forward-compatibility
changes through the `bundle_version` bump.

#### 10.4.2 Output modes

`--json` MUST emit a single line of JSON conforming to the field
table below.

**Top-level fields:**

| Field | Disposition | Type | Notes |
|---|---|---|---|
| `result` | REQUIRED | enum string | One of `valid`, `invalid`, `inconclusive`. |
| `reason` | REQUIRED | enum string | See "reason values" table below. |
| `provider_id` | REQUIRED-when-resolved, else `null` | string\|null | The coordinator-attested `provider_id` used for pubkey lookup. `null` when result is `inconclusive` and no provider could be identified. |
| `model_id` | REQUIRED-when-resolved, else `null` | string\|null | Read from the receipt tuple. `null` only when the tuple itself could not be parsed (a `65` exit-code path that produces no JSON anyway). |
| `signed_at` | REQUIRED-when-resolved, else `null` | integer\|null | The receipt's `unix_ts`. Same null rule as `model_id`. |
| `trust_source` | REQUIRED | enum string | One of `explicit_pubkey`, `cache`, `live`, `none`. The last only when `result == "inconclusive"`. |
| `coordinator_host` | REQUIRED-when-trust_source-is-network-derived, else `null` | string\|null | The coordinator host that supplied the trust root. Required when `trust_source` is `cache` (cache origin host) or `live`. `null` for `explicit_pubkey` (no coordinator involved) and `none`. |
| `details` | REQUIRED-when-invalid, else absent | object | See "details schema" below. MUST be present when `result == "invalid"`. MUST be absent otherwise. |
| `warnings` | OPTIONAL | array of objects | Each entry has a `kind` (enum) and `kind`-specific fields. See "warnings schema" below. Array MAY be empty or absent when no warnings apply. |

**`reason` values (enum, exhaustive for v0.2.x):**

- For `valid`: `signature_and_canonicalization_match`
- For `invalid`: `signature_verify_failed`, `prompt_hash_mismatch`,
  `output_hash_mismatch`, `pubkey_not_endorsed`,
  `previous_key_outside_grace_window`, `bundle_pubkey_provider_mismatch`
- For `inconclusive`: `pubkey_unresolvable`,
  `provider_id_not_in_pool`, `cache_stale_and_live_unreachable`

v0.3+ MAY extend the enum additively; v0.3+ verifiers MUST emit
v0.2-known values for v0.2-mapped cases.

**`details` schema (REQUIRED when `result == "invalid"`):**

| Field | Type | Notes |
|---|---|---|
| `field` | enum string | One of `signature`, `prompt_hash`, `output_hash`, `pubkey`, `grace_window`. |
| `computed` | string | The value the verifier computed (hex for hashes, base64 for pubkey, etc.). Absent only when `field == "signature"` (the signature check is opaque). |
| `receipt` | string | The value carried by the receipt for comparison. |
| `extra` | object | OPTIONAL, `field`-specific extra context (e.g. `rotated_at`/`expires_at`/`unix_ts` for `grace_window`). |

**`warnings[]` schema:**

| `kind` value | Additional fields | When emitted |
|---|---|---|
| `explicit_vs_live_divergence` | `live_pubkey` (string), `coordinator_host` (string) | Explicit `--pubkey` was used AND a live `/v1/receipt-keys` fetch succeeded AND returned a different pubkey for the same `provider_id`. |
| `live_check_skipped` | `reason` (one of `offline_flag`, `network_unreachable`, `provider_id_unresolvable`) | The live divergence check did not run. `offline_flag`: `--offline` was passed. `network_unreachable`: live fetch failed (network down, 5xx, timeout, 429). `provider_id_unresolvable`: explicit `--pubkey` was supplied AND no `provider_id` was recoverable from CLI, bundle, or cache (the verifier had nothing to address the resolver with). |
| `non_default_coordinator` | `coordinator_host` (string) | A non-default coordinator (i.e. not `coordinator.malibu.tech`) was used as the trust-root source. |
| `non_default_tls_trust` | `ca_file_path` (string) | The `MACPROVIDER_VERIFY_TLS_CA_FILE` env var was honored and successfully augmented the TLS trust pool used to reach the coordinator. Surfaces silent trust widening so a buyer running under a wrapper script (CI helper, devcontainer setup, ~/.profile modification by malware) where the env var has been set to point at an attacker-controlled CA chain sees a visible indicator. Added in SPEC-015 v0.3.4 (issue #128). |
| `clock_skew` | `unix_ts` (int), `system_time` (int), `delta_seconds` (int) | Receipt `unix_ts` differs from the verifier's system clock by more than 24 hours. Informational only — does NOT downgrade `result` per §10.6. |

A verifier MUST emit `warnings[]` entries regardless of `--quiet`
(which suppresses only stderr emission, not the JSON record).

**Example outputs:**

```json
{"result":"valid","reason":"signature_and_canonicalization_match","provider_id":"m1-anon","model_id":"qwen2.5-7b-instruct-q4","signed_at":1719144000,"trust_source":"live","coordinator_host":"coordinator.malibu.tech","warnings":[]}
```

```json
{"result":"invalid","reason":"output_hash_mismatch","provider_id":"m1-anon","model_id":"qwen2.5-7b-instruct-q4","signed_at":1719144000,"trust_source":"live","coordinator_host":"coordinator.malibu.tech","details":{"field":"output_hash","computed":"ab12...","receipt":"cd34..."}}
```

```json
{"result":"inconclusive","reason":"cache_stale_and_live_unreachable","provider_id":"m1-anon","model_id":"qwen2.5-7b-instruct-q4","signed_at":1719144000,"trust_source":"none","coordinator_host":null,"warnings":[{"kind":"live_check_skipped","reason":"network_unreachable"}]}
```

**Default (non-JSON) human-readable output** is a single line:

```
valid (m1-anon · qwen2.5-7b-instruct-q4 · signed 2026-06-23T08:00Z · trust=live@coordinator.malibu.tech)
invalid: output_hash mismatch (computed=ab12... receipt=cd34...)
inconclusive: cache stale and /v1/receipt-keys unreachable on coordinator.malibu.tech
```

When the `trust_source` is `live` or `cache`, the human-mode line
MUST include the coordinator host (rendered as
`trust=<source>@<host>`). Warnings MUST be printed to stderr (one
per line, prefixed `warning:`) unless `--quiet` suppresses stderr.

The v0.2 CLI SHOULD include a `--explain` flag that prints §10.6
verbatim to stderr after a `valid` result, so a buyer who reads
`valid` is reminded of what `valid` does and does not mean.

#### 10.4.3 Exit codes

| Code | Meaning |
|---|---|
| 0 | `valid` |
| 1 | `invalid` (signature, canonicalization, coordinator-rejected pubkey, or previous-key-outside-grace-window) |
| 2 | `inconclusive` (pubkey unresolvable, provider_id not in pool per §10.7 404, cache stale + live unreachable) |
| 64 | usage error (per `sysexits.h`, `EX_USAGE`) — unknown CLI flag, missing required CLI argument, mutually-exclusive flags combined (e.g. `--bundle` + `--receipt`), invalid value format for a CLI flag (e.g. malformed `--pubkey` base64) |
| 65 | input format error (per `sysexits.h`, `EX_DATAERR`) — malformed bundle JSON, missing required bundle field, unknown bundle top-level key, unsupported `bundle_version`, malformed receipt header value (cannot split on `.`), base64 decode failure on tuple or signature, tuple JSON not well-formed or wrong key set |

These exit codes are normative. Scripts and CI pipelines WILL rely
on them. A future v0.3+ verifier MUST preserve the 0/1/2/64/65
mapping; adding new exit codes for new failure modes is allowed
only in the >65 range (e.g. 66 for cache-corruption diagnostics).

**`64` vs `65` boundary:** `64` is for problems with how the
verifier was *invoked*; `65` is for problems with the *data* the
verifier was asked to verify. An unsupported `bundle_version` is
data the verifier cannot parse, so it is `65`. A typo'd flag is
how the verifier was invoked, so it is `64`. A malformed
`--pubkey` argument is `64` (the flag value is malformed,
preventing invocation), but a malformed `receipt` field inside a
syntactically-valid bundle is `65` (the bundle was accepted, but
its receipt content is unparseable).

#### 10.4.4 Flag interaction matrix

The v0.2 CLI flags are listed in §10.4. This matrix pins their
interaction semantics for combinations that are not obvious from
individual flag descriptions.

| Flag combination | Live `/v1/receipt-keys` fetch? | Divergence warning? | Stderr emission? | Result downgrade? |
|---|---|---|---|---|
| (no `--pubkey`, no `--offline`) | YES (default path) | n/a | per-mode | n/a |
| `--pubkey P` (no `--offline`) | YES (background, for divergence check) | YES if live differs | per `--quiet` | NO — explicit wins |
| `--pubkey P --offline` | NO | n/a — `live_check_skipped` warning emitted | per `--quiet` | NO |
| `--offline` (no `--pubkey`) | NO | n/a | per `--quiet` | `inconclusive` if cache miss / stale |
| `--quiet` (alone) | per other flags | per other flags | SUPPRESSED (stderr only) | NO |
| `--quiet --json` | per other flags | per other flags | SUPPRESSED (stderr); warnings still in JSON `warnings[]` | NO |
| `--coordinator H` (or env) | YES, against host `H` | per other flags | per `--quiet` | NO; `non_default_coordinator` warning if `H != coordinator.malibu.tech` |
| `--explain` | per other flags | per other flags | §10.6 verbatim printed to stderr after valid result | NO |
| `--bundle B --receipt R` | n/a | n/a | n/a | USAGE ERROR (exit 64) — mutually exclusive |
| `--bundle -` (stdin mode) | per other flags | per other flags | per `--quiet` | NO |
| `--provider-id I` + header+hashes mode (no `--pubkey`) | YES, addressed by `I` | n/a (no explicit) | per `--quiet` | NO if resolver responds; `inconclusive` if `I` returns 404 |
| `--provider-id I` + header+hashes mode + `--pubkey P` | YES (background only) | YES if live differs | per `--quiet` | NO — explicit wins |
| `--provider-id I` + bundle mode where bundle also has `provider_id: J` and `I != J` | n/a | n/a | n/a | USAGE ERROR (exit 64) — mismatched provider identity |
| `--provider-id I` + bundle mode where bundle has `provider_id: I` (or none) | per other flags | per other flags | per `--quiet` | NO |
| header+hashes mode (no `--provider-id`, no `--pubkey`) | n/a | n/a | n/a | USAGE ERROR (exit 64) — `--provider-id` required for online verification without explicit pubkey |
| bundle/stdin mode (no bundle `provider_id`, no `--provider-id`, no `--pubkey`, no single-match cache entry) | n/a | n/a | n/a | USAGE ERROR (exit 64) — same as above; provider id unobtainable for online verification |
| header+hashes mode + `--pubkey P` (no `--provider-id`) | NO (no `provider_id` to address) | n/a | per `--quiet`; `live_check_skipped` warning with `reason: provider_id_unresolvable` | NO — explicit pubkey wins; `provider_id: null` in JSON output |

**`--provider-id` summary:** REQUIRED for online verification in
header+hashes mode unless `--pubkey` is supplied. OPTIONAL in
bundle/stdin modes when the bundle carries `provider_id` (the
bundle field takes precedence on absence; mismatch is a usage
error). When neither source provides `provider_id` AND no
`--pubkey` is supplied, the verifier rejects the invocation with
exit code `64` per §10.4 "Provider-id requirements" — the
verifier MUST NOT scan and MUST NOT emit `inconclusive` in this
case (it is a CLI contract violation, not a trust-root failure).

The matrix is normative. A verifier MUST NOT introduce flag
combinations whose semantics aren't covered here or aren't
trivially derivable from §10.4 / §10.4.2 / §10.5. A v0.3+ verifier
MAY add new flags; if a new flag interacts with any v0.2 flag, the
v0.3+ spec MUST extend this matrix.

`--quiet` semantics (final): suppresses all stderr emission
(including `warning:` lines and `--explain` output). Does NOT
suppress JSON `warnings[]` records. Does NOT change exit code.

### 10.5 Network behavior

The verifier MUST NOT make any network call beyond
`GET /v1/receipt-keys/<provider_id>` (§10.7) on the configured
coordinator host for pubkey resolution. No telemetry. No opt-in
analytics. No version-check beacon. No crash reporting. No update
check. No fallback to `/poolz` (which is operator-only per SPEC-002
v1.4 §FR-O2). A buyer running
`macprovider verify --offline --pubkey <p> ...` on an air-gapped
Mac MUST observe zero network traffic (verifiable via packet
capture or a network sandbox that denies all egress).

The live fetch is a single `GET` over HTTPS with a 5-second
connection-plus-read timeout. No retries. The verifier MUST NOT
follow HTTP redirects beyond the configured coordinator host
(default: `coordinator.malibu.tech`; configurable via
`--coordinator` flag or `MACPROVIDER_COORDINATOR` environment
variable). Redirects whose `Location` resolves to a different host
MUST be treated as a fetch failure (contributing to `inconclusive`
when no fresh cache exists), not silently followed. A redirect to
the SAME host (e.g. http→https upgrade) MAY be followed.

A buyer who wants different timeout / retry semantics MUST
pre-populate the cache and run with `--offline`. The verifier MUST
NOT expose `--timeout` or `--retries` flags in v0.2: variability
in fetch semantics across deployments would make `inconclusive`
mean different things to different buyers.

When the configured coordinator host is NOT the default
`coordinator.malibu.tech`, the verifier MUST record a
`non_default_coordinator` warning per §10.4.2 in every output
(JSON and human-mode stderr unless `--quiet`). The trust boundary
is coordinator-specific; making non-default coordinators visible
is a buyer-protection invariant.

### 10.6 Trust boundary

A `valid` result from `macprovider verify` proves **exactly this**:
a holder of the provider's private key signed a canonical tuple
containing the values (`model_id`, `prompt_hash`, `output_hash`,
`provider_pubkey`, `ttft_ms`, `tokens_out`, `unix_ts`), AND the
pubkey that signature checks against is the one the coordinator
publishes for the resolved `provider_id` at verification time (or
was within the §7.5.2 rotation grace window per §10.2.1).

The phrasing "signed a tuple containing `unix_ts`" is deliberate:
the signature commits the holder of the private key to the claimed
timestamp value, but does NOT prove that value reflects the real
wall-clock time at signing. The signed-at attestation is about
content, not chronology.

A `valid` result DOES NOT prove:

- **That the response was generated by the model named in
  `model_id`.** Model-hash binding is the SPEC-011 v0.5
  catalog-signing surface; folding `model_hash` into the receipt
  tuple is the v0.3+ candidate per §15 Q6. A v0.2 verifier MUST
  NOT silently treat `valid` as "model attestation."
  **v0.3 supersession (NORMATIVE).** This bullet is SUPERSEDED
  by §M.3.3 for v0.3 `valid` results that carry non-null
  `model_hash` AND were resolved against a fresh, signature-valid,
  non-expired catalog. For v0.3 `valid` results with null
  `model_hash` OR without catalog arguments, this bullet
  REMAINS in force unchanged. v0.1 / v0.2 verifiers (locked
  releases) continue to read this bullet at full strength.
- **That `unix_ts` is honest.** The timestamp is provider-reported.
  The verifier MAY optionally cross-check against a buyer-recorded
  received-at timestamp with an operator-set skew window, but v0.2
  does NOT require this check (see §15 Q4), and a `valid` result
  without skew-check does NOT attest to timestamp honesty.
- **That no other party also saw the response.** Privacy
  properties are SPEC-008 / Cluster E territory and are orthogonal
  to receipt verification. A receipt with `valid` says nothing
  about whether the operator, the coordinator, the gateway, or
  another buyer also observed the response bytes.
- **That the pubkey itself is trustworthy in some absolute sense.**
  v0.1's §8 trust root (`/poolz`) is operator-mutable. The v0.1
  SPEC is honest about this; v0.2 inherits that honesty without
  weakening it. The §15 Q1 stronger-trust-root work (TUF-style
  signing, on-chain anchor) is v0.3+ scope.
- **That the response was delivered to the buyer who is now
  verifying it.** A receipt commits to (prompt, output, provider);
  it does not commit to `request_id` or a buyer-supplied nonce.
  Replay-resistance is §15 Q2 (v0.2 verifier scope per the v0.1
  text, now deferred to v0.3+ — see §15 Q2 update below).
- **That this was the only receipt issued for this response.** A
  receipt does not commit to uniqueness. A provider could in
  principle issue multiple receipts for the same canonical
  (prompt, output) tuple — to different buyers, on different
  reconnects, or by re-running the same prompt. Each receipt
  independently verifies on its own merits; `valid` says nothing
  about whether another `valid` receipt also exists. This matters
  for accounting (a buyer cannot use a receipt as proof of
  sole-delivery for billing-dispute purposes) and is orthogonal
  to the replay-resistance concern above.

A `valid` result from `macprovider verify` is therefore a narrow,
specific proof: cryptographic evidence that some holder of the
provider's signing key — which the coordinator currently endorses
— attests to having produced this (prompt → output) mapping. It
is necessary for verifiable inference. It is not sufficient.
SPEC-015 v0.3+ closes the remaining gaps (model attestation,
timestamp honesty, replay resistance, stronger trust root) in
priority order determined by audit-loop and operator demand.

A verifier's human-mode output line for `valid` SHOULD frame this
scope visibly — e.g. by including the phrase `signed by m1-anon`
rather than `verified m1-anon`. The `--explain` flag of §10.4.2
exists precisely to make this trust boundary unmissable to a
buyer who is about to act on a `valid` result.

### 10.7 SPEC-002 v1.5 candidate annotation: `GET /v1/receipt-keys/<provider_id>`

v0.2's verifier contract depends on a public, buyer-callable
pubkey-resolution endpoint that the locked SPEC-002 v1.4 surface
does not provide (`GET /poolz` is operator-only per §FR-O2;
`GET /v1/pool/check` does not return receipt-key material). v0.2
pins the buyer endpoint as a SPEC-002 v1.5 **candidate annotation**
following the same parser-optional / additive / non-breaking
pattern v0.1 used for `receipt_pubkey` (SPEC-002 v1.4 candidate)
and `provider_receipt_public_key` (SPEC-001 v1.6 candidate).

A SPEC-002 v1.5 release MUST add the endpoint as specified below;
SPEC-015 v0.2 implementations MAY use it before SPEC-002 v1.5 LOCK
provided the coordinator returns the exact shape.

**Endpoint:** `GET /v1/receipt-keys/<provider_id>`

- **Host placement:** Same nginx route split as the existing
  buyer-facing `GET /v1/pool/check` (SPEC-002 v1.4 §FR-O3) — i.e.
  on the `buyer_port` route, NOT the operator `/poolz` route.
- **Authentication:** NONE (public). A buyer with no operator
  credentials MUST be able to call this endpoint. Pubkey
  attestation is a public-trust-root surface — the same property
  TUF / on-chain anchoring (§15 Q1) layers on top of.
- **Rate limiting:** Operator-configurable; recommended floor
  `10 req/sec` per source IP, with a `429` response on overage.
  This protects the coordinator against amplification attacks
  while leaving headroom for batch buyer-side verification.
  **Source-IP derivation (issue #125).** Per-source bucket keying
  goes through the operator-configured `proxy.trusted_proxies`
  CIDR set (see SPEC-002 v1.4.x `proxy.trusted_proxies` block):
  when the immediate peer is in the trusted set the coordinator
  parses `X-Forwarded-For` rightmost-untrusted-hop first, falling
  back to `X-Real-IP`; for untrusted peers the forwarded headers
  are ignored and the peer's own IP is the bucket key (spoof
  rejection).
- **Caching headers:** Response MUST include `Cache-Control: public,
  max-age=300` (5 minutes). Verifiers SHOULD NOT bypass this cache
  via `Cache-Control: no-cache` request headers — staleness up to
  5 minutes is acceptable for receipt verification, and bypass
  attacks would defeat the rate-limit.

**Response (success, HTTP 200):**

```json
{
  "provider_id": "m1-anon",
  "receipt_pubkey": "<44-char base64 ed25519 pubkey>",
  "receipt_pubkey_prev": null | {
    "pubkey": "<44-char base64 ed25519 pubkey>",
    "rotated_at": "<RFC3339 UTC>",
    "expires_at": "<RFC3339 UTC>"
  },
  "fetched_at": "<RFC3339 UTC; server-side now()>"
}
```

The `receipt_pubkey` and `receipt_pubkey_prev` fields MUST be
sourced from the same coordinator memory the SPEC-002 v1.4 §FR-O2
`/poolz` response reads (i.e. the in-memory `Provider.ReceiptPubkey`
state per §13). Response MUST NOT leak any operator-sensitive
field (e.g. `endpoint_url`, `hostname`, `connected_at`,
`slots_total`, `throughput_tps_estimate`) — only the receipt-key
tuple.

**Response (error):**

- **404** — `provider_id` not in the current pool. Body is the
  SPEC-002 §FR-X-N standard JSON error envelope with
  `error.code = provider_not_found`. The verifier treats this as
  `inconclusive` with `reason: "provider_id_not_in_pool"`, NOT
  `invalid`: the provider may have been retired, but the receipt
  is not necessarily a forgery.
- **429** — rate limit exceeded. Verifier treats as a fetch
  failure (contributing to `inconclusive` if no cache), MUST NOT
  retry within the same verification invocation.
- **5xx** — coordinator internal failure. Same fetch-failure
  treatment as `429`.

**Reference behavior on rotation:** Within the §7.5.2 7-day grace
window, the response carries BOTH `receipt_pubkey` (the new key)
AND `receipt_pubkey_prev` (the previous key block, with
`rotated_at` and `expires_at`). After the grace window expires,
the coordinator MUST drop `receipt_pubkey_prev` (set to `null`).
This precisely mirrors the existing `/poolz` `receipt_pubkey_prev`
shape so SPEC-002 v1.5 reuses the v1.4 data model.

**Why this is a candidate annotation, not an operator demand:**
the SPEC-002 v1.5 amendment is additive (new endpoint, no changes
to existing endpoints), non-breaking (`/poolz` retains operator-
only access), parser-optional (a SPEC-002 v1.4 coordinator without
the new endpoint returns `404`; verifier treats as `inconclusive`
and falls back to explicit/cache). This matches the SPEC-008 v0.3
§5.3 / §5.7 candidate-annotation pattern used throughout the
v0.1-line cross-cuts.

---

## §M. Model-hash binding (v0.3 NORMATIVE)

v0.3 extends the receipt tuple to bind which model weights actually
served the buyer, closing the v0.1 / v0.2 gap the §10.6 trust
boundary names explicitly ("DOES NOT prove that the response was
generated by the model named in `model_id`"). The infrastructure
to do this already exists in production; v0.3 binds it into the
receipt:

- **SPEC-011 v0.5 R-3.3.1** defines provider-reported `model_hash`
  on the heartbeat — raw 64-char lowercase hex of the loaded MLX
  container.
- **`scripts/sign-catalog.go`** produces ed25519-signed model
  catalogs mapping `model_id → expected_hash` (the per-entry
  field is named `sha256` per `scripts/sign-catalog.go:31`).
- **`phase4-coordinator/internal/tier2/catalog.go`** parses + verifies
  signed catalogs (in-memory shape `ParsedCatalog` per `catalog.go:45`).
- **Production observation mode is LIVE.** As of 2026-06-24 Pearl
  journald shows 342+ `model_hash_verified` events over the last
  7 days for air5 against catalog
  `macprovider-tier2-model-catalog-2026-05-31`, all
  `decision:"allow", reason:"hash_match"`.

The missing piece v0.3 closes: the receipt tuple does not include
`model_hash`, so a buyer-side verifier cannot use any of the
above. v0.3 extends the tuple, the verify CLI, and the `/poolz`
surface to make catalog-based hash verification a buyer-driven
choice.

**Relationship to `RequireHashVerified` (Entry 80).** v0.3 is
ORTHOGONAL to coordinator-side hash enforcement. The
`Tier2Config.RequireHashVerified` flag
(`phase4-coordinator/internal/config/config.go:142,335`) remains
at its `false` default per the
`beta/DECISION_CRITERIA.md` 2026-06-22 Entry 80 ruling. v0.3
receipts BIND the hash from any provider that opts into SPEC-011
hash reporting (whether or not the coordinator enforces); the
buyer decides whether to demand catalog-match. AC-40 pins this
orthogonality.

### §M.0 v0.3 receipt tuple (NORMATIVE)

A v0.3 receipt is a JCS-canonicalized JSON object with EXACTLY the
following NINE fields and no others. The table rows are presented
in JCS canonical order — UTF-16 code-unit lexicographic per RFC
8785 §3.2.3 — so this is the literal byte order
`RFC8785JCS.swift` will emit:

| Field | Type | Definition |
|---|---|---|
| `model_hash` | string (64 lowercase hex) OR JSON null | The SHA-256 of the MLX container the provider had loaded at receipt-generation time, sourced from the SPEC-011 v0.5 R-3.3.1 heartbeat state. MUST be a raw 64-char lowercase hex string with no `sha256:` prefix (matching SPEC-008 §5.3-5.6 wire form and SPEC-011 R-3.3.1). MUST be the JSON literal `null` if and only if the provider is running with `--enable-warm-swap=false` per SPEC-011 R-3.3.0 (and therefore has no heartbeat-reported hash to bind). See §M.2 for provenance rules. MUST NOT be the empty string; MUST NOT be absent. |
| `model_id` | string | Unchanged from v0.1.3 §3.1 — ASCII-only, case-insensitive matching for routing, verbatim-stored in the tuple. |
| `output_hash` | string (64 lowercase hex) | Unchanged from v0.1.3 §3.1. |
| `prompt_hash` | string (64 lowercase hex) | Unchanged from v0.1.3 §3.1. |
| `provider_pubkey` | string (44 char base64) | Unchanged from v0.1.3 §3.1. |
| `receipt_version` | string | Wire-shape discriminant. MUST be exactly the ASCII string `"3"` in v0.3 receipts (NOT the integer `3`, NOT `"v3"`, NOT `"0.3"`). The string-typed choice avoids the JSON-number-vs-int canonicalization edge cases the v0.1.3 §3.1 typing notes already raised. v0.4+ MAY bump this to `"4"`; v0.3 verifiers MUST treat unknown `receipt_version` values as `inconclusive: unknown_receipt_version` per §M.1.4. |
| `tokens_out` | int64 | Unchanged from v0.1.3 §3.1. |
| `ttft_ms` | int64 | Unchanged from v0.1.3 §3.1. |
| `unix_ts` | int64 | Unchanged from v0.1.3 §3.1. |

**Field omissions and extras.** A v0.3 receipt MUST contain EXACTLY
these nine keys. Verifiers MUST reject v0.3 receipts (i.e. those
with `receipt_version: "3"`) with missing or extra keys as `invalid`
with `reason: "extra_field"` or `reason: "missing_field"` and
`details.field` populated. There are no optional fields in v0.3.
The `null`-valued `model_hash` is NOT a "missing" field — it is
present with the JSON null literal per the §M.2.3 normative rule.

**Types.** `model_hash` is `string | null`. `receipt_version`,
`model_id`, `prompt_hash`, `output_hash`, and `provider_pubkey`
are JSON strings. `ttft_ms`, `tokens_out`, and `unix_ts` are JSON
integers per the v0.1.3 §3.1 numeric rules (no decimal point, no
exponent).

**JCS extension status.** No `RFC8785JCS.swift` amendments are
required for v0.3 beyond emitting two additional keys through the
existing sorted-emit path. See §M.1.5 for the proof: the new
fields are ASCII-only (so NFC is a no-op) and the `null` literal
encoding is RFC 8785 §3.2.2.2-trivial.

### §M.1 Wire and version compatibility (NORMATIVE)

#### §M.1.1 v0.3 verifier reading a v0.1 / v0.2 receipt — BACKWARD COMPAT

A v0.3 verifier given a receipt with NO `receipt_version` field
MUST:

1. Treat the receipt as `receipt_version: "1"` (the implicit v0.1
   tuple shape — the same shape v0.2 inherited unchanged).
2. Run the v0.1.3 §3.1 7-field validation: exactly the seven
   keys `model_id`, `prompt_hash`, `output_hash`, `provider_pubkey`,
   `ttft_ms`, `tokens_out`, `unix_ts` — no missing, no extra.
3. Canonicalize per v0.1.3 §3.2 (7-field JCS) and check the
   signature against the resolved pubkey per §10.2.
4. Report `valid` / `invalid` / `inconclusive` per the §10.1
   tri-state, exactly as a v0.1 / v0.2 verifier would.
5. Skip the catalog check entirely. The v0.1 / v0.2 receipt
   carries no `model_hash` to compare against. If `--catalog`-
   family arguments WERE supplied, the JSON output's
   `warnings[]` MUST include a single entry of kind
   `catalog_skipped_legacy_receipt` naming the receipt's
   `provider_pubkey` and stating that the receipt predates v0.3
   wire shape.

The `valid` result for a v0.1 / v0.2 receipt under a v0.3
verifier carries the v0.1 / v0.2 §10.6 trust boundary, NOT the
v0.3 §M.3.3 trust boundary. The verifier's `--explain` output
MUST disclose that the legacy receipt cannot attest model-hash
binding even when a catalog was supplied to the verifier.

#### §M.1.2 v0.1 / v0.2 verifier reading a v0.3 receipt — FORWARD INCOMPAT

A v0.1 or v0.2 verifier (the locked v0.1.3 / v0.2.4 releases)
given a v0.3 receipt MUST report `invalid`. The failure path:

1. The receipt has 9 keys, two of which (`model_hash` and
   `receipt_version`) are unrecognized.
2. The v0.1 / v0.2 §3.1 "MUST contain EXACTLY these seven keys"
   rule rejects the receipt as `invalid` with
   `reason: "extra_field"` (or implementation-equivalent)
   BEFORE the signature check. The signature would have failed
   anyway — the signed canonical bytes differ — but the field-
   shape check fires first.

v0.3 does NOT amend v0.1 / v0.2 verifier behavior retroactively;
those releases are locked. The operational consequence: buyers
holding v0.1 / v0.2 verifier releases will see v0.3 receipts as
`invalid`. This is unavoidable for the v0.1 / v0.2 lock state.
v0.4+ SHOULD adopt the §M.1.4 unknown-version path so a future
v0.4 receipt against a v0.3 verifier reports `inconclusive:
unknown_receipt_version` rather than `invalid`. Buyers MUST
coordinate verifier upgrades with provider upgrades during the
v0.2 → v0.3 transition; release notes accompanying the v0.3
implementation MUST call this out.

#### §M.1.3 v0.3 verifier reading a v0.3 receipt — NORMAL PATH

Per §M.0 (nine fields exactly, signature checked per §10 against
the resolved pubkey), catalog checked per §M.3 if both
`--catalog`-family arguments AND a non-null `model_hash` are
present.

#### §M.1.4 v0.3 verifier reading an unknown `receipt_version` — FORWARD COMPAT

If a v0.3 verifier reads a receipt whose `receipt_version` field
is PRESENT and NOT equal to `"3"` (and not equal to any other
v0.x value the verifier was specifically built to handle), the
verifier MUST:

1. Report `inconclusive` with `reason: "unknown_receipt_version"`
   and exit code `2`.
2. NOT attempt to canonicalize or signature-check the unknown
   version.
3. Include the unknown version string under
   `details.receipt_version` in the JSON output.
4. NOT use field count as a fallback heuristic for version
   detection — field count is a `valid`/`invalid` discriminant
   for a known version, not a version detector.

This locks v0.4+ as a forward-compat path: a v0.4 receipt
against a v0.3 verifier reports `inconclusive` (NOT `invalid`),
matching the §10.1 `inconclusive` tri-state intent.

#### §M.1.5 Why no `RFC8785JCS.swift` amendments are required

The v0.1.3 §3.2 JCS profile (UTF-16 key order, RFC 8785 string
escape, NFC normalization on natural-language strings, RFC 8785
number handling) handles the v0.3 9-field tuple WITHOUT
amendment. Per §M.0:

- `model_hash` is either ASCII (64 hex chars) or the JSON null
  literal. ASCII → NFC is a no-op. JSON null → RFC 8785
  §3.2.2.2 fixes the encoding as the literal four bytes `null`.
- `receipt_version` is the ASCII string `"3"` (or future ASCII
  strings). NFC no-op.
- The two new keys (`model_hash`, `receipt_version`) sort
  cleanly into the existing UTF-16 key order — see §M.0 for the
  emitted order. The implementation's sorted-emit path picks
  up the new keys with no code change beyond constructing the
  tuple to include them.

The §3.2 float-handling extension (step 4) was added in v0.1.3
for the §4 prompt canonical object (`temperature`, `top_p`,
`presence_penalty`, `frequency_penalty`). Neither v0.1/v0.2 nor
v0.3 tuple-level encoding exercises floats; that extension is
still triggered only by the prompt canonical hash path.

The §3.3 signature step (`ed25519_sign(provider_receipt_private_key,
UTF-8(JCS(T)))`) and the §3.4 wire envelope (`<base64(JCS(T))>.
<base64(SIG)>`) are UNCHANGED for v0.3 — only `T`'s shape grows.

### §M.2 `model_hash` provenance (NORMATIVE)

The provider's `model_hash` value at receipt-generation time MUST
be sourced from the provider's local SPEC-011 R-3.3.1
hash-tracking state — the same value the provider reports on
heartbeats per SPEC-011 §3.3. "Most recent heartbeat" is
ambiguous in three edge cases; this section pins each.

#### §M.2.1 Heartbeat lag — post-swap, pre-heartbeat

If a SPEC-011 §3.2 warm-swap completed at T−100 ms but no
heartbeat has yet been emitted (next heartbeat scheduled at
T+200 ms), the receipt MUST commit to the POST-SWAP hash — the
SHA-256 of the in-memory container at the moment inference ran,
NOT the pre-swap hash the coordinator last received on
heartbeats.

**Rationale:** the buyer consumed the post-swap weights; the
receipt binds to what served the buyer, not to what the
coordinator most-recently knew. The implementation reads
`model_hash` from the provider-local SPEC-011 R-3.3.1
state-tracking variable, which transitions to the new hash at
SPEC-011 §3.2 `ready` re-entry — i.e. at the moment of atomic
swap, not at next-heartbeat emission.

**Coordinator/provider transient disagreement is OK.** Across
the heartbeat window the coordinator-side hash and the
provider's receipt-bound hash MAY transiently disagree. That
disagreement appears as a hash_status churn on the next
heartbeat (the coordinator's R-3.3.5 SPEC-011 path re-verifies
and `Provider.HashStatus` reflects the post-swap value). That
churn is a SPEC-011 coordinator-side audit condition, NOT a
SPEC-015 verifier-side failure. The verifier's trust root for
catalog-check is the catalog itself, NOT the coordinator's
heartbeat-derived state.

#### §M.2.2 Mid-response model swap — REFUSED (NORMATIVE)

A SPEC-011 §3.2 warm-swap MUST NOT span a single receipt-bound
response. v0.3 expresses this rule via the SPEC-011 §3.4 drain
semantics, which already make it enforceable by construction:

- A request that BEGAN on the old container and FINISHED before
  the SPEC-011 R-3.4.2 drain timeout: the runtime knows the
  inference ran entirely on the old container (R-3.4.1
  in-flight-set tracking + R-3.2.2 snapshot semantics). The
  receipt-emission code path MUST emit a receipt with the
  hash at request START — the hash that served the response,
  even if the global provider state has moved to a new hash
  mid-response. This is the §M.2.2 normative shape.
- A request that BEGAN on the old container and was R-3.4.2
  drain-timed-out: the response is HTTP 503 per SPEC-011
  R-3.4.2; v0.1.3 §12 / §6.4 already specifies no receipt for
  non-200 responses. The drain timeout itself is the audit
  trail.
- A request that ARRIVED during `loading` or `draining`:
  rejected with HTTP 503 per SPEC-011 R-3.4.4; no receipt.
- A request that BEGAN on the NEW container after the swap
  completed: receipt-emission emits the NEW hash. Normal §M.2.1
  path.

The construction is therefore: *every receipt commits to the
hash of the model that started generation for this request*, and
v0.3 forbids any other shape.

**Defence-in-depth refusal.** If the runtime detects a
swap-in-progress state at receipt-emission time AND cannot
disambiguate which container served the response (this is
not reachable under SPEC-011 R-3.4.1 / R-3.2.2 by construction;
this clause exists for future implementation regressions), the
provider MUST refuse to emit a receipt and MUST log a
`receipt_omitted` audit event with `reason:
"model_swap_violation"`. The response itself MAY still complete
normally (the buyer gets their tokens; HTTP 200) but carries
no `X-MacProvider-Receipt` header. The §6.4 receipt-omission
rules already accept this outcome.

**Deferred to v0.4+:** representing a multi-hash response in a
single receipt — i.e. a receipt that binds two `model_hash`
values for one response, one pre-swap and one post-swap. v0.3
§M.2.2 NORMATIVELY REFUSES the shape; v0.4 may design it,
particularly in the streaming-receipts context where a swap
genuinely spans a long-running response. See §15 Q5 (streaming
delivery) and the new §15 Q7 (multi-hash receipt shape).

#### §M.2.3 Absent hash — warm-swap disabled

If the provider is running with `--enable-warm-swap=false` (the
SPEC-011 R-3.1.0 default, and the production default per Entry
80), the heartbeat omits `model_hash` per SPEC-011 R-3.3.0.
The provider has no SPEC-011-sourced hash to bind into the
receipt. In this mode the provider MUST emit `model_hash: null`
in the v0.3 receipt tuple. Not the empty string. Not absence.
The JSON literal `null`, which JCS encodes as the four bytes
`null`.

A v0.3 verifier reading `model_hash: null` MUST:

1. Run the standard v0.3 verification path: §3.2 canonicalization
   over the 9-field tuple (including the literal `null`),
   signature check, prompt/output hash recomputation, exit code
   per §10.1 tri-state.
2. Skip the catalog check entirely — there is no hash to
   compare. The verifier MUST NOT report `invalid` solely
   because `model_hash` is null.
3. If `--catalog`-family arguments WERE supplied, include in
   `warnings[]` an entry of kind `catalog_skipped_null_hash`
   (NOT `catalog_skipped_legacy_receipt` — the receipt IS v0.3,
   the hash is opted-out via the warm-swap-disabled config).
4. Report `valid` if signature + canonicalization + prompt/
   output hash checks pass.

**Trust statement (NORMATIVE).** A v0.3 `valid` result for a
null-hash receipt carries the v0.1 / v0.2 §10.6 trust boundary
PLUS the explicit attestation: "the holder of the provider's
private key signed a tuple in which `model_hash` was the JSON
literal `null`." The provider is committed to the null — a
provider cannot later claim "the receipt is null because I
couldn't get a hash"; the receipt SIGNED the null. v0.3
exposes provider hash-attestation participation as a per-receipt
attestable property.

**Design rationale (the most contentious §M choice).** The
choice of "inconclusive-for-hash + valid-for-signature" rather
than "invalid because the provider didn't participate" is
deliberate. v0.3 ships against a production pool that runs
default `--enable-warm-swap=false` per Entry 80. Reporting every
receipt from that pool as `invalid` would break existing buyer
tooling on the day v0.3 ships; the softer rule preserves
"signature attestation works" while letting the catalog-check
side remain an opt-in trust upgrade. Operators who want to
demand hash attestation MAY ship a deployment-specific verifier
wrapper that filters `model_hash: null` results to "reject" —
this is policy, not protocol. AC-32 pins the protocol behavior;
the policy layer is out of scope.

### §M.3 Catalog-based verification (verify CLI extension)

When the v0.3 receipt has a non-null `model_hash` AND the
verifier is invoked with catalog arguments, the verifier MUST
compare `receipt.model_hash` against a signed catalog's expected
hash for `receipt.model_id`. The catalog format is the output
of `scripts/sign-catalog.go`, parsed and verified consistent
with `phase4-coordinator/internal/tier2/catalog.go`. The
verifier MUST re-implement parse + verify in pure Go in
`phase7-verify/` rather than import the coordinator package,
maintaining the v0.2 pure-Go discipline.

#### §M.3.1 New verify CLI flags

| Flag | Type | Required? | Purpose |
|---|---|---|---|
| `--catalog <path>` | string | optional | Path to a local signed catalog file (the output of `scripts/sign-catalog.go`). Mutually exclusive with `--catalog-url`. |
| `--catalog-url <url>` | string | optional | URL to fetch the signed catalog. Suggested target: the SPEC-002 v1.6 candidate `GET /catalog/<catalog_id>` endpoint per §M.4. Mutually exclusive with `--catalog`. |
| `--catalog-pubkey <base64url>` | string | optional | `base64.RawURLEncoding` (base64url-unpadded, NOT standard padded base64) of the ed25519 catalog-signing pubkey. Exactly 43 ASCII characters. Matches `scripts/sign-catalog.go:90,316-328` and SPEC-008 §5.2.1 wire form for ed25519 pubkeys. Mutually exclusive with `--catalog-pubkey-url`. |
| `--catalog-pubkey-url <url>` | string | optional | URL to fetch the catalog signing pubkey. Suggested target: the SPEC-002 v1.6 candidate `GET /catalog/pubkey` endpoint per §M.4. Mutually exclusive with `--catalog-pubkey`. |

**Flag-combination rules (NORMATIVE; extends §10.4.4).**

- If NONE of the four catalog flags is supplied: catalog check
  is skipped entirely. A v0.3 `valid` result carries the v0.1 /
  v0.2 §10.6 trust boundary, NOT the §M.3.3 boundary. The JSON
  output MUST set `model_hash_verified: null` (NOT absent) to
  explicitly signal the catalog check did not run.
- If `--catalog`-family flag is supplied without
  `--catalog-pubkey`-family flag (or vice versa): exit `64`
  (usage error) per §10.4.3. The catalog and the catalog pubkey
  are mutually required — a catalog without a pubkey cannot be
  verified, and a pubkey without a catalog has nothing to
  verify.
- If both `--catalog` and `--catalog-url` are supplied (or both
  `--catalog-pubkey` and `--catalog-pubkey-url`): exit `64`.
- If `--catalog-url` or `--catalog-pubkey-url` is used with
  `--offline` (§10.5): exit `64` (incompatible flags). The
  buyer is asserting offline AND requesting a network fetch.
- `--catalog-url` with no network egress (a transient network
  failure under §10.5's 5-second total network budget): report
  `inconclusive` with `reason: "catalog_unreachable"`. The
  verifier MUST NOT silently fall back to "skip catalog check
  and report valid" when the buyer explicitly asked for a
  catalog check. This is the same posture §10.2 takes for
  `/v1/receipt-keys/<provider_id>` unreachability.

#### §M.3.1.1 v0.3 catalog flag interaction matrix (extends §10.4.4)

This sub-matrix extends the v0.2.4 §10.4.4 flag matrix with the
v0.3 catalog flags. Rows = v0.3 catalog flags; columns = v0.2 +
v0.3 flags they interact with. Cells name the exit code or
behaviour. "OK" means the combination is legal and the verifier
proceeds per §M.3.2. "64" means exit `64` (usage error per
§10.4.3).

|   | `--offline` | `--coordinator H` | `--pubkey` (receipt) | `--json` | `--quiet` | `--explain` | `--provider-id` |
|---|---|---|---|---|---|---|---|
| `--catalog <path>` | OK (no network) | OK (independent) | OK | OK | OK | OK (catalog shown) | OK |
| `--catalog-url <url>` | **64** (incompatible: offline-vs-fetch) | OK (independent host from `H`) | OK | OK | OK | OK (catalog shown) | OK |
| `--catalog-pubkey <b64url>` | OK | OK | OK | OK | OK | OK (key id shown) | OK |
| `--catalog-pubkey-url <url>` | **64** (incompatible: offline-vs-fetch) | OK (independent host from `H`) | OK | OK | OK | OK (key id shown) | OK |
| `--catalog` + `--catalog-url` | n/a | n/a | n/a | n/a | n/a | n/a | n/a |  (mutually exclusive — **64**)
| `--catalog-pubkey` + `--catalog-pubkey-url` | n/a | n/a | n/a | n/a | n/a | n/a | n/a |  (mutually exclusive — **64**)
| catalog flag without matching pubkey flag (or vice versa) | n/a | n/a | n/a | n/a | n/a | n/a | n/a |  (must both be supplied — **64**)
| `--require-model-hash` (§M.3.1.2) | OK | OK | OK | OK | OK | OK (policy disclosed) | OK |

**Cross-row rules.**

1. Catalog flags compose freely with v0.2 input-mode flags
   (`--bundle`, `--receipt`+`--prompt-hash`+`--output-hash`,
   stdin) — the catalog check runs orthogonal to receipt
   resolution.
2. `--coordinator H` and `--catalog-url U` are INDEPENDENT
   hosts. `H` resolves `/v1/receipt-keys/<provider_id>` for
   the pubkey; `U` resolves the catalog. They MAY be the same
   host (Pearl-style single-coordinator deployment) or
   different (e.g. `H = test-coord` + `U = production-catalog`).
3. Explicit `--pubkey <b64>` (the v0.2 receipt-signing-pubkey
   pin) and `--catalog-pubkey <b64url>` (the v0.3 catalog-
   signing pubkey pin) are independent and can be combined.
   They sign different things (receipt vs. catalog).
4. `--json` output ALWAYS includes the v0.3 fields
   `model_hash_verified` and any §M-named `details` /
   `warnings[]` entries per §M.3.2.1, regardless of whether
   catalog flags were supplied (the field is `null` when
   catalog check did not run).
5. `--quiet` suppresses stderr emission but does NOT suppress
   any `warnings[]` entries from the JSON output (same
   posture v0.2 §10.4.4 takes for divergence warnings).
6. `--explain` MUST disclose which catalog (`catalog_id`,
   `catalog_url`-or-`--catalog` source path, `expires_at`)
   contributed to a v0.3 `valid` verdict per §M.3.3.

#### §M.3.1.2 Null-hash buyer policy flag (NEW)

To give buyers a first-class fail-closed knob on the §M.2.3
null-hash path without changing default §10.1 tri-state
semantics, v0.3 introduces ONE optional CLI flag:

| Flag | Type | Default | Purpose |
|---|---|---|---|
| `--require-model-hash` | boolean (presence) | off | When SET, a v0.3 receipt with `model_hash: null` causes `invalid` with `reason: "model_hash_required"` regardless of signature outcome. When NOT SET (default), null-hash receipts verify per §M.2.3 + AC-32 (valid + `catalog_skipped_null_hash` warning when catalog flags supplied). |

**Flag-interaction rules:**

- `--require-model-hash` composes with the v0.3 catalog flags
  per §M.3.1.1 (last matrix row). It is OPTIONAL — a v0.3
  verifier MAY omit the flag's implementation entirely if the
  release target is "buyer-default tooling"; the §M.5 AC-32a
  test is the gate.
- `--require-model-hash` applied to a v0.1/v0.2 LEGACY receipt
  (no `receipt_version` field) MUST report `invalid` with
  `reason: "model_hash_required"` — the legacy receipt has no
  hash to attest, and the buyer asked to fail closed.
- `--require-model-hash` applied to a v0.3 receipt with a
  NON-NULL `model_hash` is a no-op on result (the catalog
  check proceeds normally per §M.3.2; result is determined by
  that check).
- `--require-model-hash` without `--catalog`-family flags is
  LEGAL — the buyer is asserting "I demand the provider
  participates in hash attestation, but I'll trust the
  provider's self-reported hash without catalog cross-check."
  Result is `valid` (if signature checks) or `invalid` (if
  signature fails OR null hash); `model_hash_verified` is
  `null` (no catalog ran). This is the minimal fail-closed
  posture.

**Trust statement.** A v0.3 `valid` result with
`--require-model-hash` set carries the §M.2.3 trust statement
("the holder of the provider's private key signed a tuple in
which `model_hash` was non-null") PLUS the buyer's policy
attestation that they demanded participation. A v0.3 `invalid`
result with `reason: "model_hash_required"` is the buyer's
explicit reject of a provider that opted out of hash
attestation — this is policy, not protocol.

#### §M.3.2 Catalog verification algorithm

For a v0.3 receipt with non-null `model_hash` AND catalog
arguments supplied, the verifier MUST execute these steps in
order. Any failed step short-circuits with the named result:

1. **Resolve catalog bytes** per `--catalog` or `--catalog-url`
   (5-second total network budget per §10.5; fetch failure →
   `inconclusive` with `reason: "catalog_unreachable"`).
2. **Resolve catalog pubkey** per `--catalog-pubkey` or
   `--catalog-pubkey-url` (same 5-second budget shared with
   step 1).
3. **Parse the catalog** as the `phase4-coordinator/internal/tier2`
   `catalogFile` schema: top-level fields `catalog_id` (string),
   `expires_at` (RFC3339 UTC string), `issued_at` (RFC3339 UTC
   string), `models[]` (array of `{artifact_kind, hash_scope,
   model_id, min_ram_gb?, notes?, sha256, source}`), `signature{alg,
   key_id, sig}`, `version` (int). If present, `min_ram_gb` is a
   positive integer RAM floor for installer/provider UX and is covered
   by the catalog signature; it is NOT used for model-hash equality.
   Reject as `invalid` with `reason:
   "catalog_format_invalid"` on any schema mismatch (missing
   required field, wrong type, malformed RFC3339, `sha256`
   field not matching `[0-9a-f]{64}` per
   `phase4-coordinator/internal/tier2/catalog.go:22`).
4. **Verify catalog signature.** Reconstruct the canonical body
   (the `catalogFile` minus the `signature` field, in the exact
   key order `scripts/sign-catalog.go:42-49` produces:
   `catalog_id`, `expires_at`, `issued_at`, `models`, `version`)
   and verify `ed25519_verify(catalog_pubkey,
   canonical_body_bytes, base64_decode(signature.sig))`. The
   verifier MUST decode `signature.sig` as
   `base64.RawURLEncoding` (base64url-unpadded) to match
   `scripts/sign-catalog.go:145`. The `signature.alg` field
   MUST be the ASCII string `"Ed25519"` (capital E, matching
   the existing emitter at `scripts/sign-catalog.go:142-145`
   and the existing coordinator validator at
   `phase4-coordinator/internal/tier2/catalog.go:470`) OR the
   verifier reports `invalid` with
   `reason: "catalog_signature_invalid"`. The catalog pubkey
   itself MUST be decoded via `base64.RawURLEncoding` from the
   `--catalog-pubkey` / `--catalog-pubkey-url` source — exactly
   43 ASCII characters decoded to 32 bytes per RFC 8032. The
   `signature.key_id` field is informational (the verifier
   uses the resolved `--catalog-pubkey` /
   `--catalog-pubkey-url` bytes, NOT the embedded `key_id`,
   for verification — `key_id` is a fingerprint for
   operator-side rotation tracking). If `ed25519_verify`
   returns false: `invalid` with `reason:
   "catalog_signature_invalid"`.
5. **Check `expires_at`** against the verifier's wall clock. If
   `now() > expires_at + 60s` (60s grace for clock skew,
   matching §10.2.1 grace-window precedent): report
   `inconclusive` with `reason: "catalog_expired"` and emit a
   `warnings[]` entry with the catalog's `catalog_id` and
   `expires_at` populated. v0.3 does NOT allow `valid` against
   an expired catalog — catalog expiry is the operator's signal
   to rotate; a verifier that ignored it would defeat the
   rotation mechanism.
6. **Find the catalog entry** whose `model_id` equals
   `receipt.model_id` AFTER applying the canonical
   `catalogModelKey` transform: `strings.ToLower(strings.TrimSpace(modelID))`
   per `phase4-coordinator/internal/tier2/catalog.go:559-560`.
   The buyer-side verifier MUST mirror the coordinator-side
   match function exactly. v0.3 catalog lookup is case-FOLDED
   (lowercase) and whitespace-trimmed; this matches both
   SPEC-001 v1.5 §6.4's ASCII case-insensitivity rule for
   model IDs and the existing SPEC-008 §5.6 routing predicate.
   Diverging from the coordinator's match function would let
   the coordinator accept a model the verifier rejects (or
   vice versa) on case differences alone, which is the audit-
   round-1 A1 finding the v0.3.1 fix pass closed. If no entry
   matches after the canonical transform: report
   `inconclusive` with `reason: "model_id_not_in_catalog"`,
   `details.model_id: <receipt.model_id verbatim, no
   transform>` (the buyer needs to see what was in the
   receipt, not the lookup key). The verifier MUST NOT report
   `valid` for a model the operator has not published a hash
   for.
7. **Compare hashes.** Compare `receipt.model_hash` to the
   entry's `sha256` field (the catalog schema names this
   `sha256` per `scripts/sign-catalog.go:31`, NOT `model_hash`
   — do NOT invent a different field name). Comparison is
   case-sensitive (both sides are required to be lowercase hex
   by their respective specs; case mismatch is a schema bug,
   not an attack vector). If equal: continue to step 8. If
   mismatched: report `invalid` with `reason:
   "model_hash_mismatch"`, `details.field: "model_hash"`,
   `details.expected: <catalog sha256>`, `details.actual:
   <receipt model_hash>`. This is `invalid` regardless of
   signature outcome — a signature-valid receipt that names a
   wrong-hash model is a model attestation failure, and v0.3
   §M.3.3 makes this `invalid` rather than `inconclusive`
   because the buyer's explicit catalog choice asserts "this is
   the hash I expect."
8. **Emit `model_hash_verified: true`** in the JSON output and
   continue to the normal §10 result determination. The receipt
   reports `valid` iff signature, prompt/output hashes, AND
   catalog check all pass.

If the receipt has `model_hash: null` AND catalog arguments are
supplied, the verifier MUST skip steps 1-8 and apply §M.2.3
instead (catalog_skipped_null_hash warning, normal §10 result
determination, no hash check, `model_hash_verified: null` in
output).

#### §M.3.2.1 v0.3 result schema amendment (extends §10.4.2)

v0.3 extends the v0.2.4 §10.4.2 JSON output schema. The v0.2.4
"`details` only on `invalid`" rule is SUPERSEDED for the
v0.3-named `inconclusive` cases below; otherwise §10.4.2
remains authoritative.

**New REQUIRED top-level field (every v0.3 verifier output):**

| Field | Type | Required? | Disposition |
|---|---|---|---|
| `model_hash_verified` | bool OR JSON null | REQUIRED (always present) | Tri-state: `true` ⇔ catalog check ran AND hash equality held (§M.3.2 step 8); `false` ⇔ catalog check ran AND mismatched (§M.3.2 step 7 mismatch path; result is `invalid` with `reason: "model_hash_mismatch"`) OR `--require-model-hash` set with null hash (`reason: "model_hash_required"`); `null` ⇔ catalog check did NOT run for any reason (no catalog flags supplied; null `model_hash` without `--require-model-hash`; legacy v0.1/v0.2 receipt; unknown `receipt_version`; catalog fetch / signature / expiry failure that short-circuits before step 7). |

The field MUST be present in every JSON output, including
`valid`, `invalid`, `inconclusive` results. Absence = schema
violation. Distinguishes `false` (catalog ran, mismatched —
the cryptographic case) from `null` (catalog did not run — the
operational case).

**Extended `reason` enum (v0.3 ADDS these values):**

| `reason` | Result | Source |
|---|---|---|
| `model_hash_mismatch` | invalid | §M.3.2 step 7 |
| `model_hash_required` | invalid | §M.3.1.2 + AC-32a |
| `model_id_not_in_catalog` | inconclusive | §M.3.2 step 6 |
| `catalog_signature_invalid` | invalid | §M.3.2 step 4 |
| `catalog_unreachable` | inconclusive | §M.3.2 step 1/2 + §M.4 404/429/5xx |
| `catalog_expired` | inconclusive | §M.3.2 step 5 |
| `catalog_format_invalid` | invalid | §M.3.2 step 3 |
| `unknown_receipt_version` | inconclusive | §M.1.4 |
| `extra_field` / `missing_field` | invalid | §M.0 strict 9-key rule for `receipt_version: "3"` receipts |

The v0.2.4 `reason` enum values (signature, prompt_hash,
output_hash, provider_pubkey, pubkey_not_endorsed,
previous_key_outside_grace_window, fetch, offline_flag,
network_unreachable, provider_id_unresolvable,
provider_id_not_in_pool, etc.) remain valid and unchanged.

**Extended `details` disposition for v0.3-named inconclusive
cases.** §10.4.2's "details optional for valid / required for
invalid" rule is extended:

| `reason` | `details` requirement | Required keys |
|---|---|---|
| `unknown_receipt_version` (inconclusive) | REQUIRED | `details.receipt_version` (the unrecognized string value, verbatim) |
| `model_id_not_in_catalog` (inconclusive) | REQUIRED | `details.model_id` (the receipt's `model_id` verbatim, no case transform) |
| `catalog_expired` (inconclusive) | REQUIRED | `details.catalog_id`, `details.expires_at` (RFC3339 UTC) |
| `catalog_unreachable` (inconclusive) | OPTIONAL | `details.url` if `--catalog-url` was set; absent otherwise |
| `model_hash_mismatch` (invalid) | REQUIRED | `details.field: "model_hash"`, `details.expected: <catalog sha256, 64 hex>`, `details.actual: <receipt model_hash, 64 hex>` |
| `model_hash_required` (invalid) | REQUIRED | `details.field: "model_hash"`, `details.policy_flag: "require-model-hash"` |
| `catalog_signature_invalid` (invalid) | REQUIRED | `details.field: "signature"`, `details.alg: <observed alg string>` (e.g. `"ed25519"` lowercase to differentiate from the required `"Ed25519"`) |
| `catalog_format_invalid` (invalid) | REQUIRED | `details.field: <name of failing field>`, `details.cause: <human-readable description>` |
| `extra_field` / `missing_field` for v0.3 receipts (invalid) | REQUIRED | `details.field: <name of the offending key>` |

**Extended `warnings[]` kinds:**

- `catalog_skipped_null_hash` — v0.3 receipt with
  `model_hash: null` AND catalog flags supplied (§M.2.3,
  AC-32).
- `catalog_skipped_legacy_receipt` — v0.1/v0.2 receipt (no
  `receipt_version`) AND catalog flags supplied (§M.1.1,
  AC-37).

The v0.2.4 `warnings[]` kinds (`live_check_skipped`,
divergence, non-default coordinator) remain valid and
unchanged.

**Schema versioning.** v0.3 verifier output JSON schema is a
strict superset of the v0.2.4 schema for the unchanged fields.
The release artifact MUST include an updated JSON-Schema
document (per v0.2.4 AC-24) reflecting the v0.3 additions
above; the schema document MUST be addressable from the release
so independent buyer-side automation can validate v0.3 output
without re-deriving the schema from this spec.

#### §M.3.3 Trust boundary update (SUPERSEDES §10.6 for v0.3 catalog-valid)

A v0.3 `valid` result with non-null `model_hash` AND catalog
arguments supplied means: a holder of the provider's private key
signed a canonical tuple containing the values (`model_hash`,
`model_id`, `prompt_hash`, `output_hash`, `provider_pubkey`,
`receipt_version: "3"`, `ttft_ms`, `tokens_out`, `unix_ts`); the
pubkey that signature checks against is the one the coordinator
publishes for the resolved `provider_id` at verification time
(or in the §7.5.2 rotation grace window per §10.2.1); AND the
catalog the buyer trusted (signature-valid against the supplied
catalog pubkey, non-expired within the 60s skew grace) endorses
that `receipt.model_hash` is the expected SHA-256 of the loaded
weights for `receipt.model_id`.

In other words, v0.3 `valid` (with catalog) closes the §10.6
v0.2 "DOES NOT prove that the response was generated by the
model named in `model_id`" bullet, subject to the buyer trusting
the catalog signing pubkey — which is the new trust root the
v0.3 verifier requires, and which §15 Q1 (TUF-style root) and
the §M.4 `/poolz` `catalog_pubkey_url` surface inherit.

The remaining §10.6 DOES-NOT-PROVE list is PRESERVED unchanged:
v0.3 `valid` still does not prove timestamp honesty, no-other-
observer, pubkey-trust-root incorruptibility, replay-resistance,
or uniqueness.

**Disclaimers that v0.3 specifically inherits.** The §M.4
catalog-pubkey trust root is operator-mutable in the same way
§8 / §10.6 `/poolz` is operator-mutable: a malicious operator
can swap both the catalog AND the catalog pubkey AND a v0.3
verifier with `--catalog-pubkey-url` (rather than a pinned
`--catalog-pubkey`) will report `valid`. v0.3 §M.3.3 strengthens
the receipt against PROVIDER substitution attacks (a provider
loading a different SHA-256 than the operator published) — it
does NOT strengthen the receipt against OPERATOR-level attacks
on the catalog trust root. §15 Q1 (TUF / on-chain anchor) is
where that strengthening lands; v0.3 is honest that it is not
that work.

A v0.3 `valid` result with NULL `model_hash`, OR with no
catalog arguments, retains the v0.1 / v0.2 §10.6 trust boundary
unchanged — model-hash attestation is not made.

#### §M.3.4 Cache and TTL

A `--catalog-url` resolution MUST cache the fetched catalog
bytes AND the resolved catalog pubkey keyed by
`(catalog_url, catalog_pubkey_url_or_explicit_marker)`. Cache
TTL:

Let `R = expires_at - now()` at cache-write time, expressed in
seconds. The three TTL bands use explicit interval notation
(half-open intervals; integer-second resolution; boundary at
6h falls into the upper band):

- `R ∈ (6h, +∞)` (i.e. `R > 21600s`): cache for exactly
  `21600s` (6 hours).
- `R ∈ [60s, 6h]` (i.e. `60 ≤ R ≤ 21600`): cache for
  `R - 60s` seconds (so the cache expires 60 seconds before
  the catalog itself, matching the §M.3.2 step 5 skew grace).
- `R ∈ (-∞, 60s)` (i.e. `R < 60s`, including R ≤ 0 — a catalog
  accepted only by the §M.3.2 step 5 60s skew grace, OR a
  catalog with expires_at already in the past at fetch time):
  do NOT cache. The next verification SHOULD re-fetch. A
  catalog accepted only by skew grace is NEVER cached so that
  the next verification re-checks expiry against a fresh
  wall-clock reading.

Cache location: the same `~/.macprovider/verify/` directory as
the §10.2 pubkey cache, in a sibling subdirectory
`catalogs/<sha256-of-catalog-url>.json`. Cache entries MUST
include `{catalog_bytes, catalog_pubkey_b64, fetched_at,
expires_at, catalog_url}` so a later verification can detect
either a `--catalog-pubkey-url` rotation (cached pubkey
differs from freshly-resolved pubkey → cache miss) or a manual
pubkey override on the CLI (cached pubkey differs from
`--catalog-pubkey` → cache miss).

A stale cache entry (older than its computed TTL) MUST NOT
produce `valid`. The verifier MUST attempt a fresh fetch; on
fetch failure with a stale cache, report `inconclusive` with
`reason: "catalog_unreachable"` — mirroring §10.2's stale-cache
rule for the pubkey cache.

### §M.4 Coordinator `/poolz` extension (SPEC-002 v1.6 candidate annotation)

The coordinator's `/poolz` response gains three OPTIONAL
top-level fields (NOT per-provider-row fields — these are
catalog-level). The three fields are present iff ALL of the
following hold (the "effectively active catalog" condition):

1. `Tier2Config.CatalogPath` is set (non-empty per
   `phase4-coordinator/internal/config/config.go:142`),
2. The configured catalog file loaded cleanly (file present,
   well-formed JSON, schema-valid per `catalogFile` in
   `phase4-coordinator/internal/tier2/catalog.go:64`),
3. The catalog's signature verified against
   `Tier2Config.CatalogPublicKey` (equivalent to
   `tier2.Default().Active() == true`).

If ANY of (1)/(2)/(3) fails, the three fields MUST be ABSENT
from the `/poolz` response (NOT present-with-null, NOT
present-with-empty-string). This single rule governs §M.4
field presence AND the §M.5 AC-39 acceptance test AND the
two `/catalog/...` endpoint 404 cases below.

**Response shape (additive — extends the SPEC-002 v1.4 §FR-O2
locked shape, which uses top-level keys `pool` and `summary`).**

```json
{
  "pool": [...],               // unchanged — SPEC-002 v1.4 §FR-O2
  "summary": {...},            // unchanged — SPEC-002 v1.4 §FR-O2
  "catalog_id": "macprovider-tier2-model-catalog-2026-05-31",
  "catalog_url": "https://coordinator.malibu.tech/catalog/macprovider-tier2-model-catalog-2026-05-31",
  "catalog_pubkey_url": "https://coordinator.malibu.tech/catalog/pubkey"
}
```

- **`catalog_id`** (string): the `catalog_id` from the loaded
  signed catalog (matches `ParsedCatalog.CatalogID` per
  `phase4-coordinator/internal/tier2/catalog.go:45`).
- **`catalog_url`** (string): URL where the same catalog file
  can be fetched. SPEC-002 v1.6 candidate adds `GET /catalog/
  <catalog_id>` returning the signed catalog bytes verbatim
  with `Content-Type: application/json`. No authentication
  (public) — same trust posture as `GET /v1/receipt-keys/
  <provider_id>` in §10.7.
- **`catalog_pubkey_url`** (string): URL where the catalog
  signing pubkey can be fetched. SPEC-002 v1.6 candidate adds
  `GET /catalog/pubkey` returning a JSON object
  `{"pubkey": "<43-char base64url-unpadded ed25519 pubkey>",
  "alg": "Ed25519"}` per the detailed endpoint block below —
  matching `scripts/sign-catalog.go:90,142-145` emitters,
  `phase4-coordinator/internal/tier2/catalog.go:470,479-485`
  validators, and SPEC-008 §5.2.1's locked ed25519 wire form.
  No authentication (public).

Parsers that don't recognize the fields ignore them per the
SPEC-002 v1.4 candidate-annotation pattern. Field absence is
covered by the "effectively active catalog" condition above.

**`GET /catalog/<catalog_id>` endpoint (SPEC-002 v1.6 candidate).**

- **Authentication:** None (public).
- **Rate limiting:** Operator-configurable; recommended floor
  10 req/sec per source IP, mirroring §10.7's
  `/v1/receipt-keys` posture. Source-IP derivation goes through
  `proxy.trusted_proxies` (issue #125; see §10.7 and SPEC-002 v1.4.x).
- **Cache-Control:** `public, max-age=300` (5 minutes; same as
  §10.7).
- **Response:** the literal signed catalog bytes accepted by the
  coordinator's catalog signature verification, as produced by
  `scripts/sign-catalog.go`. Implementations MUST NOT reread and
  serve mutable on-disk catalog bytes that have not passed the active
  catalog verification state. `Content-Type: application/json`.
- **404:** the `<catalog_id>` path segment does NOT match the
  effectively-active catalog's `catalog_id`, OR the
  coordinator has no effectively-active catalog per the §M.4
  three-condition rule above. Body is the SPEC-002 §FR-X-N
  standard JSON error envelope with
  `error.code = "catalog_not_found"`. Verifier treats as
  `inconclusive: catalog_unreachable`.
- **5xx / 429:** verifier treats as fetch-failure → `inconclusive:
  catalog_unreachable`; no retry within the same verification
  invocation.

**`GET /catalog/current` endpoint (SPEC-002 v1.6 candidate).**

- Same authentication / rate-limit / cache posture as
  `GET /catalog/<catalog_id>`.
- **Response:** the same verified signed catalog bytes as
  `GET /catalog/<active catalog_id>`, without requiring clients to
  discover the active ID from operator-only `/poolz`.
- **404:** no effectively-active catalog per the §M.4 three-condition
  rule. Verifier treats as `inconclusive: catalog_unreachable`.

**`GET /catalog/pubkey` endpoint (SPEC-002 v1.6 candidate).**

- Same authentication / rate-limit / cache posture as
  `GET /catalog/<catalog_id>`.
- **Response:** `{"pubkey": "<43-char base64url-unpadded>",
  "alg": "Ed25519"}`. The `pubkey` value MUST be
  `base64.RawURLEncoding` (base64url-unpadded), exactly 43
  ASCII chars decoding to 32 bytes — matching the
  `scripts/sign-catalog.go:90` keygen emitter, the SPEC-008
  §5.2.1 wire form, and the v0.3 `--catalog-pubkey` CLI flag
  per §M.3.1. The `alg` value MUST be the capital-E ASCII
  string `"Ed25519"` matching the existing
  `scripts/sign-catalog.go:142-145` catalog-signature `alg`
  field.
- Optional: `key_id` (informational fingerprint, identical to
  the `signature.key_id` embedded in catalog files).
- **404:** no effectively-active catalog per the §M.4 three-
  condition rule. Verifier treats as
  `inconclusive: catalog_unreachable`.

**Composes with §M.3.1.** A verifier can do:

```
macprovider-verify --bundle X \
  --catalog-url https://coordinator.malibu.tech/catalog/macprovider-tier2-model-catalog-2026-05-31 \
  --catalog-pubkey-url https://coordinator.malibu.tech/catalog/pubkey
```

with the verifier resolving both URLs in two fetches (plus the
§10.7 `/v1/receipt-keys/<provider_id>` resolution for the
provider pubkey — three total fetches per verify when no caches
are warm).

**Trust posture (NORMATIVE).** §M.4 inherits §8.3's operator-
mutability limit. The operator controls `/poolz`, the catalog
file, AND the catalog signing key. v0.3 does NOT add TUF /
on-chain anchoring; that's the §15 Q1 work and remains v0.4+.
A buyer who needs stronger trust SHOULD pin
`--catalog-pubkey` to a value out-of-band (key fingerprint
shared by the operator via a separate channel) rather than
relying on `--catalog-pubkey-url`, which delegates the pubkey
trust to the same coordinator that serves `/poolz`.

**SPEC-002 v1.6 candidate-annotation status.** §M.4 is named
as a SPEC-002 v1.6 candidate annotation following the SPEC-015
v0.1.3 `receipt_pubkey` (SPEC-002 v1.4 candidate) and SPEC-015
v0.2 `/v1/receipt-keys` (SPEC-002 v1.5 candidate) precedent.
Implementations MAY add the fields and endpoints before
SPEC-002 v1.6 LOCK provided the shape matches §M.4 / §M.5 ACs.
SPEC-002 v1.6 LOCK is OUT-OF-SCOPE for v0.3 of this SPEC;
SPEC-015 v0.3 is the source of truth for the catalog-surface
shape until that LOCK.

### §M.5 Acceptance criteria (v0.3 extensions)

Each AC is independently verifiable from outside this SPEC.
Each AC cites a concrete test command an implementer can run.

**AC-28 (v0.3 receipt wire shape).** A v0.3 provider binary
serving a non-streaming `POST /v1/chat/completions` with a
fixed model, prompt, and `temperature: 0` MUST emit an
`X-MacProvider-Receipt` header whose tuple decodes to exactly
nine fields in JCS canonical (UTF-16 code-unit lexicographic)
order: `model_hash`, `model_id`, `output_hash`, `prompt_hash`,
`provider_pubkey`, `receipt_version`, `tokens_out`, `ttft_ms`,
`unix_ts`. `receipt_version` MUST be exactly the ASCII string
`"3"`. **Test command:**
```bash
curl -sD - -X POST http://provider/v1/chat/completions -d '<fixed body>' \
  | grep -i '^X-MacProvider-Receipt:' \
  | cut -d' ' -f2 | tr -d '\r' | cut -d. -f1 | base64 -d \
  | jq -r 'keys | join(",")'
```
Returns exactly `model_hash,model_id,output_hash,prompt_hash,provider_pubkey,receipt_version,tokens_out,ttft_ms,unix_ts`.

**AC-29 (`model_hash` matches loaded weights — warm-swap-on).**
A v0.3 provider running with `--enable-warm-swap=true` emits a
v0.3 receipt whose `model_hash` equals the SHA-256 of the loaded
MLX container at the moment of receipt generation.
**Test commands** (any of the two equivalent observation routes
— v0.3 does NOT require a new introspection CLI):
- **Heartbeat route (preferred — uses existing wire surface):**
  capture the provider's heartbeat-reported `model_hash` per
  SPEC-011 R-3.3.1 from a coordinator-side log/journald scrape
  (`journalctl -u macprovider-coordinator | grep model_hash_verified`
  on Pearl, or the equivalent locally); assert
  `receipt.model_hash == heartbeat.model_hash` over a fresh
  heartbeat window (no swap in flight). This route is
  observation-only and matches the Pearl-production
  `model_hash_verified` events documented in the §M opening
  paragraph.
- **MLX container route (alternative — direct binary
  introspection):** compute SHA-256 over the MLX container the
  provider has loaded (same algorithm
  `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:294-325`
  uses for the heartbeat report); assert byte-equality with
  `receipt.model_hash`. v0.3 does NOT require a new
  `models inspect` CLI subcommand to expose this; an
  implementer MAY add one as an ergonomics extension under a
  future SPEC-001 revision, but it is NOT a v0.3 prereq.

Implementations choose either route for the AC test. v0.3 §M.5
treats both as equally normative; the divergence in form
(coordinator-side vs. binary-side) does NOT change the
expected outcome.

**AC-30 (`model_hash: null` when warm-swap disabled).** A
v0.3 provider running with default `--enable-warm-swap=false`
emits a v0.3 receipt whose `model_hash` is the JSON literal
`null`, NOT the empty string, NOT absent. **Test command:**
```bash
curl -sD - -X POST http://provider/v1/chat/completions -d '<fixed body>' \
  | grep -i '^X-MacProvider-Receipt:' | cut -d' ' -f2 | tr -d '\r' \
  | cut -d. -f1 | base64 -d \
  | jq '.model_hash == null and (.model_hash | type) == "null" and has("model_hash")'
```
Returns `true` (three conjuncts: value is null, type is "null",
key is present).

**AC-31 (null-usage receipts inherit §M.2 hash).** A v0.3
provider emitting a null-usage / error receipt (SPEC-001 §6.0
error path; v0.1.3 AC-12) sets `model_hash` per §M.2 — i.e. the
same value a successful receipt from the same provider would
carry. The error did not change the loaded weights. **Test
command:** trigger `error_model_not_loaded` on a v0.3 provider
running with `--enable-warm-swap=true`; verify the resulting
receipt's `model_hash` equals the post-error SPEC-011
heartbeat-reported hash from the same provider over a fresh
heartbeat window.

**AC-32 (verifier valid on null-hash v0.3 receipt — default
posture).** A v0.3 verifier without `--require-model-hash`
MUST report `valid` for a v0.3 receipt with
`model_hash: null` when signature + canonicalization checks
pass, regardless of whether `--catalog`-family flags were
supplied. If catalog flags WERE supplied, JSON output MUST
include `warnings[]` of kind `catalog_skipped_null_hash`.
**Test command:** golden fixture in
`phase7-verify/testdata/spec015_v03_null_hash/`; assert
`macprovider-verify --bundle bundle.json --catalog catalog.json
--catalog-pubkey <pk>` exits 0, `result: "valid"`,
`warnings | map(.kind) | contains(["catalog_skipped_null_hash"])`.

**AC-32a (verifier `--require-model-hash` fail-closed on null
hash — opt-in buyer policy per §M.3.1.2).** A v0.3 verifier
invoked with `--require-model-hash` reading a v0.3 receipt with
`model_hash: null` MUST report `invalid` with `reason:
"model_hash_required"`, exit code `1`, and JSON output MUST
include `model_hash_verified: false` AND `warnings[]` MAY
include `catalog_skipped_null_hash` (the warning still records
the underlying skip; the policy flag is what flipped the result
to invalid). The signature MAY be valid; the policy flag
demands hash attestation regardless. **Test command:** same
golden fixture as AC-32; assert
`macprovider-verify --bundle bundle.json --catalog catalog.json
--catalog-pubkey <pk> --require-model-hash` exits 1,
`result: "invalid"`, `reason: "model_hash_required"`.

**AC-33 (verifier invalid on hash mismatch).** A v0.3 verifier
MUST report `invalid` with `reason: "model_hash_mismatch"`
for a v0.3 receipt whose `model_hash` does not equal the
catalog's `sha256` for the receipt's `model_id`. The signature
MAY be valid; the verifier MUST still report `invalid`.
`details.expected` and `details.actual` MUST both be populated
with the 64-hex strings. **Test command:** fixture
`phase7-verify/testdata/spec015_v03_hash_mismatch/`.

**AC-34 (verifier inconclusive on unknown model_id).** A v0.3
verifier MUST report `inconclusive` with `reason:
"model_id_not_in_catalog"` for a v0.3 receipt whose `model_id`
is not present in the supplied catalog's `models[]`. **Test
command:** fixture
`phase7-verify/testdata/spec015_v03_unknown_model_id/`.

**AC-35 (verifier invalid on bad catalog signature).** A v0.3
verifier MUST report `invalid` with `reason:
"catalog_signature_invalid"` when the catalog's `signature.sig`
does not verify against the supplied catalog pubkey, OR when
`signature.alg != "Ed25519"` (capital E; the v0.3 wire form
matches the existing `scripts/sign-catalog.go:142-145`
emitter). **Test command:** fixture
`phase7-verify/testdata/spec015_v03_catalog_bad_sig/` covering
both failure modes (tampered sig bytes; alg field set to
`"ed25519"` lowercase, `""`, `"ECDSA"`, etc.).

**AC-36 (verifier inconclusive on expired catalog).** A v0.3
verifier MUST report `inconclusive` with `reason:
"catalog_expired"` when the catalog's `expires_at` is more than
60 seconds in the past relative to the verifier's wall clock.
**Test command:** fixture
`phase7-verify/testdata/spec015_v03_catalog_expired/` using
`SOURCE_DATE_EPOCH` or `libfaketime` for deterministic clock.

**AC-37 (backward-compat: v0.3 verifier on v0.1/v0.2 receipt).**
A v0.3 verifier reading a v0.1 / v0.2 receipt (no
`receipt_version` field, 7 keys total) MUST report `valid`
without catalog check, and JSON output MUST include
`warnings[]` of kind `catalog_skipped_legacy_receipt` when
catalog flags were supplied. **Test command:**
`macprovider-verify --bundle <v0.2-bundle.json>
 --catalog <good-catalog.json>
 --catalog-pubkey <good-key.b64>`
exits 0, `result: "valid"`,
`warnings | map(.kind) | contains(["catalog_skipped_legacy_receipt"])`.

**AC-38 (forward-incompat: v0.2 verifier on v0.3 receipt).**
A v0.1.3 / v0.2.4 verifier (i.e. unmodified, locked releases)
reading a v0.3 receipt (9 keys including `receipt_version`)
MUST report `invalid` per its §3.1 seven-keys-only rule. **Test
command:** `./phase7-verify-v0.2.4 --bundle <v0.3-bundle.json>`
exits 1, `result: "invalid"`. The exact reason string is
implementation-defined for the locked release (likely
`extra_field` or signature failure depending on which check
fires first), but `result: "invalid"` MUST hold.

**AC-39 (`/poolz` catalog fields).** A coordinator with
`Tier2Config.CatalogPath` configured AND a successfully
loaded+verified catalog MUST emit `catalog_id`, `catalog_url`,
and `catalog_pubkey_url` as top-level fields in the `/poolz`
response. A coordinator with `Tier2Config.CatalogPath == ""`
MUST omit those three fields entirely (NOT
present-with-null-value). A coordinator with
`Tier2Config.CatalogPath` set but the catalog failed to load /
parse / verify-signature MUST omit those three fields (the
catalog is not effectively configured). **Test commands:**
- `curl -s -H "Authorization: Bearer $OP" http://coordinator/poolz | jq 'has("catalog_id") and has("catalog_url") and has("catalog_pubkey_url")'` returns `true` on a catalog-configured coordinator.
- Same command returns `false` on an unconfigured coordinator.
- Same command returns `false` on a coordinator whose
  configured catalog fails to load (e.g. file missing).

**AC-40 (`RequireHashVerified` orthogonality preserved).**
A coordinator with `RequireHashVerified: false` (the Entry 80
deferred default) MUST continue to route to providers whose
hash status is `uncatalogued` OR `catalog_unavailable` —
matching the SPEC-008 §5.6 routing predicate
(`phase4-coordinator/internal/tier2/catalog.go:599-604`
`IsHashPredicateFailure`) which fails-CLOSED on
`hash_mismatch` and `hash_invalid` REGARDLESS of the
`RequireHashVerified` setting. v0.3 does NOT change SPEC-008
§5.6 routing semantics. v0.3 receipt issuance on
routing-eligible providers (i.e. providers in `uncatalogued`,
`catalog_unavailable`, or `hash_verified` states) MUST still
emit the actual loaded hash per §M.2 (even when the hash is
uncatalogued, the receipt commits to it — the buyer is the one
who decides via verifier `--catalog` whether to accept).
**Test command:** with `RequireHashVerified: false`, a provider
serving a model NOT in the catalog (hash status
`uncatalogued`) routes normally; the receipt carries
non-null `model_hash`; the buyer running `macprovider-verify
--bundle X --catalog <catalog.json> --catalog-pubkey ...`
reports `inconclusive: model_id_not_in_catalog`. The
coordinator's routing decision (`uncatalogued` allowed at flag
default) and the verifier's catalog decision (`model_id` not
in catalog → inconclusive) are independent and v0.3 does NOT
change either. A separate test with a provider in
`hash_mismatch` state (configured catalog + provider reporting
the wrong hash) confirms the coordinator REJECTS routing at
both `RequireHashVerified` settings per SPEC-008 §5.6.

**AC-41 (catalog cache TTL).** The `--catalog-url`-fetched
catalog cache MUST follow §M.3.4: a catalog whose
`expires_at - now() > 6h` caches for 6h; a catalog with
`expires_at - now() < 60s` does NOT cache; a catalog with
`expires_at - now()` in [60s, 6h] caches for
`expires_at - now() - 60s`. **Test command:** mock catalog
with controlled `expires_at` + verifier wall clock; assert
cache file mtime + content + cache-miss-on-rotated-pubkey.

**AC-42 (mid-swap defence-in-depth refusal — NOT normal swap
in-flight requests).** §M.2.2's construction proof says a
normal in-flight request that began on the OLD container and
finishes while the runtime is in `loading` or `draining`
state MUST still emit a v0.3 receipt with the hash captured
at request START (per SPEC-011 R-3.4.1 in-flight tracking +
R-3.2.2 snapshot semantics). AC-42 tests ONLY the
defence-in-depth case: a synthetic state in which the
runtime CANNOT identify which container served a specific
request (i.e. the request-start-hash capture path failed or
was bypassed — unreachable in correct SPEC-011 R-3.4.1
implementations, but the §M.2.2 defence-in-depth clause
demands the check). **Test command:** synthetic harness in
`phase3-binary` that drives the runtime into a
swap-in-progress state AND simulates a request whose
request-start-hash slot is unset / nil / corrupted (e.g. via
unit-level injection that bypasses the normal R-3.4.1 path);
verify the response has no `X-MacProvider-Receipt` header AND
the audit sink contains a matching `receipt_omitted: reason
= model_swap_violation` row. A separate positive test ensures
a NORMAL in-flight request through `loading` / `draining`
DOES emit a receipt with the request-start hash (this is the
§M.2.2 construction-proof path, not a violation).

### §M.6 What v0.3 explicitly DOES NOT change

Recorded here so future audit cycles do not re-litigate. Each
item names the future SPEC that may revisit it.

1. **`RequireHashVerified` enforcement at the coordinator.**
   Per `beta/DECISION_CRITERIA.md` Entry 80 (2026-06-22), the
   flag stays at its `false` default until any of three
   triggers fire (pool size growth, catalog pipeline
   ergonomics, buyer demand). v0.3 receipts BIND the hash; the
   coordinator's route/reject policy is independent. AC-40
   pins this. Successor: an Entry-80 revisit, not a SPEC-015
   revision.

2. **Streaming receipts.** v0.1.3 §15 Q5 (streaming receipt
   delivery mechanism) was deferred by v0.3 and is resolved for
   settlement by v0.4 §N.5. v0.3's §M.2.2 one-model-per-response
   rule remains the input to v0.4's request-start model-hash rule.

3. **Mid-response model swaps producing a multi-hash receipt.**
   v0.3 §M.2.2 NORMATIVELY REFUSES the shape. v0.4 continues to
   use one request-start `model_hash` per request attempt. A later
   profile may introduce a multi-hash receipt shape, particularly
   for streaming responses where a swap genuinely spans a long
   response. §15 Q7 captures the future question.

4. **Cross-catalog federation.** A coordinator serves ONE signed
   catalog. v0.3 is single-catalog-per-coordinator; federation
   across operators (or multiple catalogs per coordinator) is
   v0.4+ scope.

5. **On-chain anchoring of catalog Merkle roots.** Gated on the
   Cluster D-tokens go/no-go decision; orthogonal to v0.3.

6. **Quantization-aware verification.** v0.3 is
   one-`model_id`-one-`sha256`. Quantization variants of the
   same logical model (e.g. 4-bit vs 8-bit qwen2.5-7b) MUST be
   published with distinct `model_id` values per SPEC-008 v0.3
   + SPEC-010 v1.5 convention. A future SPEC may allow
   per-`model_id` accept-list of multiple hashes; v0.3 does
   not.

7. **HuggingFace-style "soft" model identity** (model card
   metadata, training-run provenance, dataset provenance).
   v0.3 receipts bind weights (SHA-256 of the loaded MLX
   container), not lineage. Deferred indefinitely.

8. **`RFC8785JCS.swift` amendments.** None required for v0.3
   beyond extending the keyset emitted by the existing
   sorted-emit path. See §M.1.5.

9. **TUF / signed-root upgrade of the catalog-pubkey trust
   root.** §M.3.3 inherits the §8.3 operator-mutability limit;
   §15 Q1 names TUF / on-chain anchoring as the v0.x+
   successor. v0.3 is explicit about the limit and does not
   close it.

---

## §N. Settlement-capable receipts (v0.4 NORMATIVE)

v0.4 defines the first SPEC-015 profile that can be used by
SPEC-022 verified-model settlement. v0.1/v0.2/v0.3 receipts remain
valid for their historical verifier purposes, but they are NOT
settlement-capable under SPEC-022 enforce mode because they do not
bind request attempt, terminal state, route-time verification
snapshot, canonical usage, or streaming delivery/storage.

### §N.0 Relationship to earlier profiles

v0.4 is a new receipt profile, identified by
`receipt_version: "4"`. A v0.4 settlement receipt MUST NOT be
encoded as a v0.3 tuple with optional fields. The v0.4 field set is
strict and version-discriminated.

A v0.4 verifier MUST:

1. Continue to verify v0.1/v0.2/v0.3 receipts under their existing
   semantics.
2. Classify v0.1/v0.2/v0.3 receipts as
   `not_settlement_capable` for SPEC-022 money movement, even when
   their historical signature/prompt/output checks are `valid`.
3. Treat unknown future `receipt_version` values as
   `inconclusive: unknown_receipt_version`, not `valid`, not
   `invalid` solely by field count, and not payable.

A v0.3 verifier reading a v0.4 receipt follows §M.1.4 and reports
`inconclusive: unknown_receipt_version`.

### §N.1 v0.4 signed tuple

A v0.4 receipt is a JCS-canonicalized JSON object with EXACTLY the
fields in this section and no others. The tuple is signed using the
same envelope form as §3.4:

`<base64(JCS(T))>.<base64(SIG)>`

`SIG = ed25519_sign(provider_receipt_private_key, UTF-8(JCS(T)))`.

The signed tuple fields are:

| Field | Type | Definition |
|---|---|---|
| `account_scope` | string | Privacy-preserving account scope for the buyer account or tenant whose ledger row will consume the receipt. It MAY be a digest. It MUST be stable for settlement of the exact request attempt and MUST NOT expose bearer tokens. |
| `catalog_body_digest` | string | SHA-256 digest, 64 lowercase hex, over the signed catalog body that was route-valid for this attempt. |
| `catalog_id` | string | Catalog id from the route-time snapshot. |
| `expected_catalog_model_hash` | string | Non-null 64 lowercase hex expected hash for `model_id` from the route-time catalog snapshot. |
| `issued_at_unix_ms` | int64 | Provider receipt issuance timestamp in Unix milliseconds. |
| `model_hash` | string | Non-null 64 lowercase hex of the request-start loaded model hash. JSON null is not settlement-capable in v0.4. |
| `model_id` | string | Requested model id, verbatim as routed. |
| `output_hash` | string | SHA-256 digest, 64 lowercase hex, of the canonical delivered output material defined by §N.5. |
| `output_prefix_end_byte` | int64 | Exclusive byte offset of this attempt's buyer-visible canonical output prefix in the request-level delivered-output byte stream. Non-negative. |
| `output_prefix_start_byte` | int64 | Inclusive byte offset of this attempt's buyer-visible canonical output prefix in the request-level delivered-output byte stream. Non-negative and `<= output_prefix_end_byte`. |
| `prompt_hash` | string | SHA-256 digest, 64 lowercase hex, of the canonical request material as normalized by the coordinator/gateway. |
| `provider_id` | string | Provider identity selected for this route attempt. |
| `provider_receipt_key_id` | string | `ed25519-sha256:<64 lowercase hex>`, where the digest is SHA-256 over the raw 32-byte Ed25519 receipt public key pinned in the route-time snapshot. The raw public key is resolved out of band and MUST NOT be copied into audit rows. |
| `receipt_version` | string | MUST be exactly `"4"` for this profile. |
| `request_id` | string | Buyer-visible or coordinator-internal request id bound to the ledger row. |
| `route_snapshot_digest` | string | SHA-256 digest, 64 lowercase hex, of the immutable route-time verification snapshot. |
| `route_snapshot_mode` | string | Effective SPEC-022 policy mode at route time, e.g. `observe` or `enforce`. |
| `route_snapshot_policy_version` | string | Effective SPEC-022 policy version at route time. |
| `signature_key_alg` | string | MUST be `"Ed25519"`. |
| `terminal_state` | string | One of the §N.4 terminal states. |
| `terminal_state_ts_unix_ms` | int64 | Coordinator/gateway-recorded terminal-state timestamp in Unix milliseconds, echoed in the receipt. The coordinator ledger timestamp is authoritative and anchors pending-deadline calculation. |
| `attempt_n` | int64 | Zero-based monotonic route-attempt number for the request. The first attempt is `0`; each retry or failover increments by exactly `1`, matching the SPEC-002/SPEC-005 ledger identity. |
| `usage` | object | Canonical usage object defined by §N.6. |

The tuple MUST use JCS canonicalization. Field order in the table is
explanatory; JCS key ordering is authoritative for signed bytes.

The signed wire envelope necessarily contains a signature and may be
verifiable with public-key material. Audit, telemetry, verifier-result
rows, settlement verdict rows, operator surfaces, and buyer-facing
status rows MUST NOT contain raw receipt signatures, raw receipt
public keys, raw receipt envelopes, raw prompts, raw outputs, bearer
tokens, receipt private keys, or provider-private state. Such rows MAY
carry digests, fingerprints, reason codes, and parsed scalar fields
needed for settlement.

### §N.2 Route-time snapshot binding

For every v0.4-settled request attempt, the coordinator MUST create
and persist an immutable route-time verification snapshot before
forwarding work to the provider. The snapshot MUST be retrievable by
settlement verification. The digest is the binding anchor, not the
only retained material.

A route snapshot digest is computed as:

`sha256(UTF-8(JCS(route_snapshot_v1)))`

where `route_snapshot_v1` is a strict JCS object with EXACTLY these
fields:

- `account_scope`;
- `request_id`;
- `attempt_n`;
- `provider_id`;
- `provider_session_id`: string or JSON null when not available;
- `provider_generation_id`: string or JSON null when not available;
- `paid_entrypoint`: string identifying the paid entrypoint that admitted
  the request;
- `provider_receipt_key_id`: the `ed25519-sha256:<hex>` value defined by
  §N.1;
- `provider_receipt_key_source`: enum string, one of `auth_session`,
  `rotation_grace`, or `operator_pin`;
- `model_id`;
- `provider_reported_model_hash`;
- `expected_catalog_model_hash`;
- `catalog_id`;
- `catalog_body_digest`;
- `catalog_signature_key_id`;
- `catalog_signature_pubkey_fingerprint`: `ed25519-sha256:<64 lowercase
  hex>` over the raw 32-byte catalog public key;
- `catalog_expires_at_unix_ms`;
- `spec008_hash_status`: string, one of the SPEC-008 §5.5 hash-status enum
  values observed at route time;
- `route_snapshot_policy_version`;
- `route_snapshot_mode`;
- `route_decision_ts_unix_ms`;
- `request_start_ts_unix_ms`;
- `pending_deadline_seconds`;
- `prompt_hash_basis`: enum string naming the coordinator/gateway
  canonical request normalizer version;
- `prompt_hash`.

No other fields are allowed in `route_snapshot_v1`. If a deployment needs
additional route-validity fields for settlement, it MUST define
`route_snapshot_v2` and a corresponding policy version rather than silently
changing the digest input.

Settlement verification MUST prove the SPEC-022 three-way equality:

`receipt.model_hash == route_snapshot.provider_reported_model_hash == route_snapshot.expected_catalog_model_hash`.

Catalog rotation, catalog rollback, provider reconnect, warm-swap, or
delayed receipt arrival MUST NOT change the snapshot used for this
attempt.

### §N.3 Timestamp and replay policy

v0.4 timestamp checks are settlement-critical. Clock-skew warnings
alone are not sufficient for positive settlement.

A v0.4 settlement verifier MUST reject or quarantine positive money
movement unless all of the following hold:

1. `issued_at_unix_ms` and `terminal_state_ts_unix_ms` are within the
   exact account/request/attempt settlement window.
2. `terminal_state_ts_unix_ms` equals the coordinator/gateway-recorded
   terminal-state timestamp on the ledger row. The receipt echoes this
   timestamp; it is not authoritative for deadline calculation.
3. `issued_at_unix_ms` is greater than or equal to
   `route_snapshot.request_start_ts_unix_ms - 60000` and less than or
   equal to the coordinator receipt-received timestamp plus 60000 ms.
   The maximum v0.4 skew allowance is 60000 ms. A deployment MAY choose a
   smaller skew, but not a larger one, without a successor profile.
4. Receipt arrival before/after deadline is decided by the
   coordinator-recorded receipt-received timestamp compared with
   `terminal_state_ts_unix_ms + pending_deadline_seconds * 1000`.
   Provider `issued_at_unix_ms` cannot extend this deadline.
5. The receipt is for the exact `(account_scope, request_id,
   attempt_n, provider_id, provider_receipt_key_id)` ledger row.
6. A replay of a valid receipt onto a different account, request,
   attempt, provider, receipt key, route snapshot, or terminal state
   maps to `quarantined`.
7. A receipt that arrives after the ledger row has terminally
   quarantined by deadline is an idempotent no-op or rejected audit
   event. It MUST NOT resurrect the row, re-debit the buyer, create
   provider credit, or create payout readiness.

### §N.4 Terminal states

v0.4 defines the following terminal states:

- `normal_done`;
- `provider_error`;
- `buyer_cancel`;
- `gateway_timeout`;
- `upstream_transport_disconnect`.

The terminal state in the receipt MUST match the terminal state stored
on the ledger row for the same request attempt. A mismatch maps to
`quarantined`.

The provider/issuer-facing contract MUST expose the receipt submission
deadline or `pending_deadline_seconds` basis. It MUST disclose that a
late receipt is non-settling once its row has deadline-quarantined.

### §N.5 Output canonicalization for streaming and non-streaming

v0.4 does not use the historical §5 three-key canonical output object as
the settlement `output_hash` input. Historical v0.1/v0.2/v0.3 receipt
hashing remains unchanged. A v0.4 implementation instead reconstructs
the §5 content, tool-call, and finish-reason material, then wraps it in
the `settlement_output_v1` object defined below so streaming and
non-streaming attempts share one hash profile.

For streaming requests, the client-facing SSE stream MUST remain
OpenAI-compatible:

- no non-standard `event: receipt` block is required;
- no non-standard receipt-only `data:` payload is required;
- a stock OpenAI-compatible client MUST be able to read through
  `[DONE]` or the terminal stream condition without receipt-parser
  changes.

Streaming receipts are delivered through a coordinator-ingested
provider terminal frame, a post-stream internal receipt submission, or
another SDK-safe internal channel. Buyer receipt retrieval MAY exist,
but internal settlement verification MUST NOT depend on buyer action.

The delivered output for every v0.4 attempt is canonicalized as a JCS
object named `settlement_output_v1` with EXACTLY these fields:

| Field | Type | Definition |
|---|---|---|
| `content` | string | Buyer-visible UTF-8 content for this provider attempt. For streaming, concatenate `choices[].delta.content` fragments in delivery order and ignore missing content fragments. For non-streaming, use the same content string that §5 would place in the canonical output object. |
| `finish_reason` | string or JSON null | Final OpenAI finish reason if observed for this attempt; otherwise null. For non-streaming, use the same finish reason that §5 would place in the canonical output object. |
| `output_prefix_end_byte` | int64 | Exclusive byte offset of this attempt's canonical output bytes in the request-level delivered-output byte stream. |
| `output_prefix_start_byte` | int64 | Inclusive byte offset of this attempt's canonical output bytes in the request-level delivered-output byte stream. |
| `terminal_state` | string | One of §N.4. |
| `tool_calls` | array or JSON null | Final reconstructed tool-call array using the same field order and argument byte-preservation rules as §5.2 and §5.3; null when no tool calls were delivered. For non-streaming, use the same tool-call material that §5 would place in the canonical output object. |

`output_hash` MUST equal
`sha256(UTF-8(JCS(settlement_output_v1)))` for both streaming and
non-streaming attempts.

For non-streaming `normal_done`, `output_prefix_start_byte` MUST be `0`
and `output_prefix_end_byte` MUST equal the UTF-8 byte length of the
canonical buyer-visible output reconstructed from the complete response.
For non-streaming non-creditable terminal states, the same
`settlement_output_v1` object is used with the observed delivered prefix
or an empty prefix under §N.7. Implementations MUST NOT substitute the
legacy §5 three-key object itself as the v0.4 settlement hash input.

The coordinator/gateway MUST persist `(request_id, attempt_n,
provider_id, output_prefix_start_byte, output_prefix_end_byte,
output_hash)` for every attempt. Half-open byte ranges
`[output_prefix_start_byte, output_prefix_end_byte)` are the overlap
authority. Two attempts overlap when these ranges intersect. Overlap
or duplicate ranges MUST be excluded from buyer final debit and
provider positive settlement unless a later SPEC defines an explicit
deduplication transform.

If transparent failover delivers output from multiple provider
attempts, each provider attempt MUST have its own v0.4 receipt binding
the prefix attributed to that attempt. Overlapping or duplicate output
across attempts MUST be detectable. A duplicate prefix MUST NOT be
charged to the buyer or credited to any provider twice.

If delivered-prefix hash material needed for buyer debit or provider
positive settlement is unavailable, the row remains `pending` until
deadline, then maps to `quarantined` with buyer reservation released
and provider credit zero.

### §N.6 Usage object

The v0.4 `usage` field is a strict JCS object with EXACTLY these
integer fields and no others:

| Field | Type | Definition |
|---|---|---|
| `billable_input_tokens` | int64 | Input tokens eligible for buyer debit/provider settlement for this attempt. Non-negative. |
| `billable_output_tokens` | int64 | Output tokens eligible for buyer debit/provider settlement for this attempt. Non-negative. |
| `delivered_output_bytes` | int64 | Length in bytes of this attempt's canonical buyer-visible output prefix. MUST equal `output_prefix_end_byte - output_prefix_start_byte`. |
| `observed_input_tokens` | int64 | Coordinator/gateway-observed or cross-checked input token count for this attempt. Non-negative. |
| `observed_output_tokens` | int64 | Coordinator/gateway-observed or cross-checked output token count for this attempt. Non-negative. |

Null values are not allowed in `usage`. Non-creditable terminal states
MUST set `billable_input_tokens` and `billable_output_tokens` to `0`.
If a future billing profile needs non-token units, it MUST define a
successor receipt profile rather than adding optional fields to v0.4.

Provider-signed usage alone is not authority. Usage used for buyer
final debit or provider positive settlement MUST be derived from or
cross-checked against coordinator/gateway-observed canonical request
and delivered-output state under the applicable SPEC-005 rules. A
provider-only usage value maps to `quarantined` for positive money
movement.

### §N.7 Chargeability table

The v0.4 profile defines the settlement relationship for every §N.4
terminal state. These rows are deterministic for the v0.4 profile.
SPEC-005 may later absorb or replace them in a successor settlement
profile, but SPEC-022 enforce mode MUST NOT activate against v0.4
unless these exact rows or a locked successor table is implemented.

| Terminal state | Buyer final debit | Provider positive settlement | `zero_settled` possible | Required output hash material | Required usage material | Missing receipt or insufficient binding |
|---|---:|---:|---:|---|---|---|
| `normal_done` | yes, if verified | yes, if verified | no | complete delivered output | `billable_input_tokens == observed_input_tokens`; `billable_output_tokens == observed_output_tokens` | pending until deadline, then quarantined |
| `provider_error` | yes only for the verified delivered prefix when `delivered_output_bytes > 0`; otherwise no | yes only for the verified delivered prefix when `delivered_output_bytes > 0`; otherwise no | yes when `delivered_output_bytes == 0` and verified | delivered prefix or empty prefix | billable output tokens MUST be `0` when `delivered_output_bytes == 0`; otherwise billable output tokens MUST be `<= observed_output_tokens` | pending until deadline, then quarantined |
| `buyer_cancel` | yes only for the verified delivered prefix when `delivered_output_bytes > 0`; otherwise no | yes only for the verified delivered prefix when `delivered_output_bytes > 0`; otherwise no | yes when `delivered_output_bytes == 0` and verified | delivered prefix or empty prefix | billable output tokens MUST be `0` when `delivered_output_bytes == 0`; otherwise billable output tokens MUST be `<= observed_output_tokens` | pending until deadline, then quarantined |
| `gateway_timeout` | yes only for the verified delivered prefix when `delivered_output_bytes > 0`; otherwise no | yes only for the verified delivered prefix when `delivered_output_bytes > 0`; otherwise no | yes when `delivered_output_bytes == 0` and verified | delivered prefix or empty prefix | billable output tokens MUST be `0` when `delivered_output_bytes == 0`; otherwise billable output tokens MUST be `<= observed_output_tokens` | pending until deadline, then quarantined |
| `upstream_transport_disconnect` | yes only for the verified delivered prefix when `delivered_output_bytes > 0`; otherwise no | yes only for the verified delivered prefix when `delivered_output_bytes > 0`; otherwise no | yes when `delivered_output_bytes == 0` and verified | delivered prefix or empty prefix | billable output tokens MUST be `0` when `delivered_output_bytes == 0`; otherwise billable output tokens MUST be `<= observed_output_tokens` | pending until deadline, then quarantined |

`zero_settled` is only for verified non-creditable terminal states
allowed by this table or a successor SPEC-005 settlement profile. A
missing, invalid, legacy, hashless, wrong-key, wrong-attempt,
wrong-snapshot, wrong-terminal-state, or insufficient-binding receipt
MUST NOT map to `zero_settled`.

### §N.8 Settlement-verifier outcome mapping

The historical verifier tri-state (`valid`, `invalid`,
`inconclusive`) is necessary but not sufficient for settlement. v0.4
adds settlement outcomes consumed by SPEC-022:

- `pending`;
- `verified`;
- `quarantined`;
- `zero_settled`.

Mapping rules:

1. `valid` with a chargeable terminal-state row maps to `verified`
   only after every route snapshot, request attempt, model-hash,
   prompt-hash, output-hash, usage, timestamp, terminal-state, and
   receipt-key check succeeds.
2. `valid` with a non-creditable terminal-state row maps to
   `zero_settled` only when §N.7 or a successor SPEC-005 profile
   explicitly allows zero settlement for that terminal state.
3. `invalid`, mismatched, legacy, hashless, wrong-key,
   wrong-attempt, wrong-account, wrong-provider, wrong-snapshot,
   wrong-terminal-state, replayed, or insufficient-binding receipts
   map to `quarantined`.
4. Missing receipts and receipt trust-root `inconclusive` results
   remain `pending` until the configured deadline, then map to
   `quarantined`.
5. Unknown future receipt versions are `inconclusive` and not
   payable. They MUST NOT map to `verified` or `zero_settled`.

First terminal receipt selection closes the settlement row for this
attempt. Later receipts for the same attempt are idempotent no-ops or
rejected audit events and cannot change buyer debit, provider credit,
payout readiness, or settlement outcome.

### §N.9 Coordinator ingestion and storage

v0.4 requires a coordinator receipt-ingestion path that supports
settlement verification without requiring buyer action.

The coordinator MUST store parsed receipt records keyed by:

`(account_scope, request_id, attempt_n, provider_id)`.

The stored record MUST include:

- parsed verifier-safe v0.4 fields needed by SPEC-022;
- receipt verification outcome and reason;
- terminal-state timestamp and pending-deadline basis;
- route-snapshot digest and policy version/mode;
- provider receipt-key fingerprint or digest;
- catalog id/body digest and expected catalog model hash;
- prompt/output hash verification result;
- usage verification result;
- idempotency/replay status.

Raw receipt retention is allowed only where a retention/security policy
explicitly permits it. Raw receipt retention MUST be segregated from
audit, telemetry, verdict, and operator rows. Implementations MUST
never copy receipt signatures, receipt public keys, raw receipt
envelopes, raw prompts, raw outputs, bearer tokens, receipt private
keys, or provider-private state into audit, telemetry, verdict, or
operator rows.

The coordinator MUST expose internal verification APIs for SPEC-022
settlement code. This v0.4 SPEC does not itself add provider-positive
credit, buyer final debit, payout-ready insertion, or SPEC-022 enforce
activation.

### §N.10 Trust boundary

A v0.4 settlement `verified` outcome means:

- the receipt signature verified against the route-snapshot-pinned
  provider receipt-key identity;
- the receipt bound the exact account/request/attempt/provider row;
- the receipt bound the same model id and non-null model hash as the
  route-time catalog snapshot;
- the receipt proved
  `receipt.model_hash == route_snapshot.provider_reported_model_hash ==
  route_snapshot.expected_catalog_model_hash`;
- prompt/output hashes matched the persisted canonical material;
- usage was derived from or cross-checked against coordinator/gateway
  observation;
- timestamp/window checks passed;
- terminal-state and chargeability checks passed.

v0.4 does NOT prove that a malicious provider cannot falsify its own
local model-hash measurement before reporting it. That boundary remains
outside SPEC-015 without hardware/runtime attestation. Product and
buyer-facing language MUST NOT claim more than this.

### §N.10.1 Compute-integrity digest binding decision

SPEC-015 v0.4 receipts MUST NOT include request-start compute-integrity state
digests, sampler state, SPEC-036 policy digests, probe/reference digests, or
SPEC-036 audit-artifact digests in the signed tuple or strict `usage` object.
Any such field in a `receipt_version: "4"` tuple is an extra field under §N.1
and AC-43.

This is deliberate. SPEC-015 v0.4 proves settlement tuple integrity and
provider receipt-key accountability. SPEC-036 compute integrity is
coordinator-owned sampled/overt drift evidence and may narrow settlement only
through the SPEC-022/SPEC-036 policy gate. A v0.4 verifier MUST NOT infer
compute-integrity state, adverse-state absence, or proof of honest computation
from the receipt alone.

If externally reviewable request-start compute-integrity binding is required,
the compatible path is a separate SPEC-036 audit artifact keyed to the same
account/request/attempt/provider, route-snapshot digest, and digest of the
provider-signed SPEC-015 tuple. That artifact is not itself a SPEC-015 receipt
and is not required for v0.4 receipt validity. A future SPEC-015 successor MAY
reference a SPEC-036 artifact digest only by defining a new `receipt_version`
and verifier behavior; it MUST NOT be added as an optional v0.4 field.

### §N.11 Acceptance criteria

The v0.4 implementation MUST satisfy these acceptance criteria before
SPEC-022 can consume the profile:

- **AC-43:** A v0.4 receipt with missing or extra tuple fields is
  rejected before settlement.
- **AC-44:** `receipt_version` MUST be exactly `"4"` for the v0.4
  profile. A v0.3 verifier reports it as
  `inconclusive: unknown_receipt_version`.
- **AC-45:** `model_hash: null` is not settlement-capable and maps to
  `quarantined` for SPEC-022 positive money movement.
- **AC-46:** A receipt whose `request_id`, `attempt_n`,
  `account_scope`, `provider_id`, or `provider_receipt_key_id` differs
  from the ledger row maps to `quarantined`.
- **AC-47:** A receipt whose route snapshot digest or route-time
  policy version/mode differs from the ledger row maps to
  `quarantined`; the test fixture computes
  `sha256(UTF-8(JCS(route_snapshot_v1)))` and mutates each
  route-validity field in §N.2 at least once.
- **AC-48:** A receipt verifies the three-way model-hash equality and
  quarantines on any mismatch.
- **AC-49:** Prompt/output hash mismatch maps to `quarantined`.
- **AC-50:** Prompt/output canonical hash unavailable maps to
  `quarantined`; entrypoints that cannot persist canonical hashes are
  excluded from paid SPEC-022 traffic.
- **AC-51:** Provider-signed usage without coordinator/gateway
  cross-check cannot produce buyer final debit or provider positive
  settlement; fixtures cover missing usage fields, extra usage fields,
  null usage values, negative usage values, and mismatched
  `delivered_output_bytes`.
- **AC-52:** Non-streaming `normal_done` with a settlement-capable,
  catalog-matching v0.4 receipt can map to `verified`.
- **AC-53:** Streaming `normal_done` produces an internally
  verifiable v0.4 receipt without breaking OpenAI-compatible clients;
  the test hashes `settlement_output_v1` and verifies the
  half-open prefix byte range.
- **AC-54:** Streaming `provider_error` binds terminal state, output
  hash material, and usage material required by its chargeability row.
- **AC-55:** Streaming `buyer_cancel` binds terminal state, delivered
  prefix, and partial usage when any partial money movement is allowed.
- **AC-56:** Streaming `gateway_timeout` binds terminal state,
  delivered prefix, and partial usage when any partial money movement
  is allowed.
- **AC-57:** Streaming `upstream_transport_disconnect` binds terminal
  state, delivered prefix, and partial usage when any partial money
  movement is allowed.
- **AC-58:** Partial-output binding unavailable remains pending until
  deadline, then quarantines with buyer reservation released and no
  provider credit.
- **AC-59:** Transparent failover emits one receipt per
  provider-attempt prefix and prevents duplicate/overlapping prefix
  double charge or double credit; fixtures include adjacent ranges,
  overlapping ranges, duplicate ranges, and an out-of-order retry.
- **AC-60:** Replaying a valid receipt onto a different account,
  request, attempt, provider, key, snapshot, or terminal state cannot
  produce positive money movement.
- **AC-61:** Resubmitting a receipt after a terminal outcome is
  idempotent and cannot create a second buyer debit, provider credit,
  or payout-ready row.
- **AC-62:** A valid receipt arriving after deadline quarantine does
  not resurrect the row; fixtures prove the receipt
  `terminal_state_ts_unix_ms` must exactly equal the
  coordinator/gateway ledger timestamp and that `issued_at_unix_ms`
  cannot extend the deadline.
- **AC-63:** Unknown future receipt versions are inconclusive and not
  payable.
- **AC-64:** Legacy v0.1/v0.2/v0.3 receipts are not settlement-capable
  for SPEC-022 enforce mode.
- **AC-65:** Audit/telemetry/verdict rows redact raw receipt
  signatures, raw receipt public keys, raw receipt envelopes, raw
  prompts, raw outputs, bearer tokens, receipt private keys, and
  provider-private state.
- **AC-66:** Raw receipt retention, if enabled, is segregated from
  audit/telemetry/verdict/operator rows and is covered by an explicit
  retention/access policy.
- **AC-67:** Provider/issuer docs or API surfaces expose the receipt
  submission deadline or `pending_deadline_seconds` basis and disclose
  late receipt non-settlement.
- **AC-68:** Buyer/product disclosures state that v0.4 verifies the
  provider-reported request-start model hash against the route-time
  catalog snapshot and does not detect a provider that falsifies its
  own measurement.
- **AC-69:** A receipt whose `signature_key_alg` is absent or present
  with any value other than `"Ed25519"` is rejected before settlement.
- **AC-70:** `provider_receipt_key_id` is exactly
  `ed25519-sha256:<64 lowercase hex>` over the raw 32-byte Ed25519
  public key pinned in the route snapshot; a receipt signed by any
  other key or carrying any other fingerprint maps to `quarantined`.
- **AC-71:** Each §N.7 terminal-state row is exercised for
  `delivered_output_bytes == 0` and `delivered_output_bytes > 0`,
  proving the deterministic `verified` vs `zero_settled` mapping.

---

## 11. Audit categories

The following audit categories are added (SPEC-006 v0.9 candidate
absorption; tracked locally for now):

- `receipt_issued`: emitted by the provider when a receipt is written
  to the response. Event-specific fields: `model_id`, `tokens_out`,
  `ttft_ms`, `unix_ts`. The audit-record envelope (`provider_id`,
  `request_id`, event timestamp) is inherited from the common
  SPEC-005 v0.3 §6 audit-sink envelope and MUST NOT be duplicated
  inside the event-specific block. Implementations MUST NOT log the
  receipt's `provider_pubkey`, `prompt_hash`, `output_hash`, or
  signature into the audit sink: the receipt is a buyer-held proof,
  not a server-side audit row.
- `receipt_omitted`: emitted by the provider/coordinator/gateway when
  a receipt is suppressed per §6.4. Fields: `provider_id`,
  `request_id`, `reason` (`pre_v1_6_binary` | `no_keypair` |
  `model_swap_violation` | `pre_token_cancel` | `streaming_request`).
  **v0.3 update:** the `model_swap_violation` reason is PROMOTED from
  v0.1/v0.2 placeholder to defined semantics per §M.2.2: the
  provider's runtime was in `loading` or `draining` state at
  receipt-emission time AND could not disambiguate which container
  served the response. Emission is constrained to the
  defence-in-depth path of §M.2.2; the normal §M.2.2 construction
  (every receipt commits to the hash at request START) does NOT
  fire this reason. Operator monitoring SHOULD treat any
  `receipt_omitted: model_swap_violation` event as an
  implementation regression to investigate.
- `receipt_rotation_detected`: emitted by the coordinator when a
  reconnecting provider's `auth_request.provider_receipt_public_key`
  differs from the previously-known pubkey for that `provider_id`.
  Historical v0.1 through v0.3 fields: `provider_id`, `old_pubkey`,
  `new_pubkey`, `rotated_at`.
  This event replaces the v0.1/v0.1.1 `receipt_rotate_request` and
  `receipt_rotate_invalid` events, which are no longer emitted
  because v0.1.2 rotation is reconnect-based, not control-frame
  based.
  **v0.4 redaction update:** settlement-capable deployments MUST emit
  `old_pubkey_fingerprint` and `new_pubkey_fingerprint` using the
  §N.1 `ed25519-sha256:<hex>` form instead of raw `old_pubkey` /
  `new_pubkey` in audit, telemetry, verdict, or operator rows. Raw
  public keys remain available only from the key-resolution surface
  that verifies signatures, not from audit rows.
- `settlement_receipt_ingested` (v0.4): emitted by the coordinator
  when a v0.4 receipt is ingested through an internal settlement
  channel. Fields: `account_scope`, `request_id`, `attempt_n`,
  `provider_id`, `receipt_version`, `terminal_state`,
  `route_snapshot_digest`, `route_snapshot_policy_version`,
  `route_snapshot_mode`, `catalog_id`, `catalog_body_digest`,
  `provider_receipt_key_fingerprint`, `model_id`, `model_hash`,
  `expected_catalog_model_hash`, `prompt_hash`, `output_hash`,
  `usage_digest`, `received_at_unix_ms`. MUST NOT include raw receipt
  signatures, raw receipt public keys, raw receipt envelopes, raw
  prompts, raw outputs, bearer tokens, receipt private keys, or
  provider-private state.
- `settlement_receipt_verdict` (v0.4): emitted when a v0.4 settlement
  verifier maps a receipt or missing receipt to `pending`, `verified`,
  `quarantined`, or `zero_settled`. Fields: all
  `settlement_receipt_ingested` scalar fields plus `settlement_outcome`,
  `reason`, `deadline_unix_ms`, and redacted verifier diagnostics. Raw
  receipt material remains prohibited.

`receipt_issued` is a high-cardinality event (one per response). Its
audit destination is the existing SPEC-005 v0.3 §6 billing audit
sink; the four event-specific scalar fields named above
(`model_id`, `tokens_out`, `ttft_ms`, `unix_ts`) plus the inherited
audit envelope are the complete v0.1.3 audit shape.

---

## 12. Failure modes summary

Rows below preserve v0.1.x through v0.3 behavior. v0.4 supersedes the
streaming and settlement-capable rows through §N. Streaming requests can
produce v0.4 receipts through coordinator-internal channels, while
v0.1.x through v0.3 streaming requests carry no receipt regardless of
outcome.

All historical rows below describe **non-streaming**
`POST /v1/chat/completions` behavior unless explicitly noted.

| Condition | Receipt? | Header value | finish_reason | tokens_out |
|---|---|---|---|---|
| Normal non-streaming completion | yes (header) | populated | `stop` \| `length` \| `tool_calls` \| `content_filter` | reported |
| Streaming request (any outcome) | no (v0.1.x out of scope; v0.2+ design pending) | absent | n/a | n/a |
| Buyer HTTP disconnect mid-response on non-streaming | no | absent | n/a | n/a (provider has no full response to commit to and no buyer to deliver a receipt to) |
| Provider returns SPEC-001 null-usage error | yes | populated | `error` | `0` |
| Pre-v1.6 binary | no | absent | n/a | n/a |
| Model swap drain violation (defensive) | no, 500 returned | absent | n/a | n/a |
| Gateway/coordinator internal failure (provider never reached) | no | absent | n/a | n/a |

SPEC-005 v0.3 §X-1 settlement semantics for non-streaming
disconnects continue to apply on the billing side; v0.1.x simply
declines to emit a receipt for the partial-response disconnect case
because there is no buyer-deliverable receipt to commit to. A
v0.2+ design that captures partial-response receipts is open
design space.

---

## 13. Storage and persistence

v0.1.3 pins ONLY the provider-side Keychain storage (because the
private key is a security-critical artifact) and the audit-log
emission (because audit events are observable behavior). Coordinator
and gateway storage are implementation concerns named in the future
BUILD spec, per the §7.3 deferral.

| Surface | Field | Type | Notes |
|---|---|---|---|
| Provider Keychain | `com.malibu.provider.receipt-key/<provider_id>` | 32-byte raw ed25519 private key | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `Synchronizable=false` |
| Coordinator memory | `Provider.ReceiptPubkey []byte` | 32 bytes | populated on auth, lifetime tied to WS session unless the BUILD spec adds durable storage |
| Audit log | `receipt_issued` event | JSON | per response, fields per §11 |

The coordinator and gateway MUST NOT store the receipt value (the
`X-MacProvider-Receipt` header bytes) server-side under v0.1.x. The
receipt is buyer-held proof; persisting it server-side would defeat
the offline-verifiability property and create a server-side trove
of prompt/output digests the operator does not need. There is no
exception in v0.1.x: streaming receipts are out of scope (§6.3), so
no server-side retention is needed for any v0.1.x receipt path. A
future v0.2+ streaming-receipt design that needs server-side
storage MUST name its own retention contract and re-establish the
buyer-held-proof posture or accept the v0.1.x divergence
explicitly.

v0.4 accepts that divergence for settlement-capable receipts. The
coordinator MUST ingest and store parsed verifier-safe receipt fields
for internal settlement. Raw receipt retention, if enabled, is governed
by §N.9 and MUST be segregated from audit, telemetry, verdict, and
operator rows.

---

## 14. Acceptance criteria

Each AC is independently verifiable from outside this SPEC.

**AC-1.** A v1.6 `phase3-binary serve` process on first launch
generates an ed25519 keypair, stores it in macOS Keychain at
service `com.malibu.provider.receipt-key` account
`<provider_id>`, and on a fresh launch with the same `provider_id`
reads the same private key bytes from Keychain (verify by computing
the public key from the stored private key and comparing against the
expected pubkey).

**AC-2.** A v1.6 binary's v2 `auth_request` initial-stage frame
carries `provider_receipt_public_key` as a 44-character base64
string. Decoding it yields exactly 32 bytes.

**AC-3.** A v1.5 binary (pre-v1.6) does NOT carry
`provider_receipt_public_key` on the auth frame; the coordinator
admits it successfully and its `/poolz` row shows
`receipt_pubkey: null`.

**AC-4.** For a v1.6 provider serving a non-streaming
`POST /v1/chat/completions` with a fixed model, prompt, and
`temperature: 0`, the response carries an `X-MacProvider-Receipt`
header. The value parses as `<base64>.<base64>`. The first base64
decodes to UTF-8 JSON containing exactly the seven SPEC-015 §3.1
keys; the second base64 decodes to exactly 64 bytes.

**AC-5.** For the same request as AC-4, recomputing the canonical
prompt object per §4 and hashing it yields a 64-character lowercase
hex string identical to `receipt.prompt_hash`.

**AC-6.** For the same request as AC-4, recomputing the canonical
output object per §5 from the response body and hashing it yields a
64-character lowercase hex string identical to `receipt.output_hash`.

**AC-7.** For the same request as AC-4,
`ed25519_verify(receipt.provider_pubkey, base64_decode(b64_tuple),
base64_decode(b64_sig))` returns true.

**AC-8.** For a streaming `POST /v1/chat/completions`, the response
carries NO `X-MacProvider-Receipt` header AND NO additional
`X-MacProvider-*` response header beyond what SPEC-006 v0.8.3 §17
already allowlists. The SSE stream itself is exactly what SPEC-001
v1.5 and SPEC-006 v0.8.3 already specify (no extra `event:` blocks,
no non-OpenAI-shaped `data:` payloads). Receipts for streaming
requests are out of scope in v0.1.x.

**AC-9.** The OpenAI Python SDK ≥ v1.0 and the OpenAI JavaScript
SDK ≥ v4.0, with `base_url` pointing at the SPEC-006 gateway, MUST
complete `chat.completions.create(...)` (non-streaming) AND
`chat.completions.create(stream=True)` successfully against a v1.6
provider. The non-streaming response carries an
`X-MacProvider-Receipt` header (which the SDK ignores transparently);
the streaming response carries no SPEC-015 wire changes. The SDK
MUST NOT raise on either request shape.

**AC-10.** Running `macprovider rotate-key` on a connected
v1.6 binary causes the binary to close its current WS connection
and reconnect with a freshly-generated keypair in the v2
`auth_request` initial-stage `provider_receipt_public_key` field.
On successful reconnect, the coordinator's `/poolz` row for this
provider reflects the new pubkey under `receipt_pubkey` and the old
pubkey under `receipt_pubkey_prev` with
`rotated_at` = the reconnect time. The next response after rotation
is signed with the new key. If reconnect fails (coordinator rejects
auth or network failure), the CLI exits non-zero, the Keychain
state is unchanged, and the binary continues signing with the old
key on its restored WS session.

**AC-11.** During the 7-day rotation grace window, a buyer who
fetches `/poolz`, sees `receipt_pubkey_prev.expires_at` in the
future, and verifies a receipt against `receipt_pubkey_prev.pubkey`
succeeds for receipts whose `unix_ts` is between
`receipt_pubkey_prev.rotated_at - 60` and
`receipt_pubkey_prev.expires_at`. The −60 s slack covers in-flight
requests on the old key at rotation time (a provider may have begun
signing a receipt with the old key up to ~60 s before the
reconnect-based rotation was accepted by the coordinator).

**AC-12.** A SPEC-001 null-usage error response (e.g.
`error_model_not_loaded`) on a v1.6 provider carries an
`X-MacProvider-Receipt` header with `tokens_out: 0`,
`output_hash` equal to the sha256 of the canonical output object
`{"content":"","tool_calls":null,"finish_reason":"error"}`, and
verifies cleanly against the provider pubkey.

**AC-13.** A request that the gateway rejects before reaching any
provider (auth failure, quota exhausted, kill switch on) does NOT
carry an `X-MacProvider-Receipt` header.

**AC-14.** A non-streaming request routed to a coordinator-recorded
provider whose `receipt_pubkey` is `null` (pre-v1.6 binary) does
NOT carry an `X-MacProvider-Receipt` header.

**AC-15.** The `X-MacProvider-Receipt` header value is ≤ 4096
ASCII bytes for the v0.1.3 tuple shape; nginx between gateway and
buyer MUST be configured (or already configured) to forward headers
of this size without truncation.

**AC-16.** The receipt-issuing path MUST NOT introduce >5 ms p95
overhead over the existing SPEC-001 v1.5 baseline for a
1024-output-token completion on the smallest supported model. The
overhead is dominated by SHA-256 + ed25519_sign on a payload of ≤
600 bytes; on Apple Silicon, both are sub-millisecond.

**AC-17.** The SPEC-001 v1.6 candidate annotation
(`provider_receipt_public_key` field on `auth_request` initial-stage
ONLY) MUST be parser-optional on the coordinator: a v1.6 binary
that omits the field due to keypair-generation failure MUST still
admit successfully, the coordinator MUST log
`receipt_omitted: reason=no_keypair`, and the provider MUST be
flagged in its `/poolz` row as `receipt_pubkey: null` until a
subsequent reconnect with the field present.

### v0.2 additions: verifier acceptance criteria

**AC-18.** `macprovider verify --bundle <fresh-receipt-bundle.json>`
MUST exit `0` with `result: "valid"` for a bundle whose receipt
was issued by a v1.6 binary against a matching prompt/response,
where `GET /v1/receipt-keys/<bundle.provider_id>` (§10.7) on the
configured coordinator returns the issuing pubkey as
`receipt_pubkey` (current key) at the time of verification.

**AC-19.** Flipping a single byte in
`response.choices[0].message.content` of the bundle and re-running
`macprovider verify --bundle ...` MUST exit `1` with
`result: "invalid"`, `details.field: "output_hash"`, and the
non-matching computed/receipt hash pair populated.

**AC-20.** Flipping a single character in
`request.messages[0].content` (e.g. a single Unicode codepoint
change) MUST exit `1` with `result: "invalid"` and
`details.field: "prompt_hash"`.

**AC-21.** Mutating any byte of the base64-decoded signed tuple
(e.g. flipping the last digit of `unix_ts`) without re-signing
MUST exit `1` with `result: "invalid"` and `reason` referencing
signature verification failure (the signature check fails before
any field-level mismatch is reported).

**AC-22.** With `GET /v1/receipt-keys/<provider_id>` unreachable
(configured coordinator host returns connection refused, 5xx, or
timeout within the §10.5 5-second budget) AND no fresh cached
entry for `(coordinator_host, provider_id, receipt_pubkey)` AND no
`--pubkey` argument, `macprovider verify --bundle <bundle.json>`
MUST exit `2` with `result: "inconclusive"`,
`trust_source: "none"`, and a `warnings[]` entry of kind
`live_check_skipped` with `reason: "network_unreachable"`.

**AC-23.** `macprovider verify --offline --pubkey
<correct-44-char-base64> --provider-id <id> --bundle <bundle.json>`
MUST exit `0` with `result: "valid"` AND emit ZERO network traffic
to any host. (Test this by running in a sandbox that denies all
egress; observe exit 0 and no DNS / TCP attempts.) JSON output
MUST include a `warnings[]` entry of kind `live_check_skipped`
with `reason: "offline_flag"`.

**AC-24.** `macprovider verify --json` output MUST be exactly one
line of JSON conforming to the §10.4.2 field table. The verifier
implementation's release artifact MUST include a JSON-Schema
document covering `valid`, `invalid`, and `inconclusive` outputs
(including the `details` and `warnings[]` shapes), and the
verifier's test suite MUST validate every output across its
acceptance fixtures against that schema. The schema document MUST
be addressable from the release (e.g. published alongside the
binary) so independent buyer-side automation can validate verifier
output without re-deriving the schema from this spec.

**AC-25.** Each of the five normative exit codes (`0`, `1`, `2`,
`64`, `65`) MUST be reachable by a concrete invocation pinned in
the verifier's acceptance test suite. `64` is reachable e.g. via
`macprovider verify --unknown-flag` or `macprovider verify
--pubkey badbase64== --bundle good.json` (malformed flag value).
`65` is reachable e.g. via `macprovider verify --bundle
<malformed.json>`, a bundle with `bundle_version: 99`, a bundle
with an unknown top-level key, or a receipt header value that
fails to split on `.`. The `64` vs `65` boundary defined in
§10.4.3 MUST hold across all paths.

**AC-26.** A cache entry whose `fetched_at` is more than 7 days
before the verifier's wall clock MUST trigger a fresh
`GET /v1/receipt-keys/<provider_id>` fetch on the next
verification attempt that would use it. The acceptance test suite
MUST verify this by mocking the cache `fetched_at` and asserting
an outgoing HTTP `GET /v1/receipt-keys/...` call is made against
the configured coordinator host. If the live fetch fails AND no
fresh source remains, the verifier MUST exit `2`
(`inconclusive`); the stale entry MUST NOT be used to produce
`valid` per §10.2.

**AC-27.** A receipt issued during the §7.5.2 7-day rotation
grace window verifies `valid` if and only if ALL of the following
hold simultaneously: (a) the resolved `/v1/receipt-keys/<provider_id>`
response contains a non-null `receipt_pubkey_prev` block whose
`pubkey` field matches the receipt's `provider_pubkey`, AND (b)
the receipt's `unix_ts` satisfies `rotated_at - 60s ≤ unix_ts ≤
expires_at` per the previous-key block. A previous-key match
OUTSIDE this interval MUST verify `invalid` with
`reason: "previous_key_outside_grace_window"`. A receipt whose
`provider_pubkey` appears in neither `receipt_pubkey` nor
`receipt_pubkey_prev.pubkey` for the resolved `provider_id` MUST
verify `invalid` with `reason: "pubkey_not_endorsed"` (not
`inconclusive`).

---

## 15. Open questions

These are flagged for v0.x audit cycles and are NOT resolved in
v0.1. Implementers MUST NOT pin behavior in v0.1 that pre-decides
these.

**Q1: Stronger trust root.** Should the buyer-facing
`GET /v1/receipt-keys/<provider_id>` endpoint (SPEC-015 v0.2 §10.7
candidate annotation) eventually be signed by an offline operator
key (TUF-style) or anchored to an external registry (AntFeed
provider listing, an on-chain Cluster D-token registry)? v0.2
inherits v0.1's honest acknowledgement that the coordinator-
returned pubkey set is operator-mutable; v0.2 narrows the
buyer-exposed surface from the operator-only `/poolz` to the
public `/v1/receipt-keys` endpoint, but does NOT add a signature
or anchor on top. The §10.7 endpoint is the natural foundation
for the v0.3+ work — TUF / on-chain anchoring would sign the
response shape pinned in §10.7. v0.3+ candidate.

**Q2: Replay-resistance and request-id binding. RESOLVED in v0.4.**
§N.1 and §N.3 require `account_scope`, `request_id`, monotonic
`attempt_n`, `provider_id`, `provider_receipt_key_id`, and
`route_snapshot_digest` binding. Replay onto a different account,
request, attempt, provider, key, route snapshot, or terminal state
maps to `quarantined`.

Historical note: before v0.4 the receipt did
NOT bind `request_id`. A malicious replay of the response body to a
different buyer would yield the same `output_hash` for the same
prompt. Should the receipt commit to `request_id` or a buyer-supplied
nonce? If so, where does the buyer obtain its expected `request_id`?
v0.2 §10.6 (trust boundary) named replay-resistance as explicitly
NOT proven by a `valid` result.

**Q3: Cross-provider routing.** Once Cluster F sharding lands, a
single response may span multiple provider segments. Receipt-per-
segment with a buyer-side concatenation rule, or receipt-per-response
with an embedded route list signed by an aggregating coordinator?
v0.4+ candidate.

**Q4: Timestamp trust. RESOLVED for settlement in v0.4.** §N.3 defines
the settlement timestamp/window policy. Provider `issued_at_unix_ms`
and terminal-state timestamps are checked against the exact
account/request/attempt settlement window; skew must be explicit and
fail closed for positive settlement.

Historical note: `unix_ts` is provider-reported. Should the
buyer cross-check against the coordinator's response timestamp, and
what skew window is acceptable? **Partially addressed in v0.2:**
§10.6 names timestamp honesty as explicitly NOT proven by a `valid`
result; §10.0 step 9 removes the v0.1-sketch optional skew check
to avoid implying timestamp attestation. Full normative skew-check
(buyer-recorded received-at vs `unix_ts` with operator-set window)
remained open before v0.4.

**Q5: Streaming receipt delivery mechanism. RESOLVED for settlement in
v0.4.** §N.5 chooses coordinator-internal streaming receipt delivery:
provider terminal frame, post-stream internal receipt submission, or
another SDK-safe internal channel. Buyer retrieval is optional and not
a settlement dependency. The client-facing SSE stream remains
OpenAI-compatible and does not require receipt-only non-standard
`data:` events.

Historical note: v0.1's terminal
`event: receipt` SSE block was rejected in the round-1 audit (C1)
because the OpenAI Python and JavaScript SDKs JSON-parse every
non-`[DONE]` `data:` payload and would raise on a base64 receipt
string. v0.1.1's `X-MacProvider-Receipt-Pending` correlator header
was rejected in the round-2 audit (C1) because it added a second
buyer-visible `X-MacProvider-*` response header outside the single
SPEC-006 v0.9 candidate allowlist annotation. v0.1.2 therefore drops
streaming receipt delivery entirely.

Earlier candidates were:

(a) An OpenAI-shape extra field on the final chat-completion chunk
    (e.g. `x_macprovider_receipt` on the last `data: {...}` payload).
    Requires verifying that both SDKs' Pydantic / zod parsers
    tolerate the extra field across pinned versions.
(b) A separate `GET /v1/receipts/<request_id>` endpoint on the
    gateway, with a clearly-bounded retention contract and
    buyer-correlator delivery via an SPEC-006 v0.x candidate
    response header annotation.
(c) An HTTP trailer when the buyer SDK supports it (rare today).
(d) Acceptance that streaming requests never carry receipts — the
    buyer who needs a receipt issues a non-streaming equivalent.

v0.4 leaves the envelope format §3.4 unchanged but moves streaming
delivery to the internal settlement channel described by §N.5.

**Q6: Model-hash binding (SPEC-011 cross-cut). RESOLVED in v0.3.**
Folding `heartbeat.model_hash` (SPEC-011 v0.5 §3.3.1) into the
receipt tuple is the v0.3 §M work. v0.3 extends the tuple from 7
fields to 9 (adding `model_hash` and `receipt_version`), pins the
provenance semantics (§M.2), defines a catalog-verifier
extension (§M.3), and adds a `/poolz` catalog surface (§M.4).
**This Q6 closure is ORTHOGONAL to coordinator-side enforcement.**
`Tier2Config.RequireHashVerified` remains at its `false` default
per `beta/DECISION_CRITERIA.md` 2026-06-22 Entry 80; v0.3 makes
the receipt BIND the hash, but the operator-side decision to
REJECT providers on hash mismatch is independent and unchanged.
The Entry 80 deferral triggers (pool size growth, catalog
pipeline ergonomics, buyer demand) still gate that flip;
v0.3 receipts are usable by buyers who want catalog-match
attestation REGARDLESS of how the operator routes.

**Q7: Multi-hash receipts for swap-spanning streaming responses. CLOSED
AS OUT OF SCOPE for v0.4 settlement.**
v0.3 §M.2.2 NORMATIVELY REFUSES the shape of a single receipt
binding two `model_hash` values for one response. v0.4+ may
introduce a multi-hash receipt to represent legitimately
swap-spanning streaming responses (Q5 streaming + a swap mid-
stream). v0.4 settlement continues the one-request-attempt,
request-start model-hash rule from §N.2 and SPEC-022. Future design
questions remain: should a later receipt profile commit
to (`first_hash`, `last_hash`) or to (`hash_per_chunk_range`)?
How does the verifier compose multiple catalog lookups under
a single tuple? Is the wire-shape extension a new
`receipt_version: "5"` or a separate multi-segment profile?

**Q8: Compute-integrity request-start state digest binding. RESOLVED for
v0.4 by #1010.** §N.10.1 keeps SPEC-036 request-start state digests outside
the v0.4 signed tuple and strict `usage` object. The accepted compatible path is
a separate SPEC-036 audit artifact keyed to the same request attempt and digest
of the provider-signed SPEC-015 tuple. A future SPEC-015 successor MAY reference
that artifact digest only through a new `receipt_version`; v0.4 MUST NOT grow
optional compute-integrity fields. External v0.4 verifiers continue to reject
extra fields and to classify unknown future versions as inconclusive.

---

## 16. README compatibility and references

### 16.1 README v1 schema → SPEC-015 v0.1.1 compatibility table

The README §"Roadmap" block at lines 117–128 sketches a v1 receipt
schema. SPEC-015 v0.1.1 changes several field names and conventions
relative to that sketch. The differences are deliberate; the audit
M8 finding required explicit per-field justification.

| README sketch field | SPEC-015 v0.1.1 field | Change | Why |
|---|---|---|---|
| `model` | `model_id` | Renamed | Matches SPEC-001 v1.5 §6.4 and SPEC-002 v1.3.5 naming; `model_id` is the canonical identifier in the rest of the corpus. |
| `prompt_hash: "sha256:7c3f..."` | `prompt_hash: "<64 lowercase hex>"` | Prefix stripped | The receipt only ever uses sha256; embedding the algorithm name doubles the payload and invites parser ambiguity. Verifiers know the algorithm from the SPEC version. |
| `output_hash: "sha256:9b2a..."` | `output_hash: "<64 lowercase hex>"` | Prefix stripped | Same as `prompt_hash`. |
| `provider_id: "m1-anon"` | (NOT in tuple; in `/poolz` only) | Field removed from receipt | The cryptographic identity is the pubkey; `provider_id` is an operator-mutable label and is intentionally out-of-band via `/poolz`. See §3.1 "Why `provider_id` is NOT in the tuple". |
| `provider_pubkey: "ed25519:..."` | `provider_pubkey: "<44-char base64>"` | Algorithm prefix stripped | Same reasoning as the hash prefixes; v0.1.1 pins ed25519. Algorithm agility is v0.x+. |
| `ttft_ms: 646` | `ttft_ms: <int64>` | Unchanged semantics | Pinned as int64. |
| `tokens_out: 142` | `tokens_out: <int64>` | Unchanged semantics | Reused from SPEC-005 §4 `effective_completion_tokens`. |
| `ts: "2026-06-04T12:34:56Z"` | `unix_ts: <int64 Unix seconds UTC>` | Renamed + integerized | RFC3339 strings introduce a canonicalization surface (decimal subseconds, timezone offsets, separator characters) that doesn't add value; integer Unix seconds is unambiguous. |
| `sig: "ed25519:..."` | (transported as the post-`.` segment of the `X-MacProvider-Receipt` header value, not as a tuple field) | Moved out of tuple, prefix stripped | The signature MUST NOT be inside the signed payload. v0.1.1's `<base64-tuple>.<base64-sig>` envelope keeps the two cleanly separated. |
| "issued by the gateway" (README §"Roadmap" prose) | Issued by the PROVIDER | Architectural change | The gateway does not know the provider's private key, by design. Provider-side signing is what makes the receipt verifiable against `/poolz`'s `receipt_pubkey` without trusting the operator. The README will be updated when v0.1.1 lands to reflect provider-side issuance. |

### 16.2 References

- README.md:22 — the verifiable-inference vapor claim this SPEC
  closes.
- README.md:117–128 — the v1 receipt schema sketch (compatibility
  table above explains each deviation).
- `audits/2026-06-10/REPO_AUDIT.md` — Open Question 1 (receipts
  unimplemented) the audit raised.
- `beta/DECISION_CRITERIA.md` Entries 79–81 — operator context for
  the 2-person beta posture in which v0.1 ships.
- SPEC-001 v1.5 §6.7 — v2 `auth_request` handshake, which v0.1
  annotates with the `provider_receipt_public_key` field.
- SPEC-002 v1.3.5 §7 — `/poolz` shape, which v0.1 annotates with
  `receipt_pubkey`.
- SPEC-005 v0.3 §3 X-1 row — null-usage settlement, which v0.1's
  §7.6 receipt for null-usage errors composes with.
- SPEC-005 v0.3 §4 — `effective_completion_tokens` derivation,
  which `tokens_out` reuses.
- SPEC-006 v0.8.3 §17 — header allowlist; SPEC-015 v0.1 adds
  `X-MacProvider-Receipt` to the response pass-through allowlist as
  a SPEC-006 v0.9 candidate.
- SPEC-008 v0.3 §5.3, §6 — Pillar A model-hash and Pillar B
  encrypted-leg semantics; v0.1 is orthogonal to both.
- SPEC-011 v0.5 §3.2 (warm-swap state machine), §3.3
  (heartbeat extension, R-3.3.0 opt-in gating, R-3.3.1 raw
  64-hex format), §3.4 (drain semantics, R-3.4.1 in-flight
  tracking, R-3.4.2 drain timeout) — `model_hash` heartbeat
  and warm-swap drain; v0.1's §7.4 invariant relies on §3.4
  drain semantics. (v0.1.3 originally cited "§3.3.1 and §3.8";
  v0.3 audit-round-1 A5 normalized this to §3.2/§3.3/§3.4
  which are the sections v0.3 §M.2 actually rests on.)
- SPEC-013 v0.3 — `autotune` subcommand; this SPEC reuses
  `RFC8785JCS.swift` from SPEC-013's implementation.
- RFC 8785 — JSON Canonicalization Scheme.
- RFC 8032 — EdDSA / ed25519.
- `phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift` —
  in-house JCS implementation.

**v0.3 additional references:**

- `scripts/sign-catalog.go` (line 31 — `sha256` field name; line
  42-49 — canonical-body key order; line 145 — RawURLEncoding
  signature) — the catalog signing tool; v0.3 verifier's catalog
  parse + verify path consumes the output of this tool.
- `phase4-coordinator/internal/tier2/catalog.go` (line 22 —
  64-hex regex; line 45 — `ParsedCatalog.CatalogID`; line 64 —
  `catalogFile` schema; line 164-237 — catalog reload/swap
  semantics) — the existing catalog parser/verifier; v0.3
  re-implements the parse + verify path in pure Go in
  `phase7-verify/` rather than importing this package.
- `phase4-coordinator/internal/config/config.go` lines 142, 335
  — current state of `Tier2Config.RequireHashVerified` (default
  false, observation mode); v0.3 §M.6 #1 preserves this default
  unchanged.
- `beta/DECISION_CRITERIA.md` Entry 80 (2026-06-22) — operator
  ruling on `RequireHashVerified` deferral; v0.3 §M.6 #1
  inherits this deferral verbatim.
- SPEC-008 v0.3 §5.3-5.6 — Pillar A model-hash semantics + the
  five-state HashStatus enum the coordinator uses; v0.3
  verifier's catalog-check path is a buyer-side mirror of the
  coordinator-side check, NOT a replacement for it.
- SPEC-010 v1.5 — `supported_models[]` /
  `publishes_supported_models` semantics; informs which providers
  participate in hash attestation orthogonal to v0.3 receipt
  issuance (a provider may serve a model it has not declared
  in `supported_models`; the receipt's `model_hash` still binds
  whatever container is loaded).
- SPEC-011 v0.5 §3.2 — warm-swap state machine
  (`ready`/`loading`/`draining`/`ready` per §3.2 transitions);
  v0.3 §M.2.2 enforces the mid-swap refusal via this state.
- SPEC-011 v0.5 §3.3 (heartbeat extension) and R-3.3.0
  (opt-in gating: `--enable-warm-swap=true` is the precondition
  for `model_hash` reporting); v0.3 §M.2.3 inherits the
  opt-in nature.
- SPEC-011 v0.5 §3.4 drain semantics (R-3.4.1 in-flight tracking,
  R-3.4.2 drain timeout); v0.3 §M.2.2 enforceability rests on
  these rules.
- Live infrastructure — `coordinator.malibu.tech/healthz` +
  Pearl journald `model_hash_verified` events; v0.3 composes on
  this production observation surface.
- `specs/BUILD_SPEC_015_RECEIPTS_v0_3_MODELHASH_PROMPT.md` — the
  spec-writing brief that authored v0.3.
- `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md` — the
  staged implementation brief for the next session.
