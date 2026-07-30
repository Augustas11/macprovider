## Round 1 by Codex

Scope audited:
- `phase7-verify/internal/verify/verify.go`
- `phase7-verify/internal/verify/verify_test.go`
- `phase7-verify/internal/verify/implementation-notes.md`

Validation run:
- `cd phase7-verify && go vet ./internal/verify/...` — PASS
- `cd phase7-verify && go test ./internal/verify/... -race -count=1 -v` — PASS
- `cd phase7-verify && go test ./... -race -count=1` — PASS
- `grep -n "Result\\s*:" phase7-verify/internal/verify/verify.go` — found only inline invalid result literals at `verify.go:252`, `verify.go:266`, `verify.go:282`; the other result paths use `invalid`, `inconclusive`, or the valid assignment.
- `grep -n "Reason\\s*:" phase7-verify/internal/verify/verify.go` — found only enum constants wired at `verify.go:253`, `verify.go:267`, `verify.go:283`.
- `test -z "$(git diff impl/spec-015-v0-2-step-05 -- phase7-verify/go.sum)"` — PASS; `phase7-verify/go.sum` unchanged.

### Code lens

#### LOW C1. Previous-key grace tests miss the lower out-of-window failure and do not assert required `Details.Extra`

`phase7-verify/internal/verify/verify_test.go:277` covers previous-key grace behavior, but the case table covers the lower inclusive success boundary (`rotated_at - 60s`) at `verify_test.go:290`, the upper inclusive success boundary (`expires_at`) at `verify_test.go:296`, and only the upper out-of-window failure (`expires_at + 1s`) at `verify_test.go:302`. It does not test `unix_ts < rotated_at - 60s`, which the audit prompt explicitly calls out. The invalid assertion also checks only `details.field == "grace_window"` at `verify_test.go:339`, not that `Details.Extra` contains `unix_ts`, `rotated_at`, and `expires_at`.

Implementation evidence is correct: `trustedVerificationKey` rejects previous-key matches outside the window at `phase7-verify/internal/verify/verify.go:263`, populates `Details.Extra` with `unix_ts`, `rotated_at`, and `expires_at` at `verify.go:271`, and `insideGraceWindow` is inclusive on both ends at `verify.go:292`. This is a coverage gap, not an observed implementation defect.

#### LOW C2. Reason and warning edge coverage is weaker than the enum surface

The code defines the expected reason enum constants at `phase7-verify/internal/verify/verify.go:26`, and all implementation return paths use those constants through direct literals or helpers (`verify.go:175`, `verify.go:187`, `verify.go:200`, `verify.go:244`, `verify.go:320`). However, `provider_id_unresolvable` is reachable through `sourceNoneReason` at `verify.go:327` but has no direct `verify` package test. Existing inconclusive tests cover `pubkey_unresolvable` at `phase7-verify/internal/verify/verify_test.go:77`, `cache_stale_and_live_unreachable` at `verify_test.go:251`, and `provider_id_not_in_pool` at `verify_test.go:392`.

Warning taxonomy has similar weak spots. `convertWarnings` preserves resolver warning order and fields at `phase7-verify/internal/verify/verify.go:369`, and `clockSkewWarning` emits only `unix_ts`, `system_time`, and `delta_seconds` at `verify.go:391`. The tests assert only the presence of `clock_skew` at `phase7-verify/internal/verify/verify_test.go:435`; they do not assert the exact field set, resolver warning order preservation, or that `VerifyOpts.Quiet` leaves warning records intact. Implementation evidence is correct, but the audit prompt asked for these surfaces to be pinned.

#### INFO C3. §10.0 algorithm ordering is implemented as specified

`Verify` parses before resolution at `phase7-verify/internal/verify/verify.go:129`, resolves the trust root at `verify.go:143`, rejects `SourceNone` before signature/hash work at `verify.go:160`, selects a trusted explicit/current/previous key at `verify.go:164`, verifies the signature before canonicalization at `verify.go:175`, compares prompt hash before output hash at `verify.go:182` and `verify.go:195`, then appends `clock_skew` only as a valid-result warning at `verify.go:208`. Raw tuple bytes are preserved by `receipt.Parse` at `phase7-verify/internal/receipt/receipt.go:119` and passed unchanged into `ed25519.Verify` at `receipt.go:139`.

#### INFO C4. Parse-time errors and verification results are separated cleanly

Malformed receipt/header input is returned as `*InputFormatError` from `parseInput` at `phase7-verify/internal/verify/verify.go:214`; missing invocation data and canonicalization failures return `*UsageError` at `verify.go:222`, `verify.go:182`, and `verify.go:195`. Parsed receipts that fail cryptographic, hash, endorsement, or grace-window checks return tri-state `Result` values using the documented enum constants.

Code verdict: READY TO LOCK. Residual code risk: low test-coverage gaps remain around a previous-key lower-boundary failure and warning/reason edge assertions, but no CRITICAL/HIGH/MEDIUM code defect was found.

### Security lens

#### LOW S1. Security-sensitive warning and previous-key negative edges are not fully regression-pinned

The same low coverage gaps in C1 and C2 affect security regression confidence. A future change could remove the lower previous-key out-of-window rejection, strip grace-window detail fields, suppress warnings under `Quiet`, or drift the `clock_skew` warning schema without the current `verify` tests catching it. Relevant code is currently correct at `phase7-verify/internal/verify/verify.go:263`, `verify.go:271`, `verify.go:292`, `verify.go:369`, and `verify.go:391`; the gap is test strength.

#### INFO S2. No trust-root bypass path found

The verifier does not trust the receipt-embedded `provider_pubkey` when the resolver returns `SourceNone`: that path returns `inconclusive` at `phase7-verify/internal/verify/verify.go:160`. For resolver-derived roots, the receipt key is only compared against the resolved current key or previous key at `verify.go:249`; no match returns `invalid` with `pubkey_not_endorsed` at `verify.go:281`. Explicit pubkeys skip endorsement comparison but still flow into `receipt.Verify` at `verify.go:245` and `verify.go:175`; the wrong-explicit-key regression is covered at `phase7-verify/internal/verify/verify_test.go:372`.

#### INFO S3. Canonicalization mismatch cannot mask signature failure

Signature verification happens before prompt/output canonicalization at `phase7-verify/internal/verify/verify.go:175`, so tuple-byte mutation reports `signature_verify_failed` before hash mismatch. The AC-21 test mutates tuple bytes at `phase7-verify/internal/verify/verify_test.go:67` and expects `signature_verify_failed` at `verify_test.go:71`.

#### INFO S4. No all-provider cache scan was found in Step 6

Step 6 addresses resolver/cache lookup by `provider_id`, not by scanning all cached providers for matching pubkey bytes. Resolver cache selection calls `LookupByProviderID(coordinatorHost, providerID)` at `phase7-verify/internal/resolver/resolver.go:200`, and the cache implementation filters by both coordinator and provider id at `phase7-verify/internal/cache/cache.go:120`. The verifier never searches the cache by receipt `provider_pubkey`.

Security verdict: READY TO LOCK. Residual security risk: low regression-test weakness on edge warnings and lower previous-key failure, with implementation evidence currently satisfying the trust-root and no-bypass requirements.

### Architect lens

#### INFO A1. Step 6 remains inside the verification-orchestrator boundary

No Step 7 or Step 8 scope creep was found in the audited files. `VerifyInput` and `VerifyOpts` expose contract surfaces at `phase7-verify/internal/verify/verify.go:42`, while `implementation-notes.md` explicitly leaves CLI flag parsing, bundle JSON decoding, process exit-code mapping, and final output formatting to later steps at `phase7-verify/internal/verify/implementation-notes.md:73`. The package exposes typed errors and JSON tags, which are acceptable Step 7/8 contract surfaces.

#### INFO A2. AC-18 through AC-27 have concrete Step 6 test anchors, with noted weak edges

Mapping reviewed:
- AC-18: valid live current-key path — `phase7-verify/internal/verify/verify_test.go:40`
- AC-19: response mutation -> `output_hash_mismatch` — `verify_test.go:47`
- AC-20: request mutation -> `prompt_hash_mismatch` — `verify_test.go:57`
- AC-21: tuple byte mutation -> `signature_verify_failed` before hash mismatch — `verify_test.go:67`
- AC-22: live unreachable, no cache, no explicit pubkey -> `inconclusive` and network warning — `verify_test.go:77`
- AC-23: offline explicit pubkey -> valid with zero network calls — `verify_test.go:85`
- AC-24: JSON tags/shape readiness for Step 8 — `verify_test.go:147`
- AC-25: result state mapping and typed error split readiness for Step 7 — `verify_test.go:185`
- AC-26: stale cache live fetch and stale+live-failure inconclusive — `verify_test.go:221` and `verify_test.go:251`
- AC-27: previous-key grace success and upper out-of-window failure — `verify_test.go:277`; weak on lower out-of-window and `Details.Extra` assertions as C1 notes.

Architect verdict: READY TO LOCK. Residual architecture risk: AC-24/AC-25 are intentionally Step 6 contract-shape tests rather than full CLI/schema tests, and AC-27 should be tightened before or during later integration acceptance.

### Overall verdict

READY TO LOCK for Step 6 Round 1: 0 CRITICAL, 0 HIGH, 0 MEDIUM findings across code, security, and architect lenses. LOW findings are coverage hardening items only; implementation evidence satisfies the Step 6 verification-orchestrator contract.
