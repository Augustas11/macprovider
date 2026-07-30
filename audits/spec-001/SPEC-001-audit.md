# SPEC-001 Audit Report

Audit target: `specs/SPEC-001-phase3-binary.md`

Result: **NOT READY FOR BUILD WITHOUT REVISION**

SPEC-001 is directionally strong: it captures the major Phase 1/2 learnings,
names Tier 2 hook points, and gives a plausible build order. The blocking
problems are not the overall architecture; they are contract precision,
acceptance-test coverage, reference hygiene, and a few hidden requirements that
would force implementers to guess.

## Severity Summary

| Severity | Count | Summary |
|---|---:|---|
| CRITICAL | 2 | License SPDX/source recording is wrong or underspecified; OpenAI-compatible request schema is not complete enough to build against. |
| MAJOR | 17 | Coordinator protocol inconsistencies, Tier 2 ordering flaw, uncovered decision-log implications, missing acceptance coverage, dependency pinning, and scope bleed. |
| MINOR | 9 | Open questions that should be defaults, unclear SSE transport wording, missing global pass rule, and missing exact test commands. |
| QUESTION | 3 | Operator decisions needed before the build consumes this spec. |

## Category A: Completeness Against Source Materials

### A.1 Decision log mapping

| Decision log row | Covered? | Audit result |
|---|---|---|
| 502 vs 530 routing distinction | Partial | MAJOR finding A1 |
| Post-wake throughput dip | Yes | FR-16 maps it. |
| Stop-token leakage status | Yes | FR-6 maps it defensively. |
| Cross-provider throughput inversion | Partial | MAJOR finding A2 |
| Timeline compression | Not covered | MINOR finding A3 |

**A1 - MAJOR - D1 is mapped to health states, but loses concrete routing/backoff and tunnel-signal requirements.**

Spec quote, Section 8: "`FR-15` ... reports `degraded` vs `unavailable` states."

Source quote, `beta/DECISION_CRITERIA.md` decision log: "route around 502 with short backoff (~30s), remove 530 from pool"

Problem: SPEC-001 turns D1 into generic health states and WebSocket-close
interpretation, but drops the short-backoff behavior and `cfd_tunnel`
connection-count prediction. If those are coordinator-only, the spec should say
"deferred to SPEC-002" explicitly; if the binary must report the signal, it
needs an FR.

**A2 - MAJOR - D4 requires buyer-facing model-size choice or auto-routing, but SPEC-001 only advertises capacity.**

Spec quote, Section 8: "`FR-17` ... heartbeat includes `model_params_b` and `throughput_tps_estimate`"

Source quote, decision log: "buyer-facing API must expose model-size choice or auto-route by latency/quality preference"

Problem: Advertising model and throughput is necessary but not sufficient to
cover the implication. This may belong in the coordinator SPEC, but SPEC-001
currently says the decision is covered when the user-facing behavior is not.

**A3 - MINOR - The timeline-compression decision log row violates the prompt's "every row maps" rule.**

Spec quote, Section 8: "FR mapping: No direct FR."

Source quote, build prompt: "Every entry in beta/DECISION_CRITERIA.md's `Decision log` table becomes one or more functional requirements."

Problem: This row may reasonably have no binary behavior, but the spec should
state that it is intentionally non-functional/process-only and excluded from the
FR mapping rule. As written, it looks like a missed requirement.

### A.2 Phase 1 SSE quirks

The five HANDOFF bullets are mostly represented:

| Phase 1 bullet | SPEC-001 coverage |
|---|---|
| Ignore SSE keepalive comment lines | FR-5 eliminates outbound keepalives. |
| Strip model-specific stop tokens | FR-6. |
| Tolerate extra fields | Partial: request extras are ignored; response-side tolerance is not relevant if binary owns responses. |
| Pre-flight context length | FR-8. |
| Advertise per-Mac context cap | FR-9 and FR-17. |

No separate blocking finding here, but the wording should be tightened: the
binary does not "ignore" upstream SSE if it no longer proxies `mlx_lm.server`;
it simply never emits the keepalive comments.

### A.3 Adversarial workload coverage

All five workloads are named in AC-2, but survival expectations are too weak.

**A4 - MAJOR - `malformed_tool_call` is only covered by a crash-survival AC, not by request validation semantics.**

Spec quote, Section 6.2: "`tool_calls`, `tools`, `response_format`, and other OpenAI fields are accepted and silently ignored"

Source quote, `workloads_adversarial.py`: "gracefully rejects (4xx) or crashes (5xx / ConnectionError)"

Problem: SPEC-001 allows malformed tool-call payloads to be silently ignored,
and AC-2 even allows 500s during adversarial load. That is not a crisp contract.
The binary should either reject malformed tool/tool_call shapes with 400 or
define exactly which ignored fields are not parsed.

**A5 - MAJOR - AC-2 allows HTTP 500 during adversarial workloads, which can mask inference-engine failures.**

Spec quote, Section 9: "may return error responses (429, 413, 500) during adversarial load"

Problem: A 500 for overload, malformed JSON, or context pressure can be
materially different from a clean 429/400/413. AC-2 should allow expected
client errors and capacity errors, but treat 500 as a failure unless a specific
internal inference exception was handled and the binary remains healthy.

### A.4 Build prompt checklist

Sections 0-11 are present, `phase3-binary/implementation-notes.html` exists,
and `specs/README.md` exists.

**A6 - MINOR - Section 11 includes command-level build steps despite the build prompt anti-rule.**

Spec quote, Section 11: "`swift build` compiles an empty main"

Source quote, build prompt anti-rule: "Don't write build steps (no `swift build` commands, no Xcode invocations)."

Problem: The handoff is useful, but it crosses the prompt's boundary. Keep
deliverables and sequence; remove concrete build commands if strict prompt
compliance matters.

## Category B: Internal Consistency

**B1 - MINOR - SSE transport wording confuses event framing with HTTP transfer encoding.**

Spec quote, Section 4: "Connection is not chunked-transfer but true SSE."

Problem: SSE is an event format over an HTTP response; HTTP/1.1 streaming often
uses chunked transfer encoding when no `Content-Length` is known. This wording
may make a Swift NIO implementer fight the transport instead of producing
valid SSE.

**B2 - MAJOR - FR-17 requires fields that the heartbeat schema omits.**

Spec quote, FR-17: "capacity heartbeat message must include: `model_id` ... `throughput_tps_estimate` ... `ram_gb`"

Spec quote, Section 6.5 heartbeat: "`slots_free`, `slots_total`, `requests_served_since_last`"

Problem: The handshake includes the static capacity fields, but FR-17 says the
heartbeat must include them. The Section 6.5 heartbeat schema lacks
`model_id`, `model_params_b`, `max_context_tokens`, `max_concurrency`,
`current_slots_free`, `throughput_tps_estimate`, and `ram_gb` as named in FR-17.

**B3 - MAJOR - State-transition messages are required but not specified.**

Spec quote, FR-15: "State transitions are sent as WebSocket messages whenever the state changes."

Spec quote, Section 6.5: "All messages are JSON" followed by hello, hello_ack, heartbeat, preflight, drain, warm_up.

Problem: There is no `state_update` or equivalent message shape. Implementers
must guess whether to send immediate heartbeats, a new message type, or only
wait for scheduled heartbeat intervals.

**B4 - MAJOR - Drain status is required but has no provider-to-coordinator schema.**

Spec quote, FR-12: "Sends a `drain` status to the coordinator"

Spec quote, Section 6.5: "Drain signal (C->P) - coordinator tells provider to stop"

Problem: Section 6 only defines a coordinator-to-provider drain command. It
does not define the provider-to-coordinator drain status that FR-12 requires.

**B5 - MAJOR - WebSocket auth is a hidden requirement in open questions, not in FRs or config schema.**

Spec quote, Section 10: "The binary should accept a `coordinator_token` config field"

Spec quote, FR-19: "schema includes at minimum: `port`, `model` ... `warmup_enabled`"

Problem: If the binary "should" accept and send a bearer token, that belongs in
FR-13 and FR-19. If auth is Phase 4/6 scope, remove the implementation
instruction from the open question.

**B6 - MAJOR - Acceptance criteria do not test several numbered requirements.**

Spec quote, Section 9: "AC-1" through "AC-5"

Untested or weakly tested FRs: FR-12 SIGTERM/SIGINT drain, FR-16 wake detection
and explicit `warm_up`, FR-18 `/v1/health`, FR-19 config precedence, FR-20
startup self-test failure paths, and the immediate state transitions in FR-15.

Problem: The build session can pass AC-1 through AC-5 without proving large
parts of the spec.

## Category C: Tier 1 / Tier 2 Architecture

**C1 - MAJOR - Context pre-flight runs before `InputDecryptor`, which breaks Tier 2 encrypted prompts.**

Spec quote, architecture diagram: "Context Pre-flight ... Reject -> HTTP 413"

Spec quote, next hook: "`[InputDecryptor]` ... Tier 2: decrypt prompt"

Problem: Tier 2 buyer-side encrypted prompts cannot be tokenized before
decryption. The request chain should either place decryption before context
pre-flight in Tier 2 or split pre-flight into encrypted-envelope checks and
post-decrypt token checks.

**C2 - MINOR - Tier 2 roadmap scope includes implementation details beyond hook-point names.**

Spec quote, Section 2: "Secure enclave key derivation for identity binding"

Source quote, build prompt anti-rule: "Don't speculate about Tier 2 implementation details beyond the hook-point names."

Problem: The named hooks are good. "Secure enclave key derivation" is a design
choice for a future Tier 2 spec, not just a hook point.

**C3 - MINOR - `content_filter` is reserved for Tier 2 without a clear Tier 1 behavior.**

Spec quote, Section 6.2: "`content_filter` (reserved for Tier 2)"

Problem: Tier 1 has no content filter. This enum value may be harmless, but it
implies a future policy behavior in the Tier 1 wire contract.

## Category D: Reference Hygiene

**D1 - CRITICAL - d-inference license SPDX is not recorded accurately enough.**

Spec quote, Section 7.2: "SPDX: `LicenseRef-Proprietary`"

Observed source: GitHub API for `Layr-Labs/d-inference` reports license
`spdx_id: NOASSERTION`; the LICENSE file is titled "DARKBLOOM LICENSE
AGREEMENT" and is a custom restricted license.

Problem: `LicenseRef-Proprietary` is not the repository's GitHub/SPDX value.
The spec should record both: GitHub SPDX `NOASSERTION`, license title
`DARKBLOOM LICENSE AGREEMENT`, and the exact inspected URL/ref or commit SHA.
This matters because the build prompt explicitly made license verification a
hard requirement.

**D2 - MINOR - Reference appendix lacks immutable refs for d-inference.**

Spec quote, Appendix A: "d-inference GitHub README ... license verification"

Problem: The repository was updated recently and can change. The appendix
should include branch/ref or commit SHA for the README/LICENSE/file listing
consulted.

No findings for D3/D4: the spec avoids non-JSON code samples, states
"Informed by, not copied", and plans `THIRD_PARTY_NOTICES.md`.

## Category E: Interface Contracts

**E1 - CRITICAL - `/v1/chat/completions` request schema is not complete enough to build compatible client/server behavior.**

Spec quote, Section 6.2: "Required fields: `messages` (array of `{role, content}` objects)."

Spec quote, Section 6.2: "`tool_calls`, `tools`, `response_format`, and other OpenAI fields are accepted and silently ignored"

Problem: This is an example plus a partial field list, not the "full OpenAI
schema" requested by the build prompt. It omits required types/enums for
message roles, content forms, assistant messages with `content: null`, tool
messages, tool_calls shape, `stream_options`, penalties, seed, user, and
validation behavior for unknown or malformed fields.

**E2 - MAJOR - Error responses are incomplete.**

Spec quote, Section 6.2: "Error responses" table lists only chat completion errors.

Problem: There is no global 404/405 behavior, no malformed JSON body contract,
no streaming error behavior after headers are sent, no `/v1/health` failure
shape, and no coordinator protocol error/negative-ack shape.

**E3 - MAJOR - Coordinator preflight protocol cannot distinguish no slot vs context too large vs draining with typed enum guarantees.**

Spec quote, Section 6.5: "`reason`: `context_exceeds_capacity`"

Problem: The false response shows one reason string but does not enumerate all
valid reasons (`busy`, `queue_full`, `draining`, `model_not_loaded`, etc.) or
state whether `estimated_wait_ms` is required on busy responses.

## Category F: Acceptance Criteria

**F1 - MAJOR - Acceptance criteria lack concrete commands or harness invocations.**

Spec quote, Section 9: "Phase 2 harness (`beta/harness.py`) targets the binary's HTTP endpoint"

Problem: AC-1 names the harness but gives no command. AC-2 names workloads but
does not say how to run the adversarial registry. AC-3 defines no soak script.
AC-5 defines no mock coordinator fixture path. The prompt explicitly asks for
"test command, script reference, or harness invocation."

**F2 - MINOR - Overall pass/fail rule is implied, not stated in Section 9.**

Spec quote, Section 11: "Run AC-1 through AC-5. Fix issues."

Problem: Section 9 should say "all ACs must pass" and whether any manual
operator waiver is allowed.

## Category G: Open Questions

Section 10 lists 9 open questions, which is in the target 5-10 range.

**G1 - MINOR - Several open questions are defaults, not blockers.**

Spec quotes:
- "Should there be a fourth: mDNS/Bonjour discovery"
- "Should the binary also write to a local SQLite database"
- "Alternative: `~/.config/macprovider/config.yaml`"
- "Should the queue have a time-based eviction"
- "How does the binary reach contributors?"

Problem: These should be defaults or future-version notes. Keeping them as
operator questions increases build-session ambiguity.

**G2 - MAJOR - OQ-7 answers itself with a hidden implementation directive.**

Spec quote, Section 10: "The binary should accept a `coordinator_token` config field"

Problem: This is no longer an open question; it is an unnumbered requirement.
Move it into FR-13/FR-19 or defer it.

## Category H: Implementability

**H1 - MAJOR - Dependencies are not pinned where breakage matters.**

Spec quote, Section 7.1: "`mlx-swift-lm` ... `swift-nio` ... `swift-log` ... `Yams`"

Source quote, build prompt: "`mlx-swift-lm` without a commit or release tag is a finding"

Problem: The most important dependency, `mlx-swift-lm` via
`apple/mlx-swift-examples`, has no tag/commit. Neither do NIO, SwiftLog,
ArgumentParser, or Yams.

**H2 - MAJOR - A competent implementer would need more than three clarifications.**

Likely clarifications:
1. Exact `mlx-swift-lm` package URL/product/commit and expected tokenizer APIs.
2. Full chat-completions request validation contract.
3. Coordinator state/drain/heartbeat message shapes.
4. Whether coordinator auth token is in scope.
5. Whether 500 is acceptable for adversarial workloads.
6. How to run AC-2/AC-3/AC-5.

That exceeds the implementability bar in the audit prompt.

## Category I: Scope Discipline

**I1 - MAJOR - The spec constrains coordinator behavior beyond the binary wire contract.**

Spec quote, FR-15 table column: "Coordinator action"

Spec quote, FR-17: "The coordinator cannot assume bigger Mac = faster. It must route by..."

Problem: It is fine for SPEC-001 to define messages the binary sends. It should
not prescribe coordinator routing internals except as protocol requirements or
explicit SPEC-002 inputs.

**I2 - MINOR - WebSocket authentication may belong in SPEC-002 or SPEC-006.**

Spec quote, Section 10: "In production, the coordinator will need to authenticate providers."

Problem: Provider/coordinator auth is not buyer API auth, but it still touches
production trust. Decide whether SPEC-001 owns a bearer-token client hook or
SPEC-002 owns it.

## Auditor Questions

1. Should SPEC-001 define a provider auth token now, or should all coordinator
   authentication be deferred to SPEC-002?
2. Should the binary ever return HTTP 500 during adversarial acceptance, or
   should expected adversarial outcomes be limited to 400/413/429 plus health
   survival?
3. Should Tier 2 encrypted prompts be a hard architecture constraint now? If
   yes, the request chain must move token pre-flight after `InputDecryptor`.

## Recommended Fix Order

1. Fix Section 6 contracts first: full chat request schema, streaming/error
   behavior, and coordinator message shapes.
2. Fix FR/Section 6 inconsistencies: heartbeat fields, state updates,
   provider-to-coordinator drain status, `coordinator_token`.
3. Fix Tier 2 ordering: encrypted prompt decryption before token pre-flight, or
   define two-stage pre-flight.
4. Tighten acceptance: commands for AC-1..AC-5, no blanket 500 allowance, and
   explicit all-criteria pass rule.
5. Correct d-inference license recording with GitHub SPDX `NOASSERTION`,
   license title, inspected URLs, and commit/ref.
6. Pin dependency versions or commits before a build session starts.
