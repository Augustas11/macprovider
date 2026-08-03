# SPEC-010 — Provider Model Catalog

**Version:** 1.6
**Status:** v1.6 canonical model-identity amendment proposed by issue #609
(2026-07-18). The supported-model catalog contract remains **LOCKED** at
v1.5 (2026-06-06, Decision-log Entry 54 —
codex round-6 returned 0 CRITICAL / 0 MAJOR / 0 MINOR). Implemented on
both sides (provider `supported_models[]` advertisement, coordinator
`Provider` extension, opt-in `/v1/status` echo). The former "pre round-6"
status predated the lock and was never flipped. (Former open gap NOW
CLOSED, 2026-07-11: the R-3.3.4 `seenModels` union of `supported_models`
is implemented — the seen-model index is seeded with the union of
`ModelID` and every `SupportedModels[]` entry at BOTH the registration
and heartbeat sites, so a declared-but-cold model now returns 503
`no_provider_available` (retryable) instead of 404 `model_not_found`. No
normative text changed; see the R-3.3.4 implementation note in §3.3.)
**Date drafted:** 2026-06-06
**Companion to (LOCKED):** SPEC-001 v1.2.4, SPEC-002 v1.3.4,
SPEC-004 v0.3.1, SPEC-008 v0.3, SPEC-006 v0.8.1.

**Triage note 2026-06-26 (no version bump, no normative change):**
- §7 OQ-1 (case preservation) and OQ-2 (admission counter) marked RESOLVED inline. Pointer: `docs/OPEN_QUESTIONS.md` 2026-06-26 triage row for SPEC-010.

**Compatibility note 2026-07-30 (SPEC-023 v0.9.1 / issue #687):**
SPEC-023 owns candidate-catalog `bench_gate` provenance, including
`bench_gate.provenance.source == "omlx_seeded"` and required
`bench_gate.gate_seed` metadata. SPEC-010 does not treat oMLX evidence as provider admission or promotion authority; verified provider autotune and existing model identity/hash checks remain binding.

**Change log v1.6 (issue #609 canonical model identity):**
- Names the canonical signed-snapshot identity
  `macprovider.snapshot-manifest.v1` while reusing the canonical byte
  algorithm already specified by SPEC-023 §3.2.
- Adds typed provider/coordinator wire semantics, a separate optional
  safetensors-weights diagnostic identity, exact admitted-row comparison,
  route/receipt binding, warm-swap requirements, and a finite fail-closed
  bridge for providers that do not yet report an algorithm.
- Adds stable requirements SPEC-010-R001 through SPEC-010-R006. This is a
  bounded `model-catalog-identity` amendment; it does not reopen or reconcile
  unrelated SPEC-010 lifecycle behavior.

**Change log v1.5 (round-5 polish pass — lock candidate):**
Round-5 verdict was READY TO LOCK with 0 CRITICAL / 0 MAJOR /
3 MINOR / 0 QUESTION (`audits/spec-010/SPEC-010-audit.md` round 5). v1.5
closes the 3 MINORs as a final polish pass before lock:
- **A5.1 MINOR fix** (retention/defer creation should
  explicitly gate on SPEC-010 field presence): R-3.1.10
  clause 1 now opens with an explicit guard — "Create this
  retention entry and install the defer ONLY when
  `supported_models` or `publishes_supported_models` is
  present on the initial-stage frame; otherwise no SPEC-010
  retention state is created." This makes the L-1
  byte-identical default path's "no SPEC-010 internal
  state" assertion explicit.
- **D5.3 MINOR fix** (AC-18(f) arbitrary 1s settlement
  window): the settlement window is replaced with a
  deterministic harness join condition — "wait for the 100
  handler goroutines to return (`sync.WaitGroup.Wait()` or
  equivalent), then assert `retentionMapSize() == baseline`
  with no timeout-based slack." This eliminates the
  ambiguity between synchronous defer semantics and
  polling-based cleanup.
- **G5.1 MINOR fix** (§6.1 stale "SPEC-010 v1.2"
  self-citation): §6.1 SPEC-001 v1.2.5 candidate now cites
  "SPEC-010 v1.x locked §3.1 and §3.6" (using the
  version-agnostic form so the citation survives future
  patch revisions without re-edit).

**Change log v1.4 (round-4 audit response):** Round-4 produced
0 CRITICAL / 2 MAJOR / 5 MINOR findings
(`audits/spec-010/SPEC-010-audit.md` round 4). v1.4 closes all 7. Both
MAJORs were code-precision items at the same boundary as v1.3
focus (initial-stage table accuracy + R-3.1.10 cleanup
mechanism).
- **B4.1 MAJOR fix** (`attestation_token` still in initial-
  stage table though parser doesn't read it): row REMOVED
  from §3.1.A. Added a new §3.1.C compact note on proof-
  stage frame fields, with `attestation_token` correctly
  placed there. §3.1.A now contains ONLY fields
  `parseAuthInitial` actually reads.
- **C4.4 MAJOR fix** (R-3.1.10 disconnect cleanup pointed at
  wrong handler): clause 5(d) rewritten to require
  **auth-attempt-scoped `defer releaseRetention(authAttemptID)`
  installed immediately after retention creation**, NOT the
  registered-session `handleDisconnect`. The current
  `handleConn` only invokes `handleDisconnect` when the
  handler returns non-empty IDs (i.e. AFTER
  `registerProviderSession`); the v2 path returns from
  `handleV2Conn` without registered IDs on pre-proof
  disconnect/read-error/parse-error/expiry/attestation-fail
  paths. Clause 5(d) now enumerates these failure paths
  explicitly and requires the defer to cover them.
- **A4.2 MINOR fix** (periodic sweeper implies new
  coordinator machinery): clause 5(c) SIMPLIFIED — the
  periodic-sweeper option is REMOVED. Cleanup is now
  exclusively defer-based per clause 5(d). The 10-minute
  expiry timeout is enforced by the existing `server.go:398`
  expiry check; SPEC-010 doesn't require a new background
  task.
- **B4.3 MINOR fix** (ECDH placeholder "BPwjzkU0..." would
  fail tier2 key parse): §3.1.B example value changed to
  `"<base64url-32-byte-x25519-public-key>"` as an explicit
  placeholder label. Test fixtures using this example must
  substitute a real test key.
- **C4.2 MINOR fix** (retained `provider_id` cross-check
  redundant with server.go:398): clause 1 now explicitly
  notes the retained `provider_id` is defense-in-depth
  against future refactors that might separate catalog
  comparison from the current `initial` local variable in
  `handleV2Conn`. If a future SPEC-002 refactor moves
  catalog comparison out of the local-variable scope, the
  retained value is the binding source of truth; today the
  existing check is authoritative.
- **C4.5 MINOR fix** (retention cap 10000 arbitrary):
  retention map size bound is now tied to
  `ws.max_unauthenticated_conn` (default 64 per
  `phase4-coordinator/internal/config/config.go:269`). Each
  unauthenticated WS slot can host AT MOST ONE in-flight
  auth-attempt with retention entry, so retention map size
  is naturally capped at `MaxUnauthenticatedConn`. No
  separate cap needed.
- **D4.1 MINOR fix** (AC-18(d) debug hook): AC-18(d) prelude
  now explicitly notes implementers MUST expose a
  package-internal test accessor for retention entry
  count/lookup (no production debug endpoint required).
- **D4.3 MINOR fix** (AC-18(f) "baseline" underspecified):
  baseline is now defined as the pre-test retention map
  size for that specific coordinator instance, with the
  test required to isolate or subtract concurrent unrelated
  in-flight auth attempts.

**Change log v1.3 (round-3 audit response — code-grounding
pass):** Round-3 produced 0 CRITICAL / 5 MAJOR / 0 MINOR
findings (`audits/spec-010/SPEC-010-audit.md` round 3). All 5 MAJORs were
one logical cluster: v1.2 §3.1.A field table and R-3.1.10
retention contract were written without spot-checking the
actual `parseAuthInitial` parser and `server.go` auth-attempt
flow. v1.3 closes all 5 by code-grounding §3.1.A against
`messages.go:333-388` parser code and R-3.1.10 against
`server.go:354-355` retention timing.
- **B3.1 fix** (§3.1.A field table didn't match
  `AuthRequest`): table regenerated against actual code.
  `auth_attempt_id` is NOT in the initial-stage frame —
  parser doesn't read it, struct marks `omitempty`. It's
  coordinator-generated post-parse (server.go:354) and
  arrives on the proof-stage frame. v1.3 removes it from
  §3.1.A's initial-stage table. Fields marked REQUIRED per
  `parseAuthInitial`'s `requireString`/`requireInt`/`requireFloat`
  calls: `provider_id`, `hostname`, `model_id`,
  `model_params_b`, `ram_gb`, `max_context_tokens`,
  `max_concurrency`, `throughput_tps_estimate`,
  `binary_version`, `provider_ecdh_public_key`,
  `tier2_capabilities`. v1.2 incorrectly marked most as
  optional.
- **B3.4 fix** (§3.1.B example wasn't parser-valid): example
  rewritten to include all 11 parser-required fields. The
  "minimally valid SPEC-010 initial-stage frame" claim is
  REMOVED and replaced with explicit acknowledgement that the
  minimum frame is large (all 11 required fields plus the 2
  SPEC-010 additions); SPEC-010 v1.3 does NOT propose
  relaxing parser requirements.
- **C3.2 fix** (R-3.1.10 retention key cites a field not in
  initial frame): R-3.1.10 retention key is now explicitly
  defined as the coordinator-generated `auth_challenge.auth_attempt_id`
  (server.go:354 `authAttemptID := "auth-" + s.newUUID()`).
  Coordinator attaches the parsed initial-stage SPEC-010
  values to that generated ID before sending the
  `auth_challenge` message.
- **A3.2 fix** (R-3.1.10 cites SPEC-002 §7.3 timeout that
  doesn't exist): timeout bound moved into SPEC-010 R-3.1.10
  directly as "≤ 10 minutes, matching the existing coordinator
  challenge expiry at
  phase4-coordinator/internal/ws/server.go:355
  `challengeExpiresAt := s.now().Add(10 * time.Minute)`."
  §6.2 SPEC-002 v1.3.5 candidate also flags this as a
  normative-edit candidate (SPEC-002 should add the auth-
  attempt lifecycle text).
- **D3.1 fix** (AC-18 doesn't cover R-3.1.10 clauses 1, 2,
  5): AC-18 expanded to 6 sub-cases (a-f) covering all 5
  R-3.1.10 clauses including retention creation, parser
  capture of both SPEC-010 fields on proof stage, and
  cleanup on all four termination paths
  (success / non-mismatch failure / timeout / disconnect-
  before-proof).

**Change log v1.2 (round-2 audit response):** Round-2 produced
0 CRITICAL / 3 MAJOR / 2 MINOR findings
(`audits/spec-010/SPEC-010-audit.md` round 2). v1.2 closes all 5. The 3
MAJORs were one logical cluster — B.1 round 2, B2.1, B2.2 — all
rooted in the same issue: the v2 `auth_request` flow exists in
code but no locked spec normatively documents it, so v1.1's
attempts to bind to a locked source were chasing text that
isn't there. v1.2 resolves by making §3.1 self-contained and
reframing §6.1/§6.2 candidate annotations as "must ADD this v2
contract" rather than "must extend existing v2 text."
- **B.1 round 2 + B2.1 fix** (cluster): §3.1 now includes a
  compact normative field table for the v2 initial-stage
  `auth_request` (existing required + existing optional + the
  two SPEC-010-added fields). The example no longer hides
  required fields behind `"..."`. §6.1 and §6.2 candidate
  annotations now explicitly say SPEC-001 v1.2.5 and SPEC-002
  v1.3.5 candidates MUST ADD the v2 `auth_request` normative
  text — they do not "extend existing" because the existing
  locked text documents `hello`, not `auth_request`.
- **B2.2 fix** (proof-stage parser/retention contract): new
  R-3.1.10 specifies the proof-stage parser rule explicitly:
  absent proof-stage `supported_models` is NOT a mismatch;
  present requires NFC + ASCII case-fold normalization, then
  comparison against the initial-stage values retained for
  the auth attempt. AC-18 updated to test both branches.
- **E2.1 fix** (§9 references list still cited §7.2): §9
  reference list updated to cite SPEC-002 v1.3.4 §3, §5, §7.1
  (provider WS), §7.3 (token auth), §11. §7.2 (buyer HTTP)
  removed.
- **E2.2 fix** (change log AC numbering off-by-one): v1.1
  change log entries below corrected. E.1 covers AC-17
  through AC-21 (five ACs, not four). E.3 covers AC-22 and
  AC-23 (not AC-21 and AC-22).

**Change log v1.1 (round-1 audit response on the narrow-scope
SPEC-010 v1.0):** Round-1 produced 0 CRITICAL / 3 MAJOR / 1 MINOR
findings (`audits/spec-010/SPEC-010-audit.md` round 1). v1.1 closes all
four.
- **B.1 fix** (wire frame name + wrong SPEC-002 section): §3.1
  example now uses the correct `auth_request` frame shape with
  `version: 2` and `stage: "initial"` (per current
  `AuthRequest` Go struct in
  phase4-coordinator/internal/ws/messages.go lines 37-57).
  Source citation corrected to SPEC-002 v1.3.4 §7.1 (provider
  WebSocket handshake) instead of §7.2 (which is the buyer HTTP
  API). AC-16 added to test the actual wire shape end-to-end.
  Note: round-2 R1V-B.1 marked this PARTIAL because §7.1
  documents `hello`, not `auth_request` — fully resolved in
  v1.2 above.
- **E.1 fix** (provider-binary AC gaps): AC-17 through AC-21
  (five ACs) added covering R-3.1.1 non-array rejection,
  stage mismatch, R-3.6.2 default emission, R-3.6.3
  binary-side length validation, R-3.6.4 publish flag default.
- **E.2 fix** (AC-13 log byte-identity is CI-flaky): AC-13
  rewritten — `/v1/models` and `/v1/status` keep byte-identical
  response diffs; log assertion now requires normalized
  comparison (event names, severity levels, stable fields,
  zero new SPEC-010-related entries on the legacy path).
- **E.3 fix** (multi-failure validation priority coverage):
  AC-22 and AC-23 added covering R-3.1.9 step-1-vs-step-5
  and step-4-vs-step-5 priority.

**Change log v1.0 (initial post-split draft):** Versions v0.1
through v0.3 of SPEC-010 bundled
capability advertisement, warm-swap mechanism, demand-pull cold
wake, buyer catalog visibility, and operator state visibility into
a single ~1400-line spec. Three audit rounds (rounds 1-3 in
`audits/spec-012/SPEC-012-source-audit-history.md`) showed the wide scope
generates 12+ audit findings per round driven by cross-feature
collisions across 5 locked specs. **SPEC-010 v1.0 is the result of
splitting that work.** The wide-scope draft is preserved at
`specs/SPEC-012-coordinator-demand-pull.md`; warm-swap mechanism becomes SPEC-011;
demand-pull + catalog visibility becomes SPEC-012 (paired with a
SPEC-008 v0.4 normative edit).

**This spec (v1.5) does exactly one thing:** lets a provider
declare which MLX models it is willing to serve, in addition to
the single model it is currently serving warm. Nothing more. No
swap mechanism, no buyer-visible behavior change, no `/v1/models`
shape change, no error envelope change.

---

## 1. Problem statement

### 1.1 Why this exists

arm64golf canary run (2026-06-05): provider operator reported four
pains. Pains #1 (no CLI to swap) and #2 (restart breaks dashboard)
are the operator-side fix surface; both are owned by SPEC-011
(operator-pushed warm swap). Pain #3 (buyer picker visibility) and
#4 (HF ID discovery) are buyer-facing; both are owned by SPEC-012.

**SPEC-010 v1.0 is the foundation those specs build on.** Today,
the WS auth frame ([messages.go:8](../phase4-coordinator/internal/ws/messages.go))
carries a single `model_id` string. Coordinator stores only the
currently-loaded model on `Provider`
([provider.go:50](../phase4-coordinator/internal/pool/provider.go)).
There is no protocol way to express "this provider could also
serve X, Y, Z."

Without that primitive:

- **SPEC-011** (operator-pushed swap) cannot validate locally that
  a switch target is one the operator declared willing to serve;
  every swap would require re-auth or trust nothing.
- **SPEC-012** (coordinator-initiated demand-pull swap) cannot
  decide which provider to wake for a cold-supported request,
  because it doesn't know which providers support which models.
- The current `/v1/models` aggregation can only ever show warm
  models, even when the operator pool collectively spans many.

SPEC-010 v1.0 adds the field. It does not act on it. The acting
specs are SPEC-011 (binary-local) and SPEC-012 (coordinator-side).

### 1.2 What v1.0 explicitly does NOT do

To prevent the wide-scope drift that produced 3 audit rounds with
no convergence:

- No new WS message types
- No new provider sub-states
- No new error envelopes
- No `/v1/models` aggregation change
- No `/v1/status.state` field
- No coordinator-initiated swap path
- No buyer-visible behavior change at any default config
- No SPEC-008 §5.7 interaction (cold-supported models do NOT
  surface to buyers, so no Pillar A hash-block question arises)
- No SPEC-005 billing interaction
- No `publish_unwarm_models` config (the question doesn't arise
  because cold-supported models are not aggregated anywhere)

These are the surfaces that produced the round-2 and round-3
CRITICAL/MAJOR findings on the wide-scope draft. v1.0 omits them
entirely.

---

## 2. Locked design decisions

| Lock | Decision |
|---|---|
| L-1 | **Backward compatible.** With no SPEC-010 field present in the auth frame AND no provider opted in to `publishes_supported_models`, coordinator behavior MUST be byte-identical to pre-SPEC-010 production. Every public response and log line is unchanged. |
| L-2 | **No closed allowlist.** Coordinator does not validate model IDs against a server-side whitelist. Any string the provider sends in `supported_models` is accepted, subject only to length/shape limits in §4.1. Permissionless onboarding stays. |
| L-3 | **One *active* model per provider process at a time.** Multi-model serving (parallel loaded weights) is out of scope. `supported_models` declares *willingness*; `model_id` is what is warm right now. v1.0 has no mechanism to make a non-warm declared model become warm — that's SPEC-011/SPEC-012. |
| L-4 | **Trivial SPEC-008 Pillar A interaction.** Because v1.0 adds no new routing-eligible state and no `/v1/models` aggregation, `model_hash` continues to refer to `loaded_model` only and Pillar A logic is unchanged. No interaction surface. |
| L-5 | **No billing change.** No new SPEC-005 ledger interaction. SPEC-010 v1.0 is invisible to the request_log. |
| L-6 | **F-1.5 invariants trivially preserved.** No new wire surface that touches sticky derivation, `conv:`, or sticky TTL. |

---

## 3. Wire spec (NORMATIVE)

### 3.1 Provider → coordinator: `auth_request` frame extension

**Important note on source of truth.** The v2 `auth_request`
provider WebSocket handshake exists in code (Go struct
[`AuthRequest`](../phase4-coordinator/internal/ws/messages.go)
lines 37-57; parser at lines 302-329) and is exercised in
production, but no LOCKED spec normatively documents it.
SPEC-001 v1.2.4 §6.5 and SPEC-002 v1.3.4 §7.1 both still
document the legacy `hello` handshake. Round-2 audit verified:
the v2 contract is implementation-defined.

Rather than cite locked text that does not exist, SPEC-010 v1.3
makes this section **self-contained**: §3.1.A below enumerates
the full v2 initial-stage `auth_request` field set, **derived
directly from the actual `parseAuthInitial` parser at
[ws/messages.go:333-388](../phase4-coordinator/internal/ws/messages.go)**.
SPEC-001 v1.2.5 and SPEC-002 v1.3.5 candidates per §6.1 / §6.2
are explicitly tasked with ADDING this v2 contract as normative
text in their respective spec scopes; until those candidates
land, §3.1.A IS the source of truth for the v2 contract as it
interacts with SPEC-010.

SPEC-010 v1.3 extends the **initial-stage** `auth_request`
frame with two optional fields: `supported_models` and
`publishes_supported_models`.

#### §3.1.A Compact v2 `auth_request` initial-stage field table (B3.1 round-3 fix)

The coordinator's frame-type validator at
[ws/messages.go:302-329](../phase4-coordinator/internal/ws/messages.go)
gates on `type == "auth_request"`, `version == 2`, and
`stage ∈ {"initial", "proof"}`. Initial-stage field
requirements come from `parseAuthInitial`
([ws/messages.go:333-388](../phase4-coordinator/internal/ws/messages.go))
which uses `requireString` / `requireInt` / `requireFloat`
helpers for required fields and `if v, ok := raw[<key>]; ok`
guards for optional fields. The fields are:

| Field | JSON name | Type | Parser requiredness | Notes |
|---|---|---|---|---|
| Message type | `type` | string, exactly `"auth_request"` | REQUIRED by frame validator | parser rejects with `bad_message_type` otherwise |
| Protocol version | `version` | int, exactly `2` | REQUIRED by frame validator | parser rejects with `bad_version` otherwise |
| Stage | `stage` | string, exactly `"initial"` here | REQUIRED by frame validator | parser routes to `parseAuthInitial` for `"initial"`, `parseAuthProof` for `"proof"` |
| Provider ID | `provider_id` | string ULID | **REQUIRED** by `parseAuthInitial:334` `requireString` | |
| Hostname | `hostname` | string | **REQUIRED** by `parseAuthInitial:337` `requireString` | NOTE: struct tag is `omitempty` but parser requires it |
| Loaded model | `model_id` | string | **REQUIRED** by `parseAuthInitial:340` `requireString` | NOTE: struct tag is `omitempty` but parser requires it |
| Model hash | `model_hash` | string sha256-hex | optional (parser uses `if v, ok` guard at line 343) | SPEC-008 Pillar A |
| Model hash algorithm | `model_hash_algorithm` | string | optional at parsing; required by canonical admission policy when `model_hash` is present outside the bounded migration bridge | SPEC-010 §3.7 |
| Weights manifest hash | `weights_manifest_sha256` | string sha256-hex | optional; MUST be paired with `weights_manifest_algorithm` | Diagnostic runtime evidence only; SPEC-010 §3.7 |
| Weights manifest algorithm | `weights_manifest_algorithm` | string | optional; MUST equal `macprovider.safetensors-manifest.v1` and be paired with `weights_manifest_sha256` | Diagnostic runtime evidence only; SPEC-010 §3.7 |
| Model params (B) | `model_params_b` | float | **REQUIRED** by `parseAuthInitial:348` `requireFloat` | |
| RAM (GB) | `ram_gb` | int | **REQUIRED** by `parseAuthInitial:351` `requireInt` | |
| Max context tokens | `max_context_tokens` | int | **REQUIRED** by `parseAuthInitial:354` `requireInt` | |
| Max concurrency | `max_concurrency` | int | **REQUIRED** by `parseAuthInitial:357` `requireInt` | |
| Throughput TPS estimate | `throughput_tps_estimate` | float | **REQUIRED** by `parseAuthInitial:360` `requireFloat` | |
| Model load time | `model_load_time_ms` | int64 | optional (line 363 `if v, ok`) | |
| Binary version | `binary_version` | string | **REQUIRED** by `parseAuthInitial:368` `requireString` | |
| Endpoint URL | `endpoint_url` | string pointer (nullable) | optional (line 371 `if v, ok`) | |
| Provider ECDH public key | `provider_ecdh_public_key` | string base64 | **REQUIRED** by `parseAuthInitial:378` `requireString` | NOTE: struct tag is `omitempty` but parser requires it; SPEC-008 Tier-2 |
| Tier-2 capabilities | `tier2_capabilities` | object `{encrypted_leg: bool, attestation: bool, aead_suites: []string}` | **REQUIRED** by `parseAuthInitial:381-384` explicit ok-check | SPEC-008 Tier-2; parser returns `"missing tier2_capabilities"` error if absent |
| **Supported models** | **`supported_models`** | **array of strings** | **optional, ADDED by SPEC-010 v1.x** | **§3.1.B rules below + R-3.1.1 through R-3.1.9** |
| **Publishes supported models** | **`publishes_supported_models`** | **bool** | **optional, ADDED by SPEC-010 v1.x** | **§3.1.B rules + R-3.1.6** |

**About `auth_attempt_id`:** the `AuthRequest` Go struct
([ws/messages.go:41](../phase4-coordinator/internal/ws/messages.go))
includes `auth_attempt_id string `json:"auth_attempt_id,omitempty"``,
but `parseAuthInitial` does NOT read it. The field is
populated only on the **proof-stage** frame, where
`parseAuthProof:392` reads it via `requireString`. The
coordinator GENERATES `auth_attempt_id` at
[server.go:354](../phase4-coordinator/internal/ws/server.go)
(`authAttemptID := "auth-" + s.newUUID()`) AFTER successful
initial-stage parse, attaches it to the outgoing
`auth_challenge`, and expects the provider to echo it on the
subsequent proof-stage `auth_request`. R-3.1.10 retention is
keyed on THIS coordinator-generated ID, not on any
initial-stage client value.

**Note that 11 fields are parser-REQUIRED on the initial
stage** (provider_id, hostname, model_id, model_params_b,
ram_gb, max_context_tokens, max_concurrency,
throughput_tps_estimate, binary_version,
provider_ecdh_public_key, tier2_capabilities). Several have
`omitempty` Go struct tags but the parser enforces stricter
requirements than the struct tags suggest. Always trust the
parser, not the struct tag.

#### §3.1.B Wire example with all parser-required fields + SPEC-010 additions

This example is **parser-valid**: every field
`parseAuthInitial` requires is present.

```json
{
  "type": "auth_request",
  "version": 2,
  "stage": "initial",
  "provider_id": "p_01HK4Z3VYE...",
  "hostname": "mac-mini-01.local",
  "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "model_params_b": 7.6,
  "ram_gb": 64,
  "max_context_tokens": 32768,
  "max_concurrency": 1,
  "throughput_tps_estimate": 42.5,
  "binary_version": "1.2.5",
  "provider_ecdh_public_key": "<base64url-32-byte-x25519-public-key>",
  "tier2_capabilities": {
    "encrypted_leg": false,
    "attestation": false,
    "aead_suites": []
  },
  "supported_models": [
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    "mlx-community/Llama-3.1-8B-Instruct-4bit",
    "mlx-community/Mistral-7B-Instruct-v0.3-4bit"
  ],
  "publishes_supported_models": true
}
```

A Tier-1 provider that does not participate in SPEC-008 Tier-2
still MUST send `provider_ecdh_public_key` and
`tier2_capabilities` per the current parser (the example above
shows a Tier-1 baseline shape with `encrypted_leg: false` and
empty `aead_suites`). SPEC-010 v1.4 does NOT propose relaxing
any parser requirement; this is `parseAuthInitial`'s current
contract.

**Note on `provider_ecdh_public_key` example value (B4.3
round-4 fix).** The string
`"<base64url-32-byte-x25519-public-key>"` above is an
**explicit placeholder label**, not a working value.
`parseAuthInitial` requires only that the field be a string
(`requireString` at messages.go:378), so the example would
pass parser validation. However, the subsequent call to
`tier2.ParseX25519PublicKey` at
[server.go:330-333](../phase4-coordinator/internal/ws/server.go)
would reject the placeholder. Test fixtures using this
example MUST substitute a real base64url-encoded 32-byte
X25519 public key (or use a documented non-production test
key).

**Minimum-frame note (v1.3 correction):** v1.2's "minimally
valid SPEC-010 initial-stage frame contains `{type, version,
stage, provider_id}`" claim was INCORRECT — the parser rejects
that. The actual minimum is the 11 parser-required fields
above plus `type` / `version` / `stage` / `provider_id` (13
mandatory fields total), plus the 2 SPEC-010 fields when the
provider wants the new behavior. SPEC-010 v1.3 makes no
attempt to shrink this minimum; reducing it requires a
SPEC-001 v1.2.5 / SPEC-002 v1.3.5 parser-relaxation that is
out of SPEC-010's scope.

For deployments not yet on the v2 `auth_request` handshake,
the same SPEC-010 fields MAY appear on the legacy `hello`
frame per R-3.1.8.

#### §3.1.C Proof-stage `auth_request` field note (B4.1 round-4 fix)

The proof-stage `auth_request` frame is handled by
`parseAuthProof`
([messages.go:391-401](../phase4-coordinator/internal/ws/messages.go))
and carries a smaller field set than the initial-stage frame:

| Field | JSON name | Type | Parser requiredness | Notes |
|---|---|---|---|---|
| Message type | `type` | string, exactly `"auth_request"` | REQUIRED by frame validator | shared with initial stage |
| Protocol version | `version` | int, exactly `2` | REQUIRED by frame validator | shared with initial stage |
| Stage | `stage` | string, exactly `"proof"` | REQUIRED by frame validator | parser routes to `parseAuthProof` |
| Auth attempt ID | `auth_attempt_id` | string | **REQUIRED** by `parseAuthProof:392` | echoes coordinator-generated value from prior `auth_challenge`; v0.2's misplaced row was here, not in initial stage |
| Provider ID | `provider_id` | string | **REQUIRED** by `parseAuthProof:393-395` (server.go:398 also enforces match against initial-stage value) | |
| Attestation token | `attestation_token` | JSON raw | conditional per SPEC-008 Tier-2; checked at server.go:403 if attestation required | this is the field round-4 B4.1 found misplaced in §3.1.A — it correctly lives here |
| **Supported models** | **`supported_models`** | **array of strings** | **optional, ADDED by SPEC-010 R-3.1.10** | **handled per R-3.1.10 clauses 2-4** |
| **Publishes supported models** | **`publishes_supported_models`** | **bool** | **optional, ADDED by SPEC-010 R-3.1.10** | **handled per R-3.1.10 clauses 2-4** |

R-3.1.10 specifies how SPEC-010 fields are handled when
present on the proof stage (parser extension, comparison
against retained initial-stage values, mismatch rejection).

#### Rules

- **R-3.1.1** `supported_models`, when present, MUST be a JSON
  array of strings. The array MUST contain at least one entry;
  a present empty array (`[]`) MUST be rejected with
  `auth_response.error.code = "bad_request"` and reason text
  containing `"supported_models cannot be empty"`.
- **R-3.1.2** Each entry MUST be ≤ 256 UTF-8 bytes, mirroring
  SPEC-001 §6.1.2 model_id limit. Entries exceeding the cap MUST
  cause `bad_request`.
- **R-3.1.3** Array length cap: 64 entries. Length > 64 MUST cause
  `bad_request`. Justification: bounds coordinator memory; matches
  the high end of typical M-series HF cache contents (a 64GB
  M-series with 4-bit quants typically holds 6-20 distinct models;
  64 leaves headroom for future quant variants).
- **R-3.1.4** `model_id` MUST appear in `supported_models`
  (case-folded per R-3.1.7). If not, coordinator MUST reject with
  `bad_request` and reason text containing
  `"model_id not in supported_models"`.
- **R-3.1.5** When `supported_models` is **omitted** (legacy
  provider), coordinator MUST treat as if the provider had sent
  `supported_models: [model_id]`. No warning is logged. This is
  the legacy compat path.
- **R-3.1.6** `publishes_supported_models: bool`, when present and
  `true`, signals that the provider opts in to having
  `supported_models` echoed in the public `/v1/status` response
  per §3.3. When absent or `false`, the field MUST NOT appear in
  `/v1/status`. Legacy providers always behave as `false`.
- **R-3.1.7** Case-insensitivity: all containment, equality, and
  uniqueness checks on model IDs MUST use Unicode NFC
  normalization followed by ASCII case folding. The router uses
  this normalized form internally; the wire format preserves the
  provider's chosen case in responses.
- **R-3.1.8** The same fields MAY appear in the legacy `hello`
  frame for deployments not yet on the `auth` handshake. Rules
  R-3.1.1 through R-3.1.7 apply identically.
- **R-3.1.9** **Validation order (NORMATIVE).** Coordinator MUST
  apply validation in this exact order; the first failure produces
  the corresponding `bad_request` reason and stops further checks.
  This ordering is exposed so implementers and tests can assert
  on a single reason string per malformed auth:
  1. JSON type check on `supported_models` (must be array of
     strings) — fail reason `"supported_models must be array of
     strings"`.
  2. Per-entry UTF-8 byte length ≤ 256 (R-3.1.2) — fail reason
     `"supported_models entry exceeds 256 bytes"`.
  3. Array length ≥ 1 and ≤ 64 (R-3.1.1, R-3.1.3) — fail reasons
     `"supported_models cannot be empty"` and
     `"supported_models exceeds 64 entries"`.
  4. NFC + ASCII case-fold normalize (R-3.1.7), then duplicate
     check: after normalization, duplicate entries MUST cause
     `bad_request` with reason
     `"supported_models contains duplicate entries"`. The
     pre-normalization wire array is preserved for response use.
  5. `model_id ∈ supported_models` containment check (R-3.1.4) —
     fail reason `"model_id not in supported_models"`.
- **R-3.1.10** **Proof-stage parser and retention contract
  (B2.2 fix; C3.2 + A3.2 round-3 fixes).** The two-stage
  `auth_request` flow has the coordinator handle `initial`-stage
  and `proof`-stage frames separately. The current proof parser
  ([ws/messages.go:391-401](../phase4-coordinator/internal/ws/messages.go))
  reads only `auth_attempt_id`, `provider_id`, and
  `attestation_token`. SPEC-010 v1.3 adds the following rules:

  1. **Initial-stage retention (C3.2 round-3 fix — keyed on
     coordinator-generated ID; C4.5 round-4 fix — cap tied
     to existing config; A5.1 round-5 fix — explicit
     presence gate).** After `parseAuthInitial` successfully
     parses an initial-stage frame, the coordinator generates
     `auth_attempt_id` at
     [server.go:354](../phase4-coordinator/internal/ws/server.go)
     (`authAttemptID := "auth-" + s.newUUID()`).

     **Presence gate (A5.1 round-5 fix).** Create the
     retention entry and install the defer ONLY when the
     parsed initial-stage frame had a present
     `supported_models` OR a present
     `publishes_supported_models` field. Legacy initial
     frames (neither field present) MUST NOT create any
     SPEC-010 retention state, MUST NOT install the defer,
     and MUST NOT increment any retention-related metric.
     This guarantees the L-1 byte-identical default path
     has zero SPEC-010 internal state, not just zero
     observable behavior.

     **When the gate passes** (at least one SPEC-010 field
     was present on the initial frame), immediately before
     sending the outgoing `auth_challenge` (which carries
     the generated `auth_attempt_id`), the coordinator
     MUST:
     - (i) attach the parsed initial-stage
       `supported_models` and `publishes_supported_models`
       values to an in-memory retention entry keyed by the
       **coordinator-generated** `authAttemptID`, and
     - (ii) install an auth-attempt-scoped `defer
       releaseRetention(authAttemptID)` covering the
       remainder of `handleV2Conn` (see clause 5(d) for
       the failure-path enumeration this defer covers).

     The retention key is server-controlled; clients never
     supply it on the initial frame (it is absent from
     `parseAuthInitial`).

     The retention entry contains:
     - `supported_models` slice (post-NFC + ASCII fold per
       R-3.1.7; pre-normalization wire form preserved
       alongside for response use)
     - `publishes_supported_models` bool
     - retention start timestamp
     - `provider_id` from initial-stage (defense-in-depth
       per clause 4; see C4.2 note below)

     **Retention map size bound (C4.5 round-4 fix).** Each
     unauthenticated WS slot can host AT MOST ONE in-flight
     auth-attempt at a time (a single connection is
     processing a single auth flow). Retention map size is
     therefore naturally bounded above by
     `ws.max_unauthenticated_conn` (default 64 per
     [config.go:269](../phase4-coordinator/internal/config/config.go)).
     SPEC-010 v1.4 does NOT require a separate retention-
     specific cap; if a future SPEC-002 change decouples
     retention lifetime from connection lifetime, that change
     MUST add its own cap.

     **Defense-in-depth note on retained `provider_id` (C4.2
     round-4 clarification).** Current code at server.go:398
     rejects proof frames where `proof.ProviderID !=
     initial.ProviderID` before SPEC-010 retained catalog
     comparison would run, so today the retained `provider_id`
     is redundant. It is retained as a binding source of
     truth against a future SPEC-002 refactor that might
     separate catalog comparison from the current `initial`
     local variable in `handleV2Conn`. Implementations MAY
     omit storing it if they can guarantee the
     `proof.ProviderID == initial.ProviderID` invariant
     remains co-located with the SPEC-010 comparison call.

  2. **Proof-stage parser extension.** The proof-stage
     `auth_request` parser at
     [messages.go:391-401](../phase4-coordinator/internal/ws/messages.go)
     MUST be extended to read `supported_models` and
     `publishes_supported_models` if present, using the
     same `if v, ok := raw[<key>]; ok` optional-field guard
     pattern that `parseAuthInitial` uses for its optional
     fields. The proof parser uses the same R-3.1.7 case-fold
     normalization on read.

  3. **Absent = not a mismatch.** If proof-stage
     `supported_models` is ABSENT, the coordinator MUST
     proceed with the retained initial-stage values. No
     mismatch. No warning. Same rule for absent proof-stage
     `publishes_supported_models`.

  4. **Present = compare with case-folded normalization.** If
     proof-stage `supported_models` is PRESENT: NFC + ASCII
     case-fold normalize per R-3.1.7, then compare the
     resulting set against the retained initial-stage set
     looked up by the proof frame's `auth_attempt_id` (which
     the provider echoes back from the `auth_challenge`).
     Coordinator MUST also verify the proof frame's
     `provider_id` matches the retained initial-stage
     `provider_id` (current code at server.go:398 already
     enforces this; the retention cross-check is defensive).
     If the two normalized SPEC-010 sets differ (different
     cardinality OR different element membership), coordinator
     MUST reject the proof-stage frame with
     `auth_response.error.code = "bad_request"` and reason
     text containing `"supported_models mismatch between
     auth_request stages"`. Same comparison rule for
     `publishes_supported_models` (presence + boolean-equality
     required).

  5. **Retention cleanup via auth-attempt-scoped defer
     (C4.4 + A4.2 round-4 fixes).** The retained
     initial-stage values MUST be released by an
     auth-attempt-scoped cleanup mechanism installed in
     clause 1 step (ii). Concretely: the coordinator MUST
     install `defer releaseRetention(authAttemptID)` in
     `handleV2Conn` immediately after creating the
     retention entry (before sending the `auth_challenge`).
     This single defer covers the FULL set of auth-attempt
     terminal paths:

     - (a) **Successful completion** — provider is added to
       the pool with `Provider.SupportedModels` populated.
       The defer fires on `handleV2Conn` return as part of
       normal cleanup. (The defer fires AFTER the catalog
       values have been copied into `Provider.SupportedModels`;
       the order is: parse proof → catalog comparison →
       admit to pool → return → defer releases retention.)

     - (b) **Proof-stage validation failure** — any failure
       in the proof-stage path inside `handleV2Conn`:
       * SPEC-010 clause 4 catalog mismatch rejection
       * Attestation failure at server.go:403
       * Provider-ID mismatch at server.go:398
       * Auth-attempt-ID mismatch at server.go:398
       Each of these returns from `handleV2Conn`; the defer
       fires unconditionally.

     - (c) **10-minute expiry rejection** — server.go:398
       checks `s.now().After(challengeExpiresAt)` (matching
       the 10-minute window set at server.go:355
       `challengeExpiresAt := s.now().Add(10 * time.Minute)`).
       When the check rejects a late-arriving proof,
       `handleV2Conn` returns; the defer fires.

     - (d) **Pre-proof disconnect / read error / parse
       error** — provider WS disconnects before sending
       the proof frame, or the proof read fails, or the
       proof frame fails JSON parse. Each of these returns
       from `handleV2Conn` BEFORE `registerProviderSession`
       runs. The defer fires unconditionally on function
       return regardless of whether the registered-session
       handler `handleDisconnect` would have been invoked.

       **Why this is a CRITICAL contract distinction
       (C4.4 round-4 fix).** v1.3's clause 5(d) said "the
       disconnect handler MUST release the retention entry."
       The registered-session `handleDisconnect` only fires
       after `registerProviderSession` runs (which requires
       proof success). All paths in (d) above return from
       `handleV2Conn` BEFORE registration, so
       `handleDisconnect` never fires for them. An
       implementer wiring only `handleDisconnect` would
       leak retention entries on pre-proof failures. The
       auth-attempt-scoped defer is the correct primitive.

     - (e) **Challenge write failure** — if writing the
       `auth_challenge` message to the WS fails (network
       error, buffer overflow, etc.), `handleV2Conn`
       returns; the defer fires.

     No periodic background sweeper is required (v1.3's
     "or by a periodic sweeper that runs at least every
     60s" option is REMOVED per A4.2 round-4 fix). All
     cleanup is synchronous on `handleV2Conn` return via
     the defer. The 10-minute expiry timeout is enforced
     by the existing server.go:398 expiry check, NOT by
     SPEC-010-introduced timer machinery.

  Rationale: the absent-is-OK rule (clause 3) preserves
  backward compat with provider binaries that don't yet send
  SPEC-010 fields on the proof-stage frame (i.e. the common
  case for v1.4 rollout). The present-must-match rule
  (clause 4) prevents an adversary from declaring a
  permissive supported_models set on initial-stage (passing
  initial-stage validation) and a different set on
  proof-stage (smuggling capabilities past the initial
  check). The coordinator-generated retention key
  (clause 1) closes the C3.2 ambiguity: clients don't supply
  the key, so they can't poison the retention map. The
  auth-attempt-scoped defer (clause 5) closes the C4.4
  ambiguity: cleanup is co-located with the retention
  entry's lifetime owner (`handleV2Conn`), not with the
  separate post-registration session handler.

### 3.2 Heartbeat frame

`supported_models` and `publishes_supported_models` remain set at `auth`
and immutable for the lifetime of the WS connection. To change the
supported set, the provider must reconnect.

The v1.6 model-identity amendment adds `model_hash_algorithm`,
`weights_manifest_sha256`, and `weights_manifest_algorithm` alongside the
existing heartbeat `model_hash`. Their pairing, validation, and authority
semantics are defined only by §3.7. A heartbeat model change MUST be checked
against the exact signed catalog release admitted for that provider session.

Rationale: keeps heartbeat path zero-allocation; avoids racing
mid-stream capability changes with in-flight routing decisions.
SPEC-011 will add a heartbeat extension for operator-pushed
`model_id` changes, but `supported_models` mutability is out of
scope for SPEC-010 v1.0 and v1.x.

### 3.3 Coordinator: `Provider` struct extension

Go struct ([`Provider`](../phase4-coordinator/internal/pool/provider.go)
line 50) gains two fields:

```go
type Provider struct {
    ...
    ModelID                  string   `json:"model_id"`           // existing
    SupportedModels          []string `json:"-"`                  // SPEC-010, internal-only
    PublishesSupportedModels bool     `json:"-"`                  // SPEC-010, gate for §3.3
    ...
}
```

Note: both new fields have JSON tag `-` — not serialized in
default serializations. §3.3 specifies the one place
`supported_models` surfaces.

#### Rules

- **R-3.3.1** `SupportedModels` MUST be populated from the `auth`
  frame per R-3.1.5 (legacy → `[model_id]`).
- **R-3.3.2** `PublishesSupportedModels` MUST be populated from
  the `auth` frame's `publishes_supported_models` field. Default
  `false`.
- **R-3.3.3** Public coordinator `/v1/status` response MUST
  include `"supported_models": [...]` for a provider entry IF AND
  ONLY IF `PublishesSupportedModels == true`. Legacy providers
  and SPEC-010 providers that did not opt in produce
  byte-identical pre-SPEC-010 `/v1/status` output.
- **R-3.3.4** `seenModels` index
  ([provider.go:174](../phase4-coordinator/internal/pool/provider.go))
  MUST be populated from the union of `ModelID` and every entry
  in `SupportedModels`. Existing caller `ModelKnown()`
  ([provider.go:464](../phase4-coordinator/internal/pool/provider.go))
  returns `true` for any model that some provider declared
  supported. **Semantic effect of this change in v1.0 alone:** if
  the `ModelKnown` caller in
  [buyer/server.go:1027](../phase4-coordinator/internal/buyer/server.go)
  uses the result to decide between `404 model_not_found` and
  some other handling, it will now return `false` (i.e. NOT
  trigger 404) for a model that no provider has warm but some
  provider declared supported. **The buyer-facing consequence in
  v1.0 alone is that such requests fall through to the existing
  "no eligible provider" error path, which currently returns 503
  with the existing envelope.** No new error envelope is
  introduced. A 404→503 substitution for cold-supported requests
  is the only buyer-visible change v1.0 produces, and it appears
  only when at least one provider has explicitly opted in by
  sending `supported_models` with more than its `model_id`.
  Operators concerned about this substitution can keep all
  providers on the legacy auth shape (single `model_id`, no
  `supported_models`) until SPEC-012 ships a complete
  cold-supported handling story.

> **Implementation note (2026-07-11, no normative change):** R-3.3.4
> is implemented in `phase4-coordinator/internal/pool/provider.go` via
> `recordSeenModelsUnionLocked`, called at BOTH the registration site
> (`RegisterAtDetailed`) and the heartbeat site (`ApplyHeartbeat`).
> Each `SupportedModels[]` entry flows through the same
> `recordSeenModelLocked` path as `ModelID`, so it shares the served
> model_id's normalization (lowercase canonical key for the
> pool-lifetime accumulator, raw id for the per-session attribution
> set) and its lifecycle: dropped from the per-session index on
> disconnect / session-replacement (M2-5 / PERF-5) and retained
> append-only in the SPEC-002 § 7.2 lifetime accumulator for the
> coordinator process lifetime. Legacy providers carry
> `SupportedModels == [model_id]` (R-3.1.5 synthesis), so the union
> collapses to `{model_id}` and the L-1 / R-3.5.1 byte-identical
> default path is preserved. The buyer-side 404→503 flip is driven
> entirely by the existing `ModelKnown()` gate in
> `internal/buyer/server.go`. Covered by
> `TestModelKnownUnionsDeclaredSupportedModels`,
> `TestModelKnownUnionsSupportedModelsOnHeartbeat`
> (`internal/pool/provider_test.go`) and
> `TestChatCompletionsDeclaredButColdModelReturns503`
> (`internal/buyer/server_test.go`).
>
> **Follow-up (2026-07-11, codex code-lane audit of PR #555, no
> normative change):** the seen-index union above
> (`recordSeenModelsUnionLocked`) is a best-effort accumulator bounded
> by `maxSeenModelsPerProvider` (32, per-session),
> `maxLifetimeContribPerProvider` (128, per-provider lifetime), and
> `maxSeenModelsLifetime` (4096, global lifetime) — a provider whose
> declared catalog exceeds those caps could have entries silently
> dropped from the seen index, 404ing a declared model even though a
> currently-connected provider declares it. Fixed by adding a live-
> provider `SupportedModels` scan to `ModelKnown()` (alongside the
> pre-existing live `ModelID` scan), so a declared model on a
> CURRENTLY-CONNECTED provider is always known regardless of seen-
> index cap state — this is the correctness core of R-3.3.4, not an
> optional hardening. Covered by
> `TestModelKnownFindsDeclaredModelBeyondSeenIndexCaps`
> (`internal/pool/provider_test.go`) and
> `TestChatCompletionsDeclaredModelBeyondSeenIndexCapsReturns503`
> (`internal/buyer/server_test.go`).
>
> **Cross-spec reconciliation (RESOLVED 2026-07-15, runbook item 22):**
> R-3.3.4 above is `MUST` and is authoritative on this question (the more
> specific rule, matching shipped behavior — #555). The two sibling specs,
> which previously diverged, now cross-reference it: SPEC-002 R-3.X.6 was
> strengthened from `MAY` to `MUST` (SPEC-002 v1.5.4); SPEC-006 §17.2 now
> names declared `supported_models` alongside "served or recently seen" in
> the "known" list, so a declared-but-cold model is *known* and returns
> `503 no_provider_available` via §17.3, not `404 model_not_found`
> (SPEC-006 v0.9.12). The reconciliation changes no dispatch outcome —
> R-3.4.1 and SPEC-002 R-3.X.6's "MUST NOT change dispatch outcomes" both
> still hold; only the buyer error code for a declared-but-cold request on
> default routing is affected (404→503), which was already the shipped
> behavior (#555). No SPEC-010 normative text changed.

### 3.4 Router: candidate filter (semantically unchanged in v1.0)

The router (SPEC-004 v0.3.1 §4 dispatch) candidate-eligibility
predicate MAY use `SupportedModels` containment in v1.0, but the
operative effect is identical to today: a candidate must have
`ModelID == req_model` to actually serve, because v1.0 introduces
no swap mechanism.

In other words: v1.0 adds the *vocabulary* `req_model ∈
p.SupportedModels` to the router but no new dispatch *outcome*. A
buyer request for a cold-supported model still finds zero
eligible candidates (because no provider has it as `ModelID`) and
falls through to the existing no-eligible-provider error.

#### Rule

- **R-3.4.1** Router behavior under v1.0 with all defaults MUST
  be byte-identical to pre-SPEC-010 for any pool of providers.
  The candidate filter MAY internally consult `SupportedModels`,
  but no dispatch outcome changes. SPEC-011 and SPEC-012 are
  where `SupportedModels` becomes actionable.

### 3.5 Config additions

```toml
[catalog]
# Max entries accepted in supported_models per provider. Default 64.
max_supported_models_per_provider = 64
```

That is the entire SPEC-010 v1.0 config surface. No
`publish_unwarm_models`, no `cold_wake_*`, no `swap_*`. Those
configs are introduced by SPEC-011 (swap_*) and SPEC-012
(publish_unwarm_models, cold_wake_*).

#### Rule

- **R-3.5.1** With default config AND no provider sending
  `supported_models` AND no provider sending
  `publishes_supported_models: true`, coordinator behavior is
  byte-identical to pre-SPEC-010 production. This is the L-1
  guarantee made operationally testable.

### 3.6 Provider binary CLI (SPEC-001 v1.2.5 candidate)

- **R-3.6.1** Provider binary MUST gain `--supported-models <ids>`
  CLI flag (comma-separated), `MACPROVIDER_SUPPORTED_MODELS` env,
  and config-file key `supported_models: [string]`. Resolution
  priority: CLI > ENV > config (matches existing `--model`).
- **R-3.6.2** If `supported_models` is unset after resolution,
  the provider MUST send `supported_models: [model_id]`
  (single-entry). This is the wire-level equivalent of R-3.1.5.
- **R-3.6.3** After resolution, the provider MUST validate
  locally before opening the coordinator WS connection:
  - `model_id` (the warm model) MUST be in `supported_models`
    (case-folded). Mismatch → exit with code 2 and stderr
    message `"--model <X> not in --supported-models; aborting
    to avoid auth rejection"`.
  - `supported_models` length MUST be ≤ 64 and each entry ≤ 256
    bytes. Violation → exit code 2 with specific stderr message.
  - Local validation prevents the operator from hitting a remote
    coordinator rejection after a multi-second connect+auth
    round-trip.
- **R-3.6.4** Provider binary MUST gain `--publish-supported-models
  <bool>` flag (default `false`), populating
  `publishes_supported_models` in the `auth` frame.

### 3.7 Canonical model artifact identity (v1.6 amendment)

This section is the sole authority for model identity names and comparison
semantics. SPEC-023 §3.2 remains the authority for the canonical artifact-set
manifest bytes referenced below; this section does not duplicate that byte
algorithm.

- **SPEC-010-R001 — Canonical signed-snapshot identity.** The algorithm
  identifier is exactly `macprovider.snapshot-manifest.v1`. Its digest is the
  lowercase SHA-256 `model_sha256` from the exact signed candidate-catalog row,
  whose canonical bytes are defined by SPEC-023 §3.2. The CLI MUST first
  verify the downloaded snapshot against that row, then report the verified
  row digest as `model_hash`. No component may infer this algorithm from the
  presence or shape of a hash, or report a weights-only/subset digest under
  this name.

- **SPEC-010-R002 — Typed wire contract.** Provider hello, v2 auth initial,
  heartbeat, local status, safety telemetry, and Tier-2 attestation projections
  MUST keep `model_hash` paired with `model_hash_algorithm`. A modern canonical
  pair uses only `macprovider.snapshot-manifest.v1` and a 64-character
  lowercase SHA-256 digest. An explicit unknown algorithm, malformed pair, or
  algorithm without a hash MUST be rejected; the coordinator MUST NOT guess
  semantics from a hash value.

- **SPEC-010-R003 — Separate weights evidence.** Implementations MAY report
  `weights_manifest_sha256` only with
  `weights_manifest_algorithm = "macprovider.safetensors-manifest.v1"`.
  This pair identifies the sorted safetensors weights manifest used for runtime
  diagnostics. It MUST NOT substitute for, be compared with, or satisfy the
  canonical catalog artifact identity.

- **SPEC-010-R004 — Exact admitted-row authority and settlement binding.**
  Admission MUST select the expected `model_sha256` from the provider's exact
  signed current or explicitly compatible-previous catalog release and model
  row. That expected value remains session authority for later heartbeats.
  Coordinator/Tier-2 logic MUST compare only the named provider artifact
  identity with that same expected row; an independently selected catalog row
  or second catalog fallback cannot authorize it. If existing Tier-2 signed
  material is retained as proof, its expected hash MUST equal the admitted
  autotune row. Buyer route snapshots MUST bind both algorithm and digest; the
  existing receipt v0.4 transitively binds them through the signed route
  snapshot digest without adding receipt keys.

- **SPEC-010-R005 — Bounded missing-algorithm migration.** A provider that
  omits `model_hash_algorithm` MAY remain connected only before an explicit
  future RFC3339 `tier2.model_hash_legacy_until`. Its hash is untyped evidence
  and MUST NOT be compared with any catalog digest or treated as verified.
  Missing, malformed, or expired deadlines fail closed. Deploy preflight MUST
  reject a declared mixed-version bridge unless the deadline resolves and is
  in the future. Operators MUST count
  `model_hash_algorithm_legacy_bridge`, update the remaining providers, and
  remove the bridge field when the count reaches zero.

- **SPEC-010-R006 — Warm-swap identity.** Before publishing a warm-swapped
  model, the CLI MUST verify the complete target snapshot against the exact
  signed target row and atomically replace the model ID, digest, and algorithm.
  A swap with no bound signed target row, a mismatched digest, or a snapshot
  that fails SPEC-023 §3.2 validation MUST fail closed without publishing the
  new model under the prior model's identity.

---

## 4. Backward compatibility

### 4.1 Legacy provider against SPEC-010 v1.0 coordinator

- Coordinator receives `auth` with no `supported_models` and no
  `publishes_supported_models`.
- Per R-3.1.5: `SupportedModels` is synthesized as `[model_id]`.
- Per R-3.3.2: `PublishesSupportedModels` defaults to `false`.
- Per R-3.3.3: `/v1/status` for this provider is byte-identical
  to pre-SPEC-010. No new `supported_models` field appears.
- Per R-3.3.4: `seenModels` is populated from `{model_id} ∪
  [model_id]` = `{model_id}`. Identical to pre-SPEC-010.
- Per R-3.4.1: router behavior unchanged.
- Net: zero behavioral change. AC-2 verifies.

### 4.2 SPEC-010 v1.0 provider against legacy coordinator

- Provider sends `supported_models` and
  `publishes_supported_models`; legacy coordinator's
  `json.Unmarshal` ignores unknown fields by default (verify: no
  `DisallowUnknownFields()` in
  `phase4-coordinator/internal/ws/messages.go` auth parsers;
  standard Go behavior). Provider is admitted with `model_id`
  only.
- Provider's declared `supported_models` is dropped on the
  coordinator side. The provider serves its `model_id` as
  today. No errors.
- AC-9 verifies.

### 4.3 What's visible to buyers under v1.0 defaults

- `/v1/models`: byte-identical to today. v1.0 does not change
  this endpoint.
- `/v1/chat/completions`: behavior identical when buyer asks for
  a model that some provider has warm.
- Edge case: when a provider sends `supported_models` with
  entries beyond its `model_id` AND a buyer asks for one of those
  declared-but-not-warm models, the request takes the existing
  no-eligible-provider error path (see R-3.3.4 note). This is
  the only buyer-visible behavioral change and it appears only
  under explicit operator opt-in.

---

## 5. Acceptance criteria

- **AC-1** SPEC-010 provider sending `supported_models: [A, B, C]`
  with `model_id: A` and `publishes_supported_models: true`
  registers successfully. Coordinator `/v1/status` shows
  `supported_models: [A, B, C]` and `model_id: A`.
- **AC-2** Legacy provider (no `supported_models`, no
  `publishes_supported_models`) registers successfully.
  Coordinator stores `SupportedModels: [A]` internally.
  `/v1/status` for this provider is byte-identical to pre-SPEC-010
  output. No `supported_models` field appears.
- **AC-3** Provider sending `supported_models: []` (present empty
  array) is rejected with `bad_request` and reason text
  containing `"supported_models cannot be empty"`.
- **AC-4** Provider sending `supported_models: [A, B, C]` with
  `model_id: D` is rejected with `bad_request` and reason text
  containing `"model_id not in supported_models"`.
- **AC-5** Provider sending `supported_models` with 65 entries is
  rejected with `bad_request` and reason text containing
  `"supported_models exceeds 64 entries"`. Rejection log entry
  MUST NOT dump the full list.
- **AC-6** Provider sending `supported_models` with an entry > 256
  bytes is rejected with `bad_request` and reason text containing
  `"supported_models entry exceeds 256 bytes"`.
- **AC-7** Provider sending `supported_models: ["mlx-community/
  Qwen2.5-7B", "Mlx-Community/Qwen2.5-7B"]` (case-variant
  duplicate) is rejected with `bad_request` and reason text
  containing `"supported_models contains duplicate entries"`.
- **AC-8** Multi-failure validation priority: provider sends
  `supported_models: [<200×257-byte-entry>]` AND `model_id` not in
  the array. Per R-3.1.9, the FIRST failure reported is the
  per-entry byte length (step 2), NOT the empty/cap step (step 3)
  or model_id containment (step 5). Test asserts the exact reason
  string returned matches step 2.
- **AC-9** Provider binary CLI: invoking with `--model A
  --supported-models B,C` exits with code 2 and stderr message
  containing `"--model A not in --supported-models"` BEFORE
  attempting a WS connect.
- **AC-10** CLI/env/config resolution priority: provider binary
  started with `--supported-models A,B,C`, env
  `MACPROVIDER_SUPPORTED_MODELS=D,E`, config file
  `supported_models: [F]`. Effective `supported_models` is
  `[A, B, C]` (CLI wins). Same priority for
  `--publish-supported-models`.
- **AC-11** Provider sending `supported_models: [A, B]` with
  `model_id: A` and `publishes_supported_models: false` registers
  successfully. `/v1/status` for this provider MUST NOT include
  `supported_models`. `ModelKnown(B)` returns `true` (per R-3.3.4).
- **AC-12** SPEC-010 provider against a legacy (pre-SPEC-010)
  coordinator is admitted normally; the legacy coordinator
  silently ignores `supported_models` and
  `publishes_supported_models` fields. Provider operates as
  today.
- **AC-13** **L-1 byte-identical (response) + structurally
  identical (logs)**: coordinator running SPEC-010 v1.1 code with
  default config (`max_supported_models_per_provider = 64`) and
  only legacy providers in the pool produces:
  (a) Byte-identical `/v1/models` and `/v1/status` JSON responses
      compared to a pre-SPEC-010 coordinator on the same pool.
      Verified by JSON-canonical diff over a fixed-seed scenario.
  (b) **Normalized-log identity**: after stripping known
      non-deterministic fields (timestamps, ULID/UUID identifiers,
      connection-order indices, process IDs, monotonic counter
      values), the resulting log stream MUST have:
        - The same set of event-type names (no new SPEC-010-related
          event name appears on the legacy path)
        - The same severity levels per event
        - The same set of stable fields per event (no new
          `supported_models`-related field on legacy events)
        - The same total event count per scenario run
      Verified by parsing both runs into structured event records,
      applying the normalization, and diffing the sorted record
      sets. The raw byte-stream diff is NOT asserted because
      timestamps and IDs make it inherently nondeterministic across
      runs.
- **AC-14** Router behavior under v1.0 defaults is unchanged:
  buyer request for model `Z` (in no provider's `SupportedModels`
  and not warm on any provider) returns the same error envelope
  it would have pre-SPEC-010 (existing `404 model_not_found` per
  SPEC-001 §6.1).
- **AC-15** Legacy `hello` frame (not `auth_request`): provider
  on the legacy `hello` handshake sends `supported_models` and
  `publishes_supported_models`. Coordinator MUST apply R-3.1.1
  through R-3.1.9 identically; admission and `/v1/status`
  behavior are identical to the `auth_request` path.

### Added in v1.1 (round-1 audit fixes)

- **AC-16** **B.1 fix — actual `auth_request` wire shape**:
  provider sends a real `auth_request` frame with `type:
  "auth_request"`, `version: 2`, `stage: "initial"`, and the new
  `supported_models` + `publishes_supported_models` fields
  alongside the existing required fields. Coordinator's parser
  ([ws/messages.go:302-329](../phase4-coordinator/internal/ws/messages.go))
  accepts the frame and stores the fields per §3.3. Negative
  case: a frame with `type: "auth"` (the v1.0-spec example shape,
  pre-fix) MUST be rejected by the existing v2 parser BEFORE
  reaching SPEC-010 catalog validation. This AC pins the spec to
  the actual coordinator wire.
- **AC-17** **E.1 fix — R-3.1.1 non-array rejection**: provider
  sends `supported_models: "not-an-array"` (string, not array).
  Coordinator rejects with `bad_request` and reason text
  containing `"supported_models must be array of strings"`.
  Second case: provider sends `supported_models: [42, "ok"]`
  (mixed array with a non-string element); same rejection.
- **AC-18** **E.1 + B2.2 fix + D3.1 round-3 fix — R-3.1.10
  proof-stage parser + retention contract**: six sub-cases
  covering all 5 R-3.1.10 clauses:

  (a) **Absent proof-stage `supported_models` is NOT a
      mismatch (R-3.1.10 clause 3)**: provider sends
      `initial`-stage with `supported_models: [A, B, C]`;
      proof-stage `auth_request` omits `supported_models`
      entirely (legacy proof shape). Coordinator MUST accept
      and proceed; `Provider.SupportedModels` populated from
      the retained initial-stage values. No warning.
      `publishes_supported_models` absent on proof tested
      identically.

  (b) **Present matching proof-stage `supported_models` is OK
      (R-3.1.10 clauses 2 + 4)**: same initial-stage;
      proof-stage carries `supported_models: [a, b, c]`
      (case-variant of initial). After NFC + ASCII fold per
      R-3.1.7, the normalized sets are equal. Coordinator
      MUST accept. Test asserts both fields (`supported_models`
      and `publishes_supported_models`) are READ off the
      proof frame by the extended parser, not silently
      dropped.

  (c) **Present mismatching proof-stage rejected (R-3.1.10
      clause 4)**: same initial-stage; proof-stage carries
      `supported_models: [A, B]` (one fewer entry).
      Coordinator MUST reject proof-stage frame with
      `bad_request` and reason text containing
      `"supported_models mismatch between auth_request
      stages"`. Retained initial-stage values are released
      per clause 5(b).

  (d) **Retention creation on initial-stage success
      (R-3.1.10 clause 1)**: after a successful
      `parseAuthInitial` for a SPEC-010 provider, the
      coordinator-internal retention map MUST contain an
      entry keyed by the coordinator-generated
      `authAttemptID` (server.go:354 format `"auth-" +
      UUID`). The entry contains the parsed
      `supported_models`, `publishes_supported_models`,
      `provider_id`, and a start timestamp. **Test access
      (D4.1 round-4 fix):** the implementation MUST expose
      a package-internal test accessor (e.g. unexported
      `retentionLookup(authAttemptID) -> (entry, bool)` in
      `phase4-coordinator/internal/ws/` reachable from
      `_test.go` files within the same package). No
      production debug endpoint is required. Test asserts
      retention entry existence via this accessor
      immediately after the `auth_challenge` is emitted.

  (e) **Cleanup on success (R-3.1.10 clause 5(a))**: after
      AC-18(b) successful completion, the retention map MUST
      NO LONGER contain the entry for that
      `authAttemptID`. Cleanup also tested for clause 5(b)
      failure path (asserted via AC-18(c) — retention
      released after mismatch rejection) and for clause 5(c)
      timeout path: inject `s.now()` returning a value 11
      minutes after `challengeExpiresAt`; provider sends a
      late-arriving proof frame; test asserts (a) server.go:398
      rejects with expiry error, AND (b) the retention
      entry is released synchronously on `handleV2Conn`
      return (NOT via background sweep — v1.4 removed the
      sweep option per A4.2).

  (f) **Cleanup on disconnect-before-proof (R-3.1.10 clause
      5(d) — defer-based)**: provider sends valid initial-
      stage frame; coordinator emits `auth_challenge` and
      installs `defer releaseRetention(authAttemptID)`;
      retention entry created. Provider's WebSocket
      disconnects BEFORE sending the proof-stage frame.
      `handleV2Conn` returns due to read error; the defer
      fires synchronously. Test asserts retention entry is
      released by the time `handleV2Conn` returns (no
      polling needed — synchronous via defer).

      **Bounded-state assertion with explicit baseline
      (D4.3 round-4 fix; D5.3 round-5 fix — deterministic
      harness join).** "Baseline" is defined as the
      pre-test retention map size for the specific
      coordinator instance under test. The test MUST:
      1. Record baseline = `retentionMapSize()` before any
         test-induced auth attempts.
      2. Spawn 100 partial auth-attempt goroutines tracked
         by a `sync.WaitGroup` (or equivalent join
         primitive). Each goroutine: connects, sends valid
         initial-stage frame, awaits `auth_challenge`,
         disconnects WS, allows the coordinator's
         `handleV2Conn` to return, then signals
         `WaitGroup.Done()` from the test-side cleanup
         when the corresponding handler goroutine has
         joined (via test-only `handlerJoined(authAttemptID)`
         hook that fires on `handleV2Conn` return).
      3. Optionally subtract or isolate any concurrent
         unrelated in-flight auth attempts (e.g. by running
         the test against a coordinator instance with no
         other connected clients).
      4. `WaitGroup.Wait()` to deterministically join all
         100 handler goroutines.
      5. Assert `retentionMapSize() == baseline` with NO
         timeout-based slack. The defer is synchronous per
         clause 5(d); if the wait-group join completes,
         every defer has already fired. A test-harness
         timeout MAY exist as a sanity-check upper bound
         on the WaitGroup wait itself (e.g. 30s deadline
         to fail fast on a deadlock), but it is a harness
         deadline, NOT a cleanup-semantics allowance.

      No oldest-evict logic is exercised because the
      defer-based cleanup keeps the map bounded by
      `ws.max_unauthenticated_conn` (default 64) at any
      given moment (per clause 1 cap note).
- **AC-19** **E.1 fix — R-3.6.2 binary default emission**:
  provider binary started with `--model A` and NO
  `--supported-models` flag, NO `MACPROVIDER_SUPPORTED_MODELS`
  env, NO `supported_models` config key. Wire capture of the
  outbound `auth_request` MUST show `supported_models: ["A"]`
  (single-entry, matching `--model`). Coordinator-side state
  for this provider MUST have `SupportedModels = ["A"]` per
  R-3.3.1.
- **AC-20** **E.1 fix — R-3.6.3 binary-side length validation**:
  invoking `macprovider --model A --supported-models "A,A,A,...,A"`
  with 65 entries MUST exit code 2 BEFORE WS connect with stderr
  containing `"supported_models exceeds 64 entries"`. Separate
  case: a single entry of 257 ASCII bytes MUST exit code 2 with
  stderr containing `"supported_models entry exceeds 256 bytes"`.
  Both messages match the coordinator-side reason strings in
  R-3.1.9 verbatim so operators see identical text whether the
  failure is local or remote.
- **AC-21** **E.1 fix — R-3.6.4 publish flag emission**: provider
  binary started without `--publish-supported-models` and with no
  env/config override MUST emit `publishes_supported_models:
  false` (or omit the field entirely; both are wire-equivalent
  per R-3.1.6 and R-3.3.2). When started with
  `--publish-supported-models true`, the field MUST appear as
  `true` in the outbound `auth_request`. The /v1/status field
  presence in §3.3.3 MUST match accordingly.
- **AC-22** **E.3 fix — multi-failure validation priority,
  step-1-vs-step-5**: provider sends `supported_models:
  "not-an-array"` AND `model_id: "Z"`. Both R-3.1.1 (step 1
  type check) and R-3.1.4 (step 5 containment) would fail. Per
  R-3.1.9 ordering, the coordinator's rejection MUST cite step 1
  (`"supported_models must be array of strings"`), NOT step 5.
- **AC-23** **E.3 fix — multi-failure validation priority,
  step-4-vs-step-5**: provider sends `supported_models:
  ["A", "a"]` (case-variant duplicate after NFC + ASCII fold)
  AND `model_id: "Z"`. Both R-3.1.7+R-3.1.9 step 4 (duplicate)
  and R-3.1.4 step 5 (containment) would fail. Per R-3.1.9
  ordering, the coordinator's rejection MUST cite step 4
  (`"supported_models contains duplicate entries"`), NOT step 5.

---

## 6. Companion-spec annotations (vNEXT candidates)

These are NOT modifications to locked specs. They describe what
SPEC-001 v1.2.5 and SPEC-002 v1.3.5 would need to add to fully
house SPEC-010 v1.2.

**Important framing change in v1.2 (B.1 round-2 / B2.1 fix):**
v1.1 used phrasing like "extend the existing v2 auth_request
initial-stage" in these candidate annotations. Round-2 audit
established that **no locked spec normatively documents the v2
`auth_request` flow** — both SPEC-001 §6.5 and SPEC-002 §7.1
document the legacy `hello` handshake. So §6.1 and §6.2 below
are correctly framed as **"the candidate spec MUST ADD the v2
`auth_request` contract as new normative text"**, not as
"extending existing text that already documents v2." Until those
candidates land, SPEC-010 §3.1.A is the source of truth for the
v2 contract as it interacts with SPEC-010.

### 6.1 SPEC-001 v1.2.5 candidate (provider binary)

SPEC-001 v1.2.5's BUILD prompt MUST cite SPEC-010 v1.x locked §3.1 and
§3.6 as the binding source-of-truth for this change. Concretely:

- §6.2: gain CLI `--supported-models`, env
  `MACPROVIDER_SUPPORTED_MODELS`, config key `supported_models`.
  CLI > ENV > config priority per R-3.6.1.
- §6.2: gain CLI `--publish-supported-models <bool>` (default
  `false`) per R-3.6.4.
- **NEW §6.5 (v2 `auth_request` handshake — NEW normative
  section).** SPEC-001 v1.2.4's current §6.5 documents the
  legacy `hello` handshake. SPEC-001 v1.2.5 MUST ADD a new
  normative section (likely §6.5.2 or §6.6) documenting the v2
  two-stage `auth_request` handshake with `initial` and `proof`
  stages, including the field set per SPEC-010 §3.1.A and the
  proof-stage retention/comparison contract per R-3.1.10. This
  is a SPEC-001 normative addition driven by the SPEC-010 BUILD
  pass — the v2 contract has been in code since v1.2.x but was
  never normatively documented.
- The two SPEC-010-added fields (`supported_models[]` and
  `publishes_supported_models: bool`) are documented as part of
  the new v2 section above. They are NOT applicable to the
  legacy `hello` handshake (the SPEC-010 fields MAY appear on
  `hello` per R-3.1.8 with identical semantics).
- Local pre-flight validation per R-3.6.3 (mismatch model_id vs
  supported_models exits with code 2 before WS connect; specific
  stderr messages per failure class per R-3.1.9 reason text).
- No binary-side `/v1/models` change (the local-only single-entry
  response stays as today).
- NOTE: the v2 `auth_request` handshake is NOT the buyer HTTP
  API; the binary serves no buyer requests on the
  `auth_request` path.

### 6.2 SPEC-002 v1.3.5 candidate (coordinator)

- **NEW §7.1.2 or §7.4 (v2 `auth_request` provider handshake —
  NEW normative section).** SPEC-002 v1.3.4's current §7.1
  documents the legacy `hello` provider handshake; §7.2 is the
  buyer HTTP API; §7.3 is token/auth. SPEC-002 v1.3.5 MUST ADD
  a new normative section documenting the v2 two-stage
  `auth_request` handshake (initial + proof) with the full field
  set per SPEC-010 §3.1.A. v1.1 mistakenly framed this as
  "extending §7.1" — that section documents `hello`, not
  `auth_request`. v1.2 (this revision) reframes.
- Within the new v2 section: gain optional `supported_models[]`
  and `publishes_supported_models: bool` on the initial-stage
  frame per SPEC-010 §3.1.B.
- Within the new v2 section: document the proof-stage parser
  contract per SPEC-010 R-3.1.10 (absent = OK; present must
  match initial-stage with NFC + ASCII case-fold comparison).
- **NEW §7.4 or sub-section (auth-attempt lifecycle —
  A3.2 round-3 fix).** SPEC-002 v1.3.4 does NOT currently
  document the auth-attempt lifecycle as a normative
  contract. Implementation timers exist at
  [server.go:354-355](../phase4-coordinator/internal/ws/server.go)
  (10-minute `challengeExpiresAt`) but are not specified
  normatively. SPEC-002 v1.3.5 MUST ADD a normative
  auth-attempt lifecycle section covering:
  - Initial-stage parse → coordinator generates `authAttemptID`
  - Coordinator emits `auth_challenge` carrying the generated
    ID with an explicit expiry timestamp
  - Coordinator retains per-attempt state (including SPEC-010
    R-3.1.10 retention entries when applicable) keyed by the
    generated ID
  - Per-attempt state MUST be released on: successful
    completion, proof-stage rejection, expiry timeout, or
    WebSocket disconnect-before-proof
  - Timeout bound: 10 minutes (matching current
    `challengeExpiresAt`). Implementations SHOULD also bound
    aggregate retention map size as a defensive safeguard.

  Until SPEC-002 v1.3.5 lands, SPEC-010 R-3.1.10 clauses 1
  and 5 ARE the source of truth for the auth-attempt
  retention lifecycle as it interacts with SPEC-010.
- §3 provider state machine: NO change. v1.3 introduces no
  new states or sub-states.
- §5 routing: NO behavior change. v1.3 may add the
  `req_model ∈ SupportedModels` predicate internally per
  R-3.4.1 but it produces no dispatch outcome change.
- §11 audit-log: NO new event types in v1.3.
- `Provider` struct extension per SPEC-010 §3.3.
- `/v1/status` opt-in echo per SPEC-010 R-3.3.3.

### 6.3 SPEC-008 v0.3 interaction

NONE. v1.2 does not surface cold-supported models to buyers,
does not change `/v1/models` aggregation, and does not introduce
any new routing-eligible state. SPEC-008 §5.7 hash block is
unaffected.

### 6.4 SPEC-005 interaction

NONE. v1.2 does not touch the request_log, settlement ledger,
or any billing path.

### 6.5 SPEC-004 interaction

NONE in normative behavior. v1.2 makes a `SupportedModels`
predicate available for SPEC-011 / SPEC-012 to consume.

---

## 7. Open questions

- **OQ-1** _RESOLVED 2026-06-26 (`docs/OPEN_QUESTIONS.md` triage): closed — preserve-case shipped (`phase3-binary/Sources/MacProviderCore/Config.swift:251`) and produced no buyer-dashboard signal in 6+ months._ Should `/v1/status.supported_models` per-entry echo
  preserve the provider's chosen case (R-3.1.7's "wire format
  preserves case") or always normalize? v1.0 chooses
  preserve-case to give operators a way to spot
  case-normalization issues in their config; reconsider if
  buyer-side dashboards demand consistency.
- **OQ-2** _RESOLVED 2026-06-26 (`docs/OPEN_QUESTIONS.md` triage): closed — SPEC-011 and SPEC-012 shipped without adding the counter, so the punt landed nowhere. Revisit only if operator observability genuinely needs the metric._ Should the coordinator log a counter
  (`spec010_providers_with_supported_models`) at admission for
  operator metrics? Currently no — v1.0 produces no new log
  events to preserve L-1. SPEC-011/SPEC-012 can add metrics as
  they need them.

---

## 8. Out of scope (explicit, with successor spec)

| Feature | Successor spec | Why deferred |
|---|---|---|
| Provider binary async load + local `models switch` CLI | **SPEC-011** | Needs binary-side runtime changes; ships on SPEC-001 v1.2.5+ |
| Coordinator → provider `set_model` wire | **SPEC-012** | Couples to demand-pull; needs cold-wake queue + cooldown design |
| Buyer-facing `/v1/models` aggregation with `warm: bool` | **SPEC-012** | Requires SPEC-008 v0.4 normative edit to §5.7 hash block |
| `503 model_not_warm` envelope | **SPEC-012** | Only meaningful if cold-supported is buyer-visible |
| `/v1/status.state` field with `loading`/`ready`/`down` | **SPEC-012** | Only meaningful when swap state exists on coordinator side |
| Recommended catalog (`GET /v1/recommended-catalog`) | **SPEC-013** (future) | Closes pain #4 (HF ID discovery) |
| Multi-model serving in a single provider process | (none planned) | Architectural; L-3 |
| Catalog signing | (none planned) | Phase 3+ |

---

## 9. References

- [SPEC-001 v1.2.4](SPEC-001-phase3-binary.md) §6.1, §6.2, §6.5
- [SPEC-002 v1.3.4](SPEC-002-coordinator.md) §3, §5, §7.1
  (provider WS — legacy `hello`), §7.3 (token/auth), §11.
  NOTE: v1.3.4 does NOT normatively document the v2
  `auth_request` flow that SPEC-010 §3.1 binds to; the SPEC-002
  v1.3.5 candidate per §6.2 above MUST ADD that section
- [SPEC-004 v0.3.1](SPEC-004-smart-router.md) §4
- [SPEC-008 v0.3](SPEC-008-tier2.md) (no interaction — see §6.3)
- [SPEC-012 coordinator demand-pull draft](SPEC-012-coordinator-demand-pull.md)
  — retained unique coordinator-driven contract
- [SPEC-012 split history](../docs/spec-history/SPEC-012-v0.3-history.md)
  — wide-scope predecessor and split rationale
- [SPEC-012 source audit history](../audits/spec-012/SPEC-012-source-audit-history.md)
  — rounds 1-3 against the wide-scope v0.1, v0.2, v0.3
- [phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift](../phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift)
- [phase4-coordinator/internal/ws/messages.go](../phase4-coordinator/internal/ws/messages.go)
- [phase4-coordinator/internal/pool/provider.go](../phase4-coordinator/internal/pool/provider.go)
- [phase4-coordinator/internal/buyer/server.go](../phase4-coordinator/internal/buyer/server.go)
  lines 1027-1030 (ModelKnown caller — see R-3.3.4 note)
- arm64golf canary run, 2026-06-05 (trigger)
- Decision-log Entry 21 (no premium positioning), Entry 35
  (SPEC-004 Pillar B dispatch-rewrite)
