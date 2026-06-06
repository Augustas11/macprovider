# SPEC-011 v0.2 — Audit Report (round 1 normative)

Date: 2026-06-06
Spec under audit: `specs/SPEC-011-operator-pushed-warm-swap.md` (v0.2)
Audit prompt: `specs/AUDIT_SPEC_011_V0_2_PROMPT.md`
Sibling audits read: `specs/SPEC-011-outline-audit.md` (pre-draft outline rounds 1-2)
Total findings: 10 (2 CRITICAL, 5 MAJOR, 3 MINOR, 0 QUESTION)

## Executive summary

SPEC-011 v0.2 is substantially closer to implementable normative shape than the two outline drafts: the state-machine split, reconnect flow, SPEC-002 replacement annotation, concurrent-switch behavior, and observation-only audit posture all reflect prior audit feedback.

The draft is not yet ready to lock. The highest-risk problems are code-grounded: the default control socket path uses `$XDG_RUNTIME_DIR`, which is not a macOS runtime invariant, and the no-switch compatibility path contradicts locked L-1 by allowing new heartbeat fields in the byte-identical default case. The draft also contains several exact-contract mismatches: control-socket frames are shown with and without `type`, new 503 examples are not full SPEC-001 OpenAI error envelopes, `model_hash` is specified with a `sha256:` prefix while SPEC-008 and current Swift code use raw lowercase hex, and the reconnect `hello.model_hash` source is incorrectly attributed to locked SPEC-001/SPEC-002 text rather than current code plus SPEC-008 candidate text.

Recommended v0.3 direction: preserve the current scope and architecture, but patch exact wire/path/hash/error contracts before implementation. Do not loosen L-1 to fit AC-18; make AC-18 prove the locked default behavior instead.

## Category A — Locked-decision preservation

### A.1 No-switch heartbeat fields contradict locked L-1 [CRITICAL]

Location: `SPEC-011-operator-pushed-warm-swap.md` §2 L-1 lines 100-102, §3.3.2-§3.3.4 lines 386-405, AC-18 lines 888-902.

What: L-1 says a provider that never invokes `models switch` must produce "zero new coordinator events, zero new heartbeat fields, and byte-identical default behavior." AC-18 then permits a non-swapping SPEC-011 provider to emit heartbeats carrying `loading:false` and `model_hash`.

Why: This is a direct violation of a locked decision. It also creates the same class of rollout risk the audit prompt calls out: a default/no-op provider upgrade changes coordinator-observed wire shape even when the operator never uses warm swap.

Recommendation: Keep L-1 strict. Change AC-18 so the no-switch/default path asserts no SPEC-011 heartbeat fields at all. If legacy-tolerance testing for `loading`/`model_hash` is still desired, make it a separate opt-in compatibility AC that does not claim byte-identical default behavior.

## Category B — Wire-format correctness

### B.1 Control-socket examples disagree on whether `type` is required [MAJOR]

Location: `SPEC-011-operator-pushed-warm-swap.md` §3.1.2 step 4 lines 157-168 and §3.1.5 lines 205-216.

What: The `models switch` sequence shows `switch_request{target_model_id:<X>}` and untyped acknowledgement/rejection objects. The protocol definition later requires newline-delimited JSON messages with `type:"switch_request"` and `type:"switch_ack"`.

Why: This is a new local wire contract. If implementers or tests follow the step-by-step sequence, one side may omit `type` while the parser requires it, or the parser may accept shapes the normative protocol did not intend.

Recommendation: Rewrite §3.1.2 to use the exact §3.1.5 message shapes, including `type`, `requested_at_ms`, and response fields. Add an acceptance test that sends parser-valid control-socket frames and rejects ambiguous untyped frames.

### B.2 New 503 examples are not full SPEC-001 error envelopes [MAJOR]

Location: `SPEC-011-operator-pushed-warm-swap.md` §3.2.3 lines 281-287 and §3.4.2-§3.4.4 lines 459-480; `SPEC-001-phase3-binary.md` §6.2 lines 943-946.

What: SPEC-011 defines `provider_loading` and `swap_drain_timeout` examples as abbreviated objects containing only `error.type` and `error.code`. SPEC-001 requires all error responses to use the OpenAI-compatible envelope with `message`, `type`, `param`, and `code`.

Why: Error body shape is externally observable by buyers and SDKs. An abbreviated normative example can produce incompatible implementations even if the HTTP status code is correct.

Recommendation: Define the exact 503 bodies for both errors with `message`, `type`, `param:null`, and `code`. Update AC-5 and AC-7 to assert the complete response body, not only status and code.

## Category C — Code-grounding and implementation match

### C.1 Default control socket path uses a non-macOS runtime invariant [CRITICAL]

Location: `SPEC-011-operator-pushed-warm-swap.md` §3.1.4 lines 191-198, §3.1.5 lines 200-204, and §3.9.1 lines 662-667. Spot-check: `printenv XDG_RUNTIME_DIR` returned unset in the current macOS-hosted workspace.

What: The default local state and control socket paths are specified under `$XDG_RUNTIME_DIR/macprovider-cli/...`.

Why: The target provider binary is a macOS CLI. `$XDG_RUNTIME_DIR` is a freedesktop/Linux convention and is not a reliable macOS default. A literal implementation can produce an invalid or empty-prefix path, leaving `models switch` and `models status` unable to find the running provider.

Recommendation: Use a macOS-native default such as `FileManager.default.temporaryDirectory` / `$TMPDIR/macprovider-cli/ctl.sock` for the socket and a private user-state directory for durable cooldown state, with mode constraints on the containing directory and socket. Keep `--ctl-socket-path` as an override.

### C.2 Reconnect `hello.model_hash` source is attributed to locked SPEC-001 text that does not contain it [MAJOR]

Location: `SPEC-011-operator-pushed-warm-swap.md` §3.8.3 lines 619-637; `SPEC-001-phase3-binary.md` §6.5 lines 1024-1041; `SPEC-002-coordinator.md` §7.1 lines 1654-1674; `phase4-coordinator/internal/ws/messages.go` lines 8-15; `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift` lines 675-697.

What: SPEC-011 says `hello` may carry `model_hash` "per current SPEC-001 §6.5." Locked SPEC-001 and SPEC-002 hello schemas do not include `model_hash`. Current code does: the Go `Hello` struct has `ModelHash`, and Swift `helloMessage` emits `model_hash` when present. SPEC-008 §5.4 also has a SPEC-001 v1.3 candidate annotation for this field.

Why: This is source-of-truth drift. An implementer reading locked specs cannot reconstruct the reconnect contract, while an implementer reading code can.

Recommendation: Reword §3.8.3 to cite current code and SPEC-008 §5.4 candidate text, or add an explicit SPEC-001 companion annotation for `hello.model_hash`. If the draft does not want to normatively depend on hello hash, make reconnect wait for the first post-reconnect heartbeat hash instead.

### C.3 `model_hash` format conflicts with SPEC-008 and current Swift output [MAJOR]

Location: `SPEC-011-operator-pushed-warm-swap.md` §3.3.1 lines 381-384 and §3.6.5 lines 554-559; `SPEC-008-tier2.md` §5.3 lines 679-693 and §5.4 lines 697-718; `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` lines 294-325.

What: SPEC-011 requires heartbeat `model_hash` to be `"sha256:" + 64-char-lowercase-hex` and uses `sha256:...` examples in audit payloads. SPEC-008 requires providers to report lowercase hex SHA-256 without a prefix, and its hello example is a 64-character lowercase hex string. Current Swift code returns `hexString(SHA256.hash(data: data))` directly.

Why: Hash format participates in Tier-2 catalog verification. A prefix mismatch can make an otherwise correct provider appear `hash_invalid` or force special-case parsing in the coordinator.

Recommendation: Align SPEC-011 to SPEC-008 and current code: use raw 64-character lowercase hex for `model_hash` everywhere, including heartbeat fields and `operator_model_swap` audit examples. If a prefixed form is desired, first change SPEC-008 and code in a separate locked-spec revision.

Code facts verified as non-findings:

- `phase4-coordinator/internal/ws/messages.go` lines 121-135: current `Heartbeat` has no `model_hash` or `loading`, matching the draft's replacement premise.
- `phase4-coordinator/internal/pool/provider.go` lines 411-432: current `ApplyHeartbeat` clears `ModelHash` and resets hash status on `ModelID` change, matching the draft's §6.2 replacement target.
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` lines 25-68 and 86-147: `ModelRuntime` is an immutable single-model actor today, matching the draft's refactor premise.
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift` lines 1-16: no existing `models` subcommand conflicts with the proposed CLI namespace.

## Category D — Acceptance criteria and testability

### D.1 Several normative rules lack direct acceptance coverage [MAJOR]

Location: `SPEC-011-operator-pushed-warm-swap.md` §3.1.3 lines 187-189, §3.1.4-§3.1.5 lines 191-216, §3.2.7 lines 350-354, §3.7.3 lines 598-604, §3.9.1 lines 671-675, and §5 lines 738-933.

What: The AC set does not directly test all externally observable MUSTs and defaults. Missing coverage includes: `--force` suppresses only the CLI cooldown, exact control-socket frame parsing, CLI state-file cooldown behavior, boot path remains non-loading, runtime cooldown versus CLI cooldown distinction, and config range validation for `swap_drain_timeout_seconds`.

Why: These are not editorial details. They define operator-visible behavior, local wire compatibility, and rollout safety. A v0.3 implementer can satisfy the current 20 ACs while still violating one of these normative rules.

Recommendation: Add targeted ACs for each listed rule. At minimum, include one AC for `--force`/cooldown semantics, one for parser-valid control-socket frames, one for boot/no-loading/no-new-heartbeat behavior, and one for `swap_drain_timeout_seconds` validation.

### D.2 AC-20 negative privacy checks are too string-grep dependent [MINOR]

Location: `SPEC-011-operator-pushed-warm-swap.md` §3.6.5 lines 561-564 and AC-20 lines 928-931; `SPEC-006-buyer-api.md` §F-1.5 lines 161-182.

What: AC-20 relies on JSON-key scans plus content grep for `conv:`, `account_id`, buyer prompt text, and sticky identifiers.

Why: The audit payload schema itself is clean, but the AC can miss renamed raw identifiers, raw buyer tags, nested metadata, or sticky inputs that do not contain those exact strings.

Recommendation: Keep the grep checks, but add an allowlist assertion for permitted audit keys and value classes. Include fixture values for raw buyer tag, raw account ID, sticky headers, and prompt text, and assert none can appear under any key.

## Category E — Companion-spec annotations

### E.1 Billing interaction overstates `request_log` non-involvement [MINOR]

Location: `SPEC-011-operator-pushed-warm-swap.md` §6.4 lines 1025-1029; `SPEC-005-billing.md` fixture lines 2126-2132.

What: §6.4 says SPEC-011 "does not touch request_log, settlement ledger, operator ledger, or billing hot path semantics." SPEC-005 already has a 503 fixture where no ledger rows are written, but the state is still counted through `request_log` with no provider assignment.

Why: L-5 is correctly ledger/billing-focused, but `request_log` is not the same as billing mutation. For 503 warm-swap outcomes, the intended invariant should be no buyer debit and no provider/operator ledger rows, not necessarily absence from request logging.

Recommendation: Change §6.4 to say SPEC-011 introduces no new billing or ledger semantics and no new provider credit path. Clarify that existing request logging of terminal 503 attempts remains governed by the request-log/billing specs.

### E.2 SPEC-001 companion section numbering collides with existing §6.6 [MINOR]

Location: `SPEC-011-operator-pushed-warm-swap.md` §6.1 lines 953-966; `SPEC-001-phase3-binary.md` §6.6 lines 1286-1300.

What: §6.1 says SPEC-001 should gain a "NEW §6.6 or §6.7 runtime..." section, but locked SPEC-001 already has §6.6 for inference message types. The later proposed §6.8 and §6.9 numbering then becomes unstable.

Why: This is not a behavior bug, but companion annotations are supposed to be easy to apply without creating editorial conflicts.

Recommendation: Use non-conflicting candidate labels, such as "new subsection after current §6.6" or explicit §6.7+ numbering after checking the locked SPEC-001 table of contents.

## Category F — Scope discipline vs SPEC-012

(no findings)

Spot-check: `SPEC-012-source.md` owns coordinator-pushed `set_model`, cold wake, parked queue, `/v1/models` warm flags, `model_not_warm`, and `/v1/status.state=loading` surfaces. SPEC-011 v0.2 stays on the operator-pushed warm-swap side and does not smuggle those surfaces into this draft.

## Category G — Operator UX and failure modes

(no findings)

The core UX decisions from the outline audit are preserved: explicit `models switch`, no implicit catalog writes, non-blocking status, rejection on concurrent switch, and audit-only observability for operator actions. The blocking UX issue is covered above as C.1 because it is a platform-path rollout risk, not a product-flow disagreement.

## Category H — Anything else

(no findings)

Decision-log spot-check: `beta/DECISION_CRITERIA.md` Entry 21 reinforces that this product line should not grow billing or premium-positioning semantics from model availability work. SPEC-011's L-5 and SPEC-012 boundary are consistent with that direction. Add a decision-log entry only when SPEC-011 is accepted, not during this audit.

---

## Round 2 — Codex GPT-5 — 2026-06-06

**Audited:** SPEC-011 v0.3 (specs/SPEC-011-operator-pushed-warm-swap.md)  
**Auditor model:** Codex / GPT-5  
**Audit round:** 2 of N (normative)  
**Date:** 2026-06-06  
**Total findings:** 6 (0 CRITICAL / 2 MAJOR / 4 MINOR / 0 QUESTION)

### Round-2 executive summary

SPEC-011 v0.3 closes the two round-1 CRITICALs in substance but is not ready to LOCK directly. The `--enable-warm-swap` gate is now load-bearing and mostly complete: default serve mode omits the new heartbeat fields, does not open the control socket, and keeps the state machine dormant. The macOS path fix is also directionally correct: `$TMPDIR` is set in this workspace (`/tmp/claude-501`), Swift `FileManager.default.temporaryDirectory` returned the same writable path, and the launchd template explicitly sets `HOME`, making the Application Support cooldown path realistic for the repo's launchd flow.

Two MAJOR contract drifts still block locking. First, the round-1 B.1 control-frame fix did not fully rewrite §3.1.2: the step-by-step switch flow still shows untyped `switch_request` / `switch_ack` shorthand even though §3.1.5 later defines `type` as required on every frame. Second, §3.9 still lists `--ctl-socket-path` defaulting to `$XDG_RUNTIME_DIR/macprovider-cli/ctl.sock`, contradicting the new macOS-native §3.1.5 default. These are exact normative surfaces an implementer can follow.

Verdict: v0.3 is ready after the round-2 findings are closed, not lock-ready as written. No new CRITICAL was found, but with 2 MAJOR findings a v0.4 fix pass should be drafted and rechecked narrowly.

### Round-1 fix verification (R1V)

| ID | Round-1 finding | v0.3 location verified | Status | Evidence |
|---|---|---|---|---|
| R1V-A.1 | L-1 violation via heartbeat fields | L-1 lines 172-174; R-3.1.0 lines 204-225; R-3.3.0 lines 559-565; AC-18 lines 1132-1155 | PARTIAL | The opt-in gate closes the wire-shape CRITICAL in substance, and code still lacks heartbeat `model_hash` / `loading` fields today (`messages.go` lines 121-135), but AC-18 does not cover every L-1 observable and the disabled/no-serve CLI detection remains under-specified. |
| R1V-B.1 | Control socket frame `type` consistency | R-3.1.5 lines 318-394; §3.1.2 lines 254-264 | PARTIAL | Every §3.1.5 frame example now has `type`, but §3.1.2 still normatively shows untyped request/ack shorthand and omits `requested_at_ms`. |
| R1V-B.2 | 503 envelopes not full SPEC-001 | R-3.4.2 lines 651-672; R-3.4.4 lines 683-706 | PASS | Both 503s now include OpenAI-shaped `error.message`, `error.type`, `error.param`, and `error.code`; `provider_loading` also carries `Retry-After` and `retry_after_seconds` where a retry estimate exists. |
| R1V-C.1 | `$XDG_RUNTIME_DIR` on macOS | R-3.1.5 lines 302-316; R-3.1.4 lines 288-300; §3.9 lines 904-911 | PARTIAL | The main socket and cooldown rules moved to `$TMPDIR` and `$HOME/Library/Application Support`, and code-grounding passed, but §3.9 still advertises the old `$XDG_RUNTIME_DIR` default. |
| R1V-C.2 | `hello.model_hash` citation drift | R-3.8.3 lines 842-879; `messages.go` lines 8-15; `CoordinatorClient.swift` lines 675-697; SPEC-008 lines 695-718 | PASS | v0.3 correctly cites current Go/Swift code and the SPEC-008 §5.4 candidate annotation instead of claiming locked SPEC-001/SPEC-002 already define the field. |
| R1V-C.3 | `model_hash` format mismatch | R-3.3.1 lines 567-575; §3.6 lines 746-754; AC-20 lines 1179-1180; Swift `hexString` lines 340-341 | PASS | All normative examples use raw lowercase hex; no live `sha256:` example remains outside the change-log description of the removed v0.2 form. |
| R1V-D.1 | Missing AC coverage | AC-21 through AC-25 lines 1199-1259 | PARTIAL | Five ACs were added, but AC-23 depends on an undefined debug hook and AC-25 has a unit typo in its lower-bound case. |
| R1V-D.2 | AC-20 grep too permissive | AC-20 lines 1169-1197; R-3.6.1/R-3.6.2 lines 763-771 | PASS | AC-20 now has a positive top-level key allowlist that matches the §3.6 schema plus planted negative fixtures for buyer/sticky leakage. |
| R1V-E.1 | §6.4 overstates `request_log` | §6.4 lines 1365-1391; SPEC-005 lines 225-245 and 516-524 | PASS | v0.3 now says SPEC-011 inherits existing request_log behavior for 503 outcomes and does not change ledger/billing semantics. |
| R1V-E.2 | SPEC-001 §6.6 numbering collision | §6.1 lines 1270-1307; SPEC-001 lines 1286-1300 | PASS | §6.1 uses §6.7+ candidate numbering after the locked SPEC-001 §6.6 inference-message section. |

### Category A2 — Opt-in gate completeness

#### R2-A2.1 Disabled/no-serve control-socket detection is under-specified [MINOR]

Location: `SPEC-011-operator-pushed-warm-swap.md` R-3.1.0 lines 204-220; R-3.1.1 lines 227-239; R-3.1.2 lines 250-253; R-3.1.5 lines 318-322.

What: R-3.1.0 says any `models <subcommand>` invocation detects disabled warm swap via control-socket absence and exits code 4 with `"warm swap not enabled; restart serve with --enable-warm-swap"`, but R-3.1.1 says `models list` with no serve process exits 0, and R-3.1.2 says connection failure exits code 4 with `"macprovider-cli serve is not running on this host"`.

Why: A disabled serve process, no serve process, and stale/unreachable socket can all present as "no usable control socket." The spec does not define how the CLI distinguishes those states, so the A.1 fix is behaviorally correct but operationally ambiguous at the CLI boundary.

Recommendation: Add a short detection rule: define the exact precedence for no serve vs disabled serve vs stale socket, and state whether the CLI may use a pid/lock file, socket handshake error, or process probe to distinguish them.

#### R2-A2.2 AC-18 still does not assert every L-1 default observable [MINOR]

Location: `SPEC-011-operator-pushed-warm-swap.md` L-1 line 174; §4.3 lines 953-968; AC-18 lines 1132-1155.

What: AC-18 now checks heartbeat JSON shape, default socket absence, `models list`, audit events, hash-clearing behavior, and normalized logs, but it does not explicitly assert `/v1/status`, `/v1/models`, or ordinary inference HTTP behavior against the pre-SPEC-011 baseline.

Why: L-1 claims byte-identical default behavior for an upgraded binary with no flag changes. §4.3 separately states `/v1/status` is byte-identical unless SPEC-010 is opted in, but AC-18 is the lock-test anchor and should cover those externally visible surfaces directly.

Recommendation: Extend AC-18 with explicit `/v1/status`, `/v1/models`, and representative `/v1/chat/completions` comparisons under `--enable-warm-swap=false`, with SPEC-010 opt-in differences excluded from the oracle.

### Category B2 — macOS platform paths

#### R2-B2.1 §3.9 still advertises the old `$XDG_RUNTIME_DIR` control-socket default [MAJOR]

Location: `SPEC-011-operator-pushed-warm-swap.md` R-3.1.5 lines 302-316; §3.9 lines 904-911.

What: R-3.1.5 correctly changes the macOS control socket default to `$TMPDIR/macprovider-cli/ctl.sock`, but §3.9 still lists `--ctl-socket-path <path>` with default `$XDG_RUNTIME_DIR/macprovider-cli/ctl.sock`.

Why: §3.9 is a normative config-additions summary. An implementer following that block can reintroduce the round-1 C.1 platform bug even though the detailed rule was fixed.

Recommendation: Change §3.9 to `$TMPDIR/macprovider-cli/ctl.sock`, add `--enable-warm-swap` and `--switch-state-path` to the same serve-flag summary, and add an AC grep/assertion that no live default path mentions `$XDG_RUNTIME_DIR`.

Code-grounding notes: `printenv TMPDIR` returned `/tmp/claude-501`; `FileManager.default.temporaryDirectory` returned `/tmp/claude-501` and `isWritableFile` returned `true` when Swift was run with module caches redirected into `/tmp`; `stat` showed `/tmp/claude-501` is `drwx------`. The launchd template at `phase3-binary/dist/launchd-plist-template.plist` lines 40-46 explicitly sets `HOME=__USER_HOME__`, so `$HOME/Library/Application Support/macprovider-cli/last-switch.ts` is realistic for the repo's launchd flow. No stock LaunchAgent plist omitting `HOME` was found.

### Category C2 — Control socket frame correctness

#### R2-C2.1 §3.1.2 still shows untyped control-socket frame shorthand [MAJOR]

Location: `SPEC-011-operator-pushed-warm-swap.md` R-3.1.2 lines 254-264; R-3.1.5 lines 318-394.

What: R-3.1.2 step 4 still says the CLI sends `switch_request{target_model_id: <X>}` and receives `{accepted: true}` / `{accepted: false, ...}` responses. Those shapes omit `type`, and the request shorthand omits `requested_at_ms`, even though R-3.1.5 defines exact newline-delimited JSON frames with `type` required on every frame.

Why: This is the same implementation-risk class as round-1 B.1, just narrowed to the step-by-step flow. If tests or implementers follow §3.1.2 instead of §3.1.5, one side can produce parser-invalid frames.

Recommendation: Rewrite R-3.1.2 step 4 to reference the exact `switch_request` / `switch_ack` shapes from R-3.1.5 or inline the typed objects there. Also include `type` in the examples embedded in R-3.7.1 and R-3.7.3 consistently.

### Category D2 — 503 envelopes

(no findings)

R-3.4.2 and R-3.4.4 now use OpenAI-shaped error objects with `message`, `type`, `param`, and `code`, matching SPEC-001's envelope requirement. The `swap_drain_timeout` response omits `retry_after_seconds`; that is acceptable because it cancels an already in-flight request and has no clear per-request retry estimate. The `provider_loading` response includes both `Retry-After` and `retry_after_seconds`, matching the later SPEC-012 `model_not_warm` pattern.

### Category E2 — model_hash format

(no findings)

Every live `model_hash` occurrence in v0.3 uses raw lowercase hex. Code spot-check: `ModelRuntime.swift` returns `hexString(SHA256.hash(data: data))` for manifest hashes and `hexString` formats bytes with `String(format: "%02x", $0)`, producing raw lowercase hex without a `sha256:` prefix.

### Category F2 — hello.model_hash source-of-truth note

(no findings)

The R-3.8.3 source-of-truth note is accurate. Current Go `Hello` includes `ModelHash string` with `json:"model_hash,omitempty"` in `phase4-coordinator/internal/ws/messages.go` lines 8-15; Swift `helloMessage` emits `model_hash` when `snapshot.modelHash` is present in `CoordinatorClient.swift` lines 675-697; SPEC-008 §5.4 lines 695-718 contains the SPEC-001 v1.3 candidate annotation.

### Category G2 — New ACs

#### R2-G2.1 AC-23 depends on an undefined debug hook [MINOR]

Location: `SPEC-011-operator-pushed-warm-swap.md` AC-23 lines 1220-1226.

What: AC-23 verifies that boot never transitioned through `loading` by using a "debug hook exposing transition count = 0", but v0.3 does not define that hook, its flag, or its observability boundary.

Why: The behavioral assertion is correct, but an acceptance criterion that depends on an unspecified debug hook is not directly implementable or reviewable.

Recommendation: Either specify the minimal test-only hook in §5/AC-23, or rephrase the AC to use observable state/heartbeat evidence plus internal unit-test instrumentation owned by the implementation.

### Category H2 — AC-20 allowlist

(no findings)

The AC-20 allowlist matches R-3.6.1/R-3.6.2 exactly: required keys plus optional `from_model_hash` and `drain_inflight_count_estimate`. Its negative fixtures cover the relevant audit-event payload leak classes from SPEC-006 F-1.5: `conv:`, raw `account_id`, sticky identifiers/headers, raw buyer tag, and prompt text.

### Category I2 — §6.x companion annotations

(no findings)

SPEC-001 v1.2.4 still has §6.6 occupied by "Inference message types (WS-tunneled mode)", so v0.3's §6.7 through §6.10 candidate numbering avoids the round-1 collision. SPEC-005 confirms `request_log` is coordinator-owned/read-only to billing and that 503 no-provider states are counted through request_log joins without ledger rows; v0.3 §6.4's narrowed wording matches that boundary.

### Category J2 — Scope discipline

(no findings)

SPEC-011 v0.3 remains operator-pushed. SPEC-012 owns coordinator-pushed `set_model`, cold-wake queues, `/v1/models warm`, `/v1/status state: "loading"`, and `model_not_warm`; SPEC-011 §4.4 and §8 keep those deferred/out-of-scope surfaces out of this draft. No coordinator-side cooldown knob was added.

### Category K2 — Anything else

#### R2-K2.1 v0.3 has stale v0.2/AC-count editorial residue [MINOR]

Location: `SPEC-011-operator-pushed-warm-swap.md` §5 line 984; §6.2 lines 1311-1314; §6.3 lines 1354-1355; §6.6 lines 1414-1415; AC-25 lines 1246-1251.

What: §5 still says "20 ACs covering the surface above" even though v0.3 now totals 25; several companion annotations still say SPEC-011 v0.2; AC-25 labels `--swap-drain-timeout-seconds 3` as "`< 5 min`" even though the rule is a 5-second minimum.

Why: These are editorial, but they sit in normative handoff text and acceptance criteria. They can cause stale BUILD prompts or confused test names.

Recommendation: Update the AC count to 25, replace stale v0.2 references with v0.3 where the current draft is meant, and change AC-25's lower-bound label to "`< 5 minimum`" or "`< 5s`".

---

## Round 3 — Codex GPT-5 — 2026-06-06

**Audited:** SPEC-011 v0.4 (specs/SPEC-011-operator-pushed-warm-swap.md)  
**Auditor model:** Codex / GPT-5  
**Audit round:** 3 of N (normative)  
**Date:** 2026-06-06  
**Total findings:** 2 MINOR (0 CRITICAL / 0 MAJOR / 2 MINOR / 0 QUESTION)

### Round-3 executive summary — LOCK READINESS

Verdict: **LOCK-READY pending narrow polish.** SPEC-011 v0.4 closes the round-2 MAJOR blockers in substance and introduces no CRITICAL or MAJOR regression, but two narrow MINOR hygiene issues remain before a clean lock stamp.

### Round-2 fix verification (R2V)

| ID | Round-2 finding | v0.4 location verified | Status | Evidence |
|---|---|---|---|---|
| R2-B2.1 | §3.9 advertised stale `$XDG_RUNTIME_DIR` default | §3.9 lines 1022-1054; R-3.9.2 lines 1064-1073; AC-26 lines 1453-1463 | PARTIAL | The live config default is now `$TMPDIR/macprovider-cli/ctl.sock` and `--enable-warm-swap` / `--switch-state-path` are listed, but the literal AC-26 grep contract is too strict for the current v0.4 text because `$XDG_RUNTIME_DIR` still appears in normative rationale and the AC body itself. |
| R2-C2.1 | §3.1.2 step 4 used untyped control-socket shorthand | R-3.1.2 step 4 lines 315-330; R-3.1.5 field reference lines 449-465 | PASS | Step 4 now sends typed `switch_request` with `type`, `target_model_id`, `requested_at_ms`, and receives typed `switch_ack` with required/conditional fields matching R-3.1.5. |
| R2-A2.1 | Disabled-vs-no-serve detection was ambiguous | R-3.1.5.x lines 477-510; R-3.1.0 lines 262-283 | PASS | v0.4 defines the ENOENT, ECONNREFUSED, and 2s `status_request` timeout precedence without adding pid files or other mechanisms, and R-3.1.0 still says disabled serve MUST NOT open the socket. |
| R2-A2.2 | AC-18 did not cover all L-1 observables | AC-18 lines 1286-1334 | PASS | AC-18 now covers heartbeat shape, control socket absence, audit events, `/v1/status`, `/v1/models`, representative `/v1/chat/completions`, and normalized logs against a pre-SPEC-011 baseline. |
| R2-G2.1 | AC-23 debug hook undefined | AC-23 lines 1399-1417; `phase3-binary/Package.swift` lines 69-73 | PASS | AC-23 now requires a package-internal test accessor with no production debug endpoint; the Swift package already has a same-module test target that can use `@testable import macprovider_cli`. |
| R2-K2.1 | Editorial residue: AC count, AC-25 label, stale self-references | AC-25 lines 1437-1449; footer lines 1465-1466; §6.1 line 1478 | PARTIAL | The AC count is 26 and AC-25's lower-bound label is fixed, but one live companion BUILD citation still says SPEC-001 must cite `SPEC-011 v0.3 §3.1`. |

### Category R2V — Round-2 fix verification

Findings are listed in the R2V table above. The two PARTIAL rows are MINOR polish only; neither reintroduces a stale runtime default or an untyped §3.1.2 switch frame.

### Category A3 — Locked-decision preservation

(no findings)

A3.1: L-1 through L-7 remain preserved. R-3.1.5.x only governs the operator's `models` CLI detection path after the operator invokes that surface; disabled `serve` still opens no socket and emits no new heartbeat fields per R-3.1.0 lines 262-283.

A3.2: R-3.9.2's intent is correctly scoped to advertised defaults. It does not need to forbid historical traceability in the change log, but the AC wording below should be narrowed so that the literal grep test matches that intent.

### Category B3 — §3.1.2 + §3.9 cross-section consistency

#### B3.1 AC-26 literal grep contract does not match v0.4 text [MINOR]

Location: `SPEC-011-operator-pushed-warm-swap.md` R-3.1.5 lines 394-397, §3.9 lines 1047-1049, R-3.9.2 lines 1064-1073, AC-26 lines 1453-1461. Spot-check: `grep -n 'XDG_RUNTIME_DIR' specs/SPEC-011-operator-pushed-warm-swap.md` returned matches at lines 25, 31, 94, 394, 396, 1049, 1064, 1066, 1068, 1453, and 1456.

What: AC-26 says the substring `$XDG_RUNTIME_DIR` MUST match only in change-log entries historically describing the removed default and MUST NOT appear in any normative rule, config block, or AC body. The current spec necessarily mentions it in R-3.1.5's "Why not" rationale, R-3.9.2's prohibition, and AC-26's own text.

Why: The runtime/config contract is correct, but the acceptance test is impossible as written: a literal grep over v0.4 fails because the rule and AC must name the forbidden token to forbid it.

Recommendation: Reword AC-26 to assert no advertised default path or wire/config example contains `$XDG_RUNTIME_DIR`, while allowing change-log entries and explicit "forbidden/historical rationale" sections such as R-3.9.2 and AC-26 itself.

B3.2: §3.1.2 step 4's field set matches R-3.1.5 for `switch_request` and `switch_ack`; no extra step-4 field appears outside the field reference.

B3.3: §3.9 defaults align with their normative sources: `--enable-warm-swap` default disabled per R-3.1.0; `--swap-drain-timeout-seconds` default 20 and range 5-600 per §3.9/R-3.9.1; `--ctl-socket-path` default `$TMPDIR/macprovider-cli/ctl.sock` per R-3.1.5; `--switch-state-path` default `$HOME/Library/Application Support/macprovider-cli/last-switch.ts` per R-3.1.4.

### Category C3 — R-3.1.5.x detection precedence

(no findings)

C3.1: The ordering is implementable with standard macOS Unix-domain-socket primitives: `stat` can distinguish ENOENT before connect, `connect(2)` documents ENOENT for missing named sockets and ECONNREFUSED when a stream-socket connection attempt is ignored, and the spec uses a normal blocking connect path rather than a nonblocking path where in-progress errors would complicate precedence. A sandboxed live stale-socket probe returned EPERM in this managed workspace, so it was not used as behavioral evidence.

C3.2: The 2s handshake timeout is defensible. A correctly implemented enabled `serve` should answer `status_request` quickly; a 2s read deadline is generous relative to a local UDS round trip and gives operators a useful unresponsive/wedged diagnostic.

C3.3: The case (3) note is consistent with R-3.1.0 lines 262-283: disabled mode MUST NOT open the control socket, so successful connect without a `status_response` should not occur for a correct v0.4 disabled serve.

### Category D3 — AC-18 expansion

(no findings)

D3.1: AC-18's public HTTP comparison is implementable as written if the oracle compares status, headers, JSON shape, and token counts rather than volatile values such as `id` and `created`; current code creates response UUIDs and timestamps in `HTTPServer.swift` lines 322-328. `ChatCompletionRequest` parses `seed` at lines 73 and 96, while `ModelRuntime` passes temperature/topP but not seed into MLX generation at lines 103-107 and 157-160; because AC-18 uses `temperature: 0` and excludes nondeterministic output text, this is not a lock blocker.

D3.2: The SPEC-010 exclusion is narrow enough for this audit pass: AC-18 explicitly says the oracle excludes SPEC-010 opt-in differences, and SPEC-010 v1.5 locked status means that exclusion can be implemented by the same baseline-aware harness pattern referenced in AC-18's normalized-log clause.

### Category E3 — AC-23 test accessor

(no findings)

The requested accessor shape is standard for this Swift package. The existing test target depends on `macprovider-cli` (`Package.swift` lines 69-73), and current tests already use `@testable import macprovider_cli`, so an internal `runtimeTransitionCount()` helper can be reached from same-module tests without a production endpoint.

### Category F3 — AC count + editorial hygiene

#### F3.1 Residual v0.4 polish drift in live companion text and one cooldown shorthand [MINOR]

Location: `SPEC-011-operator-pushed-warm-swap.md` §6.1 line 1478 and R-3.7.3 lines 939-945.

What: The AC count and AC-25 unit label are fixed, but one live companion BUILD annotation still says SPEC-001 v1.3 must cite `SPEC-011 v0.3 §3.1`; additionally, R-3.7.3 still uses `{accepted: false, reason: "cooldown", seconds_remaining: N}` without `type` even though the v0.4 change log says the R-3.7.3 example references were also converted to typed frames.

Why: These are narrow editorial/citation drifts, not implementation blockers. The authoritative switch path and AC-24 both point back to typed R-3.1.5 frames, but leaving stale version text and one untyped shorthand invites future BUILD prompt or example drift.

Recommendation: Change the live §6.1 citation to `SPEC-011 v0.4 §3.1` and rewrite the R-3.7.3 cooldown object as `{type: "switch_ack", accepted: false, reason: "cooldown", seconds_remaining: N}`.

F3.2: Counting `^- **AC-` headings returns AC-1 through AC-26 exactly, and the footer says "Total: 26 ACs."

F3.3: §10/OQ cleanup is satisfactory: OQ-1 through OQ-4 are "Open for v0.5" and no old v0.3 release-target label remains there.

### Category G3 — Cross-spec citations (SPEC-010 just locked)

(no findings)

G3.1: SPEC-011 R-3.1.2 step 2 cites SPEC-010 R-3.6.3; SPEC-010 v1.5 still defines R-3.6.3 at lines 863-872.

G3.2: SPEC-011 R-3.1.2 step 2 cites SPEC-010 R-3.1.7; SPEC-010 v1.5 still defines R-3.1.7 at lines 513-517.

G3.3: Other SPEC-010 rule citations checked in v0.4 still resolve: R-3.6.1 exists at SPEC-010 v1.5 lines 856-859, R-3.1.4 exists at lines 500-503, and SPEC-010 round 6 confirmed v1.5 lock with 0 CRITICAL / 0 MAJOR / 0 MINOR at `SPEC-010-audit.md` lines 630-640.

### Category H3 — Scope discipline

(no findings)

SPEC-011 v0.4 remains operator-pushed. It does not add coordinator-side `set_model`, cold-wake queues, `/v1/models warm`, `/v1/status state: "loading"`, or `model_not_warm` surfaces; those remain deferred/out-of-scope for successor specs.

### Category I3 — Anything else

(no findings)

Code-grounded spot checks matched v0.4's premises: current Go `Heartbeat` still lacks `loading` and `model_hash` fields (`messages.go` lines 121-135); Swift model-hash code returns raw lowercase hex with no `sha256:` prefix (`ModelRuntime.swift` lines 294-325); and `MacProviderCLI.swift` lines 7-15 has no existing `models` subcommand conflict. Environment checks matched the macOS path rationale: `printenv TMPDIR` returned `/tmp/claude-501`; `printenv XDG_RUNTIME_DIR` was unset.

Decision-log note: add the SPEC-011 lock/polish decision to `beta/DECISION_CRITERIA.md` after the owner decides whether to lock v0.4 with these minor notes or issue a narrow v0.5 polish patch.

### Self-verification

- Round-3 section appended after round 2; rounds 1-2 were not overwritten.
- Every round-2 finding has PASS / PARTIAL / FAIL in R2V.
- Every category R2V, A3, B3, C3, D3, E3, F3, G3, H3, and I3 has a section.
- Executive summary states the explicit lock-readiness verdict: LOCK-READY pending narrow polish.
- Code spot-checks covered the requested Go heartbeat struct, Swift hash implementation, CLI subcommand list, macOS env values, SPEC-010 v1.5 citations, and SPEC-010 round-6 lock context.
- No `d-inference` source was inspected.

---

## Round 4 — Codex GPT-5 — 2026-06-06 — LOCK CONFIRMATION

**Audited:** SPEC-011 v0.5 (specs/SPEC-011-operator-pushed-warm-swap.md)  
**Auditor model:** Codex / GPT-5  
**Audit round:** 4 of N (normative, LOCK confirmation pass)  
**Date:** 2026-06-06  
**Total findings:** 0 CRITICAL / 0 MAJOR / 0 MINOR / 0 QUESTION

### Round-4 executive summary — LOCK VERDICT

Verdict: **LOCK CONFIRMED.** SPEC-011 v0.5 closes both round-3 MINOR polish findings, and the requested AC-26 spot-check found no new CRITICAL, MAJOR, or MINOR regression in the narrow round-4 surface.

### Round-3 fix verification (R3V)

| ID | Round-3 finding | Status | v0.5 location | Evidence |
|---|---|---|---|---|
| R3V-B3.1 | AC-26 grep contract impossible | PASS | AC-26 lines 1483-1525; §3.9 config block lines 1060-1084; R-3.9.2 lines 1094-1103 | AC-26 now defines three structural assertions and a four-location literal-token allowlist, while the §3.9 default lines use `false`, `20`, `$TMPDIR/macprovider-cli/ctl.sock`, and `$HOME/Library/Application Support/macprovider-cli/last-switch.ts`, not `$XDG_RUNTIME_DIR`. |
| R3V-F3.1 | Residual editorial drift: stale §6.1 citation and one untyped cooldown shorthand | PASS | §6.1 lines 1538-1542; R-3.7.3 lines 968-976 | §6.1 now cites `SPEC-011 v0.x locked §3.1`, and R-3.7.3 now refers to a typed `switch_ack` frame with an explicit REQUIRED `type: "switch_ack"` field. |

### Category R3V — Round-3 MINOR fix verification

(no findings)

Both round-3 MINORs are closed in v0.5. B3.1 is addressed by replacing the impossible literal grep contract with structural assertions plus an explicit allowlist, and F3.1 is addressed by the version-agnostic §6.1 citation plus typed cooldown frame wording.

### Category A4 — Locked-decision preservation

(no findings)

A4.1: L-1 through L-7 remain unchanged at lines 259-267. The v0.5 polish edits touch AC-26 wording, one §6.1 citation, R-3.7.3 typed-frame wording, and §3.9 inline-comment cleanup; none changes a locked decision.

A4.2: R-3.1.0 still preserves L-1: the SPEC-011 surface activates only with `--enable-warm-swap`, disabled `serve` opens no control socket, hosts no new state machine, emits no `loading` or `model_hash`, and preserves byte-identical pre-SPEC-011 behavior (lines 291-312).

### Category B4 — AC-26 structural assertion correctness

(no findings)

B4.1: Exact spot-check command `grep -n '\$XDG_RUNTIME_DIR' specs/SPEC-011-operator-pushed-warm-swap.md` returned matches only at lines 22, 29, 54, 60, 123, 423, 1094, 1096, 1098, 1483, 1492, 1497, 1501, 1503, 1513, and 1521. Those fall into AC-26's four allowed locations: change-log entries, R-3.1.5 "Why not" rationale, R-3.9.2 prohibition body, and AC-26 self-reference.

B4.2: AC-26's three structural assertions are operationally testable. The §3.9 config block `default` lines at 1061, 1069, 1074, and 1081 contain no `XDG_RUNTIME_DIR`; scanned code blocks in §3.1, §3.4, §3.6, and §3.8 contain no `XDG_RUNTIME_DIR` value; and the only R-rule-body uses are R-3.1.5's forbidden-rationale paragraph and the allowed R-3.9.2 prohibition rule.

### Category C4 — §6.1 citation correctness

(no findings)

C4.1: §6.1 now uses `SPEC-011 v0.x locked §3.1` at lines 1540-1541, matching the SPEC-010 v1.5 precedent where §6.1 uses `SPEC-010 v1.x locked §3.1 and §3.6`.

### Category D4 — R-3.7.3 typed frame consistency

(no findings)

D4.1: R-3.7.3 is not ambiguous: it says cooldown may be reported via a typed `switch_ack` frame per R-3.1.5 and explicitly names the REQUIRED `type: "switch_ack"` field (lines 970-973), consistent with R-3.1.5's "Every message MUST include a `type` field" and field reference (lines 428-494).

D4.2: The rest of §3.7 has no missed untyped cooldown shorthand. R-3.7.1 includes `{type: "switch_ack", accepted: false, reason: "loading_in_progress", current_target: "Y"}` at lines 955-957; R-3.7.2 has no frame literal; R-3.7.3 is now typed as above.

### Category E4 — Anything else

(no findings)

E4.1: v0.5 introduces no new code-grounded surface; the change log describes a polish-only pass closing B3.1, F3.1, and one §3.9 inline-comment cleanup.

E4.2: No documentation drift found in the requested narrow surface. The AC count remains 26 at lines 1527-1528, and §6.1's v0.x locked citation aligns with the SPEC-010 v1.5 precedent.

E4.3: Decision-log reminder: after SPEC-011 is locked, add a `beta/DECISION_CRITERIA.md` entry alongside SPEC-010 v1.5 Entry 54. This is not a finding.

### Self-verification

- Round-4 section appended after round 3; rounds 1-3 were not overwritten.
- Every round-3 MINOR has PASS / PARTIAL / FAIL in R3V.
- Every category R3V, A4, B4, C4, D4, and E4 has a section.
- Executive summary states the explicit lock verdict: LOCK CONFIRMED.
- Required AC-26 grep spot-check was run and every `$XDG_RUNTIME_DIR` match was classified into the four allowed locations.
- No `d-inference` source was inspected.
