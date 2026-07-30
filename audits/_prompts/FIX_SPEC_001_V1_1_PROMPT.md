# Fix prompt — SPEC-001 v1.1

This is the operator-paste prompt to apply audit findings to SPEC-001 and
produce v1.1. The audit identified 2 CRITICAL, 17 MAJOR, 9 MINOR, and 3
operator-only questions. The 3 operator questions have already been
resolved (see below). The d-inference license has been verified as a
custom restrictive license (NOT open source); the reference hygiene
policy has been updated to strict clean-room.

Run this in **Claude Code** (same model that wrote v1.0). Expected
duration: ~1-1.5 hours.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Claude Code session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are revising SPEC-001 to address audit findings. Output is SPEC-001
v1.1, edited in place at /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md,
plus an appended "Resolved during v1.1" section in
/Users/augstar/macprovider-poc/phase3-binary/implementation-notes.html.

The architecture is sound. The audit's findings are about contract
precision, missing schemas, hidden requirements, and a reference-hygiene
correction. This is targeted revision, not a rewrite.

## Required reading (in order)

1. /Users/augstar/macprovider-poc/specs/SPEC-001-audit.md
   — the audit findings you are addressing. Read carefully, every finding.

2. /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
   — the spec under revision.

3. /Users/augstar/macprovider-poc/HANDOFF.md (skim — project context)

4. /Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md
   — re-read the decision log; map every row to FRs and confirm coverage.

5. /Users/augstar/macprovider-poc/beta/workloads_adversarial.py
   — adversarial workload contract for AC tightening.

6. /Users/augstar/macprovider-poc/beta/harness.py (skim — for AC commands)

## Resolved operator decisions (pinned — do not relitigate)

The audit asked three operator-only questions. The operator has answered:

**A1: Provider auth token — DEFER TO SPEC-002.**
Remove all `coordinator_token` references from SPEC-001 FRs, config schema,
and open questions. Add one sentence in Section 7 ("Dependencies") noting
"Provider authentication to coordinator is specified in SPEC-002 and is
out of scope for this binary's wire protocol."

**A2: HTTP 500 during adversarial — DISALLOWED.**
Tighten AC-2 to:
"Each adversarial workload (`retry_storm`, `concurrent_burst_8way`,
`midstream_disconnect`, `malformed_tool_call`, `long_context_oom_probe`)
must complete with NO HTTP 500 responses. Acceptable responses during
adversarial load are: 200 (success), 400 (malformed request),
413 (payload too large), 429 (rate limited / queue full). The binary
must remain healthy (passes /v1/health) within 30 seconds of workload
completion. Any 500 response or process crash is a hard failure of AC-2."

**A3: Tier 2 encrypted prompts — HARD ARCHITECTURE CONSTRAINT.**
Re-order the request chain in Section 3 architecture diagram so
`InputDecryptor` runs BEFORE context pre-flight in Tier 2 mode. Tier 1
skips InputDecryptor entirely. Split pre-flight into:
  - Stage 1 (Tier 1 + Tier 2): envelope size check (raw bytes)
  - Stage 2 (after decrypt for Tier 2; immediately for Tier 1): token-count
    pre-flight against model context limit
Document this in FR-8 and in the Section 3 architecture diagram. Both
stages must be Tier-aware.

## New reference hygiene policy (replaces v1.0 Section 7.2 wholesale)

The DARKBLOOM LICENSE AGREEMENT (custom restrictive license, SPDX
NOASSERTION) prohibits use of d-inference Software to operate any
competing service. Mac Provider is such a service. Reference hygiene is
therefore **strict clean-room** for d-inference. Replace Section 7.2 with
the following EXACTLY:

```
### 7.2 Reference hygiene — strict clean-room for d-inference

This binary is built strict clean-room with respect to d-inference.

PROHIBITED references for this spec and the Phase 3 binary build:
- The d-inference GitHub repository (https://github.com/Layr-Labs/d-inference)
- Any d-inference source files, including the README and config files
- Any third-party analyses that quote or reproduce d-inference source
- Reverse-engineered analyses of any compiled Darkbloom binary

Reason: the DARKBLOOM LICENSE AGREEMENT (Eigen Labs, Inc., copyright 2026;
SPDX NOASSERTION; canonical URL https://github.com/Layr-Labs/d-inference/blob/master/LICENSE
as inspected 2026-05-27) explicitly prohibits in Section 3 the use of the
Software to "provide, operate, or enable any hosted service, platform,
marketplace, or product that offers AI inference coordination, private
inference services, or decentralized compute marketplace capabilities
that compete with Darkbloom." Mac Provider fits this description.

PERMITTED references:
- Darkbloom / Eigen Labs published academic papers (cite by URL/DOI)
- Darkbloom blog posts, conference talks, marketing pages (public)
- Third-party reviews that do NOT reproduce d-inference source
- mlx-swift-lm (MIT, Apple/mlx-swift-examples, unrelated to Darkbloom)
- swift-nio, swift-log, swift-argument-parser (Apache 2.0)
- Yams (MIT)
- Apple MLX documentation
- OpenAI API reference (https://platform.openai.com/docs/api-reference)
- HuggingFace tokenizer_config.json schema
- This repository: Phase 1 doc/PHASE1_REPORT.md, Phase 2 DECISION_CRITERIA.md,
  harness.py, workloads_adversarial.py

Patent analysis is separate from license. Darkbloom holds patents around
their privacy/attestation model. Tier 1 of this binary does not implement
that model; Tier 2 hooks are designed-in but unimplemented. Patent risk
analysis for Tier 2 is deferred to its eventual SPEC.

If during implementation you are uncertain how Darkbloom solved a problem,
STOP and add an open question to implementation-notes.html. Do not resolve
it by reading their source.
```

When updating Section 7.2, also remove the d-inference URL from anywhere
else in the spec (e.g. Section 7's reference list, Section 11 hand-off,
Appendix A). Replace with the permitted references above.

## Critical fixes (apply first)

### CRITICAL D1 — License recording

Replace Section 7.2's license entry as specified above. The verbatim
"strict clean-room" block IS the fix.

### CRITICAL E1 — /v1/chat/completions request schema

Replace Section 6.2's partial schema with the full OpenAI-compatible
request contract. Required content:

- Required fields, with exact types and constraints:
  * `model` (string, must match loaded model id; error 404 if mismatch)
  * `messages` (array, non-empty; per-message validation below)
- Optional fields (with types and defaults):
  * `max_tokens` (int, default depends on remaining context capacity)
  * `temperature` (float, 0.0–2.0, default 1.0)
  * `top_p` (float, 0.0–1.0, default 1.0)
  * `n` (int, MUST be 1; reject 400 if >1 — single-tenant)
  * `stream` (bool, default false)
  * `stream_options` (object with `include_usage`: bool; required to be true
    if stream=true per FR-7's usage chunk requirement)
  * `stop` (string or array<string>; max 4 entries)
  * `presence_penalty`, `frequency_penalty` (float -2.0..2.0)
  * `seed` (int, optional, passed to MLX for deterministic decoding)
  * `user` (string, optional, logged for debugging only)
  * `response_format` (object with `type`: "text" | "json_object";
    "json_object" engages MLX's structured-decoding hint if available;
    "content_filter" enum value is RESERVED for Tier 2 — Tier 1 rejects
    with 400 to keep the wire contract clean)
- Per-message validation:
  * `role` is one of "system", "user", "assistant", "tool"
  * "system" messages MUST have string `content`
  * "user" messages MUST have string `content` (no multimodal content
    arrays in Tier 1)
  * "assistant" messages MAY have string `content` OR `content: null`
    with `tool_calls`. If both `content` and `tool_calls` are null or
    absent: error 400.
  * "tool" messages MUST have `tool_call_id` (string) and `content` (string)
- Tool-call shape:
  * Top-level `tools` and `tool_choice` are PARSED and ECHOED in response
    behavior in Tier 1: parse them syntactically; if malformed → 400. The
    binary does not actually execute tool calls but it must validate
    the shape so SPEC-002's coordinator can route tool-aware buyers.
  * If `tools` is present and malformed (any tool missing `function.name`
    or `function.parameters` not being valid JSON Schema), reject with
    400 and error `{"error": {"message": "invalid tools[N]", "type":
    "invalid_request_error", "code": "invalid_tools"}}`.
  * `tool_calls` in assistant messages (history): validate
    `[{id, type: "function", function: {name, arguments: string}}, ...]`.
    Each `arguments` must be valid JSON (string-encoded). Malformed → 400.
- Unknown top-level fields: ignore silently (forward-compat), log at
  DEBUG level for diagnostics.

Add a "Validation order" subsection naming the steps the request handler
runs in order (parse → schema check → tool validation → model match →
context pre-flight → enqueue), with the HTTP status produced at each
failure point.

### MAJOR C1 — Tier 2 decrypt ordering

Update Section 3 architecture diagram so the request chain in Tier 2 mode
is:

```
HTTP receive → JSON parse → schema validate →
  [Tier 2: InputDecryptor → token-count pre-flight] |
  [Tier 1: token-count pre-flight] →
inference → response stream → [Tier 2: OutputEncryptor] → HTTP send
```

Update FR-8 to specify two-stage pre-flight as described in A3 above.

## Major fixes (apply after critical)

Walk the audit findings in order. For each:
- If MAJOR, address it.
- If MINOR, address it if cheap; otherwise document the decision in
  implementation-notes.html under "Knowingly deferred minor findings."

Per-finding required changes:

### B2 — Heartbeat schema completeness
Update Section 6.5 heartbeat schema to include EVERY field FR-17 names:
`model_id`, `model_params_b`, `max_context_tokens`, `max_concurrency`,
`current_slots_free`, `throughput_tps_estimate`, `ram_gb`. Static fields
appear in hello/hello_ack AND every heartbeat (so the coordinator can
re-establish state if it restarts).

### B3 — State-transition messages
Add a `state_update` message type in Section 6.5 (P→C):
```json
{
  "type": "state_update",
  "state": "healthy" | "degraded" | "unavailable" | "draining",
  "reason": string,
  "since": ISO8601 timestamp,
  "metrics_snapshot": {... same as heartbeat ...}
}
```
Fired whenever state changes, independent of heartbeat schedule.

### B4 — Drain status (P→C)
Add `drain_status` message in Section 6.5 (P→C):
```json
{
  "type": "drain_status",
  "phase": "starting" | "in_progress" | "complete",
  "inflight_requests": int,
  "estimated_drain_seconds": int
}
```
Required when binary receives SIGTERM/SIGINT (FR-12) or coordinator
`drain` command (current C→P).

### B5 / G2 — Coordinator auth (DEFERRED per A1)
Remove `coordinator_token` from open questions (Section 10) and from any
FR. Add to Section 7 dependencies: "Coordinator authentication: deferred
to SPEC-002."

### B6 — Acceptance coverage
Add AC-6 through AC-10 to cover FR-12, FR-16, FR-18, FR-19, FR-20:
- AC-6: SIGTERM during 3 in-flight requests → drain completes ≤30s,
  drain_status messages logged, 0 mid-stream cuts.
- AC-7: Wake-event hook `warm_up` from coordinator → first request after
  warm_up shows ≥95% throughput of long-running baseline.
- AC-8: GET /v1/health returns 200 + JSON `{status, model, uptime_s,
  slots_free, slots_total}` when healthy; 503 with same JSON when degraded.
- AC-9: Config precedence: CLI flag > env var > config file > default.
  Test by overriding `port` at each layer.
- AC-10: Startup self-test failure (model load fails) → binary exits with
  code 1 and diagnostic to stderr; no partial server state.

### E2 — Error responses
Add to Section 6.2:
- Global 404: any unrecognized path → `{"error": {"message": "not found",
  "type": "invalid_request_error", "code": "path_not_found"}}`
- Global 405: wrong method → 405 with `Allow` header.
- Malformed JSON body: 400 with `{"error": {"message": "invalid JSON",
  "type": "invalid_request_error", "code": "invalid_json"}}`.
- Streaming error after headers sent: emit `data: {"error": {...}}\n\n`
  then `data: [DONE]\n\n` and close. Do not change HTTP status mid-stream.
- /v1/health failure shape: 503 with same body as 200, but `status: "degraded"`.
- Coordinator protocol negative-ack: `{"type": "nak", "in_reply_to":
  <msg_id>, "error": {"code": string, "message": string}}`.

### E3 — Preflight reason enum
Enumerate ALL valid `reason` values for coordinator `preflight_response`
with `accepted: false`:
- `context_exceeds_capacity` (with `max_context_tokens` field)
- `queue_full` (with `estimated_wait_ms`)
- `draining`
- `model_not_loaded`
- `unhealthy`
- `tier_mismatch` (e.g. coordinator asked for Tier 2 but binary is Tier 1)

### F1 — Acceptance test commands
For each AC, add a "Run by:" line with the exact command. Use harness.py
where applicable. Example:
- AC-1 Run by: `cd beta && python harness.py --config <fixture> --batch
  cooperative --verbose` where `<fixture>` is `beta/config-phase3-test.yaml`
  pointing at the SPEC-001 binary's HTTP endpoint. SPEC-001 v1.1 must
  include a stub for this fixture path; the binary build creates the file.
- AC-2 Run by: `cd beta && python harness.py --config <fixture> --batch
  adversarial --verbose`
- AC-3 (24h soak) Run by: `phase3-binary/scripts/soak-test.sh` — to be
  created during build. The script wraps a long-running harness invocation
  with a memory-pressure monitor.
- AC-5 (mock coordinator) Run by: `phase3-binary/scripts/test-coordinator.sh`
  — to be created during build. Spins up a mock WebSocket server that
  exchanges handshake + 5 heartbeats + drain.

### F2 — Pass rule
Add to Section 9 introduction: "AC-1 through AC-10 must ALL pass for the
binary to be considered build-complete. No partial passes, no operator
waivers without an explicit waiver entry in implementation-notes.html."

### H1 — Dependency pinning
Section 7.1: pin each dependency to a specific tag or commit. Use:
- `mlx-swift-lm`: from `https://github.com/ml-explore/mlx-swift-examples`,
  pin to a specific release tag (record the tag chosen) AND record the
  commit SHA at v1.1 write time
- `swift-nio`: `2.65.0` (or current stable; record the actual choice)
- `swift-log`: `1.6.0`
- `swift-argument-parser`: `1.5.0`
- `Yams`: `5.1.0`
Note that these are starting pins; the build session may bump after
testing, with a documented reason in implementation-notes.html.

### I1 — Coordinator-internals language
Strip language from SPEC-001 that prescribes coordinator behavior beyond
wire contract. Specifically Section 8's "FR mapping" column entries that
say "coordinator must route by..." — restate as "Coordinator MAY use
these fields. Binary's responsibility ends at sending them."

### Remaining MAJOR + MINOR

Apply the rest from the audit doc following the audit's recommended fix
order. For each MINOR you DON'T fix, log a one-line entry in
implementation-notes.html under "Knowingly deferred minor findings"
with reason ("low value", "rephrasing risk introducing new ambiguity", etc.).

## Coverage matrix update

Section 8 currently has a partial coverage matrix for decision log entries.
Update it to:
- Include EVERY row from beta/DECISION_CRITERIA.md's decision log
- Mark each as: Fully covered | Partial (with reason) | Process-only (with
  reason)
- For rows currently "uncovered" or "partial," promote to "covered" by
  adding the missing FR, OR explicitly mark "process-only" with rationale

## Open questions cleanup

Section 10 should have 4-6 open questions after revision (down from 9).
Convert the following to defaults or remove (per audit G1):
- mDNS discovery → default to "no; deferred to SPEC-007 if ever needed"
- Local SQLite vs stdout for logging → pick "JSON Lines to stdout, captured
  by launchd; optional file via `log_file` config"
- Config file location → default to `~/.config/macprovider/config.yaml`
  with override by CLI flag
- Queue eviction policy → default "FIFO, no time-based eviction in v1; queue
  rejects 429 when full"
- Mid-stream resumption → "not supported in v1"

Each becomes a one-line "Default chosen:" entry in Section 9 (Acceptance
Criteria's implicit defaults), not an open question.

## Output: implementation-notes.html update

Append a new section at the top of the existing scaffold:

```html
<section id="v1-1-revision">
  <h2>SPEC-001 v1.1 revision (2026-05-27)</h2>
  <p class=meta>Applied audit findings from
  <a href="../specs/SPEC-001-audit.md">SPEC-001-audit.md</a>.</p>

  <h3>Resolved operator decisions</h3>
  <ul>
    <li><strong>Provider auth:</strong> deferred to SPEC-002.</li>
    <li><strong>HTTP 500 during adversarial:</strong> disallowed; only
    400/413/429/200 acceptable.</li>
    <li><strong>Tier 2 encrypted prompts:</strong> hard architecture
    constraint; decrypt before token pre-flight.</li>
  </ul>

  <h3>Reference hygiene update</h3>
  <p>DARKBLOOM LICENSE AGREEMENT verified as custom restrictive license,
  not OSI-approved open source. Switched to strict clean-room for
  d-inference: no source files referenced, only public papers/blog posts.</p>

  <h3>Findings addressed</h3>
  <p>2 CRITICAL, [N] MAJOR, [N] MINOR — see SPEC-001-audit.md for
  per-finding mapping.</p>

  <h3>Knowingly deferred minor findings</h3>
  <ul>
    <!-- one-line entry per deferred minor with reason -->
  </ul>
</section>
```

Insert this BEFORE the existing "Design decisions" section. The existing
sections (design decisions, deviations, tradeoffs, open questions, refs
consulted) remain empty for the build session to fill.

## specs/README.md update

Update the SPEC-001 row to show:
```
| SPEC-001 | Phase 3 binary (Swift) | v1.1 | reviewed against audit |
```

## Commit message

When done, propose this exact commit message (operator runs the actual git
commit; you do not run it):

```
SPEC-001 v1.1: address audit findings; strict clean-room reference policy

Audit (specs/SPEC-001-audit.md) flagged 2 CRITICAL + 17 MAJOR + 9 MINOR.
v1.1 addresses all CRITICAL, all but the cheapest-to-defer MAJOR, and
applies easy MINORs. Knowingly deferred items recorded in
implementation-notes.html.

Reference policy revised: DARKBLOOM LICENSE AGREEMENT verified as custom
restrictive license. Strict clean-room established. d-inference source
is not consulted; only public papers and our own findings inform the spec.

Resolved operator questions:
  - Provider auth deferred to SPEC-002
  - HTTP 500 disallowed during adversarial acceptance
  - Tier 2 decrypt ordering: hard architecture constraint

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

## Hard rules

1. SPEC-001 is edited IN PLACE — same file, same path. Version is tracked
   by the spec's own metadata line (add "Version: 1.1, dated 2026-05-27").
2. Don't introduce new requirements that weren't in v1.0 unless directly
   prompted by an audit finding.
3. Don't relitigate decisions pinned in this prompt (auth, 500s, decrypt
   ordering, clean-room).
4. Don't reduce existing coverage. If a fix accidentally weakens a
   requirement, flag it as a deviation in implementation-notes.html.
5. Don't fetch or read d-inference source files. The license analysis is
   already done; the verbatim Section 7.2 replacement above IS the result.

## Anti-rules

- Don't restart spec writing from scratch. v1.0 is mostly right; you're
  applying patches.
- Don't add operator-facing TODOs. Either fix the issue or document the
  deferral with rationale.
- Don't expand the spec beyond ~2000 lines total. If you're past that
  budget, you're probably over-engineering.
- Don't quote audit findings verbatim in SPEC-001. The spec is its own
  artifact; the audit lives in its own file. Reference by finding id
  (e.g., "addresses audit B2") in implementation-notes.html only.

## When you finish

1. Re-read SPEC-001 v1.1 end to end. Does any audit finding remain
   unaddressed without an entry in "Knowingly deferred"? If yes, fix.
2. Update implementation-notes.html as specified.
3. Update specs/README.md as specified.
4. Print to stdout:
   - The proposed commit message (verbatim)
   - A <200-word summary of what changed
   - Count of audit findings: addressed vs deferred
   - Recommendation: re-audit YES/NO (if more than 2 MAJOR were complex
     enough that v1.1 might have introduced new issues, recommend re-audit)

That's the whole job. Begin by reading the required files in order.

=== END PROMPT ===
```

---

## How to use

```bash
cd /Users/augstar/macprovider-poc
claude < specs/FIX_SPEC_001_V1_1_PROMPT.md
```

Expected wall time: 1–1.5 hours.

## What you'll get back

- `specs/SPEC-001-phase3-binary.md` — edited in place, now v1.1
- `phase3-binary/implementation-notes.html` — new top section recording v1.1 revision
- `specs/README.md` — SPEC-001 row updated to v1.1
- A `<200-word` summary + commit message in the final reply
- A recommendation: re-audit or proceed to build?

## Recommended flow after v1.1 lands

| Step | Effort | What it does |
|---|---|---|
| Read v1.1 yourself | ~20 min | Sanity check, especially Section 6 (interface contracts) and Section 7.2 (reference hygiene) |
| **Optional re-audit** | ~30 min | If the fixer recommends it OR you want extra confidence. Same Codex audit prompt; should return < 5 MAJORS this time |
| Commit | ~1 min | Use the commit message from the agent's output |
| Start binary build | next session | Use the operator-paste invocation block at SPEC-001 § 0 |

## Why this prompt is shorter than the build prompt

Build prompt had to generate a 1500-line spec from scratch. Fix prompt only patches a working spec. Most decisions are already made — this prompt just locks in answers and points at audit findings.

## What stays open after v1.1

- **Patent analysis for Tier 2.** Deferred to its own SPEC.
- **Coordinator protocol details** beyond wire contract — SPEC-002 territory.
- **Buyer-facing API** — SPEC-006.
- **Reward distribution** — SPEC-005.

None of these block the Phase 3 binary build. v1.1 should be build-ready.
