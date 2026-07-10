# BUILD_SPEC_015 — Receipts v0.3: model-hash binding (write prompt)

**You are starting a fresh session in `/Users/augstar/macprovider-poc`. You have no memory of prior conversations. Read this prompt end-to-end before writing anything.**

Your job is to bump `specs/SPEC-015-receipts.md` from **v0.2.x (locked, issuance + verify CLI shipped)** to **v0.3** by extending the receipt tuple to bind **which model weights actually ran**, not just which model name was requested.

This work is downstream of SPEC-015 v0.1 (issuance, 7-field tuple) and v0.2 (verify CLI). Do NOT start until both are locked AND their IMPL has landed on `main`. Verify by checking the change-log entries for v0.1 and v0.2 at the top of `specs/SPEC-015-receipts.md` and confirming `phase3-binary/Sources/` (Swift provider, issuance) and `phase7-verify/` (pure-Go buyer CLI, verification) contain the corresponding code.

## Why this exists (read first)

SPEC-015 v0.1/v0.2 receipts bind: model **name**, prompt, output, provider pubkey, ttft, tokens, timestamp. They prove "a holder of provider X's key signed this tuple." They do **NOT** prove which weights the provider actually loaded into MLX when serving the response. A provider could advertise `qwen2.5-7b-instruct-mlx-4bit`, load `qwen2.5-7b-instruct-mlx-8bit` (or worse, a cheaper smaller model), and emit a receipt that verifies cleanly.

The infrastructure to close this gap **already exists in production**, just not bound into receipts:

- **SPEC-011 v0.5 LOCK-candidate** defines provider-reported `model_hash` on the heartbeat (`R-3.3.1`) — raw 64-char lowercase hex of the loaded MLX container
- **`scripts/sign-catalog.go`** produces ed25519-signed model catalogs mapping `model_id → expected_hash`
- **`phase4-coordinator/internal/tier2/catalog.go`** parses + verifies signed catalogs and emits `model_hash_verified` events
- **Production runs observation mode RIGHT NOW** — Pearl journald shows 342+ `model_hash_verified` events in the last 7 days, all `decision:"allow", reason:"hash_match"` for air5 against catalog `macprovider-tier2-model-catalog-2026-05-31`

The missing piece: the receipt tuple does not include `model_hash`, so a buyer-side verifier cannot use any of the above. v0.3 closes the loop by extending the receipt and the verify CLI.

The thesis-buyer (long-running personal agents, dev workflows, privacy-sensitive tooling per `README.md`) is the *only* macprovider differentiator that out-trusts hyperscaler APIs: those buyers can prove which weights ran. v0.1/v0.2 was the floor; v0.3 is the differentiating ceiling.

## Repo conventions you MUST honour

Same as v0.1/v0.2 — re-read `specs/BUILD_SPEC_015_RECEIPTS_v0_1_PROMPT.md` §"Repo conventions" if you haven't.

- Line 3 of `specs/SPEC-015-receipts.md` is the version of record. v0.3 means `**Version:** 0.3 (YYYY-MM-DD, ...)`.
- Append a new `**Change log v0.3:**` block at the top (newest first). State the wire-shape delta explicitly: "Receipt tuple extends from 7 fields to 8 by adding `model_hash` (string, base64-32-byte sha256 hex, optional under §M.3 conditions)."
- Bump `**Depends on:**` to add SPEC-011 vX.Y (whatever it locked at). v0.3 has a hard SPEC-011 dependency that v0.1/v0.2 did not.
- House voice: terse, normative, MUST/SHOULD/MAY per RFC 2119.

## What v0.3 MUST normatively add to SPEC-015

### §M (new) — Model-hash binding

The receipt tuple becomes 8 fields:

| Field | Type | Source |
|---|---|---|
| `model_id` | string | (unchanged from v0.1) |
| `prompt_hash` | sha256 hex | (unchanged) |
| `output_hash` | sha256 hex | (unchanged) |
| `provider_pubkey` | base64 ed25519 | (unchanged) |
| `ttft_ms` | int64 | (unchanged) |
| `tokens_out` | int64 | (unchanged) |
| `unix_ts` | int64 | (unchanged) |
| **`model_hash`** | string (64-char lowercase hex) or null | **NEW** — per SPEC-011 R-3.3.1; the hash the provider reported on its most recent heartbeat at the time of receipt generation |

Define exactly how the JCS canonical encoding handles the new field (most likely: appended at the end of the alphabetical field ordering or wherever JCS dictates — verify against `phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift` byte order).

### §M.1 — Wire compatibility statement

v0.3 receipts are **NOT** signature-compatible with v0.1/v0.2 verifiers. A v0.1 verifier given a v0.3 receipt MUST report `invalid` (the signature won't check the 7-field canonical encoding). State this normatively and define the upgrade path:

- v0.3 verifier MUST handle both v0.1/v0.2 (7-field) and v0.3 (8-field) receipts. Decision: by tuple shape (count fields) or by an explicit `receipt_version` field in the canonical encoding? **This is the most contentious v0.3 design choice — pick one and defend it.** Recommendation: explicit `receipt_version` field added in v0.3 (becomes the 9th field, with v0.1/v0.2 receipts treated as `receipt_version="1"` and v0.3 as `receipt_version="3"`). The cost (1 extra field) is small; the future-proofing payoff is large.

### §M.2 — `model_hash` provenance

The provider's `model_hash` value at receipt-generation time MUST match the hash advertised on its most recent successful heartbeat per SPEC-011 R-3.3. Define precisely what "most recent" means in three edge cases:

1. **Heartbeat lag:** if a warm-swap completed at T-100ms but no heartbeat has fired yet (next heartbeat at T+200ms), what hash does the receipt commit to? The pre-swap hash (last heartbeat reported value)? Or the post-swap hash (the in-memory container)? Recommendation: **post-swap** — the in-memory container at the moment the inference ran — because that's what the buyer ultimately consumed. Define and justify.

2. **Warm-swap mid-response:** if a swap happens during a streaming response (model A served tokens 1-50, model B served tokens 51-100), the receipt MUST commit to which hash served. v0.3 says: receipts MUST be one-model-per-response. If a swap is in progress at receipt-time, provider MUST emit the receipt with the hash of the model that **started** generation, and an audit event MUST log the mid-stream swap (operator visibility). Streaming-receipt design (deferred to v0.4) may revisit this.

3. **Absent hash (SPEC-011 §3.3.2 allows it):** if the provider is running with `--enable-warm-swap=false` (the SPEC-011 default), it does NOT emit `model_hash` on heartbeats. In this mode, receipts MUST emit `model_hash: null`. A v0.3 verifier MUST treat a null `model_hash` as **inconclusive for hash-verification**, but still report `valid` if signature + canonicalization check. State the trust-statement consequence explicitly: a v0.3 receipt with `null` model_hash binds everything v0.1/v0.2 bound, PLUS the assertion "this provider did not participate in hash attestation."

### §M.3 — Catalog-based verification (verify CLI extension)

The verify CLI gains a new check: when the receipt has a non-null `model_hash`, the verifier compares against a **signed model catalog**. v0.3 §M.3 normative additions:

- New `--catalog <path>` flag accepts a signed catalog file (the output of `scripts/sign-catalog.go`)
- New `--catalog-pubkey <base64>` flag accepts the catalog's ed25519 verifying key (or `--catalog-pubkey-url <url>` to fetch from coordinator)
- If catalog is provided: verifier MUST verify catalog signature, find the entry for `receipt.model_id`, and check `receipt.model_hash == catalog[model_id].sha256` (the catalog's per-model SHA field is named `sha256` per the existing schema in `scripts/sign-catalog.go:31` and `phase4-coordinator/internal/tier2/catalog.go:35` — do NOT invent a different field name)
- If hash matches: existing `valid` result includes `model_hash_verified: true` in JSON output
- If hash mismatches: result becomes `invalid` with reason `model_hash_mismatch` — even if signature was fine
- If model_id is absent from the catalog: result becomes `inconclusive` with reason `model_id_not_in_catalog` — verifier MUST NOT report `valid` (a model the operator hasn't published a hash for is a model whose integrity cannot be asserted)
- If catalog itself fails signature verification: result is `invalid` with reason `catalog_signature_invalid`

The trust-boundary statement (v0.2 §V.5) MUST be updated: v0.3 `valid` now means "signature checked AND (if model_hash present AND catalog provided) the loaded weights match the catalog's expected hash for the requested model."

### §M.4 — Coordinator surface (`/poolz` extension)

The coordinator's `/poolz` response MUST gain two optional fields per SPEC-002 (whichever locks first — this becomes a Step 0 absorption candidate for the v0.3 IMPL prompt):

- `catalog_id` (string) — identifier of the catalog the coordinator is currently observing against
- `catalog_pubkey_url` (string) — URL where the verifier can fetch the catalog's public key (suggest `/catalog/pubkey`)
- `catalog_url` (string) — URL to fetch the catalog itself (suggest `/catalog/<catalog_id>`)

These allow a verify CLI to do `macprovider-verify --bundle X --catalog-url https://coordinator.streamvc.live/catalog/macprovider-tier2-model-catalog-2026-05-31 --catalog-pubkey-url https://coordinator.streamvc.live/catalog/pubkey` with the verifier pulling everything it needs in two requests.

### §M.5 — Acceptance criteria (extend numbering from v0.2)

Add ACs for:
- `valid` path with v0.3 receipt + matching catalog
- `invalid` path with v0.3 receipt + tampered `model_hash`
- `invalid` path with v0.3 receipt + model swapped to a different SHA mid-response (must be impossible by §M.2.2 — test that the provider's emission code refuses to issue a receipt that spans a swap)
- `inconclusive` path with v0.3 receipt + null `model_hash` (warm-swap-disabled provider)
- `inconclusive` path with v0.3 receipt + `model_id` not in catalog
- `invalid` path with catalog whose own signature is bad
- Backward-compat path: v0.3 verifier receives v0.1/v0.2 receipt + reports `valid` without catalog check
- Forward-compat path: v0.1/v0.2 verifier receives v0.3 receipt + reports `invalid` (expected — signature won't check)
- `/poolz` exposes `catalog_id`, `catalog_pubkey_url`, `catalog_url` when coordinator has a catalog loaded
- `/poolz` omits the catalog fields when coordinator has no catalog (config absent)
- Cache-TTL for catalog files on the verifier side (define and test)

Each AC MUST cite a concrete test command an implementer can run.

## What v0.3 MUST explicitly defer (do not creep)

- **Flipping `tier2.require_hash_verified` enforcement on at the coordinator.** This is an operator-side decision per `beta/DECISION_CRITERIA.md` Entry 80 (deferred until the pool grows past 2-3 Macs, catalog pipeline is ergonomic, OR a buyer asks). v0.3 makes the receipt bind hash; whether the coordinator REJECTS providers on hash mismatch is independent. State this explicitly in §M.5.
- **Mid-response model swaps producing a single multi-hash receipt** (i.e., a receipt that binds two `model_hash` values for one response, one pre-swap and one post-swap). v0.3 §M.2.2 normatively REFUSES this — the provider's emission code MUST decline to issue a receipt spanning a swap. What is deferred is the *future feature* of representing such swaps in a single receipt; that, plus full streaming-receipt design, is v0.4+ territory. Be precise: v0.3 forbids the situation, v0.4+ may model it.
- **Cross-catalog federation** (multiple coordinators with different signed catalogs, or third-party catalogs). v0.3 is single-catalog-per-coordinator.
- **On-chain anchoring of catalog Merkle roots.** Gated on the Cluster D-tokens go/no-go decision; orthogonal to v0.3.
- **Quantization-aware verification** (e.g., "this is the 4-bit version of qwen2.5-7b, accept matching either of these two hashes"). v0.3 is one-model-id-one-hash. Operator publishes a separate `model_id` per quantization.
- **HuggingFace-style "soft" model identity** (model card metadata, training-run provenance, dataset provenance). Defer indefinitely; receipts bind weights, not lineage.

## Files you should read before writing

- `specs/SPEC-015-receipts.md` v0.2.x (LOCKED) — the contract you're extending
- `specs/SPEC-011-operator-pushed-warm-swap.md` v0.5+ (whatever locked) — particularly §3.3 (heartbeat fields), §3.4, §3.8 (model_hash semantics + warm-swap lifecycle)
- `specs/SPEC-010-model-catalog.md` v1.5 (line 3 is the version of record — confirm before citing in §M) — for the `supported_models[]` + `publishes_supported_models` context that determines whether a provider participates in hash attestation
- `specs/SPEC-008-tier2.md` v0.3+ — particularly §5 (Pillar A) for the existing hash-verification semantics the receipts work composes on
- `specs/SPEC-001-phase3-binary.md` (whatever its locked version is post-v0.1 IMPL) — for the auth frame / heartbeat shape
- `specs/SPEC-002-coordinator.md` (whatever its locked version is post-v0.1 IMPL) — for the `/poolz` surface that gains `catalog_*` fields in Step 0 of the v0.3 IMPL
- `scripts/sign-catalog.go` — the existing catalog signing tool; the verifier must accept what this produces
- `phase4-coordinator/internal/tier2/catalog.go` — the existing catalog parser/verifier; the verify CLI can either copy-paste or re-implement (pure-Go discipline from v0.2 says reimplement)
- `phase4-coordinator/internal/config/config.go:142,335` — current state of `RequireHashVerified` flag (default false, observation mode); v0.3 does NOT change this
- `beta/DECISION_CRITERIA.md` Entry 80 — the deferral context for enforcement flag; v0.3 must respect it
- The v0.1/v0.2 audit transcripts — `specs/SPEC-015-audit.md` (SPEC-level audit history) and `specs/SPEC-015-IMPL-STEP_N-audit.md` (per-IMPL-step transcripts). The `specs/AUDIT_SPEC_015_*_PROMPT.md` files are audit INPUT prompts, not transcripts — read both. Knowing what got deferred from v0.1/v0.2 surfaces likely v0.3 audit hotspots
- **Pearl journald (live evidence):** `ssh -i ~/.ssh/pearl_operator_ed25519 root@159.223.165.194 'journalctl -u macprovider-coordinator --since "24h" --no-pager | grep model_hash_verified | head -3'` — confirms observation mode is live; cite this in §M as proof of catalog infrastructure readiness

## Audit-loop discipline (NON-NEGOTIABLE)

Per `~/.claude/projects/-Users-augstar-macprovider-poc/memory/feedback-spec-audit-loop-before-pr.md`:

> Freshly-written SPECs go through codex audit → fix → re-audit → loop until 0 CRITICAL/MAJOR BEFORE push/PR.

Workflow:

1. On a fresh branch off `origin/main`, name suggestion `spec/015-receipts-v0-3`, edit `specs/SPEC-015-receipts.md` to bump to v0.3 with §M appended. Do NOT push yet.
2. Author `specs/AUDIT_SPEC_015_V0_3_PROMPT.md` — an audit prompt asking codex to find CRITICAL/MAJOR/MINOR findings against the v0.3 deltas only. v0.1/v0.2 are locked; do not invite re-audit of them.
3. Run the audit. Apply fixes. Bump to v0.3.1 / v0.3.2 per findings. Re-audit.
4. Loop until **0 CRITICAL, 0 MAJOR**. Each MINOR fixed or acknowledged with `deferred-to-vX` tag.
5. Push and open PR.

Expect 3-5 audit rounds. v0.3 has more contention than v0.2 because it actually changes the wire shape. The audit will hammer on:

- **The receipt_version field decision.** Either you add it (and justify the cost) or you don't (and justify how upgrades work). There's no neutral answer.
- **The `model_hash: null` semantics.** Is it `inconclusive for hash` or is it `invalid because the provider didn't participate`? The latter is harsher and might reject every provider running default `--enable-warm-swap=false`. The former is softer but lets opt-out providers slide.
- **The §M.2.2 mid-swap forbiddance.** Is "provider's emission code must refuse to issue a receipt that spans a swap" enforceable, or does it require new SPEC-011 normative additions? If the latter, v0.3 has a SPEC-011 amendment as a sub-task.
- **The catalog-trust root.** v0.2 §V.1 left `/poolz` as operator-mutable trust root with a "TUF later" note. v0.3 extends the same trust root to the catalog. Does v0.3 promote the TUF question to a v0.4 must-have, or stay at "operator-mutable, accept the limitation"?
- **The forward-compat statement.** v0.1/v0.2 verifiers reporting v0.3 receipts as `invalid` is technically correct but operationally bad — users with old CLIs will think their receipts are forged. Should the wire encoding include a marker that lets old verifiers report `inconclusive: unknown_receipt_version` instead? This is where `receipt_version` earns its keep.

## Implementation BUILD prompt (separate, after SPEC v0.3 locks)

After SPEC-015 v0.3 is LOCKED and merged:

1. Write `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md` — step-by-step implementation prompt. Structure should mirror `specs/BUILD_SPEC_015_IMPL_PROMPT.md` (the v0.1 IMPL, ~12 steps). v0.3 is smaller — expect ~5-7 steps:
   - Step 0: Spec absorptions (SPEC-001, SPEC-002 for `/poolz` extension, SPEC-011 if §M.2.2 needs a normative amendment)
   - Step 1: JCS canonicalizer extension for the new field
   - Step 2: Receipt construction extension (Swift) — read current `model_hash` from heartbeat state at receipt-generation time
   - Step 3: Wire emission unchanged (still `X-MacProvider-Receipt`, longer payload)
   - Step 4: `/poolz` catalog field exposure (Go)
   - Step 5: Verify CLI extension (Go) — `--catalog`, `--catalog-pubkey`, `--catalog-url` flags + new result codes
   - Step 6: Test fixtures + integration acceptance
2. Implementation follows the BUILD audit-loop pattern per `~/.claude/projects/-Users-augstar-macprovider-poc/memory/feedback-build-audit-loop.md`.
3. Implementation MUST NOT begin until v0.3 SPEC is locked. The SPEC is the contract; the BUILD is the code that fulfils it.

## Quality bar

A great v0.3 reads like SPEC-011's own LOCK candidate: every normative rule has a citation (file:line, RFC, other SPEC §), every edge case has a worked example, and the trust-boundary update in §M.3 is uncompromising about what `valid` does and doesn't mean now.

A bad v0.3 hand-waves the `receipt_version` decision, lets `model_hash: null` quietly become a free pass, or makes §M.2.2 a "best effort" rather than a normative refusal. The audit loop will catch this; better if you catch it yourself first.

## Final deliverables when you're done

1. `specs/SPEC-015-receipts.md` at v0.3.x that passed the audit loop with 0 CRITICAL/MAJOR
2. `specs/AUDIT_SPEC_015_V0_3_PROMPT.md` plus the audit transcript
3. A pushed branch and an open PR linking the SPEC delta, the audit prompt, audit results
4. An appended entry to `beta/DECISION_CRITERIA.md` noting SPEC-015 v0.3 LOCKED, what landed, deferred items, audit-round count, and explicit reference to Entry 80's `RequireHashVerified` deferral (so the next reader knows v0.3 receipts bind hash but the coordinator-side enforcement decision is unchanged)
5. `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md` queued up for the implementation session that follows
6. NO implementation code in this session — v0.3 is normative spec only

**You're not done when the spec exists. You're done when the audit loop closes, the PR is open, and the IMPL prompt is staged for the next session.**
