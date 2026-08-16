# Audit prompt — SPEC-006 v0.1 cross-model audit

Operator-paste prompt to audit SPEC-006 v0.1 (`specs/SPEC-006-buyer-api.md`),
Mac Provider's first buyer-facing API gateway spec.

**Cross-model pattern:** the spec was drafted by Claude (executing
`specs/BUILD_SPEC_006_PROMPT.md`). For independence, the audit runs in
**Codex CLI first**. After Codex round 1 lands, run the same prompt in
Claude as round 2; both audit reports go into `specs/SPEC-006-audit.md`
as separate sections, matching the SPEC-001/002/003 audit history.

Expected duration: ~60-90 min per model (single-spec audit, but SPEC-006
is a 2,373-line first product spec with no prior audit history; bias
toward thoroughness over speed).

History note: SPEC-006 is the project's first **product** spec, not a
protocol spec. The audit bar is the same as SPEC-001/002 (those went
through 3-4 rounds each), but the failure modes are different —
business-rule precision, OAuth correctness, abuse defense, OpenAI
SDK compatibility, and 10K-Mac scale property preservation.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Codex CLI session (round 1) or Claude Code session (round
2) rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-006 v0.1, Mac Provider's first buyer-facing API
gateway spec at /Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md.

You are NOT here to validate, rewrite, or extend the spec. Find
problems, report them with specific severity and location, let the
operator decide fixes. The operator has read the spec; they need an
independent second (or third) opinion on what's missing, wrong, or
under-specified.

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-006-audit.md

Format: structured audit report. Findings grouped by category, each
finding tagged with severity (CRITICAL / MAJOR / MINOR / QUESTION) and
location (section number + line range if possible). Match the rigor of
the prior audit reports in this repo (specs/SPEC-001-audit.md,
specs/SPEC-002-audit.md, specs/SPEC-003-audit.md). If you are running
as round 2 (Claude after Codex), APPEND your section to the existing
file, do not overwrite Codex's round 1.

## Severity definitions

- **CRITICAL** — would cause production failure, security incident,
  unreplayable data loss, OpenAI SDK incompatibility, or violate one of
  the locked architectural invariants (10K-Mac trajectory, stateless
  gateway, append-only schema, sub-ms auth, no buyer-visible secrets).
- **MAJOR** — would cause significant operator burden, predictable
  user confusion, or a v0.2 patch within first month of deployment.
  Unjustified numeric thresholds, hand-wavy requirements, "TBD"s
  disguised as OQs, missing rate-limit semantics, ambiguous failure
  modes.
- **MINOR** — quality issues that don't block v0.1 but should be
  cleaned in v0.2. Naming inconsistencies, missing cross-references,
  underspecified edge cases that won't fire frequently.
- **QUESTION** — genuinely unresolved design choices the spec couldn't
  decide alone. Operator-input required. Distinguish from OQs the spec
  already names — those are not findings unless they're hiding a
  CRITICAL/MAJOR underneath.

## Critical constraints to honor while auditing

**1. SPEC-001 v1.2.2 and SPEC-002 v1.1.3 are locked.** SPEC-006 layers
on top of them. Any SPEC-006 clause that would require changes to
SPEC-001 or SPEC-002 is a CRITICAL finding ("scope creep across spec
boundary"). The gateway is new infrastructure; coordinator stays the
router SPEC-002 v1.1.3 defines.

**2. Backward-compat for legacy direct-tunnel buyers.** M4 and M1
partners' Macs serve direct buyer traffic at `m4.malibu.tech` and
`m1.malibu.tech` outside the coordinator. Those paths MUST remain
operational. If SPEC-006 contains any clause that breaks them, CRITICAL.

**3. d-inference clean-room.** Do NOT inspect d-inference source.
Reading their LICENSE for cross-reference is allowed; reading their
README/docs is allowed but discouraged. Any SPEC-006 clause that
appears to require d-inference inspection is a CRITICAL finding.

**4. No premium positioning.** The operator pre-rejected premium
pricing for small open models. If any SPEC-006 clause invents a
buyer persona, positions the API as premium, or recommends a price
above $0.05/M tokens, that is a MAJOR finding ("operator pre-commitment
violated").

**5. Locked design choices are read-only.** Section 2 of SPEC-006
("Locked decisions") restates the operator's pre-commitments. Any
audit finding that recommends changing a locked decision is REJECTED
unless the finding shows the decision is structurally incompatible
with another locked decision (in which case, file as CRITICAL with
specific incompatibility documented). Do not "improve" what the
operator already decided.

**6. 10K-Mac trajectory is non-negotiable.** The spec MUST preserve
the architectural properties that enable scaling to 10,000+ Macs:
stateless handlers, abstracted data layer, append-only schema, sub-ms
auth, multi-coordinator-ready forwarding. Any clause that traps the
gateway at <100-Mac scale is CRITICAL.

## Required reading (in order, fully)

1. `/Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md`
   v0.1 — the spec under audit. Read fully, all 20 sections, all 25
   acceptance criteria. Bias toward reading the acceptance criteria
   and Section 14 (Storage layer) carefully — these encode the most
   precise commitments.

2. `/Users/augstar/macprovider-poc/specs/SPEC-006-design.md`
   — the design exploration that preceded the spec. Verify the
   spec's locked decisions match the design's Section 4
   ("Recommended Path") AND the operator's pre-commitments in
   `specs/BUILD_SPEC_006_PROMPT.md` "Locked design choices" header.
   Any deviation = MAJOR finding ("locked-decision drift during
   draft").

3. `/Users/augstar/macprovider-poc/specs/BUILD_SPEC_006_PROMPT.md`
   — the BUILD prompt with the operator's locked design choices. The
   spec MUST match this verbatim where applicable. Diff it against
   SPEC-006 Section 2; any deviation MAJOR.

4. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.2.2 — the provider-side spec. Focus on § 6.2
   (`/v1/models` response shape), § 6.4 (`/v1/chat/completions`
   request shape, case-insensitive model match, JSON-escape
   tolerance). The gateway MUST preserve these contracts when
   forwarding. Any SPEC-006 clause that mishandles these = CRITICAL.

5. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.1.3 — the coordinator spec. Focus on § 3 (mode resolution),
   § 5 (routing), § 7 (HTTP surfaces), § 11 (audit categories).
   The gateway's relationship to coordinator MUST be consistent
   with what SPEC-002 v1.1.3 defines as coordinator's
   responsibilities. The coordinator MUST remain "router-only" per
   v1.1.3's charter — any SPEC-006 clause that pushes auth/billing/
   account state into coordinator = CRITICAL.

6. `/Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md`
   v0.5 — parallel pattern. SPEC-006's front-door + docs +
   accessibility model should rhyme with SPEC-003's distribution
   approach. Inconsistencies = MINOR unless they break user
   experience.

7. `/Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md`
   — read Entries 19-21 fully. Critical context: ship-then-spec
   pattern, hardware-verification gate discipline, capacity-burst
   pre-commitments. The SPEC-006 spec should not silently reverse
   any of these decisions.

8. `/Users/augstar/macprovider-poc/specs/SPEC-001-audit.md`,
   `specs/SPEC-002-audit.md`, `specs/SPEC-003-audit.md` — your
   prior audit outputs in this repo, for tone and severity-bar
   continuity.

9. `/Users/augstar/macprovider-poc/phase4-coordinator/internal/`
   — read enough of the Go coordinator code to verify what the
   gateway will actually forward to. Especially the buyer HTTP
   handlers and SSE relay path. Do NOT propose coordinator
   changes; understand the surface.

10. (Skim) `/Users/augstar/macprovider-poc/beta/web/` if present
    — the existing Vercel demo. SPEC-006's front-door contract
    references it. Verify the contract is achievable against
    actual frontend code, not aspirational.

## Audit categories — work through each

### Category A: Locked-decision fidelity (HIGHEST PRIORITY)

This is the category that gates whether the BUILD session honored the
operator's pre-commitments.

A.1  Walk through every decision in the BUILD prompt's "Locked
     design choices" header. For each, locate the corresponding
     normative clause in SPEC-006. Findings:
       - MISSING (decision in BUILD prompt but absent from spec) = CRITICAL
       - SEMANTICALLY DRIFTED (present but with different content) = CRITICAL
       - WEAKENED (MUST in prompt became SHOULD in spec) = MAJOR
       - SCOPE EXPANDED (spec added clauses the prompt did not authorize) = MAJOR

A.2  Verify Section 2 of SPEC-006 restates the locked decisions
     verbatim from the BUILD prompt, NOT in the spec author's words.
     Operator-pre-commitments must be quoted, not paraphrased.

A.3  Verify the spec does NOT contain a Tier-3 deprecation clause.
     Operator explicitly chose iteration over deprecation. If the
     spec includes a "MUST shut down" branch in capacity-burst or
     falsification frameworks = CRITICAL.

A.4  Verify the user-rating mechanism is captured via BOTH option B
     (POST /v1/feedback) AND option C (dashboard widget) per
     operator's "B+C" lock. Missing either = MAJOR.

A.5  Verify monthly cash absorption cap is $500, not a different
     number. Different number = MAJOR.

A.6  Verify default quota is 100K tokens/account/day, not different.

A.7  Verify GitHub OAuth is primary, email magic link is secondary-
     if-cheap. If spec inverts the priority or makes email primary
     without operator authorization = MAJOR.

### Category B: 10K-Mac scale property preservation

B.1  Stateless handlers requirement: spec must forbid in-process
     rate-limit counters, in-process quota state, in-process session
     caches. If anywhere in the spec implies in-process state for
     hot-path operations = CRITICAL.

B.2  Data layer abstraction: spec must define `AuthStore`,
     `UsageStore`, `FeedbackStore` (or similar) as Go interfaces.
     SQLite is the v1 concrete implementation but the interface MUST
     be the contract. If implementation details (e.g., "SELECT *
     FROM keys") leak into normative text = MAJOR.

B.3  Append-only schema requirement: usage events MUST be
     append-only. If the spec describes UPDATEs to usage rows in
     hot paths = CRITICAL.

B.4  Sub-ms auth check: spec MUST specify how the schema and
     indexes achieve <1ms p95 bearer-token validation. If only
     prose ("auth should be fast") without specific index/schema
     commitment = MAJOR.

B.5  Multi-coordinator-ready: gateway's coordinator backend MUST
     be a configurable list, not hardcoded. Spec must explicitly
     name this property. If "backends:" config only takes a single
     URL = MAJOR.

B.6  No long-lived TCP connections in gateway: spec must explicitly
     forbid persistent connections or state in gateway handlers
     (SSE streams pass through but the gateway handler is
     request-scoped). If absent = MAJOR.

B.7  Horizontal scalability: spec should specify behavior under
     multiple gateway replicas behind a load balancer. Quota
     decrement under concurrent requests = atomic? Sessions
     sticky? If undefined = MAJOR.

### Category C: OpenAI SDK compatibility

C.1  OpenAI Python SDK + OpenAI JavaScript SDK with `base_url =
     "https://api.malibu.tech/v1"` and `api_key = "mp_..."`
     MUST work drop-in for `chat.completions.create()` and
     `models.list()`. If the spec specifies any request/response
     shape that breaks SDK assumptions = CRITICAL.

C.2  Streaming SSE shape MUST match OpenAI's `data: {...}\n\n`
     framing exactly. Any deviation in framing, terminating
     `data: [DONE]`, or chunk schema = CRITICAL.

C.3  Error envelope: all error responses MUST use OpenAI shape
     `{"error": {"message": "...", "type": "...", "code": "..."}}`.
     If any error path returns a different shape = MAJOR.

C.4  Rate-limit headers: spec MUST require `X-RateLimit-Limit`,
     `X-RateLimit-Remaining`, `X-RateLimit-Reset` on rate-limited
     paths. Missing or non-standard names = MAJOR.

C.5  Model field semantics: case-insensitive ASCII match per
     SPEC-001 v1.2.2 § 6.4. If gateway forwards differently from
     coordinator's case handling = CRITICAL.

C.6  JSON-escape tolerance: spec must permit `\/` and `/` in
     model id responses per SPEC-001 v1.2.2 § 6.2. If absent =
     MINOR.

### Category D: Identity and auth correctness

D.1  OAuth state parameter: spec must require CSRF defense via
     state parameter validated on callback. If absent = CRITICAL
     (CSRF vulnerability).

D.2  OAuth scope minimization: spec must require requesting only
     necessary GitHub scopes (e.g., `read:user`, `user:email`),
     NOT broader scopes. If unspecified = MAJOR.

D.3  Bearer token shape: spec must require `mp_` prefix +
     high-entropy random secret (at minimum 256 bits before
     base64/base62 encoding). If entropy is hand-wavy = MAJOR.

D.4  Token storage: spec must require server-side hashing
     (SHA-256 or HMAC-SHA-256 with a secret) and store only the
     hash. If plaintext storage is implied = CRITICAL.

D.5  Token display: spec must require the full key is shown
     exactly once at issuance and never re-displayable. If absent
     = MAJOR.

D.6  Token revocation: spec must support revocation that takes
     effect within bounded time (recommend <60s). If only "best
     effort" = MAJOR.

D.7  Token rotation: spec should allow account holders to rotate
     keys without losing usage history. If absent = MAJOR.

D.8  Sybil defense at signup: spec specifies per-IP signup rate
     limit. If absent or unrealistic (e.g., 1000/IP/day) = MAJOR.

D.9  Demo traffic identification: how does the gateway know a
     request is "demo" vs "API"? If unclear or relies on
     spoofable headers = MAJOR.

### Category E: Quota arithmetic + concurrency

E.1  Atomic decrement: spec MUST describe how concurrent requests
     against the same key decrement quota atomically. CAS,
     transactional UPDATE, or row-level lock? If undefined = MAJOR
     (race condition risk).

E.2  Quota reset semantics: spec must define when the "daily
     quota" resets. UTC midnight? Account-creation-time anchor?
     Sliding 24h window? If ambiguous = MAJOR.

E.3  Quota fairness during burst: if 10 concurrent requests
     arrive when 50 tokens remain, do they all see "available" or
     only some? Spec must define. If undefined = MAJOR.

E.4  Quota visibility timing: do rate-limit headers reflect
     pre-decrement or post-decrement values? If undefined = MINOR.

E.5  Quota for streaming: streaming responses' token count is
     known only at end-of-stream. How is quota debited and at
     what point can the next request start? If undefined = MAJOR.

E.6  Quota refund on error: if a request returns 502/503/504
     after partial token generation, are tokens refunded? Spec
     must specify. If undefined = MAJOR.

E.7  Token estimation when provider usage missing: spec must
     address how the gateway counts tokens if the upstream
     binary returns no `usage` field (the SPEC-006 BUILD prompt
     surfaced this as an open question). If unaddressed = MAJOR.

### Category F: Kill switches + capacity-burst protection

F.1  Kill switch activation latency: spec MUST require activation
     within bounded time after toggle (recommend <5s). If only
     "best effort" = MAJOR.

F.2  Kill switch persistence: spec must define whether kill
     switch state survives gateway restart. If undefined = MAJOR.

F.3  Two-tier semantics: `demo-only` and `all-public-api` MUST
     be independently togglable. If they're modeled as a single
     enum (off/demo-off/all-off) the spec must specify legal
     transitions. If unclear = MINOR.

F.4  Capacity-burst Tier 1/2/3 escalation: spec MUST require
     mechanical execution, NOT operator discretion. If any tier
     reads "operator may decide to..." = MAJOR ("capacity-burst
     pre-commitment violated").

F.5  Tier signal monitoring: spec must specify how each of the
     five Tier 1 signals (CPU, memory, bandwidth, provider
     feedback, cost) is measured and at what frequency. If
     undefined = MAJOR.

F.6  Tier reversal: spec must define what causes a tier to
     de-escalate. If only escalation logic is specified = MAJOR.

F.7  Capacity expansion off-ramp: spec must explicitly allow
     operator to choose budget expansion / VPS upgrade / provider
     recruitment as an alternative to tier escalation. If absent
     = MINOR.

### Category G: User feedback + iteration signal

G.1  Rating capture B (POST /v1/feedback): spec must define
     full request/response schema, authentication, idempotency,
     and storage. If schema is hand-wavy = MAJOR.

G.2  Rating capture C (dashboard widget): spec must define
     the data contract (what data is sent to gateway, how it's
     stored). If absent or only in front-door spec = MAJOR.

G.3  Rating aggregation endpoint: spec must define
     /admin/feedback-summary shape and how aggregation is
     computed (window, weighting, deduplication). If absent =
     MAJOR.

G.4  Rating iteration trigger: spec must define what shift in
     distribution triggers operator review (e.g., 7-day rolling
     mean drops below X). If unstated = MAJOR.

G.5  Rating storage: spec must require append-only storage of
     rating events. If row UPDATEs implied = MAJOR.

### Category H: Failure modes + error envelopes

H.1  All 4xx and 5xx paths must have a documented status code
     and error type/code. If any failure mode is undefined =
     MAJOR.

H.2  No long queueing: spec must explicitly forbid queueing
     buyer requests beyond a small (sub-second) preflight
     window. If absent = MAJOR.

H.3  Streaming cancellation: spec must require gateway to
     cancel upstream within bounded time on client disconnect.
     If absent or "best effort" = MAJOR.

H.4  Error envelope consistency: every error path uses the same
     OpenAI-shaped envelope. If any path returns a different
     shape (e.g., generic 500 HTML) = MAJOR.

H.5  Status code semantics: 404 vs 503 vs 502 vs 504
     distinctions must be clear and consistent with SPEC-001
     and SPEC-002. If overlapping = MAJOR.

### Category I: Instrumentation completeness

I.1  North-star metric (time to first successful API call) must
     be normatively required to be instrumented. If only
     "should" = MAJOR.

I.2  All falsification metrics from SPEC-006-design.md Section 6
     must be normatively required. If some are missing = MAJOR.

I.3  Capacity-burst signals (CPU, memory, bandwidth, provider
     feedback, cost) must be normatively required with
     measurement specifications. If unspecified = MAJOR.

I.4  Audit / compliance trail: every key issuance, revocation,
     quota change, kill switch toggle, capacity tier transition
     MUST be logged. If absent = MAJOR.

### Category J: Front-door contract clarity

J.1  Gateway responsibility vs front-door responsibility: spec
     must clearly partition. If overlap or gap = MAJOR.

J.2  Demo traffic mechanism: how does the demo invoke the
     gateway and identify itself? If unclear or spoofable =
     MAJOR.

J.3  /account page: gateway-rendered or front-door-rendered?
     The BUILD prompt's open question must be addressed in v0.1
     or explicitly deferred to v0.2 with rationale. If
     unaddressed = MINOR.

### Category K: Scope discipline

K.1  Out-of-scope list must include: Stripe/payments,
     metered billing, paid plans, provider payouts, donations,
     vision, embeddings, batch, tool execution, strict
     structured outputs, complex abuse scoring, Mintlify docs,
     multi-region coordinator, Workers/Vercel/Lambda edge
     deployment, enterprise/compliance, captcha-first signup.
     Each missing item = MINOR (these were named in BUILD
     prompt's out-of-scope).

K.2  No premium positioning: spec must not invent buyer
     personas, recommend prices, or position the API as
     premium. Any deviation = MAJOR.

K.3  No Tier-3 deprecation: spec must not contain a "MUST
     shut down SPEC-006" branch. If present = CRITICAL
     (operator pre-commitment violated).

K.4  No SPEC-001/002 changes: spec must not propose
     normative changes to upstream specs. If present =
     CRITICAL ("scope creep across spec boundary").

### Category L: Acceptance criteria quality

L.1  Each AC must have a deterministic verification step
     (curl command, SDK invocation, test fixture). If any AC
     is hand-wavy ("the system should work") = MAJOR.

L.2  ACs must cover at minimum: signup flow, key issuance,
     key revocation, OpenAI SDK drop-in (Python + JS),
     streaming, demo traffic, quota enforcement (per-account
     + per-IP), kill switch activation, capacity-burst tier
     triggers, rating capture (B + C), status endpoint
     shape, failure modes (404/401/403/429/502/503/504),
     provider transparency rules, OAuth CSRF defense, token
     revocation latency, instrumentation presence. If any
     uncovered = MAJOR.

L.3  Quantified thresholds in ACs: where the AC specifies
     "within N seconds" or "at least N samples," N must be
     justified. Unjustified N = MINOR.

### Category M: Backward-compat with the rest of the project

M.1  Legacy direct-tunnel buyer paths (m4.malibu.tech,
     m1.malibu.tech) must remain operational. Any clause
     that breaks them = CRITICAL.

M.2  Existing coordinator endpoints
     (coordinator.malibu.tech/v1/*, /healthz, /admin/*,
     /poolz, /ws/provider) — gateway introduction must not
     break any of these. Spec must specify nginx routing
     ensuring coordinator continues to serve its own
     surface. If unspecified = MAJOR.

M.3  M4 + M1 partner Macs are on phase3-binary v1.1.4 / v1.1.3
     (not yet upgraded to v1.2.3). Spec must not require
     binary upgrade to use the gateway. If required = CRITICAL.

### Category N: Security

N.1  No buyer-visible secrets: spec must forbid leaking
     provider hostnames, stable provider IDs, operator keys,
     signing keys in any buyer-facing response. If any
     buyer-visible response contains potentially-sensitive
     data = CRITICAL.

N.2  Storage encryption at rest: spec should address whether
     the SQLite DB is encrypted. If absent = MINOR for v1
     (operator-only access), but should be MAJOR if the DB
     migrates to multi-tenant storage in v2.

N.3  Audit trail tamper resistance: the audit log spec must
     specify whether logs are append-only and tamper-evident.
     If only append-only without integrity check = MINOR.

N.4  OAuth callback URL validation: spec must require strict
     callback URL allowlist. If absent = CRITICAL.

N.5  No reflection of user-controlled data without escaping:
     spec must address how the dashboard renders user-supplied
     comments (feedback `comment` field). If unspecified =
     MAJOR (stored XSS risk).

## Output format

Produce `/Users/augstar/macprovider-poc/specs/SPEC-006-audit.md` with
this structure:

```
# SPEC-006 v0.1 audit report

## Round 1 (Codex, 2026-MM-DDTHH:MM:SSZ)

### Summary
- N CRITICAL findings
- M MAJOR findings
- K MINOR findings
- L QUESTIONS

### CRITICAL findings

C1. [Title]
    **Location:** § X.Y, line range
    **Finding:** [description]
    **Why it matters:** [impact]
    **Suggested fix:** [if obvious; "operator decision" if not]

(repeat for each critical finding)

### MAJOR findings
M1. ...

### MINOR findings
m1. ...

### Operator questions surfaced
q1. ...

### Verdict
- READY TO BUILD (zero CRITICAL, zero MAJOR-blocking)
- READY WITH FIX PASS (CRITICALs all closable in narrow fix prompt)
- ANOTHER DESIGN ROUND NEEDED (architectural CRITICALs, fix won't suffice)

## Round 2 (Claude, 2026-MM-DDTHH:MM:SSZ)
(appended in round 2; do NOT overwrite round 1)

[same structure]

### Round 2 notes on Round 1
- Findings I confirm
- Findings I disagree with (and why)
- New findings round 1 missed
- Verdict (mine, independent of round 1)
```

## Self-verification before declaring audit complete

- [ ] Read every section of SPEC-006 v0.1 (all 20 sections, all 25
      ACs).
- [ ] Compared SPEC-006 § 2 against BUILD prompt's locked-design
      header. Drift documented.
- [ ] Walked each Category A through N. Even if no findings, noted
      "no findings" explicitly.
- [ ] Severity for each finding chosen against the definitions above,
      not subjectively.
- [ ] Location (section number, line range when applicable) on every
      finding.
- [ ] Suggested fix for CRITICAL findings (operator may accept or
      reject; the suggestion is data, not prescription).
- [ ] Verdict (READY / READY+FIX / DESIGN ROUND NEEDED) at end.

When done, print a 200-word handback summary:
- finding count by severity
- top 3 most impactful findings
- the verdict + one-sentence rationale

Then stop. Do NOT begin drafting a fix prompt. The operator decides
whether to fix, retry the audit, or escalate to a design round.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~30 min per round):

1. Read the Codex round 1 findings start to finish.
2. For each CRITICAL: confirm whether it's real (Codex caught something Claude missed) or a false alarm (Codex misread the spec).
3. For each MAJOR: same triage.
4. After round 1: run the same prompt in Claude for round 2. Claude will read round 1 in the audit file and add round 2 below.
5. After round 2: cross-reference. Findings both audits agree on are high-confidence. Findings only one audit raised need operator triage.

## How to use the audit output

- **READY TO BUILD verdict from both rounds**: skip the fix pass, move to `BUILD_PHASE5_PROMPT.md` for the gateway implementation.
- **READY WITH FIX PASS**: draft `FIX_SPEC_006_V0_2_PROMPT.md` covering only the CRITICAL findings. Run, audit again (round 3 + 4 if needed). Lock at v0.2 or v0.3.
- **ANOTHER DESIGN ROUND NEEDED**: re-open the design exploration. The spec's architectural choices may have been wrong.

Historic pattern from SPEC-001/002/003: round 1 typically surfaces 2-4 CRITICAL + 6-10 MAJOR + 5-8 MINOR. Round 2 confirms most CRITICALs and adds 3-5 new MAJORs the first auditor missed. Total ~3 audit cycles to reach a locked spec.
