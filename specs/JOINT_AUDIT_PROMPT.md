# Joint audit prompt — SPEC-001 v1.1.1 + SPEC-002 v1.0.1

Final pre-build audit. Verifies SPEC-002 v1.0.1 patches landed correctly
**and** walks cross-spec consistency between SPEC-001 and SPEC-002. Run
with **Codex CLI** (same auditor as before, for continuity).

Expected duration: ~60–90 minutes.

Paste everything between the markers into a fresh Codex CLI session
rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are conducting the FINAL pre-build audit of the Mac Provider spec
pair: SPEC-001 v1.1.1 (Phase 3 binary) and SPEC-002 v1.0.1 (Phase 4
coordinator). Both have been individually audited and revised. Your job
is to:

1. Verify SPEC-002 v1.0.1 actually addresses each finding from your
   prior SPEC-002 audit.
2. Walk cross-spec consistency — every protocol field, header, enum
   value, hook point, dependency, error code that appears in both specs.
3. Render a single verdict for the spec PAIR — are they jointly ready
   for parallel build?

This is a higher-stakes audit than the prior single-spec rounds because
its output gates 5–8 weeks of build work across two codebases. Be
thorough on cross-spec drift; that's where the highest-leverage
findings will be.

You are NOT here to validate. You are NOT here to rewrite. Find what's
wrong, ambiguous, missing, or inconsistent, and report. The operator
decides fixes.

## Required reading (in order, fully)

1. /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
   v1.1.1 — Phase 3 binary spec, build-ready per prior audits.

2. /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md
   v1.0.1 — Phase 4 coordinator spec, post-audit patches applied.

3. /Users/augstar/macprovider-poc/specs/SPEC-002-audit.md
   — your prior SPEC-002 v1.0.0 audit findings. SPEC-002 v1.0.1 claims
   to address all of these; you verify.

4. /Users/augstar/macprovider-poc/phase4-coordinator/implementation-notes.html
   — top "v1.0.1 patches" section records what the patch round did.
   Use as a cross-check: every claim there should be reflected in
   SPEC-002 v1.0.1.

5. /Users/augstar/macprovider-poc/specs/SPEC-001-audit.md
   /Users/augstar/macprovider-poc/specs/SPEC-001-v1-1-audit.md
   — prior SPEC-001 audits for context only (SPEC-001 is already
   re-audited; don't re-walk it unless cross-spec checks force you).

6. /Users/augstar/macprovider-poc/phase3-binary/implementation-notes.html
   — SPEC-001 v1.1.1 patch log; cross-reference if needed.

7. /Users/augstar/macprovider-poc/HANDOFF.md
   /Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md
   — project context. Decision log entries are inputs both specs must
   address; check coverage matrix.

You MAY consult Go module documentation (pkg.go.dev) and Swift Package
Manager docs to verify dependency tag existence. You may NOT clone
d-inference source files (strict clean-room policy applies to you).

## Audit structure — three parts

### Part 1 — SPEC-002 v1.0.1 patch verification

For each finding in specs/SPEC-002-audit.md (C1-C3, M1-M9, m1-m5, Q1),
produce a one-line verdict:

  CRITICAL findings (C1, C2, C3) — must be ADDRESSED.
  MAJOR findings (M1-M9) — should be ADDRESSED.
  MINOR findings (m1-m5) — should be ADDRESSED or KNOWINGLY DEFERRED.
  QUESTION (Q1) — must be RESOLVED with explicit answer in spec.

Format:

| Finding | Severity | Status | SPEC-002 § ref | One-line justification |
|---|---|---|---|---|
| C1 | CRITICAL | ADDRESSED | § 3, FR-P3 | Static config map locked in; no SPEC-001 amendment. |
| ... | | | | |

Use ADDRESSED / DEFERRED / NOT ADDRESSED / RESOLVED uppercase values
for grep-ability.

### Part 2 — Cross-spec consistency walk

This is the highest-leverage part. The two specs must be coherent as a
system. Walk every category below systematically.

#### 2.1 Protocol message coverage

For every message in SPEC-001 § 6.5:
- Field-by-field name match between SPEC-001's definition and SPEC-002's
  handling references. Any field renamed silently = finding.
- Direction (P→C vs C→P) consistent.
- Required/optional status consistent.
- Enum values (e.g. `state` ∈ {ready, busy, degraded, draining,
  unavailable}) match across both specs exactly.

Produce a matrix:

| Field path | SPEC-001 says | SPEC-002 says | Verdict |
|---|---|---|---|
| `hello.provider_id` | required string | required string, used as static-config key | match |
| `state_update.reason` | string (free-form) | logged values include `http_530_observed` | match — SPEC-001 permits free-form |
| `preflight.purpose` | NOT IN SPEC-001 | added in SPEC-002 recovery preflight | finding if SPEC-001 doesn't tolerate unknown fields |
| ... | | | |

Cover every field. A field in SPEC-002 that SPEC-001 doesn't acknowledge
is a finding unless SPEC-001 explicitly says "unknown fields tolerated"
for that message.

#### 2.2 HTTP header namespace

SPEC-002 introduces several custom headers:
- `X-MacProvider-Pref` (buyer-side)
- `X-MacProvider-Provider` (buyer-side, stable provider_id)
- `X-MacProvider-Session` (buyer-side, session-scoped assigned_id)
- `X-MacProvider-Route` (response, assigned_id)

For each, verify:
- SPEC-001 doesn't reserve a conflicting header name.
- SPEC-001's binary doesn't generate a response header SPEC-002 expects
  to add itself (collision).
- Header semantics are consistent if both specs reference them.

#### 2.3 Endpoint discovery (C1 cross-check)

SPEC-002 says: static `provider_id → endpoint_url` config; no SPEC-001
change. Verify:
- SPEC-001 v1.1.1 truly does not mention endpoint URLs anywhere that
  would conflict.
- SPEC-001's binary serves HTTP on its local port (8080 default); the
  cloudflared tunnel / endpoint mapping is operator-managed externally.
- The binary doesn't need to know its own endpoint URL.

If SPEC-001 implies the binary should know or report its endpoint, that
contradicts SPEC-002's design.

#### 2.4 Auth posture (C2 cross-check)

SPEC-002 says: WebSocket auth optional in v1; path A (no header) is the
default for SPEC-001-strict binaries. Verify:
- SPEC-001 v1.1.1 contains no requirement that the binary send an
  Authorization header (would conflict with path A being "valid").
- SPEC-001 doesn't specify any other auth mechanism on WebSocket
  upgrade that SPEC-002 missed.

If SPEC-001 mentions any auth that contradicts "no header in v1", flag it.

#### 2.5 Recovery preflight (M8 cross-check)

SPEC-002 adds a `purpose: "health_recovery"` field to the `preflight`
message. SPEC-001 § 6.5 defines the `preflight` message shape. Verify:
- SPEC-001 explicitly says unknown/extra fields are tolerated on
  incoming messages (or at minimum: doesn't say they're rejected).
- The `request_id` prefix convention `recovery-probe-` doesn't conflict
  with any SPEC-001 request_id format rules.
- `preflight_ack` response is the same shape regardless of whether the
  triggering preflight had `purpose` set.

#### 2.6 Tier 2 hook point compatibility

SPEC-001 names Tier 2 hooks: `InputDecryptor` (before pre-flight),
`OutputEncryptor` (after response).
SPEC-002 names Tier 2 hooks: `AttestationVerifier` (after hello),
`BuyerEncryptionRelay` (before forwarding), `TrustChainAuditor` (after
response).

Verify:
- These compose: the coordinator's `BuyerEncryptionRelay` sends an
  encrypted payload; the binary's `InputDecryptor` receives it. The
  flow is end-to-end consistent.
- Naming convention is intentional, not accidental drift.
- Neither spec speculates about Tier 2 implementation beyond hook point
  locations.

#### 2.7 Error code consistency

Walk every HTTP status + error code mentioned in either spec:
- Same code = same meaning across both specs?
- Same condition = same code across both specs?
- SPEC-002 routes provider errors through to buyers; verify provider
  error codes (SPEC-001) map cleanly to buyer-facing error codes
  (SPEC-002 § 7.2 error table).

Examples to spot-check:
- 502 in SPEC-001 (provider HTTP layer fails internally) vs 502 in
  SPEC-002 (coordinator received 502 from provider).
- 413 context-too-large in SPEC-001 vs SPEC-002's pre-flight rejection
  flow.
- 503 semantics in SPEC-002 (no eligible provider) — SPEC-001 doesn't
  emit 503, so no direct collision; verify.

#### 2.8 Dependency family consistency

SPEC-001 pins Swift dependencies (mlx-swift-lm 2.29.1, swift-nio 2.65.0,
etc.).
SPEC-002 pins Go dependencies (gobwas/ws v1.4.0, go-chi v5.1.0, etc.).

These are different language stacks so there's no version overlap, but
verify:
- Both targets compatible Linux/macOS combinations (binary on macOS,
  coordinator on Linux).
- No shared third-party service or wire-protocol library version mismatch.

#### 2.9 Reference hygiene

Both specs claim strict clean-room for d-inference. Verify:
- Both specs cite the same d-inference license verdict (NOASSERTION,
  DARKBLOOM LICENSE AGREEMENT).
- Permitted-references lists are functionally equivalent (SPEC-002 has
  a Go-specific addendum, which is fine).
- Neither spec contains a d-inference URL outside its hygiene policy
  block.

#### 2.10 Decision log coverage (joint)

Walk every row in beta/DECISION_CRITERIA.md's decision log:
- D1 (502 vs 530): SPEC-001 handles binary-side; SPEC-002 handles
  coordinator-side. Both covered?
- D2 (post-wake throughput dip): SPEC-001's binary supports warm-up;
  SPEC-002's coordinator dispatches it. Coverage symmetric?
- D4 (capacity-vs-quality): SPEC-001 advertises capacity; SPEC-002
  routes by it. End-to-end coverage?
- Timeline compression: process-only in both.

For each, mark COVERED (both sides) | PARTIAL (one side missing) |
UNCOVERED.

### Part 3 — Final implementability gate

The build sessions will run in parallel and consume both specs. The
question:

**Could a competent Swift dev AND a competent Go dev (or two fresh
Claude/Codex sessions) each pick up their respective spec and build
without requiring more than 3 clarifying questions PER spec, AND
without any cross-spec clarifications that aren't already documented?**

3.1  List the ≤3 clarifications per spec that a builder would still need.
3.2  Identify any cross-spec clarification (where the builder of one spec
     would need to read or ask about the other spec to proceed). These
     are the riskiest, because in parallel builds the two devs don't
     coordinate in real time.
3.3  Verify mock infrastructure (mock provider for coordinator AC, mock
     coordinator for binary AC) is sufficiently specified that one team
     could build a mock without ambiguity.

## Severity rubric

  CRITICAL — cross-spec mismatch that would cause integration failure;
             SPEC-002 v1.0.1 critical patch not actually landed; build-
             blocking ambiguity in either spec exposed by joint reading.

  MAJOR    — cross-spec inconsistency that would cause subtle bugs
             integration tests would catch but unit tests would miss;
             SPEC-002 v1.0.1 major patch incomplete; mock infra missing
             a detail one side needs.

  MINOR    — wording drift, redundant documentation, defaults that
             could be tighter.

  QUESTION — auditor cannot determine from spec content alone; operator
             input needed.

Expected: 0 CRITICAL, ≤3 MAJOR, ≤10 MINOR, ≤3 QUESTIONS. If you find
more, that's a real signal — operator may need to do another revision
cycle on one or both specs.

## Output format

Write to:
  /Users/augstar/macprovider-poc/specs/JOINT-SPEC-001-002-audit.md

Structure:

  # Joint Audit — SPEC-001 v1.1.1 + SPEC-002 v1.0.1
  Auditor: <model + version>
  Audit completed: <UTC timestamp>
  Specs audited: SPEC-001 v1.1.1 (commit 2d8106e), SPEC-002 v1.0.1 (commit c3a1476)

  ## TL;DR verdict
  One of:
    READY TO BUILD BOTH — both specs cleared for parallel build start.
    REVISE SPEC-002 ONLY — issues localized to SPEC-002 v1.0.2 patches needed.
    REVISE SPEC-001 ONLY — issues found that require SPEC-001 v1.1.2.
    REVISE BOTH — joint inconsistencies; coordinated patch round needed.

  One paragraph justification including:
    - SPEC-002 v1.0.1 patch verification summary (N ADDRESSED / M DEFERRED /
      K NOT ADDRESSED)
    - Cross-spec finding count by severity
    - Top risk identified

  ## Part 1 — SPEC-002 v1.0.1 patch verification table

  (Per the table format above; one row per prior finding.)

  ## Part 2 — Cross-spec consistency findings

  ### CRITICAL (N)
  ### MAJOR (N)
  ### MINOR (N)
  ### QUESTIONS (N)

  Per-finding format:
    - Title
    - Severity
    - Subsection (2.1 through 2.10)
    - Section refs in BOTH specs
    - Quoted text from each
    - What's wrong / what conflicts
    - Fix direction (which spec to patch, what change)

  ## Part 3 — Implementability gate verdict

  Per-spec ≤3 clarifications list.
  Cross-spec clarifications list (target: 0).
  Mock infra sufficiency verdict.

  ## Joint protocol/header/error matrices

  Required tables:
    - SPEC-001 § 6.5 message field × SPEC-002 handling
    - Custom HTTP header × spec that defines × spec that references
    - HTTP status code × meaning in SPEC-001 × meaning in SPEC-002

  ## What this spec pair does well

  3-5 specific cross-spec design choices that demonstrate good thinking.
  Anti-bias: don't omit; calibrates the audit's tone.

  ## Final verdict recommendation

  Concrete next step:
    - READY → "Commit no further; start parallel binary + coordinator builds."
    - REVISE SPEC-002 → list ≤5 patch items + recommend in-place patches.
    - REVISE SPEC-001 → list ≤3 amendment items (these are higher-stakes
      because SPEC-001 v1.1.1 was thought locked).
    - REVISE BOTH → coordinated patch round; provide ordering recommendation
      (patch SPEC-001 first if any of its findings change the protocol;
      otherwise SPEC-002 can be patched in isolation).

## Hard rules

1. Do NOT rewrite either spec. Identify problems only.
2. Cite section numbers and quote text from both specs when describing
   cross-spec findings.
3. The wire protocol from SPEC-001 § 6.5 is treated as locked. If
   SPEC-002 violates it, the fix is to SPEC-002, not SPEC-001 — unless
   SPEC-001's locking was itself wrong (rare; would be a CRITICAL).
4. SPEC-002 v1.0.1 made design choices that constrain SPEC-001's
   behavior (e.g. "static config map"). Verify those constraints are
   actually satisfied by SPEC-001 v1.1.1 verbatim text.
5. You MAY check dependency tag existence via gh CLI / pkg.go.dev / SPM
   docs. You may NOT clone d-inference content.

## Anti-rules

- Don't re-audit SPEC-001 from scratch — its single-spec audits are
  closed. Only flag SPEC-001 issues that the joint reading exposes.
- Don't audit the build/audit prompts themselves.
- Don't speculate about future SPEC-003+ work. Out of scope.
- Don't propose alternative architectures. The C1/C2/Q1 decisions are
  locked.
- Don't ask the operator questions during the audit; use the QUESTIONS
  section.

## When you finish

1. Re-read your audit. Anything you'd back off? Downgrade or move to
   QUESTIONS.
2. Verify every CRITICAL has full citations from both specs.
3. Verify Part 1's table covers every finding from SPEC-002-audit.md.
4. Verify Part 2 covers every subsection 2.1 through 2.10.
5. Print to stdout:
   - TL;DR verdict (one of 4 options)
   - Per-severity counts
   - Top 3 items operator should focus on first
   - "Builds may start: YES" or "Builds blocked on: [spec(s)]"

Begin by reading the required files in order. Most of your time should
be in Part 2 (cross-spec consistency walk) — that's the highest-leverage
work this audit does.

=== END PROMPT ===
```

---

## How to use

```bash
cd /Users/augstar/macprovider-poc
codex < specs/JOINT_AUDIT_PROMPT.md
```

Expected wall time: 60–90 minutes.

## What you'll get back

- `specs/JOINT-SPEC-001-002-audit.md` — joint audit report
- A `<200 word` summary in Codex's final reply with the four-state verdict

## Expected outcomes & next moves

| Verdict | Action |
|---|---|
| **READY TO BUILD BOTH** | Commit joint audit, start parallel binary + coordinator builds the same day |
| **REVISE SPEC-002 ONLY** | Patch SPEC-002 in-place to v1.0.2 (likely small; same pattern as v1.0.1 patches) |
| **REVISE SPEC-001 ONLY** | More serious — SPEC-001 was thought locked. ≤3 amendment items become v1.1.2 |
| **REVISE BOTH** | Coordinated patch round; audit will recommend ordering |

Most likely outcome: **READY TO BUILD BOTH** with a few MINORs as polish.

## Why this audit is different from the prior ones

Prior audits asked "is this spec correct on its own terms?"
This audit asks "do these two specs work together as a system?"

The cross-spec drift check (Part 2) is unique — it's the only audit in the chain that catches the integration risk that would otherwise only surface during binary-coordinator end-to-end testing in week 5+ of the build.

## Total spec investment to here

After this audit (if READY):

```
SPEC-001 spec round:   write + audit + v1.1 + re-audit + v1.1.1 patches
SPEC-002 spec round:   write + audit + v1.0.1 patches
Joint pre-build audit: this round
```

Roughly 8-10 hours of spec/audit work for a 5-8 week build. That's the right ratio — heavy spec investment pays back as fewer mid-build pivots.

## After joint audit

Once READY TO BUILD BOTH lands, you can write **`BUILD_PHASE3_BINARY_PROMPT.md`** and **`BUILD_PHASE4_COORDINATOR_PROMPT.md`** — the actual paste-ready prompts for the two build sessions. Both wrap their respective spec's § 0 invocation block in the established self-contained format. ~30 min each to draft. Optional: I can pre-draft them now while the joint audit runs, so they're ready when its verdict lands.

Want them pre-drafted in parallel, or wait for the joint audit verdict first?