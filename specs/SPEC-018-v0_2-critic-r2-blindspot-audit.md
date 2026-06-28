# SPEC-018 v0.2.3 — Critic Blind-Spot Audit, Round 2 (defensive)

**Date:** 2026-06-28
**Reviewer:** Claude critic r2 defensive pass (Opus 4.7)
**Verdict:** READY TO LOCK
**Prior r1 verdict:** FIX REQUIRED (3H + 4M + 3m + 2Q)

## Tally: C/H/M/m/Q

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- minor: 3
- Q: 1

v0.2.3 closes all three r1 HIGH findings AND the load-bearing M-4 precedent
finding, AND survives a fresh adversarial sweep of v0.2.3 additions. Three
new minor observations are documentation-quality issues that do not block
lock. One Open Question is forwarded.

Mode operated in: THOROUGH (no findings warranted ADVERSARIAL escalation
after the closure pass on prior HIGHs was clean).

---

## Closure status — r1 findings

### H-1 (AC-48 / Cline+openai-python category error) — CLOSED

v0.2.3 splits AC-48 into AC-48a and AC-48b:

- AC-48a (line 624) gates the openai-python ecosystem on terminal-SSE
  error behavior using `openai-python` v2.44.0+ streaming reader. Generic
  SDK-side gate.
- AC-48b (line 626) gates Cline VS Code extension v4.0.0 through
  `sdk/packages/llms/src/providers/vendors/openai-compatible.ts`
  importing `@ai-sdk/openai-compatible` from Vercel AI SDK. Explicitly
  names the file path I cited in r1 H-1 as the Cline OpenAI-compatible
  vendor entry point.

§10d.4 (line 828) adds explicit clarification: `"The Cline v4.0.0
anchor framework drives OpenAI-compatible chat completions through
Vercel AI SDK (@ai-sdk/openai-compatible), not openai-python. Cline-
specific terminal-SSE-error behavior is gated by AC-48b"`.

AC-43 (line 858) appends: `"AC-43 is an OpenAI Python SDK regression
and is NOT a Cline-stack regression; Cline-stack streaming behavior is
gated by AC-48b."`

The category-error pattern that drove H-1 is fully closed: the SPEC now
distinguishes the two SDK families and gates them with independent ACs.
The fixture-cannot-exist problem is gone.

### H-2 (§3.9 minimal prompt-echo guard self-DoS + whitespace bypass) — CLOSED

v0.2.3 takes Path (a): §3.9 DELETED entirely. AC-49 DELETED. The deletion
is documented as Amendment 2 in §10c.1 amendment log (line 705), the
`AMENDED v0.2.3` paragraph in §10c (line 686), and the change-log entry
at line 29. Residual risk (same-family echo attack remains unmitigated
in v0.2) is explicitly named in the orientation block, change log, and
§10c amendment paragraph. v0.3 owns the full guard with the four
properties I called for in r1 H-2 fix recommendation (whitespace
normalization, tool-description scope coverage, Cline-shaped false-
positive testing, SPEC-018-self-reading absence-of-self-DoS test).

AC-25a (line 574) now explicitly requires the Cline release-gate
fixture workspace to include `specs/SPEC-018-agentic-tool-calling.md` as
a possible `read_file` target with a Fail condition `"SPEC-018 self-
reading breaks a legitimate follow-up tool call"`. This is the exact
self-DoS test I called for. With §3.9 deleted, the assertion is
trivially satisfied in v0.2.3, but the test stays as a regression guard
for v0.3 full-guard work.

Path (a) was the cleaner of the two H-2 fix options I proposed. The
deletion + honest documentation pattern is better than a half-fixed
guard.

### H-3 (per-provider auto-downgrade buyer-vs-buyer DoS) — CLOSED

AC-45 (line 618) is rewritten with explicit per-(buyer, provider)
attribution:
- 3 malformed streams from the same buyer to the same provider within
  a 5-minute window triggers downgrade for that (buyer, provider)
  tuple only.
- Downgrade lifts after 10 minutes of clean streams from that buyer to
  that provider.
- AC-45c adversarial-buyer fixture asserts: `"one buyer repeatedly
  induces malformed streams from a provider; other buyers sticky-routed
  to the same provider continue to receive incremental unless their
  own tuple crosses the downgrade threshold."`
- Fail condition explicitly enumerates: `"one buyer's malformed
  incremental stream disables streaming for other buyers or globally
  for all providers, downgrade fails to recover after the clean
  interval"`.

§10d.4 (line 824) mirrors the per-tuple rule and explicitly states
recovery semantics. `X-MacProvider-Streaming-Mode` value
`buffered_provider_downgrade` (line 826) is now scoped to the tuple,
not the provider globally.

The buyer-vs-buyer attack vector I described in r1 H-3 is fully closed.
The author chose the prompt's concrete threshold values (3/5min/10min)
rather than my alternative N/W/R recommendations; the chosen values are
defensible and audit-traceable.

Sybil bypass note (not a finding): a single attacker controlling N
buyer accounts can still trigger N independent tuple downgrades against
the same provider without crossing the threshold. This degrades the
attacker's own UX but does not reach other (real) buyers' streams,
which is the H-3 invariant we wanted to preserve. The downstream
FaultBreaker behavior on accumulated malformed-final-close events is
governed by SPEC-001 / SPEC-002, not SPEC-018; this audit treats that
as out of scope.

### M-4 (Path B precedent under-specified) — CLOSED

§10c.1 (line 692) promotes lock-amendment discipline to a named section
with four explicit clauses:
- (a) Names the specific clause being amended.
- (b) States the strategic rationale.
- (c) Names the replacement mitigation OR explicitly documents residual
  risk.
- (d) Carries the amendment label `AMENDED v<X.Y.Z>` in the original
  clause's location (preserved as historical text + amendment
  paragraph).

Plus: `"Silent scope cuts of locked invariants are NON-COMPLIANT."` and
explicit AC-number stability rule (`"once an AC is assigned a number,
that number is never reused or renumbered, even if the AC content is
amended"`).

Plus: enumerated amendment log with Amendment 1 (v0.2.1 model-hash
registry deferral) and Amendment 2 (v0.2.3 §3.9 deletion), each with
clause-being-amended + rationale + mitigation/residual-risk fields.

This addresses the core M-4 concern: future authors who want to amend
locked content now have a documented process with auditable artifacts.
The author elected not to add my proposed stricter sub-clauses (no-
patch-bump rule, no-weakening-security rule, required audit gates per
DRAFT NOTES line 12). I rated this in r1 as MEDIUM with explicit
recommendation text; the author's chosen text is looser than my
recommendation but covers the core grievance (precedent semantics
named, not silent). Re-rating: substantively closed at MEDIUM
threshold; remaining governance gap is a minor concern documented
below.

---

## Fresh sweep — v0.2.3 additions

### Minor findings (do not block lock)

#### m-1 — §3.9 deletion lacks an in-place breadcrumb in §3

§3 subsection ordering is §3.1, §3.2, §3.3, §3.4, §3.5, §3.6, §3.8, §3.7.
§3.9 is absent with no in-place placeholder. The amendment marker
`AMENDED v0.2.3` lives at §10c (line 686), and Amendment 2 is in the
§10c.1 amendment log (line 705). A reader scanning §3 sees the gap with
no in-place pointer to §10c.1 explaining where §3.9 went.

§10c.1 clause (d) requires the amendment label `"in the original
clause's location"`. For a deletion there is no `"preserved as
historical text"`, so clause (d) is partially N/A for the deletion
case. The amendment log + §10c.1 + the orientation block do provide a
discoverable trail. This is a documentation-discoverability minor, not
a process violation.

**Recommended fix (optional):** Add a one-line stub in §3 between
§3.6 and §3.8:

```
### 3.9 [DELETED v0.2.3]

The v0.2.1 minimal prompt-echo guard introduced in this section was
deleted in v0.2.3 per §10c.1 Amendment 2. See §10c.1 for rationale
and residual risk.
```

This satisfies clause (d) in spirit by leaving a breadcrumb at the
original location.

(While there, consider re-ordering §3.7 / §3.8 so that 3.x sections
appear in numeric order. §3.7 currently sits after §3.8 because §3.8
was inserted in v0.2.1 ahead of locked-content §3.7. The v0.1.5 change
log entry at line 47 notes this was deliberate to keep §3.7 lock-
addressable. Either order is defensible; the current order surprised me
on first read.)

#### m-2 — AC-44 NTP precondition cites a non-existent SPEC-006 requirement

AC-44 (line 616) says: `"Timing measurements assume NTP-anchored clock
skew |t_provider - t_gateway| ≤ 100 ms at request start, verified via
heartbeat per the SPEC-006 buyer-API NTP sync precondition inherited by
v0.2."`

Verification: I grepped for `NTP` / `clock skew` / `time sync` across
`specs/SPEC-006-buyer-api.md` and `specs/SPEC-006-design.md` — zero
hits. There is no `"SPEC-006 buyer-API NTP sync precondition"` in
SPEC-006. The inheritance citation is fabricated.

DRAFT NOTES line 14 admits the author chose to `"treat SPEC-006 NTP
sync as inherited precondition rather than introducing a new SPEC-018
deployment requirement."` The intent (don't add a fresh deployment
requirement) is reasonable; the execution (cite an inherited
requirement that doesn't exist) is a documentation defect.

Substantively, AC-44's technical fix to r1 M-1 (100 ms skew bound +
heartbeat verification + skew-corrected p95) is sound. The defect is
only in the citation. An IMPL author who follows AC-44's own text can
implement the NTP-anchored heartbeat without SPEC-006 saying anything
about NTP — AC-44 is self-contained even with the bad citation.

Severity: minor (after Realist Check). The substantive r1 M-1 closure
holds; only the citation source is wrong.

**Recommended fix:** Replace the inheritance citation with one of:

(a) `"Timing measurements assume NTP-anchored clock skew
|t_provider - t_gateway| ≤ 100 ms at request start, verified via a
SPEC-018 v0.2-introduced heartbeat probe. v0.3 candidate: factor this
precondition into SPEC-006 as a shared buyer-API deployment
requirement."`

(b) Or open a SPEC-006 v0.X amendment that adds the NTP precondition,
and only then claim inheritance.

#### m-3 — AC-56 6 MiB total decoded prompt cap is non-binding under AC-50

AC-56 (line 640) caps total decoded UTF-8 bytes across `messages[].content`
+ assistant-history `tool_calls[].function.arguments` + `role:"tool".content`
at 6 MiB. AC-50 caps raw HTTP body at 4 MiB.

JSON decode strictly reduces byte length (escape sequences shrink:
`A` → `A`; `\n` → newline; multi-byte UTF-8 stays the same). Raw
body 4 MiB implies decoded content ≤ 4 MiB minus JSON-structural
overhead (braces, commas, key strings, quote marks). The 6 MiB decoded
cap is unreachable without first violating AC-50's 4 MiB raw body cap.

AC-56 is therefore vacuous as a release gate — no fixture can
demonstrate decoded > 6 MiB while satisfying raw ≤ 4 MiB. The cap is
documentary, not enforcement.

This addresses my r1 M-2 in a technically-honest but redundant way:
AC-50 was already the binding total bound, and r1 M-2's recommendation
was to either add a single explicit cap OR document that AC-50 is the
binding bound and the others are sub-bounds. The author chose option
(a) by adding AC-56; that option closes the M-2 concern but leaves the
new cap unverifiable.

**Recommended fix (optional):** Either:

(a) Tighten AC-56 to a value that can bind under AC-50 (e.g., 3.5 MiB
to leave 0.5 MiB for JSON overhead). This makes AC-56 enforceable.

(b) Or downgrade AC-56 to a documentary note in §10d.1 explaining that
the 4 MiB raw body cap is the binding total bound and aggregate
sub-caps (1 MiB tool-result, 2 MiB assistant-history) are channel-
specific defense-in-depth, not additive sub-bounds.

(c) Or leave AC-56 as a forward-compat cap that lets future v0.2.x
raise the raw body cap without losing the prompt-aggregate bound. This
is the strongest reading of the current text but should be made
explicit.

---

## Open Questions

### Q-1 — Should §10c.1 distinguish locked-content amendments from draft-content amendments?

§10c.1 (line 694) scopes amendments to `"a previously LOCKED normative
claim (introduced as MUST in a prior SPEC version)"`. Amendment 1
(v0.2.1 model-hash registry deferral) amends a v0.1.3-locked clause —
classic locked-content amendment. Amendment 2 (v0.2.3 §3.9 deletion)
amends a v0.2.1-introduced MUST. v0.2.x is not yet locked, so §3.9 was
not, strictly speaking, "LOCKED normative claim" content at the time
of deletion.

DRAFT NOTES line 17 explicitly notes the author treated this carefully:
`"Adjusted the lock-amendment sentence to '2 invariants' so it does
not conflict with the explicit constraint that §3.9 deletion is
v0.2.1-content, not v0.1.5-content."` The orientation block (line 15)
uses the word `"invariants"` not `"locked invariants"`, which is
technically consistent with §10c.1's scope.

But the amendment LOG includes both as if they are governed by the same
discipline. A reader could conclude: any draft-version MUST is now
treated as an "invariant" that requires (a)-(d) ceremony to revise.
This is heavier than draft-content normally warrants and lighter than
locked-content protection should be.

This is process semantics, not a v0.2.3 lock-blocker. Forward to v0.3
governance work: should §10c.1 split into "locked-content amendment"
(strict (a)-(d) ceremony) and "draft-content revision" (lighter
process, log-only)? If so, Amendment 2's status should be
reclassified.

I do not block lock on this question because the SPEC's current text
is internally consistent — §10c.1 governs locked content; the
amendment log records both for transparency without claiming Amendment
2 is technically a locked-content amendment. But a future
clean-up pass should consider the distinction.

---

## Codex blind-spots reconfirmed

Cross-checking the 9 r1 vectors against v0.2.3 state:

1. **AC-46 `usage.macprovider_model_hash_observed`** — CLOSED. r1 M-3
   absorbed via buyer-side type assertion + provider self-test split
   at line 620.
2. **AC-25a CI fixture (Cline session determinism + SPEC-018 self-
   reading)** — CLOSED. r1 m-1 + m-2 absorbed via explicit
   SPEC-018-self-reading requirement at line 574 (Fail condition:
   `"SPEC-018 self-reading breaks a legitimate follow-up tool call"`).
3. **AC-44 1500ms p95** — SUBSTANTIVELY CLOSED. Skew correction added;
   only m-2 citation-source defect remains.
4. **AC-47/AC-48 §8.4.2/§8.4.3 split + openai-python terminal SSE** —
   CLOSED. AC-48 split into AC-48a/AC-48b at lines 624-626.
5. **Minimal prompt-echo guard (§3.9)** — CLOSED via deletion.
6. **Path B precedent (locked invariants amendment)** — SUBSTANTIVELY
   CLOSED via §10c.1. Q-1 forwarded on locked-vs-draft semantics.
7. **§10d.4 streaming kill switch auto-downgrade** — CLOSED via
   per-(buyer, provider) attribution + AC-45c adversarial fixture.
8. **Aggregate caps composability** — CLOSED via AC-56, with m-3 note
   on AC-56's non-binding nature under AC-50.
9. **Cline reality check** — CLOSED. AC-48b explicitly references
   `sdk/packages/llms/src/providers/vendors/openai-compatible.ts` and
   `@ai-sdk/openai-compatible`. The H-1 category error is fixed at the
   AC text level.

---

## Adversarial sweep on v0.2.3 net-new content

I deliberately probed v0.2.3's new and modified content for fresh
issues my r1 pass would not have caught:

- **§10c.1 governance loopholes:** rule does not gate WHO may amend,
  doesn't prevent patch-version amendments, doesn't require specific
  audit gates. Per Realist Check, codex + critic audit cycles gate
  every SPEC change in practice. The discipline rule is process-floor,
  not approval gate. Not a v0.2.3 lock-blocker.
- **AC-48b verifiability:** AC-48b requires Cline VS Code extension
  test that triggers final-close failure mid-stream. Operationally
  complex (needs a controllable provider mock that injects terminal-
  error) but mechanically feasible. Not a defect; an IMPL note.
- **H-3 sybil bypass:** N-buyer-account attacker can trigger N
  independent (buyer, provider) downgrades without cross-buyer impact.
  This is the H-3 invariant we wanted; sybil bypass degrades the
  attacker's own UX, not other buyers'. Not a regression.
- **AC-44 NTP citation:** documented as m-2.
- **AC-56 vacuousness under AC-50:** documented as m-3.
- **§3 reading order with §3.9 deletion gap:** documented as m-1.
- **Quick orientation `"amends 2 invariants"` semantic stretch:**
  navigated carefully by the author per DRAFT NOTES; Q-1 forwarded.
- **Amendment markers in original locations:** Amendment 1's `AMENDED
  v0.2.0/v0.2.1` marker exists in §10c (line 684) at the right
  location. Amendment 2's `AMENDED v0.2.3` marker is at §10c (line
  686) but §3.9's actual location has no breadcrumb — m-1 covers this.

No fresh CRITICAL, HIGH, or MEDIUM emerged from the sweep.

---

## Realist Check applied

Each finding re-tested:

- **m-1 (§3.9 missing breadcrumb):** Realistic worst case = reader
  confusion when skimming §3. Easy fix (one stub). Detection
  immediate. Mitigated by amendment log + orientation block giving
  discoverable trail. Severity correctly minor.
- **m-2 (AC-44 NTP citation):** Realistic worst case = IMPL author
  hunts for SPEC-006 NTP requirement, doesn't find it, falls back to
  AC-44's self-contained text. Time cost small. Substantive fix
  technically sound. Severity correctly minor (downgraded from
  MEDIUM because the technical content is right; only the citation
  source is wrong).
- **m-3 (AC-56 non-binding):** Realistic worst case = AC-56 is a
  vacuous release gate that always passes. Doesn't harm correctness;
  doesn't add real protection beyond AC-50. Severity correctly minor.

No finding meets MEDIUM severity after Realist Check.

---

## Verdict justification

**READY TO LOCK.** All three r1 HIGH findings are substantively closed
with the technical content I asked for (or a cleaner alternative for
H-2 via Path (a) deletion). r1 M-4 is closed via the §10c.1 discipline
rule, AC-number stability rule, and amendment log. r1 M-1/M-2/M-3 are
each closed at the substantive level, with only m-2 (AC-44 NTP
citation) leaving a documentation residue at minor severity.

The three fresh minor findings are documentation-quality issues that
do not block lock and can be absorbed in a v0.2.4 polish round or
addressed inline by an IMPL-prompt revision. The single Open Question
is governance semantics, deferred to v0.3 or a SPEC-discipline
clean-up pass.

Mode: started THOROUGH. Did not escalate to ADVERSARIAL because the
HIGH-closure pass was clean and the fresh sweep surfaced only minor
documentation issues. The v0.1.5 → v0.2.2 → v0.2.3 pattern of
"each round absorbs the prior critic findings without regression" is
the expected codex-converged-plus-critic-adversarial-absorbed lock
trajectory, and v0.2.3 reaches that trajectory's natural fixed point.

Lock-bar (0 CRITICAL + 0 HIGH + 0 MEDIUM): **MET.**

Recommend declaring v0.2.3 LOCKED pending the other three codex r4
defensive lanes (architect / code / security / product-design) and
the Claude narrative r4 lane also returning 0/0/0.

