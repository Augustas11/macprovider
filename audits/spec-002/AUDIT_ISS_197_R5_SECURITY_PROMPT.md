You are reviewing branch `spec/iss-197-v1-4-3-clarifications` of the macprovider repo
(working tree `/Users/augstar/macprovider-iss197`), SECURITY lane, ROUND 5.

R4 returned 0 CRITICAL / 0 HIGH / 2 MEDIUM:

1. (R4 MEDIUM #1) Provider-side `hello.provider_id` accepted valid-UTF-8
   C1 chars and reached structured logs / close-frame reason. R5 fix:
   `requireString` in `phase4-coordinator/internal/ws/messages.go` now
   rejects control characters (C0, DEL, C1) at parse time, covering all
   provider-supplied required strings on a hello. New regression test
   `TestParseHelloRejectsControlCharsInRequiredStrings` pins it.

2. (R4 MEDIUM #2) SPEC v1.5.1 prose described sanitizer hardening as
   mostly `external_request_id` / `X-MacProvider-Account` only; FR-B9
   listed `model`, `error`, `pref_header`, `provider_header` as plain
   text. R5 fix: SPEC-002 §11 now has a top-level "Buyer-controlled
   text sanitization (v1.5.1)" paragraph enumerating EVERY
   buyer-controlled persisted text column and the sanitizer that
   covers it (opaque headers → `sanitizeOpaqueHeader`; text fields →
   `sanitizeRequestLogText`; WS hello strings → `requireString`).
   FR-B9 row for `model` now includes the sanitization note pointing
   at that paragraph.

## Verify

- The new `requireString` reject for C0/DEL/C1 covers all hello
  required strings, but does the WS server have OTHER provider-
  controlled values that bypass `requireString` and reach logs?
  Check JSON-parsed objects like `attestation`, `model_hash`,
  `tier_proof` — anything that goes into structured logs without
  passing through the new control-char check.
- Buyer-side: are there OTHER buyer-controlled fields reaching
  request_log or logs that aren't covered by `sanitizeRequestLogText`
  or `sanitizeOpaqueHeader`? E.g. `buyer_ip` (server-derived from
  RemoteAddr, low risk), `provider_assigned_id` (coordinator-
  generated, low risk).
- The SPEC §11 paragraph and FR-B9 row — do they accurately
  describe what the code does? Look for divergence between SPEC
  text and the actual sanitizer signatures.
- Does the v1.5.1 SPEC text adequately convey that the sanitization
  contract is a load-bearing security property (not just hygiene)?
- Re-verify the operational binding scope: no in-process money-path
  computation silently produces wrong credits under state
  `unindexed`.

## Severity rubric

- **CRITICAL**: real sanitizer bypass or money-path bug remains.
- **HIGH**: an R4 MEDIUM still open OR a new exploit class.
- **MEDIUM**: hardening that should land but didn't.
- **LOW / NIT**: defensive suggestions.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.
