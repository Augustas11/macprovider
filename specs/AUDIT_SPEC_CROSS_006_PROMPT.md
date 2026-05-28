# Cross-spec coherence audit prompt — SPEC-001/002/003/006 corpus

Operator-paste prompt for **cross-spec coherence audit** of the four
specs that now define the Mac Provider stack end-to-end:

  - SPEC-001 v1.2.2 (phase3-binary, provider-side wire protocol)
  - SPEC-002 v1.1.3 (phase4-coordinator, request router)
  - SPEC-003 v0.5   (open onboarding, distribution + install)
  - SPEC-006 v0.2   (buyer API gateway, public-facing surface)

Each spec passed its own per-spec audit cycle (SPEC-001/002/003 went
3-4 rounds each; SPEC-006 went two rounds + regression check). What
has NEVER been audited is whether the FOUR specs compose into a
coherent end-to-end story. That's this audit.

**Cross-model pattern (mandatory for an integration-class audit):**
Codex round 1 first, then Claude round 2 appended to the same audit
file. Same pattern that caught the SPEC-001/SPEC-002 provider_id
disagreement (Day 2 production deploy bug) before code shipped.

Expected duration: ~60-90 min per round. Two rounds total: 2-3 hours
wall-clock if sequential, ~90 min if run in parallel sessions.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Codex CLI session (round 1) or Claude Code session
(round 2) rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are performing a cross-spec coherence audit of the four Mac
Provider specs. Each spec has been individually audited (per-spec
cycles totaling 13+ audit rounds across the corpus). This audit is
DIFFERENT: you are checking that the four specs COMPOSE into a
coherent end-to-end story.

The four specs under composition audit, with their current versions
and locked status:

  SPEC-001 v1.2.2 — phase3-binary wire protocol (LOCKED, locked-in
                    via three-stream patch + hardware drain test on
                    v1.2.3 binary)
  SPEC-002 v1.1.3 — coordinator request router (LOCKED, spec-text
                    catch-up to commit 47d6433 production hotfix)
  SPEC-003 v0.5   — open onboarding / distribution / install.sh
                    (LOCKED, four-bug stranger-install closed)
  SPEC-006 v0.2   — buyer API gateway (REGRESSION-AUDITED with
                    three narrow MAJORs pending, otherwise CLOSED)

Your job: read all four specs, trace cross-spec contract points,
produce a structured audit at
/Users/augstar/macprovider-poc/specs/SPEC-CROSS-006-audit.md.

You are NOT here to re-audit per-spec quality. The per-spec audits
already covered:
- Internal correctness within a spec
- Single-spec normative rigor
- Per-spec acceptance criteria

You ARE here to catch:
- **Wire compat across specs**: does SPEC-006 expose buyer fields
  that SPEC-001/002 actually deliver? Does SPEC-002 forward fields
  SPEC-006 accepts?
- **Cross-spec invariants**: a behavior MUST hold across the full
  stack (e.g., "provider hostnames never reach buyers" is a SPEC-006
  invariant — does the SPEC-002 path actually enforce it?).
- **Implicit assumptions one spec makes about another**: e.g.,
  SPEC-006 F-M19 has the gateway consuming SPEC-002's /poolz for
  buyer-safe status. Does SPEC-002 actually expose what SPEC-006
  promises buyers?
- **End-to-end failure-mode stories**: when a provider drains
  (SPEC-002 drain) or reconnects (SPEC-001 reconnect lifecycle) or
  installs fresh (SPEC-003 curl-pipe-bash) or hits a buyer API call
  (SPEC-006), the buyer-visible behavior must be coherent across
  layers.
- **Cross-spec version dependencies**: each spec declares
  "Depends on:" — are those declarations accurate? Has anything
  drifted since the dependency line was written?
- **Implicit surfaces**: spec X uses field Y from spec Z but spec Z
  doesn't normatively define Y. The Day-3 provider-pinning header
  bug (M2-21) is the reference case: coordinator code accepts
  `X-MacProvider-Provider` headers, SPEC-002 doesn't normatively
  define them, SPEC-006 defensively strips them. Find more like
  this.

## Scope discipline (HARD CONSTRAINTS)

**1. This is a SPEC-level audit, not a code review.** Read enough
code to verify what the specs claim is actually delivered, but the
output should be findings against SPEC text, not code patches.

**2. Per-spec quality is out of scope.** If you spot a within-SPEC-006
issue that none of the prior per-spec audits caught, file it as a
QUESTION (operator can decide whether to backlog or open a v0.3 fix).
Don't make it the main finding.

**3. Findings can propose minor patches to ANY of the four specs.**
Unlike a per-spec audit where mutating an upstream spec was
forbidden, this audit's job is to surface cross-spec drift and
propose where to fix it. The fix may be:
- SPEC-001 v1.2.3 (next provider-side patch)
- SPEC-002 v1.1.4 (next coordinator-side patch)
- SPEC-003 v0.6 (next distribution patch)
- SPEC-006 v0.3 (next gateway-side patch)
- Combination patch across multiple specs
For each finding, recommend WHICH spec(s) should change AND in what
version, with rationale.

**4. The "ship-then-spec" pattern is NOT acceptable for findings
discovered here.** Cross-spec drift caught at spec phase is the
cheapest place to fix it; pushing to implementation phase risks
production fires of the Entry 18/19 class. If a finding deserves a
spec change, recommend it explicitly.

**5. d-inference clean-room.** Do not inspect d-inference source.

## Severity definitions for cross-spec findings

- **CRITICAL** — would cause a production incident of Entry 18/19/20
  class (silent failure, cross-stream contract mismatch, security
  hole). Examples: two specs claim ownership of the same data with
  different write semantics; a buyer-visible secret leaks through
  because one spec doesn't enforce what another assumes.
- **MAJOR** — would surface as a v0.2/v0.3 patch within first month
  of running the four-spec stack. Examples: SPEC-006 promises buyer
  data that SPEC-002 doesn't currently expose; failure-mode story
  inconsistent between two specs.
- **MINOR** — terminology drift, naming inconsistency, missing
  cross-reference, stale dependency line.
- **QUESTION** — a within-single-spec issue this audit happened to
  notice; not the main scope.

## Required reading (in order)

### The four specs (read fully)

1. `specs/SPEC-001-phase3-binary.md` v1.2.2 — focus on:
   - § 6.2 (`/v1/models` response, JSON escape tolerance)
   - § 6.4 (`/v1/chat/completions` request, case-insensitive
     model match)
   - § 6.5 (hello message, reconnect lifecycle)
   - § 6.6 (WS-tunneled inference message types)
   - § 8.2 (clean-room paragraph)

2. `specs/SPEC-002-coordinator.md` v1.1.3 — focus on:
   - § 3 (mode resolution, HTTP-forwarding vs WS-tunneled)
   - § 5 (routing, admission tier weighting)
   - § 6 (close codes, drain semantics)
   - § 7.1 (auth.require_provider_tokens, log-every-close)
   - § 7.5 (admin endpoints, /poolz shape — important for SPEC-006
     F-M19 cross-check)
   - § 11 (audit categories, including the new "always-non-nil
     gate" category from Entry 19)

3. `specs/SPEC-003-open-onboarding.md` v0.5 — focus on:
   - § 4 (distribution-channel decoupling property)
   - § 5 (onboarding UX, wire-bytes-on-failure)
   - audit categories (shell-script paths touching real OS)

4. `specs/SPEC-006-buyer-api.md` v0.2 — focus on:
   - § 1 (scope, including the new single-instance acknowledgment
     and the relationship statements about other specs)
   - § 5.4 (chat completions request — the OpenAI field list +
     header strip)
   - § 5.6 / § 12.2 (status endpoint, coordinator bridge)
   - § 7 (quota, the streaming reservation pattern)
   - § 8 (provider transparency)
   - § 17 (failure modes, refund matrix)
   - § 18 (acceptance criteria — especially anything that touches
     coordinator state)

### Audit history (for tone + prior-finding context)

5. `specs/SPEC-001-audit.md`, `SPEC-001-v1-1-audit.md`,
   `SPEC-002-audit.md`, `SPEC-002-v1-0-2-audit.md`,
   `SPEC-003-audit.md`, `SPEC-006-audit.md`,
   `SPEC-006-v0-2-audit.md` — the per-spec audit history. Don't
   re-audit; use these to know what's already been triaged.

6. `specs/INTEGRATION-audit.md` and
   `specs/INTEGRATION-audit-claude.md` — the prior cross-stream
   IMPLEMENTATION audit (Entry 19). Different target (code vs.
   code) but same discipline (cross-stream drift) and reference
   for the audit-pattern lesson: cross-stream audits catch what
   per-stream audits cannot.

7. `beta/DECISION_CRITERIA.md` Entries 18, 19, 20, 21 — the
   production cross-spec failures these audits aim to prevent.
   Entry 18 (SIGTERM/drain conflation) and Entry 19 (cross-stream
   audit findings, including the unconditional token validator
   bug) are the reference cases. Your job is to find Entry 22
   candidates before they fire in production.

### Code surfaces (for verification, not re-audit)

8. `phase4-coordinator/internal/buyer/server.go` — confirm
   coordinator's actual buyer-surface fields match what SPEC-006
   claims to receive.

9. `phase4-coordinator/internal/ws/server.go` — confirm
   coordinator's WS handling matches SPEC-001's drain + reconnect
   normative requirements.

10. `phase4-coordinator/internal/poolz/` (if exists) — confirm
    /poolz shape vs SPEC-006 F-M19 promises.

11. `phase4-coordinator/cmd/coordinator/main.go` — confirm the
    auth.require_provider_tokens flag and close-logging behavior
    match SPEC-002 v1.1.3's normative text.

12. `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift` —
    confirm reconnect-after-drain lifecycle implements SPEC-001
    v1.2.2 § 6.5 normative requirements.

13. `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift`
    + `HTTPServer.swift` — confirm case-insensitive match + JSON
    escape behavior.

14. `phase3-binary/dist/install.sh` — current install.sh state for
    SPEC-003 v0.5 verification.

## Audit categories — work through each

### Category α: Wire-contract continuity end-to-end

The buyer call path: buyer SDK → SPEC-006 gateway → SPEC-002
coordinator → SPEC-001 binary (provider) → MLX → response back up
the chain. For each buyer-visible request/response field, verify the
contract is consistent at every hop.

α.1  Chat completion request fields. SPEC-006 § 5.4 lists supported
     fields (after F-M2 fix: n, stream_options, user, logprobs +
     base set). For each field, walk: does SPEC-001 § 6.4 accept it?
     Does SPEC-002 § 3/§ 5 forward it? Drift = MAJOR.

α.2  Streaming. SPEC-006 § 5.4 promises OpenAI-compatible SSE
     framing. SPEC-001 § 6.6 defines inference_response_chunk
     messages. SPEC-002 § 5 relays them. Walk: how does the binary's
     chunk shape become the buyer's `data: {...}\n\n` frame? Any
     missing translation step = MAJOR.

α.3  Token usage reporting. SPEC-006 mentions
     stream_options.include_usage forwarding (F-M2). SPEC-001 v1.2.x
     binaries emit usage tokens (per Day-2 FR-7). SPEC-002 forwards
     them. Verify the chain: include_usage:true → coordinator → binary
     → final SSE chunk has usage. Any breakage = MAJOR.

α.4  Model identifier semantics. SPEC-001 v1.2.2 § 6.4 requires
     case-insensitive ASCII match. SPEC-006 must preserve this when
     forwarding. SPEC-002 must not normalize. Verify all three
     enforce or pass through.

α.5  JSON escape tolerance. SPEC-001 v1.2.2 § 6.2 says `\/` and `/`
     are both legal in id fields. Does SPEC-006's /v1/models response
     emit one form or pass through whichever the coordinator emits?
     Does the coordinator (SPEC-002) emit one form consistently?
     Mismatch between layers = MINOR.

### Category β: Implicit-surface findings (the Entry 19 bug class)

The Day-3 audit found that coordinator code accepts
`X-MacProvider-Provider` and `X-MacProvider-Session` inbound headers
that SPEC-002 doesn't normatively define. SPEC-006 v0.2 defensively
strips them. This is the **Entry 19 bug class**: a surface that
exists in code but isn't in any spec.

β.1  Walk coordinator's HTTP buyer handler
     (`phase4-coordinator/internal/buyer/server.go`) and enumerate
     every header it inspects, every query param, every body field.
     For each, ask: is it normatively defined in SPEC-002? If not,
     CRITICAL or MAJOR depending on the impact (security-relevant
     surfaces = CRITICAL; debug-only = MAJOR).

β.2  Walk SPEC-006's gateway-strip list (§ 5.4 / § 8 after F-M21).
     Compare against the coordinator's actually-handled headers.
     Any header coordinator accepts that SPEC-006 doesn't strip and
     SPEC-002 doesn't define = CRITICAL.

β.3  /poolz shape. SPEC-006 F-M19 promises buyer-safe status
     aggregation. Walk `phase4-coordinator/internal/poolz/` (or
     equivalent) and confirm:
     - The fields SPEC-006 promises buyers (ready/draining/
       unavailable counts, per-model slots_free) actually exist
       in /poolz output today
     - SPEC-002 normatively defines /poolz schema
     If SPEC-002 doesn't normatively define /poolz, file as SPEC-002
     v1.1.4 candidate. MAJOR.

β.4  WS message types. SPEC-001 § 6.6 defines inference_request,
     inference_response_chunk, etc. Are all message types coordinator
     handles in SPEC-001? Any code-level message type SPEC-001 doesn't
     define = CRITICAL.

### Category γ: End-to-end failure-mode coherence

A buyer hits SPEC-006. SPEC-006 forwards to SPEC-002 coordinator.
Coordinator routes to SPEC-001 binary. Things can fail at each layer.
The buyer-visible behavior MUST be coherent.

γ.1  Provider drain. SPEC-001 § 6.5 drain handshake. SPEC-002 close
     code semantics. SPEC-006 § 17 failure modes. Walk the story: a
     provider receives drain. What does an in-flight buyer request
     observe? Does SPEC-006 explicitly say what happens (e.g., 503
     with retry-after, or stream cuts mid-response with [DONE], or
     error frame)? Inconsistency = MAJOR.

γ.2  Provider reconnect. SPEC-001 v1.2.2 § 6.5 normative reconnect
     within 15s. SPEC-002 admits the reconnect. SPEC-006 § 10 may
     have capacity-burst implications. Walk: during the 15s gap,
     what does SPEC-006 /v1/status report? What does SPEC-006 /v1/models
     show? Any contradiction = MAJOR.

γ.3  Coordinator restart. SPEC-002 § 6 drain on SIGTERM. SPEC-001
     handles post-drain reconnect. SPEC-006 must define what buyers
     see during the gap. Anything implicit = MAJOR.

γ.4  Capacity-burst tier escalation. SPEC-006 § 10 Tier 1/2/3.
     SPEC-002 has its own admission tier weighting (§ 5). Do they
     interact? E.g., when SPEC-006 closes signups (Tier 1), does
     anything cascade to SPEC-002? Or are they independent? If
     independent, SPEC-006 should explicitly state so. MAJOR if
     undefined.

γ.5  Provider unavailable (lid close). SPEC-001 lifecycle, SPEC-002
     marks state=unavailable, SPEC-006 returns 503 + status reflects.
     Walk the path. Any gap = MAJOR.

γ.6  Fresh install from SPEC-003 curl-pipe-bash. New provider lands
     in pool via provisional admission. SPEC-002 § 7 admits.
     SPEC-006 /v1/models adds the new model. SPEC-006 quota count
     unaffected. Walk: anywhere this story breaks at a spec boundary =
     MAJOR.

### Category δ: Operator-decision cross-spec consistency

SPEC-006 has D1/D2/D3 (operator pre-commitments). Each spec has its
own operator-decided values. Verify cross-spec consistency.

δ.1  Provider authentication mode. SPEC-002 v1.1.3 § 7.1 says
     auth.require_provider_tokens defaults false. SPEC-001 doesn't
     mention provider tokens. SPEC-006 doesn't depend on them
     (buyer auth is separate). Verify these are independent.
     Inconsistency = MAJOR.

δ.2  Provider identity. SPEC-001 § 6.5 provider_id is stable
     operator-issued. SPEC-002 § 7.1 F-2 pinned providers. SPEC-006
     § 8 hides provider IDs from buyers. Verify the chain: stable
     ID exists, used internally, never leaked. Any leak path =
     CRITICAL.

δ.3  Versions. Each spec's "Depends on:" line. SPEC-002 v1.1.3 line 4
     says "Depends on: SPEC-001 v1.2.1" (which is now stale —
     SPEC-001 is v1.2.2). SPEC-003 v0.5 may have similar staleness.
     SPEC-006 v0.2's "Depends on:" line should be current. Each
     stale dependency = MINOR.

δ.4  Audit-category vocabulary. SPEC-002 v1.1.3 added "always-non-nil
     gate" category I.X. SPEC-003 v0.5 added "shell-script paths
     touching real OS" category. SPEC-006 § 19 audit categories
     should reference both. Missing = MINOR.

### Category ε: Backward-compat preservation across layers

Each spec maintains its own backward-compat invariant. The full
stack must preserve compat for legacy buyers + legacy providers.

ε.1  M4 + M1 provider Macs still run v1.1.4 / v1.1.3 binaries (not
     yet upgraded to v1.2.3). Walk: do these legacy binaries still
     work end-to-end through the stack? SPEC-001 v1.2.2 says
     compatible; SPEC-002 v1.1.3 admits them; SPEC-006 v0.2 doesn't
     care about provider version. Any spec text contradicting any
     other on this = CRITICAL.

ε.2  Direct-tunnel buyer paths (m4.streamvc.live, m1.streamvc.live).
     SPEC-006 v0.2 explicitly preserves these. Verify SPEC-002 does
     too. Inconsistency = MAJOR.

ε.3  Pre-v1.2.2 buyers (existing harnesses pointing at
     coordinator.streamvc.live) still work. SPEC-006's gateway
     stands up at api.streamvc.live; SPEC-002 keeps coordinator
     direct surface working. Verify no spec text breaks this. MAJOR
     if it does.

### Category ζ: Distribution-channel coherence

A stranger runs `curl get.streamvc.live/install.sh | bash`. They
end up as a provider running SPEC-001 v1.2.3 binary connecting to
SPEC-002 coordinator. Some time later their model gets routed by a
buyer via SPEC-006 gateway. Verify this end-to-end story.

ζ.1  install.sh hardcoded URLs/versions vs SPEC-006 changes. SPEC-006
     introduces api.streamvc.live for buyers. Does install.sh
     hardcode coordinator.streamvc.live as the provider's destination?
     If SPEC-006's gateway forwards to coordinator at
     127.0.0.1:8443 (per F-M19), what does the provider connect to?
     Verify provider-side URL is still wss://coordinator.streamvc.live/ws/provider
     (unchanged from SPEC-001 v1.2.x). Any drift = MAJOR.

ζ.2  Self-test flow. SPEC-003 v0.5 install.sh wire-bytes-on-failure.
     The self-test checks /v1/models on the provider's local port. Is
     that contract still valid after SPEC-006 changes the public
     buyer URL? Yes (provider-local /v1/models is unchanged). Verify
     spec text doesn't accidentally contradict.

ζ.3  Onboarding UX from SPEC-003 + buyer UX from SPEC-006. A user
     might be both. Verify the two specs don't make conflicting
     claims about user identity / persona / authentication paths.

### Category η: Operator audit-log coherence

SPEC-002 has an audit log surface. SPEC-006 § 14.3 has an audit_events
table. Are these two log streams that should be unified, kept
separate, or cross-referenced?

η.1  If unified, who owns the table? CRITICAL if undefined.
η.2  If separate, are operator queries that need a full picture
     defined? MAJOR if not.

### Category θ: Network state ownership

For each piece of state in the network (provider list, pool state,
account list, key list, usage events, ratings, audit events), exactly
one spec MUST own the write-path. If two specs imply ownership of the
same data, CRITICAL.

θ.1  Provider list. SPEC-002 § 7.1 owns it (`config.providers[]`).
     Verify SPEC-006 doesn't claim to manage it.

θ.2  Pool state. SPEC-002 owns it (live state machine). SPEC-006
     reads via /poolz bridge. Verify no SPEC-006 write claim.

θ.3  Account / API key list. SPEC-006 owns it. Verify no SPEC-002
     claim.

θ.4  Usage events. SPEC-006 owns it. SPEC-002 has its own
     request_logs (coordinator side). Are they redundant?
     Synchronized? Independent? Spec must say.

θ.5  Ratings. SPEC-006 owns it. No overlap. Pass.

### Category κ: SPEC-006 v0.2 regression findings — cross-spec implications

SPEC-006 v0.2 regression audit surfaced 3 narrow AC text findings.
Note any that have cross-spec implications:

κ.1  AC-26 method mismatch (POST vs GET /auth/github/callback):
     SPEC-006 contract issue, no SPEC-001/002/003 impact. Note in
     output, defer to FIX_SPEC_006_V0_3.

κ.2  AC-27 revocation latency test (65s retry on a 60s bound):
     SPEC-006 contract issue, no cross-spec impact.

κ.3  AC-26..AC-37 missing explicit status codes / response shapes:
     SPEC-006 contract issue, no cross-spec impact.

(These three are already known; mention only if cross-spec
implications surface.)

## Output format

Produce `/Users/augstar/macprovider-poc/specs/SPEC-CROSS-006-audit.md`
with this structure:

```
# Cross-spec coherence audit (SPEC-001 v1.2.2 + SPEC-002 v1.1.3 + SPEC-003 v0.5 + SPEC-006 v0.2)

## Round 1 (Codex, 2026-MM-DDTHH:MM:SSZ)

### Summary
- N CRITICAL findings
- M MAJOR findings
- K MINOR findings
- L QUESTIONS

### CRITICAL findings
For each: title, locations across multiple specs, finding,
why it matters, recommended fix (WHICH spec, what version, brief
patch description).

### MAJOR findings
[same]

### MINOR findings
[same]

### Category coverage notes
- α through κ: one-line note on each ("no findings", or "see Mx, My")

### Self-verification

### Verdict
- CORPUS COHERENT (cross-spec ready, no spec patches needed)
- READY WITH NARROW PATCHES (small patches to SPEC-X v(N+1) close all
  findings)
- DESIGN ROUND NEEDED (architectural cross-spec drift requires
  redesign)

## Round 2 (Claude, 2026-MM-DDTHH:MM:SSZ)
(appended after round 1; do NOT overwrite)

[same structure]

### Round 2 notes on Round 1
- Findings I confirm
- Findings I disagree with (and why)
- New findings round 1 missed
- Verdict (mine, independent)
```

## Self-verification before declaring audit complete

- [ ] Read all four spec documents at their current versions.
- [ ] Walked all categories α through κ.
- [ ] For each finding, the proposed fix specifies WHICH spec(s) to
      patch and at what next version.
- [ ] Code-surface verifications (Required reading items 8-14)
      actually consulted, not assumed.
- [ ] Severity per the cross-spec definitions above (CRITICAL =
      production-incident class, MAJOR = first-month-patch class).
- [ ] Verdict reflects whether the corpus composes (CORPUS COHERENT)
      or needs patches (READY WITH NARROW PATCHES) or has
      architectural drift (DESIGN ROUND NEEDED).
- [ ] Round 2 specifically: added "Round 2 notes on Round 1" section.

When done, print a 250-word handback summary:
- Total findings + severity counts
- Top 3 most impactful cross-spec drift findings
- Which specs would need patches and at what versions
- Verdict + one-sentence rationale

Then stop. Do NOT begin drafting fix prompts. The operator decides
next move (single combined FIX prompt, per-spec FIX prompts, or
DESIGN ROUND).

=== END PROMPT ===
```

---

## After running this prompt (both rounds)

Operator's review checklist (~30 min):

1. Read `specs/SPEC-CROSS-006-audit.md` start to finish.
2. For each CRITICAL: confirm whether it's real cross-spec drift or
   a single-spec issue mistakenly classified as cross-spec.
3. For each MAJOR: same triage, with focus on whether the fix
   requires multiple specs to change in lockstep.
4. If verdict is **CORPUS COHERENT**: lock the spec corpus, proceed
   to `FIX_SPEC_006_V0_3_PROMPT.md` (the three narrow AC text fixes)
   and then `BUILD_PHASE5_PROMPT.md`.
5. If verdict is **READY WITH NARROW PATCHES**: draft a combined fix
   prompt covering all cross-spec changes + the three narrow SPEC-006
   v0.3 AC fixes. Single FIX session locks everything; specs bump in
   sync.
6. If verdict is **DESIGN ROUND NEEDED**: re-open the architectural
   choice that drifted. Probably the gateway-coordinator boundary or
   the failure-mode story.

## Why two rounds (Codex + Claude) matters

Cross-spec drift is the bug class Entry 19 surfaced: per-stream Codex
audits caught what each per-stream agent missed; cross-stream
integration audit (Codex + Claude) caught what BOTH per-stream agents
missed. The pattern repeats here: SPEC-006 v0.1 audit was Codex round
1 + Claude round 2 (each catching ~5 things the other missed). The
v0.2 regression audit was single-round Codex (narrow scope, single
round sufficient). This cross-spec audit's scope is wider than the
regression check; single-round risks under-covering. Two rounds
matches the precedent.

If you only have time for one round, run Codex round 1 — it tends to
be more rigorous on contract-level findings (which dominate
cross-spec drift). Claude round 2 typically adds ~30-40% more
findings on top of round 1; valuable but not strictly required for
shipping if round 1 produces a CORPUS COHERENT verdict.

## Historical precedent

This is the second cross-stream/cross-spec composition audit in the
project's history. The first (Entry 19) audited THREE codebases
(Swift + Go + Distribution) composing into a working stack. Findings
list:
- 3 CRITICAL (Codex round 1 + Claude round 2 both confirmed)
- 8 MAJOR (Codex 5 + Claude added 3)
- 3 QUESTIONS

Net result: integration fixes applied in one pass, no version bumps
required for the per-stream specs (the integration findings were
about composition, not single-spec quality). Same outcome is the
target here — cross-spec patches if needed, no design round.

If this audit produces architectural CRITICALs (e.g., "SPEC-006's
gateway model fundamentally incompatible with SPEC-002's routing"),
that's the signal to re-open SPEC-006 design before any
implementation. Cheaper at spec phase than implementation phase by 1+
order of magnitude.
