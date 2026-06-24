# IMPL audit prompt — SPEC-015 v0.3 IMPL Step 1 (Swift provider 9-field receipt)

You are auditing the Step 1 implementation of SPEC-015 v0.3 model-hash binding
in `phase3-binary/` (Swift provider). The controlling spec is
`specs/SPEC-015-receipts.md` v0.3.3 LOCKED (line 3). The build prompt is
`specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md` Step 1.

Output: APPEND a section to
`specs/SPEC-015-v0-3-IMPL-STEP_1-audit.md` for your lens. If the file does
not exist, create it. Use section headers
"## Lens — CODE — Round R", "## Lens — SECURITY — Round R",
"## Lens — ARCHITECT — Round R" so the operator can run three independent
lenses and aggregate.

You are running ONE lens per invocation. The operator tells you which lens
in the `--agent-prompt` argument or this prompt's opening sentence. Default
to **CODE** if unspecified.

End your section with one of:

  VERDICT: READY TO PROCEED | READY WITH FIX PASS | DESIGN ROUND NEEDED

  COUNTS: CRITICAL=N HIGH=N MEDIUM=N LOW=N

User policy: loop until **0 CRITICAL + 0 HIGH + 0 MEDIUM** for this step
before proceeding to Step 2. LOW findings can be deferred.

## Severity definitions

- **CRITICAL** — would cause: receipt-signature divergence; v0.3 receipts
  failing to verify against a correctly-written v0.3 verifier;
  back-compat break for v0.1/v0.2 receivers; `model_hash` reading from
  the wrong source (e.g. post-swap state at receipt-emission time rather
  than request-start container); locked-spec line-3 version changes;
  byte-shape mismatch with the §M.0 JCS canonical order; null-encoding
  divergence from RFC 8785 §3.2.2.2.

- **HIGH** — would cause: AC-28..AC-42 failure on a deterministic test;
  validation gaps (`model_hash` accepted in wrong format, e.g. uppercase
  hex, prefixed `sha256:`, wrong length); receipt-emission paths missing
  the `model_hash` argument (e.g. error-receipt path emits with stale
  hash); thread-safety / async ordering issues that could let a swap
  observe a stale snapshot; missing tests for §M.0 strict 9-key shape.

- **MEDIUM** — would cause: predictable bug in first month
  (e.g. comment claims one thing, code does another); under-specified
  edge cases not tested; code style / patterns that diverge from
  existing house style; minor inconsistencies in the `model_hash`
  validation (e.g. test corpus missing UTF-16 ASCII trap input);
  documentation gaps that would mislead next implementer.

- **LOW** — quality polish; deferrable to v0.3.x+1.

## Critical constraints to honor

1. **SPEC-015 v0.3.3 is LOCKED.** Any change required to the SPEC text
   is a CRITICAL finding ("Step 1 silently demands SPEC amendment").
2. **`phase3-binary` is the provider runtime.** Step 1 is the only step
   that touches Swift. Coordinator + verifier work is Steps 2-5.
3. **No locked-spec line-3 version shifts** in SPEC-001 / 002 / 005 /
   006 / 008 / 010 / 011 / 013 — verify by
   `git diff HEAD~ -- 'specs/SPEC-{001,002,005,006,008,010,011,013}-*.md'`.
4. **RFC8785JCS.swift MUST NOT be amended** per SPEC-015 §M.1.5 — the
   existing emitter handles the 9-field tuple, including JSON `null`
   for `model_hash`, without changes.
5. **The receipt-issuance contract is byte-identical to v0.1/v0.2 EXCEPT
   for the §M.0 9-field tuple shape.** The header envelope
   (`<base64(JCS(T))>.<base64(SIG)>`), the signature step, and the
   `X-MacProvider-Receipt` header name are UNCHANGED.

## Required reading (in order)

1. `specs/SPEC-015-receipts.md` v0.3.3 — particularly §M.0 (9-field
   tuple), §M.1.5 (no JCS amendment), §M.2.1 (request-start
   provenance), §M.2.2 (mid-swap construction proof), §M.2.3
   (null-hash semantics), §7.6 (error-receipt hash inheritance), §3.4
   v0.3 wire-size envelope, §M.5 AC-28..AC-31 (Step 1-bound ACs).

2. `phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift` — the
   v0.3 9-field tuple constructor.

3. `phase3-binary/Sources/macprovider-cli/HTTPServer.swift` — the
   receipt-emission path (success + error + parse-error). Particularly:
   the `Task.detached` block in `handleChatCompletions`; the
   `receiptHeaderResult` / `errorReceiptHeaderResult` static helpers;
   how `requestStartSnapshot` is threaded.

4. `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift` — the
   coordinator-WS-mediated receipt path. Particularly:
   `buildReceiptHeader` and `processNonStreaming`.

5. `phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift` — verify
   that no amendment is required (the existing `Value.null` and
   `Value.string` cases already handle the new fields).

6. `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` —
   particularly the `RuntimeSnapshot` struct and `currentSnapshot()`.
   Verify that the snapshot captured by Step 1 IS the request-start
   container per SPEC-011 §3.2 + R-3.4.1.

7. `phase3-binary/Tests/macprovider-cliTests/ReceiptBuilderTests.swift`
   — the v0.3 9-field tuple tests, parity test, null encoding, hash
   validation, wire-size budget.

8. `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md` Step 1 — the
   build directive list. Diff against the implementation; missing
   items = MAJOR finding.

## Lens-specific categories

### CODE lens — implementation correctness

C.1 **Tuple shape (§M.0).** Verify the v0.3 tuple has exactly 9 keys.
    Verify the dictionary literal in `ReceiptBuilder.tupleObject` lists
    all 9 in any order (JCS sorts before emission), and verify there's
    a test that asserts the emitted byte order is the §M.0 alphabetical
    UTF-16 order.

C.2 **`model_hash` validation.** Verify `isValidModelHash` rejects
    every non-conforming input from §M.0 (uppercase hex, prefix,
    wrong length, non-hex chars). Verify `nil` maps to `RFC8785JCS.Value.null`.

C.3 **Snapshot threading.** Verify `requestStartSnapshot` is captured
    BEFORE any state-mutating operation (e.g. `modelRuntime.complete`).
    Verify it is threaded through every receipt-emission path
    (success, model_not_loaded error, parse error). Verify the
    `requestStartSnapshot.modelHash` is the value that lands in the
    receipt, NOT a fresh snapshot at receipt-emission time.

C.4 **Error-receipt inheritance (§7.6 + §M.2).** Verify
    `errorReceiptHeaderResult` accepts `modelHash` and passes it to
    `receiptHeaderResult`. Verify all callers (success-path,
    apiError-catch, generic-catch, parse-error path) pass the right
    source for `model_hash`.

C.5 **Compatibility with legacy InferenceRelay test surface.**
    `processNonStreaming` adds a `requestStartSnapshot` capture; verify
    this composes with `acquireRequestHandle` / preflight semantics in
    the relay's tier-2 + non-tier-2 paths.

C.6 **Wire-size envelope (§3.4 v0.3).** Verify the new tests project
    the receipt size budget per §3.4 (≤ ~1025 bytes header value).

C.7 **House-style consistency.** Verify Swift property and method
    naming, comments, error enum cases match neighbouring code style.
    Particularly check `ReceiptBuilder.Error.invalidModelHash` is in
    the same place as the existing cases.

### SECURITY lens — cryptographic claims, threat model, attestation honesty

S.1 **§M.0 wire shape integrity.** Verify the signature commits the
    full 9-field canonical tuple (including the `null` byte sequence
    for absent hash). Verify no path emits a 7-field tuple with the v0.3
    code (which would be a downgrade attack vector). Verify
    `receipt_version: "3"` is a STRING not an int.

S.2 **`model_hash` provenance.** Verify the value sourced is the
    request-start container hash per §M.2.1 + §M.2.2. Any path that
    sources from a fresh snapshot at receipt-emission time is a
    CRITICAL: a malicious provider could swap mid-response and emit a
    receipt claiming the post-swap hash served the response.

S.3 **`model_hash: null` attestation.** Verify the receipt SIGNS the
    null literal — i.e. JCS canonical bytes for the tuple INCLUDE
    `"model_hash":null` (not absence). Confirm via the parity test that
    the canonical bytes are deterministic.

S.4 **Mid-swap refusal (§M.2.2).** Verify the §M.2.2 defence-in-depth
    path: the runtime cannot disambiguate which container served →
    `receipt_omitted: model_swap_violation`. (The drain-cancelled path
    already emits this audit reason for the SPEC-011 R-3.4.2 timeout;
    verify that semantic is preserved.)

S.5 **Error-receipt hash binding (§7.6 v0.3).** Verify error receipts
    DO carry the request-start `model_hash` (the buyer is entitled
    to know which weights were loaded when the error fired). A null
    hash on a successful error-receipt issuance is a regression vs
    §7.6 v0.3.

S.6 **`RFC8785JCS.swift` invariants.** Verify no amendment to
    `RFC8785JCS.swift` per §M.1.5. Verify the existing UTF-16 key
    order produces alphabetical ASCII order for the new keys.

S.7 **Receipt envelope size.** Verify the receipt header fits the
    §3.4 v0.3 ≤ ~1025-byte budget AND the 4096-byte nginx headroom
    cap. A receipt that exceeds the cap is silently truncated by
    nginx and the buyer sees a malformed receipt.

S.8 **Audit-log emissions.** Verify `ReceiptAudit.emitOmitted` /
    `emitIssued` calls in error paths name the right reason and do
    not leak hash material into the audit sink (the receipt is a
    buyer-held proof; logging the hash duplicates the secret and
    can leak provider identity).

### ARCHITECT lens — cross-spec consistency, evolution arc, build-prompt coverage

A.1 **BUILD prompt Step 1 coverage.** Diff every "What lands" item in
    BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md Step 1 against the
    implementation. Missing = MAJOR. Particularly:
    - `ReceiptBuilder.swift` extended to construct the 9-field tuple
    - `receipt_version: "3"` as a constant
    - `model_hash` provenance from local SPEC-011 state
    - `RFC8785JCS.swift` NOT amended
    - Parity test for 9-field canonicalization
    - `receipt_omitted: model_swap_violation` defence-in-depth path
    - Raw 64-char lowercase hex format preserved
    - Tests for: 9-field tuple parity, null model_hash, non-null,
      `receipt_version == "3"`, ≤ 960-byte receipt size, error-receipt
      hash inheritance, mid-swap refusal, no v0.1/v0.2 wire regression

A.2 **Locked-spec line-3 versions unchanged.** Verify by `git diff
    HEAD~ -- 'specs/SPEC-{001,002,005,006,008,010,011,013}-*.md'`.

A.3 **Composes with v0.2 verifier release** (the BUILD prompt
    Step 0 pre-flight asserts `phase7-verify/cmd/macprovider-verify/main.go`
    exists). Step 1 should not regress any v0.2 surface; Step 5
    (verifier extension) is where v0.3 verifier work lives.

A.4 **§7.6 update is applied to existing AC-12 invariant.** The
    v0.1.3 AC-12 (null-usage / error receipt invariant for
    `error_model_not_loaded`) is preserved at the v0.1/v0.2 wire
    shape; v0.3 AC-31 binds `model_hash` per §M.2. Verify both ACs
    are testable from the existing test surface.

A.5 **No new third-party dependencies in `phase3-binary/`** —
    verify `Package.swift` is unchanged.

A.6 **`receipt_omitted` reason enum** — verify the `modelSwapViolation`
    case still exists (it was a v0.1/v0.2 placeholder; v0.3 promotes
    it per §11). No new enum cases should be added that aren't named
    in §11.

A.7 **InferenceRelay (`processNonStreaming`) snapshot capture.**
    Verify it composes cleanly with the tier-2 session and
    `acquireRequestHandle` patterns; the snapshot capture happens
    BEFORE `modelRuntime.complete`.

## What MUST be in every audit report

Each finding cites:
- The source file + line range (`HTTPServer.swift:234-237`).
- Severity (CRITICAL / HIGH / MEDIUM / LOW).
- One-sentence problem statement.
- One-paragraph elaboration with cross-references to the spec / code.
- Suggested resolution direction (NOT a written diff; pointer at most).

End with the VERDICT + COUNTS lines.
