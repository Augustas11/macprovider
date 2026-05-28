# Audit prompt — SPEC-003 second-opinion review

Operator-paste prompt to audit `specs/SPEC-003-open-onboarding.md` after
it's been written by Claude. Run with **Codex CLI** for cross-model
independence — the SPEC-003 draft was written by Claude; the auditor
should be Codex to maximize the chance of catching blind spots.

The auditor's job: find problems. Be skeptical. Expected duration: ~60min.

Paste everything between the markers into a fresh Codex CLI session rooted
at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-003 (Open onboarding + WS-tunneled inference +
dynamic admission + distribution lifecycle) for the Mac Provider
project. You previously audited SPEC-001 (Phase 3 binary spec) and
SPEC-002 (Phase 4 coordinator spec); your prior audit outputs live at
specs/SPEC-001-audit.md, specs/SPEC-001-v1-1-audit.md,
specs/SPEC-002-audit.md, and specs/SPEC-002-v1-0-2-audit.md.

Your job: read SPEC-003 v0.1 and its source materials, then produce a
structured audit report at /Users/augstar/macprovider-poc/specs/SPEC-003-audit.md.
Find what's wrong, ambiguous, missing, over-specified, or inconsistent
with SPEC-001 v1.1.4 / SPEC-002 v1.0.4 / the Decision log entries 12-18.
You are NOT here to validate or rewrite SPEC-003. Find problems, report
them, let the operator decide fixes.

SPEC-003 is the project's first architectural pivot. It amends SPEC-001
v1.1.4 § 6.5 (WebSocket envelope) and SPEC-002 v1.0.4 § 7.1 (static
provider config map) + § 3 (request forwarding model). Cross-spec
consistency is the highest-value check in this audit.

## Critical constraints to honor while auditing

**1. d-inference clean-room.** The d-inference codebase
(https://github.com/layr-labs/d-inference) is custom-licensed
(NOASSERTION SPDX). Do NOT inspect their source code at any point.
Reading their LICENSE for cross-reference is allowed; reading
README/docs is allowed but discouraged. If you find yourself reaching
for d-inference inspiration to evaluate a SPEC-003 design choice, stop
and reason from first principles (or from the industry patterns cited
in SPEC-003 § 5.1: Tor, Tailscale, GitHub Actions runners, AWS IoT,
Cursor agents). The WS-tunneled inference pattern is convergent design,
not derivative; verify the spec's rationale chain stands on its own.

**2. Buyer API stability.** The buyer-facing HTTP API
(POST /v1/chat/completions, GET /v1/models, GET /healthz) MUST NOT
change in observable behavior. Any place SPEC-003 mentions buyer-side
changes is a CRITICAL finding.

**3. Backward compat for pinned providers.** M4 (running phase3-binary
v1.1.4) and M1 (v1.1.3) are in production today serving real traffic
through HTTP-forwarding mode. They must continue to work unchanged
after SPEC-003 ships. Any spec text that requires M4/M1 to upgrade
or reconfigure is a CRITICAL finding unless explicitly justified.

**4. Match SPEC-001/002 rigor.** Those specs went through 3-4 audit
rounds each. Apply the same severity bar. "Hand-wavy" requirements,
unjustified numeric thresholds, and "TBD"s disguised as OQs are MAJOR
findings.

## Required reading (in order, fully)

1. /Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md
   — the spec under audit. ~2245 lines / 92 KB / 15 top-level sections.
   Read all of it; do not skim Part A (§ 5) since that's the highest-risk
   wire-protocol design in the project so far.

2. /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
   v1.1.4 — the binary spec SPEC-003 amends. § 6.5 (WebSocket envelope)
   is the most important section. Note v1.1.3 + v1.1.4 change logs — they
   document the drain-conflation bug + state-reset fix discovered during
   Phase 4 deploy. SPEC-003 Part A must not re-introduce either.

3. /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md v1.0.4
   — the coordinator spec SPEC-003 amends. Pay attention to:
     § 3   Request forwarding model (SPEC-003 replaces this for
           provisional providers; preserves it for pinned)
     § 5   Routing algorithm (SPEC-003 adds admission-tier weight)
     § 7.1 Provider WebSocket (SPEC-003 extends with 4 new message types)
     § 7.4 Operator endpoints (SPEC-003 adds 3 more)
     § 10  D6 findings F-1/F-2/F-3 (SPEC-003 § 9 references + extends)

4. /Users/augstar/macprovider-poc/specs/BUILD_SPEC_003_PROMPT.md
   — what the spec writer was instructed to produce. Check whether
   SPEC-003 actually delivers the outline + honors the constraints.

5. /Users/augstar/macprovider-poc/specs/SPEC-001-audit.md
   /Users/augstar/macprovider-poc/specs/SPEC-001-v1-1-audit.md
   /Users/augstar/macprovider-poc/specs/SPEC-002-audit.md
   /Users/augstar/macprovider-poc/specs/SPEC-002-v1-0-2-audit.md
   — your prior audits, for tone/format continuity.

6. /Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md
   — decision log entries 12-18 cover the Phase 4 deploy, drain bugs,
   and the Day 2 wrap that motivated SPEC-003. SPEC-003 § 9 (D7-D10)
   claims to encode lessons from these; verify the encoding is faithful.

7. /Users/augstar/macprovider-poc/phase4-coordinator/internal/ws/messages.go
   /Users/augstar/macprovider-poc/phase4-coordinator/internal/ws/server.go
   — current wire-format Go structs + handlers. SPEC-003's new message
   types should be specifiable in terms compatible with these.

8. /Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift
   — current provider-side WS handler. SPEC-003 § 5 (Part A) must
   compose cleanly with the existing drainFromCoordinator() and the
   v1.1.4 state-reset path.

9. /Users/augstar/macprovider-poc/HANDOFF.md and CONTINUE_RUNBOOK.md
   — project context.

You may browse the rest of phase3-binary/ and phase4-coordinator/ for
context. Do NOT browse d-inference repos or sources, even if accessible.

## Audit categories — work through each

### Category A: Cross-spec consistency (HIGHEST PRIORITY)

A.1  Does SPEC-003 explicitly state which SPEC-001 / SPEC-002 sections
     it amends? Missing amendment markers = MAJOR. Unclear amendment
     markers = MINOR.

A.2  Walk through SPEC-001 v1.1.4 § 6.5 message types. SPEC-003 adds 4
     new types (inference_request, inference_response_chunk,
     inference_response_end, cancel_request). Do they:
     - Use the same `type` field convention as existing messages?
     - Use compatible JSON envelope shape (no nested `payload` field
       breaking from existing flat shape)?
     - Specify request_id correlation field consistent with existing
       preflight request_id usage?
     - Avoid shadowing any existing field name with different semantics?
     Any wire-incompatible choice = CRITICAL.

A.3  SPEC-001 v1.1.4 specified that coordinator-initiated drain MUST
     reset provider state to ready (§ 6.5 drain message normative
     paragraph). Does SPEC-003 Part A respect this when WS-tunneled
     inference requests are in flight during a drain? What happens to
     in-flight inference_request requests when drain arrives?
     CRITICAL if undefined.

A.4  SPEC-002 v1.0.4 F-2 says coordinator rejects unknown provider_id
     with close 4002. SPEC-003 Part B relaxes this with provisional
     tier. Is the transition path normative (when does close 4002
     fire vs. when does provisional admission happen)? Is there a
     coordinator config flag that determines which? CRITICAL if
     ambiguous.

A.5  SPEC-002 v1.0.4 F-3 says admin endpoints live on provider_port,
     not buyer_port. SPEC-003 Part B adds /admin/provisional,
     /admin/promote, /admin/reject. Are they explicitly on
     provider_port? MAJOR if silent.

A.6  Coordinator deploy script (deploy-pearl-vps.sh) has FORCE_RESTART
     safeguard from Decision log Entry 15. SPEC-003 introduces dynamic
     admission, which changes what "providers connected" means (now
     includes provisional). Does SPEC-003 update the safeguard
     semantics? MAJOR if silent.

### Category B: Wire protocol rigor (Part A — highest risk)

B.1  Multiplexing. SPEC-003 claims N concurrent requests per WS via
     request_id demux. Walk through the failure modes:
     - What if provider returns inference_response_end for a request_id
       the coordinator never sent? (silently drop? log? close WS?)
     - What if coordinator sends 2 inference_requests with the same
       request_id? (must reject? duplicate-detect window?)
     - What if request_id is never reused but the provider keeps
       state per request_id — is there a cleanup policy?
     Each = MAJOR if undefined.

B.2  Streaming chunk framing. SPEC-003 must specify EXACTLY how SSE
     chunks map to WS frames. Options the spec must choose between:
     (a) one WS frame per SSE chunk, (b) batched chunks per frame,
     (c) bytewise stream with separator. Whichever is chosen, ordering
     and atomicity guarantees must be normative. MAJOR if ambiguous.

B.3  Cancellation latency. SPEC-003 § 5.6 (or equivalent) claims 1s
     SLA from buyer disconnect to provider abort. Trace the path:
       buyer TCP RST -> nginx detect (~100ms?) -> coord buyer-side
       detect -> coord lookup provider -> send cancel_request WS frame
       (~50ms TLS) -> provider parse + signal model -> model abort
       (model-runtime-dependent).
     Is 1s achievable? What's the rationale for 1s vs 500ms vs 5s?
     MAJOR if no rationale.

B.4  Backpressure. SPEC-003 must specify per-provider WS write buffer
     bounds. Walk through: provider model is generating 100 tokens/sec
     at 200 bytes/token = 20 KB/sec; if buffer is 1 MB, that's 50s of
     buffering before drop. Is the drop policy (close WS? abort
     request? blocking send?) normative? MAJOR if undefined.

B.5  Backward-compat detection. SPEC-003 says coordinator inspects
     `endpoint_url` in hello to determine routing mode (HTTP-forward
     vs WS-tunneled). What if a pinned provider sends hello with NO
     endpoint_url? (treat as provisional? error? use static config
     fallback?) What if a provisional provider sends hello WITH
     endpoint_url? CRITICAL if undefined — affects M4/M1 directly.

B.6  Error semantics. SPEC-003 must distinguish:
     - Protocol errors (malformed inference_request) → nak per SPEC-001
     - Inference errors (model not loaded, OOM) → inference_response_end
       with non-200 status
     - Network errors (provider disconnected mid-stream) → coordinator
       returns 502/503 to buyer + cancels pending state
     Are all three paths normative? MAJOR if conflated.

B.7  Frame size limits. OQ-1 already calls out 32K-token responses.
     Does SPEC-003 give an interim default (e.g., 64 KB per frame)
     pending resolution? MAJOR if OQ-1 leaves the value entirely
     undefined — implementations need at least a default to compile.

### Category C: Admission tier semantics (Part B)

C.1  Are rate limits internally consistent? SPEC-003 specifies:
     - 10 admissions/hr globally
     - 100 total provisional cap
     - 100 requests/hr/provider
     Math check: 10 admissions/hr × 24 hr = 240/day, but cap is 100.
     Does eviction policy exist? (LRU on inactivity? FIFO? operator-
     directed?) MAJOR if cap unenforceable.

C.2  Routing weight integration. SPEC-002 § 5 routing was sort-stable
     on (slots_free ASC, throughput DESC, connected_at ASC). SPEC-003
     adds tier weight (pinned 1.0, provisional 0.3). Where in the sort
     does this weight apply? Multiplicative? New primary key? Spec
     must be explicit. MAJOR if ambiguous.

C.3  Rejected tier persistence. If a provider is rejected, does the
     ban survive coordinator restart? Is there a JWT-like proof, an
     IP ban, a provider_id blocklist? SPEC-003 must specify storage.
     MAJOR if undefined.

C.4  Anti-abuse posture. Without Tier 2 attestation, what prevents:
     (a) Sybil attack: one actor spinning 100 provisional providers
         to drain the pool, monopolize buyer traffic, then collect
         tokens?
     (b) Resource exhaustion: provisional provider that always passes
         preflight but then returns garbage / hangs on
         inference_request?
     OQ-7 acknowledges this; the audit should evaluate whether the
     interim mitigations (rate limit, request quota) are adequate or
     just lip service. MAJOR if mitigations are insufficient AND not
     called out as such.

C.5  Promotion persistence (OQ-6 territory). Is admin/promote a
     runtime-only operation, or does it write back to
     coordinator.yaml? Decision log Entry 17 explicitly flagged this
     class of bug. Is the resolution normative? MAJOR if OQ-6 dodges
     the question.

### Category D: Distribution lifecycle (Part C)

D.1  install.sh contract. Does SPEC-003 specify the script's
     normative behavior precisely enough to write a security review
     against?
     - What does it download from where?
     - SHA256 verification: against what reference?
     - What gets installed at what paths with what permissions?
     - What runs as the user vs. needs sudo?
     MAJOR if any of these are vague.

D.2  Self-update. SPEC-003 must specify what happens to in-flight
     requests during macprovider-cli update:
     - Drain protocol like SIGTERM?
     - Buyer-visible behavior (503 for the swap window)?
     - Rollback on update failure?
     MAJOR if any gap.

D.3  launchd plist. Is the exact path + reverse-domain + RunAtLoad +
     KeepAlive policy normative? Logging path specified? Restart-on-
     crash policy normative? MAJOR if not.

D.4  Version nudging vs enforcement. OQ-4 acknowledges the policy
     gap. Is the interim behavior (nudge only, no enforcement)
     normative? MAJOR if SPEC-003 makes implementation hand-wave.

D.5  Coordinator-advertised version. New field in hello_ack — does
     it amend SPEC-001 v1.1.4 § 6.5 hello_ack schema? Cross-spec
     consistency check (overlaps with A.2).

### Category E: Onboarding UX (Part D)

E.1  Is the curl-pipe-bash pattern called out as inherently risky
     (no signature verification before execution)? Mitigation
     proposed? MAJOR if the security tradeoff is invisible.

E.2  First-run model download. Is the download size + duration
     surfaced to the user? Bandwidth-constrained users have a right
     to know "you're about to download 5 GB." MINOR if absent.

E.3  Uninstall coverage. Does macprovider-cli uninstall remove:
     binary, plist, logs, models, runs.sqlite, any system caches?
     MINOR if incomplete; MAJOR if uninstall leaves orphaned
     launchd jobs that could re-spawn.

### Category F: Backward compatibility for pinned providers

F.1  Walk through what happens when M4 (current v1.1.4) reconnects
     after a coordinator that's been updated to support SPEC-003.
     Their hello will include endpoint_url (from coordinator's
     static config). Does the coordinator route via HTTP-forwarding
     unconditionally? CRITICAL if not normative.

F.2  Walk through what happens when a NEW provisional provider's
     handle collides with a pinned provider_id (e.g., they claim
     "m4-anon"). Does the coordinator reject the provisional? Force-
     close? Apply pinned tier? CRITICAL if undefined.

F.3  Will today's `install-m4-coordinator.sh` continue to work after
     SPEC-003 ships? (Provider still sends hello with provider_id +
     coordinator_url; the only change is admission-tier logic on the
     coord side.) MAJOR if SPEC-003 silently breaks the existing
     install path.

### Category G: Buyer API stability

G.1  Does SPEC-003 modify any field in the OpenAI-compatible request
     or response shape? CRITICAL if yes (load-bearing invariant).

G.2  Does SPEC-003 change the routing target for any
     model_id-buyer-request combination that worked yesterday? E.g.,
     today a buyer asking for "mlx-community/Qwen2.5-7B-Instruct-4bit"
     gets routed to M4. After SPEC-003, do they still? CRITICAL if
     the routing change would affect a real buyer in production.

G.3  /v1/models aggregation — does the admission tier affect which
     models are advertised? E.g., is a provisional-only model
     advertised? Should it be? MAJOR if undefined.

### Category H: Internal consistency

H.1  Do FRs contradict each other?
H.2  In-scope (§ 2) matches what FRs (§ 4) cover?
H.3  Acceptance criteria (§ 10) test the FRs?
H.4  Interface contracts (§ 7) consistent with FRs referencing them?
H.5  Open questions (§ 11) actually open, or hand-waved decisions?

### Category I: Acceptance criteria

I.1  Are AC-1..AC-12 measurable, with concrete commands or script
     names?
I.2  AC-1 (mockprovider WS-tunneled inference) — does it reference an
     existing or to-be-created mockprovider tool? SPEC-003 should
     either extend phase4-coordinator/tools/mockprovider or specify
     a new tool path.
I.3  AC-8 (install.sh <2 min from clean Mac) — what counts as "clean"?
     Reproducible test environment specified? Otherwise the AC is
     unverifiable. MAJOR if absent.
I.4  AC-9 (atomic update with running service) — does the test setup
     accommodate the v1.1.3-style drain handshake?
I.5  Pass rule stated? (All ACs must pass, no partials.)
I.6  At least one AC exercises backward-compat (pinned + provisional
     in same pool)?

### Category J: Open questions

J.1  Count: target 5-8. Spec has 7. Are any actually defaults dressed
     as questions?
J.2  For each OQ, can YOU (the auditor) answer it from source
     materials (Decision log, prior specs, industry practice)?
     If yes, the OQ is artificial and should be MAJOR finding "OQ-X
     is decidable from sources."
J.3  Are OQ-1 (frame size), OQ-4 (version enforcement), OQ-5 (code
     signing) given enough rationale that the operator can decide
     without re-research?

### Category K: Reference hygiene (clean-room)

K.1  § 8 (or wherever it lives) reaffirms d-inference clean-room
     separation? Same wording as SPEC-001 § 8.2 / SPEC-002 § 8.2?
K.2  Any d-inference URLs or references outside the hygiene block?
K.3  Convergent-design rationale chain in § 5.1 (or wherever Part A
     architecture is justified) cites industry patterns explicitly
     (Tor, Tailscale, GitHub Actions, etc.) with at least one
     concrete reference per citation?

### Category L: Scope discipline

L.1  Anything that belongs in SPEC-004 (smart router), SPEC-005
     (rewards), SPEC-007 (Antseed seller, was SPEC-003) sneak in?
L.2  Does SPEC-003 over-constrain SPEC-007's eventual Antseed
     integration?
L.3  Tier 2 attestation territory crept in?
L.4  Anything that should be in a future revision of SPEC-003
     (v0.2+) and is bloating v0.1?

### Category M: Implementability

M.1  Could a competent Swift+Go developer (or fresh Claude/Codex
     session) start coding Part A with ≤3 clarifications? List them
     if more.
M.2  Are new Go dependencies (if any) pinned to specific versions?
M.3  Is the multiplexing/cancellation/backpressure spec (§ 5)
     detailed enough for build session to implement without operator
     guidance?
M.4  Does the build-step section (§ 12) provide paste-ready Codex
     prompts for each phase (phase3-binary v1.2, coordinator v0.2,
     install.sh, etc.)?

## Severity rubric

  CRITICAL — wire compat break with SPEC-001 v1.1.4 (would corrupt
             M4/M1 routing), buyer API observable change, anti-abuse
             loophole at provisional tier, undefined behavior in
             backward-compat path, internally contradictory FRs at
             the "X must Y" / "X must not Y" level.

  MAJOR    — ambiguous requirement with multiple valid interpretations,
             missing acceptance for a stated capability, OQ that's
             actually decidable from sources, dependency not pinned
             where pinning matters, numeric threshold without
             rationale, normative gap in error semantics.

  MINOR    — formatting, wording, or default choices that cause
             friction but not failure.

  QUESTION — auditor cannot determine from source materials.

## Output format

Write to:
  /Users/augstar/macprovider-poc/specs/SPEC-003-audit.md

Structure:

  # SPEC-003 Audit Report
  Auditor: <model name + version>
  Spec audited: SPEC-003 v0.1 commit <hash if known>
  Audit completed: <UTC timestamp>

  ## TL;DR verdict
  READY TO BUILD | NEEDS REVISION | RESTART
  One paragraph with finding counts and the top three risks.

  ## Findings by severity

  ### CRITICAL (N)
  ### MAJOR (N)
  ### MINOR (N)
  ### QUESTIONS (N)

  Format per finding: title, severity, category (A-M), section ref
  (§ N or FR-X / AC-X / OQ-X), quoted spec text, what's wrong,
  fix direction.

  ## Cross-spec consistency matrix

  Standalone table verifying every claimed amendment to SPEC-001
  v1.1.4 and SPEC-002 v1.0.4 is internally consistent. Columns:
  - Source spec/section
  - SPEC-003 amendment claim
  - Auditor verdict: consistent / partial / contradictory

  ## OQ disposition

  For each of the 7 OQs in SPEC-003 § 11:
  - Quote the OQ
  - State whether you (auditor) can answer it from source materials
  - If yes, propose the answer + cite the source
  - If no, confirm it's a real operator decision

  ## Suggested fix order

  Ordered list of which findings should be addressed first in the
  next revision. Group CRITICALs first, then MAJORs that block
  build start, then MAJORs that block ship.

## What NOT to do

  - Do NOT modify SPEC-003 yourself. Audit only.
  - Do NOT build or scaffold code.
  - Do NOT browse d-inference repos or sources.
  - Do NOT propose features beyond fix direction (no scope creep
    into v0.2 design).
  - Do NOT validate by running the AC scripts — those don't exist yet.
    Validate by reading the spec.

When done, print a 200-word summary to stdout with the verdict +
finding counts + your top three risks + which OQs you could answer
from sources. Then stop.

=== END PROMPT ===
```

---

## After running this prompt

Expected outputs:
- `specs/SPEC-003-audit.md` (full audit report)
- stdout 200-word summary

Then:
1. Operator reads the audit verdict + top three risks
2. If verdict is READY TO BUILD with only MINORs → skip directly to build prompt
3. If verdict is NEEDS REVISION → use `FIX_SPEC_003_V0_1_PROMPT.md` (to be drafted next) to have Claude resolve findings, producing v0.2
4. Re-audit v0.2 (`AUDIT_SPEC_003_V0_2_PROMPT.md` — same structure, narrower scope)
5. Repeat until clean (target 2-3 rounds total, matching SPEC-001/002 pattern)
6. Then `BUILD_SPEC_003_PROMPT.md` hands off to implementation

The audit prompt is intentionally heavy on Categories A (cross-spec consistency) and B (wire protocol rigor) because those are the parts of SPEC-003 that, if wrong, would either break M4/M1 in production or produce a deeply broken implementation that's expensive to undo later.
