# AUDIT_SPEC_015_v0_3_IMPL_BUNDLE_PROMPT

**Target:** the full SPEC-015 v0.3 IMPL bundle on branch `impl/spec-015-v0-3`
(PR #131, head `26eeda9`), six step commits stacked on the v0.3.3 LOCKED SPEC
commit `af53cb1`.

**Base for diff:** `spec/015-receipts-v0-3` (the v0.3.3 LOCKED SPEC tip).
The six IMPL commits in scope:

```
bdaeb9f Step 1: Swift provider 9-field receipt tuple
3b86522 Step 2: coordinator /poolz catalog fields + 2 endpoints
a22e3c8 Step 3: nginx /catalog/ routes + Pearl deploy gate
5b5f401 Step 4: pure-Go verifier catalog parser + cache
f92f7f5 Step 5: verifier CLI + 9-field algorithm + v0.3 schema
26eeda9 Step 6: integration acceptance + cross-binary parity
```

**Normative anchors:**

- `specs/SPEC-015-receipts.md` (v0.3.3 LOCKED at `specs/SPEC-015-receipts.md:3`).
  Sections that MUST be enforced end-to-end: §M.0 (9-field tuple), §M.1.1
  (back-compat), §M.1.2 (forward-incompat), §M.1.4 (unknown receipt_version),
  §M.1.5 (JCS canonical order), §M.2.1 (request-start container provenance),
  §M.2.2 (mid-swap defence-in-depth), §M.2.3 (null-hash semantics), §M.3.1
  (CLI flag matrix), §M.3.1.1 (mutual-exclusion), §M.3.1.2
  (--require-model-hash), §M.3.2 (8-step verifier algorithm), §M.3.2.1
  (tri-state schema), §M.3.4 (three-band TTL cache), §M.4 (/poolz + 2
  endpoints), §M.5 (AC-28..AC-42 + AC-32a), §M.6 (deferred to v0.4+).
- `specs/SPEC-002-coordinator.md` (v1.6 candidate /poolz extension).
- `beta/DECISION_CRITERIA.md` Entry 80 (2026-06-22): `RequireHashVerified`
  deferral — MUST be preserved verbatim by this IMPL bundle.

**Independent steps already passed locally:** each of the six step transcripts
at `specs/SPEC-015-v0-3-IMPL-STEP_{1..6}-audit.md` ended at 0/0/0/0 across all
3 lenses. This bundle audit is the cross-step / system-level pass — DO NOT
re-audit individual step concerns the step transcripts already closed unless
you find a NEW cross-step bug.

## Output discipline (applies to every lens, every round)

Append your section to `specs/SPEC-015-v0-3-IMPL-BUNDLE-audit.md` with a header
of the form `## Lens — CODE — Round N` (or SECURITY / ARCHITECT). End every
lens with two literal lines:

```
VERDICT: <PASS|FAIL> — <one-line rationale>

COUNTS: CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n>
```

Findings format inside each lens section:

```
### <SEVERITY>-<ROUND>-<KIND>-<INDEX> <short-title>

<file>:<line> — <claim with file:line evidence; quote ≤3 lines if needed>
Why it matters: <one-sentence consequence>
Suggested fix: <one-sentence remediation>
```

Sort findings within a section: CRITICAL → HIGH → MEDIUM → LOW.

Severities (use these exactly):
- **CRITICAL**: corrupts receipts on the wire, drops bytes the SPEC requires,
  flips an Entry-80-preserved invariant, lets an attacker forge a valid v0.3
  receipt against the verifier's stated checks, or breaks §M.1.2 forward-
  incompat such that a locked v0.2 verifier would silently accept v0.3.
- **HIGH**: violates a §M.* normative MUST, leaks a money-path invariant,
  introduces an unbounded resource (memory, fd, goroutine, rate-limit
  bypass), or makes a deploy gate false-pass on a real broken config.
- **MEDIUM**: breaks a §M.* SHOULD, weakens a test such that a future
  regression slips through, or leaves a deferred-to-v0.4+ semantic ambiguous
  enough that an operator could misconfigure it.
- **LOW**: style, doc drift, minor schema redundancy, naming, deferrable
  follow-up.

Target: **0 CRITICAL + 0 HIGH + 0 MEDIUM** across all 3 lenses. LOW
findings are deferrable to a v0.4 cleanup.

## Lens — CODE

You are the **CODE** auditor. Read every changed file in the six commits above.
Compose against the SPEC text, not your generic instincts.

Focus areas (in priority order):

1. **§M.0 tuple wire shape, end-to-end parity.** The 9-field JCS-canonical
   tuple emitted by `phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift`
   MUST byte-match what the verifier in `phase7-verify/internal/receipt/`
   reconstructs for the signature check. Sample at least one non-null-hash
   and one null-hash case. Verify both binaries agree on the UTF-16-codeunit
   field-sort order (§M.1.5) and on JSON literal `null` for the missing
   `model_hash` (§M.2.3).
2. **§M.2.1 / §M.2.2 / §M.2.3 race + defence semantics.** Trace the
   producer side: who sampled the `RuntimeSnapshot` whose hash is bound to
   the receipt, and is that sample atomic with respect to the generation
   it certifies? `ModelRuntimeServing.completeWithServedSnapshot` is the
   gating call — confirm every receipt-emit path now flows through it.
   `.warmSwapDisabled` MUST emit JSON `null` (not the absent field).
   `.ambiguous` MUST emit `receipt_omitted: model_swap_violation` audit
   row and NO header. Look for any path that still calls
   `currentSnapshot()` outside the runtime actor and bypasses the
   atomic-read.
3. **§M.1.2 forward-incompat (AC-38).** The cross-binary parity test at
   `phase7-verify/internal/receipt/v02_parity_test.go` re-implements the
   v0.2.4 LOCKED parser inline. Verify the inline behaviour exactly
   matches the v0.2.4 LOCKED parser at commit `99d0c1e` on `main`. Check
   `git show 99d0c1e:phase7-verify/internal/receipt/receipt.go` to confirm.
   Any drift here masks the forward-incompat invariant.
4. **§M.1.4 unknown receipt_version dispatch order.** In the live parser
   at `phase7-verify/internal/receipt/receipt.go`, the unknown-version
   detection MUST happen BEFORE the strict v0.3 9-key shape validation.
   Otherwise an unknown-version receipt would fail with `extra_field` or
   `missing_field` instead of the correct `inconclusive: unknown_receipt_version`.
   Trace the parser entry and confirm the parse order.
5. **§M.3.2 8-step algorithm fidelity.** Read
   `phase7-verify/internal/verify/catalog_check.go`. Each of steps 1..8
   in §M.3.2 MUST be present and correctly ordered. Step 4 (catalog
   cache) MUST compose with step 5 (catalog signature verify) such that
   a cache-hit still produces `signature_verified=true` in the result.
   Step 7 (model_id lookup) MUST use the case-folded `catalogModelKey`.
6. **§M.3.4 three-band TTL.** Read
   `phase7-verify/internal/cache/catalog/catalog_cache.go`. The three
   bands (R > 6h → 6h; R ∈ [60s, 6h] → R - 60s; R < 60s → no cache)
   MUST be enforced at write time, not just documented. Test
   coverage MUST exercise each band.
7. **§M.4 coordinator surface.** Read
   `phase4-coordinator/internal/ws/server.go` (`handlePoolz`) and
   `phase4-coordinator/internal/buyer/server.go` (`handleCatalogFile`,
   `handleCatalogPubkey`). The new top-level /poolz fields MUST only
   emit when `tier2.Active()` is true AND `CatalogPath` is configured
   AND the catalog loaded AND the signature verified. The endpoint
   handlers MUST be public (no Authorization required), rate-limited
   via the receipt-keys bucket, and the catalog pubkey response MUST
   serialize with `alg: "Ed25519"` (capital E) matching
   `scripts/sign-catalog.go`.
8. **Deploy gate scoping.** Read
   `phase4-coordinator/dist/test/check_nginx_catalog_routes_test.sh`.
   The `proxy_pass` assertion MUST be scoped to the `/catalog/` block
   only (awk-based block extraction). A regression that changes the
   proxy to operator port 8444 MUST be caught. Run the gate against a
   crafted broken conf to confirm.
9. **Manifest test invariants.** Read
   `test/integration/spec015/v03_acceptance_manifest_test.go`. The
   ≥2-evidence-anchor assertion MUST fire on a single-anchor entry.
   AC-32a (defence-in-depth) MUST have its own entry, not be folded
   into AC-32. Subtests MUST run for every AC.

Produce at least one CRITICAL/HIGH/MEDIUM finding if any exists. If you
cannot find one, write "No <SEVERITY> findings." literally — do NOT
invent findings to fill the bucket.

## Lens — SECURITY

You are the **SECURITY** auditor. Threat model:

- **Forge a valid v0.3 receipt** against a buyer-side verifier with no
  catalog configured. (Should be impossible — non-null model_hash with
  no catalog → `inconclusive` warning, NOT `valid`.)
- **Forge a valid v0.3 receipt** against a buyer with `--catalog-url`
  configured. (Should require Ed25519-signed catalog from the matching
  operator pubkey.)
- **Pearl operator key disclosure.** The runbook + deploy script MUST
  treat the operator key as a secret, never log it, never embed in URLs.
- **Catalog public-key trust root.** The CLI flag matrix MUST enforce
  that `--catalog-pubkey` and `--catalog-pubkey-url` cannot both be set,
  and that file-mode catalog use without an explicit pubkey requires
  the catalog signature alg to match the embedded pubkey.
- **Mid-swap container substitution.** A provider that disabled warm-
  swap mid-request, OR loaded a new container mid-request, MUST NOT
  emit a non-null model_hash for the OLD container — the §M.2.1 atomic
  snapshot semantics block this. Confirm the runtime-actor sample
  cannot be raced.
- **Catalog endpoint amplification.** `/catalog/<id>` and
  `/catalog/pubkey` are public + rate-limited; verify a single buyer
  cannot exhaust the rate-limit bucket of another buyer (per-IP or
  per-bucket?). Verify that an attacker cannot trigger a coordinator
  full-disk-read via path traversal in `<catalog_id>`.
- **Schema-level confusion attacks.** The CLI JSON output schema
  enforces `model_hash_verified` tri-state on every variant. A
  malicious verifier-fork could emit `model_hash_verified: "anything"`
  and pass a downstream consumer's `JSON.parse(out).model_hash_verified
  === true` check. The schema MUST reject any value not in
  {true, false, null}.
- **Deploy gate bypass.** The new `check_nginx_catalog_routes_test.sh`
  gate runs BEFORE SSH/DNS phase. Verify the deploy script cannot be
  invoked with a `SKIP_*=1` env flag that silently bypasses just this
  gate. Verify that a stale local nginx conf cannot still ship if the
  user `cp`s the previous-version conf into place.

Focus areas (in priority order):

1. **Operator-key handling end-to-end.** Grep the runbook + deploy
   script for any path that prints or logs the operator key. Confirm
   the smoke-check commands use `$OP` not the literal key.
2. **CLI flag matrix mutual-exclusion (§M.3.1.1).** Read
   `phase7-verify/internal/cli/cli.go`. Confirm: (a) `--catalog` and
   `--catalog-url` are mutually exclusive; (b) `--catalog-pubkey` and
   `--catalog-pubkey-url` are mutually exclusive; (c) `--offline` and
   any `--catalog-*-url` flag is rejected; (d) `--require-model-hash`
   without any catalog source is rejected with a clear error.
3. **Catalog signature verification.** Read
   `phase7-verify/internal/catalog/catalog.go`. Confirm: signature
   alg literal is checked as `"Ed25519"` (capital E) ONLY, no
   case-insensitive accept; signature byte-decode uses
   `base64.RawURLEncoding` and rejects padded; pubkey byte-decode
   matches; `ed25519.Verify` returning `false` produces
   `ErrSignatureInvalid` with `ObservedAlg` stamped.
4. **Cache poisoning + atomic-write.** Read
   `phase7-verify/internal/cache/catalog/catalog_cache.go`. Confirm:
   writes use temp-file + atomic-rename + 0600 perms; expired entries
   are rejected on read; pubkey rotation invalidates (stale cache for
   one pubkey MUST not satisfy a request for another).
5. **Rate-limit bucket reuse.** Read
   `phase4-coordinator/internal/buyer/server.go`. Confirm the new
   catalog endpoints share the receipt-keys rate-limit bucket and
   the bucket is keyed in a way that prevents one buyer from
   starving another. Path traversal: confirm `<catalog_id>` is
   validated against a whitelist (or sanitized) before any
   filesystem read.
6. **Schema enforcement on tri-state.** Read
   `phase7-verify/schemas/output.schema.json`. Confirm
   `model_hash_verified` is REQUIRED on every variant + the JSON
   Schema type enumerates exactly `[boolean, null]` (or equivalent).
   Confirm a schemavalidator run rejects `"anything"`,
   `"yes"`, `1`, `[]`.
7. **Entry 80 invariant preservation.** Grep
   `phase4-coordinator/internal/config/config.go` and any tier2
   config-load path. Confirm `RequireHashVerified` defaults to
   `false` and no IMPL commit flips that default. Cross-reference
   `beta/DECISION_CRITERIA.md:374`.
8. **Deploy-script `SKIP_*` flags.** Read
   `phase4-coordinator/dist/deploy-pearl-vps.sh`. Confirm the new
   step 0 gate cannot be skipped via `SKIP_NGINX_CHECK=1` or
   similar.
9. **Cross-binary forward-incompat.** §M.1.2 SECURITY angle: a v0.2.4
   verifier MUST NOT silently accept a v0.3 receipt. Confirm the
   `parseTupleV02Locked` mirror is faithful to the locked release and
   the assertions in `TestV02LockedParserRejectsV03Receipts` cover
   both null and non-null v0.3 receipts.

## Lens — ARCHITECT

You are the **ARCHITECT** auditor. Focus on system-level invariants and
contracts that span multiple components.

Focus areas (in priority order):

1. **End-to-end /poolz → /catalog → verifier flow.** A buyer with no
   prior knowledge of the operator's catalog learns it via /poolz,
   fetches the catalog file from /catalog/<id>, fetches the pubkey
   from /catalog/pubkey, and verifies the receipt locally. Trace the
   four hops:
     - Provider emits `model_hash` bound to served snapshot (§M.2.1)
     - Coordinator advertises `catalog_id`, `catalog_url`,
       `catalog_pubkey_url` on /poolz (§M.4)
     - Coordinator serves the file + pubkey on the two endpoints (§M.4)
     - Verifier fetches both, verifies signature, looks up model_id,
       compares hash (§M.3.2)
   Confirm every hop is wired in this IMPL bundle, error paths exist,
   and the contract names are stable across binaries.
2. **§M.1.2 forward-incompat + provider/verifier rollout ordering.**
   The runbook tells the operator to release the verifier BEFORE the
   provider. Confirm the system can survive an out-of-order rollout
   without silent acceptance of forged receipts. Confirm the SPEC says
   what the operator runbook claims about §M.1.2.
3. **Entry 80 preservation across the bundle.** v0.3 makes the
   receipt BIND the hash; the coordinator's `RequireHashVerified` is
   independent. Confirm no commit in the bundle accidentally
   couples these. Confirm the operator runbook's "Entry 80 invariant"
   section reflects this.
4. **§M.6 deferred-to-v0.4+ scope discipline.** §M.6 lists 6 items
   deferred (streaming receipts, multi-hash receipts, cross-catalog
   federation, on-chain anchoring, quantization-aware, TUF). Confirm
   no IMPL commit implements any of these. Confirm the runbook lists
   the same six and no others.
5. **Tagged-union architecture for receipt-version dispatch.** The
   live parser at `phase7-verify/internal/receipt/receipt.go` MUST
   detect version BEFORE strict shape validation, return a Tuple stub
   carrying ReceiptVersion only for unknown versions, and let the
   verify layer short-circuit to `inconclusive: unknown_receipt_version`.
   This is the architecture round-2 CRIT fix from Step 5 — confirm it
   survived through Step 6 unmodified.
6. **AC manifest as living contract.** Each AC entry's evidence
   anchors point at a file + grep pattern that MUST exist. The
   manifest test asserts every named pattern exists in the named
   file. Confirm the ≥2-anchor invariant + the per-AC pattern check
   actually fire (run the test and inspect output).
7. **Cross-step coupling.** Are there any places where two of the six
   step commits touch the same file with subtly different assumptions?
   Common offenders:
     - Step 4 vs Step 5: catalog parser vs verifier integration
     - Step 1 vs Step 6: receipt tuple emission vs cross-binary parity
       test
     - Step 2 vs Step 3: coordinator endpoints vs nginx routes
   Trace each cross-step boundary and confirm the contract names line
   up (field names, error envelopes, status codes).
8. **Runbook composability with deploy script.** The runbook claims
   the deploy script writes to `/opt/macprovider/coordinator.prev`.
   Confirm by reading
   `phase4-coordinator/dist/deploy-pearl-vps.sh`. Confirm the rollback
   path the runbook gives composes cleanly with whatever state the
   deploy script leaves on Pearl.
9. **Operator runbook drift risk.** The runbook references file paths,
   env vars, journald event names, smoke-check URLs. Grep each
   reference against the actual code on this branch. Any drift = HIGH
   (operator follows stale instruction during an incident).

## Process

For each lens:

1. Read every file the lens names in your focus areas.
2. For findings, cite `<file>:<line>` and quote ≤3 lines.
3. Note what you DID confirm working (one paragraph at most).
4. Run any test or gate you reference as evidence; quote the result.
5. End with VERDICT + COUNTS.

When ALL three lenses return 0 CRITICAL + 0 HIGH + 0 MEDIUM, the bundle
is READY TO LOCK. Until then, the response invokes a fix round on the
maintainer side, who will re-fire this prompt with a Round N+1 header.
