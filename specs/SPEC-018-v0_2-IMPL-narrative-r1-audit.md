# SPEC-018 v0.2.4 IMPL — Narrative Blind-Spot r1 Audit

**Date:** 2026-06-28
**Reviewer:** claude narrative-blind-spot
**Verdict:** FIX REQUIRED

## Tally: C/H/M/m/Q

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 3
- minor: 4
- Q: 2

## Scope of this audit

The four codex lanes (architect / code / security / product-design) inspect
the IMPL diff for correctness, citation, money-path, and Cline-stack
intent. This lane asks a different question: **does the narrative trail
left behind (`SPEC-018-v0_2-IMPL-NOTES.md` + `BUILD_SPEC_018_v0_2_IMPL_PROMPT.md`
+ `BUILD_SPEC_018_v0_2_IMPL_CONTINUATION_PROMPT.md` + commit message
`23266e7`) let three cold readers act without paging in this session's
chat history?**

Three reader tests below.

---

## Reader Test 1 — IMPL reviewer reading the diff cold + IMPL-NOTES

**Scenario:** GitHub reviewer opens the PR. They read the commit message,
`specs/SPEC-018-v0_2-IMPL-NOTES.md`, and the diff. Goal: decide whether
to approve the four-deliverable + 5-supporting-work claim.

**Result:** the commit message carries the heavy lifting. IMPL-NOTES is
under-specified relative to the diff. Specifically:

- The "Deliverable Summary" line for Deliverable #1 names `AC-25 through
  AC-29` as a range, but `git show 23266e7 --stat` plus
  `specs/BUILD_SPEC_018_v0_2_IMPL_PROMPT.md` add a second AC set bound to
  the same Swift+Go validation surface (AC-50, AC-51, AC-52, AC-53,
  AC-54, AC-55 = aggregate body / aggregate tool-result / aggregate
  arguments / message count / total tool calls / linear validation).
  These six AC numbers do not appear anywhere in `SPEC-018-v0_2-IMPL-NOTES.md`.
  The commit message mentions the 4 MiB / 1 MiB / 2 MiB / 256 / 128
  numbers but not the AC-50..AC-55 mapping. A reviewer chasing
  "Where is AC-53 verified?" gets no answer from the notes.

- AC-47 (`#4 Final-close terminal completeness on provider EOF/disconnect`)
  is a SPEC v0.2.4 AC and is implemented by the §8.4 split work cited at
  `server.go:2474/2528/2551/2572`, but AC-47 is not named in IMPL-NOTES.

- AC-23s (streaming forward-compat regression) shipped as
  `test/integration/run-ac23s.sh`. AC-23s is not named in IMPL-NOTES.
  The BUILD prompt called it out explicitly; the audit prompt
  (`AUDIT_SPEC_018_v0_2_IMPL_r1_PROMPT.md`) calls it out under "Smoke
  evidence". A reviewer reading only IMPL-NOTES sees no trace.

- AC-25b (`#1 Multi-turn end-to-end Cline manual recorded smoke`,
  release-evidence-only) is alluded to ("Full live Cline automation
  remains a release-gate manual smoke until CI can provision VS Code/
  Cline") but not named. A reviewer asking "what discharges AC-25b?"
  cannot tell whether the gap is acknowledged-by-design or
  forgotten-by-accident.

- `docs/operations/spec-018-v0.2-deploy.md` shipped as part of the
  diff but is not referenced from IMPL-NOTES. The notes' AC-44 entry
  mentions NTP skew enforcement but does not point at the operator
  checklist. The deploy doc itself is also incomplete — see Reader
  Test 3.

**Severity rollup:** MEDIUM. A reviewer can reconstruct the picture from
the commit message and the v0.2.4 SPEC body, but the IMPL-NOTES file
that the audit prompt designates as the absorption record materially
under-claims what shipped. This is exactly the surface the
[[feedback-three-lane-codex-audits]] convention relies on as ground
truth.

---

## Reader Test 2 — PR reviewer doing a money-path security review with no prior context

**Scenario:** reviewer arrives at the PR with one question: "does any new
failure path settle non-zero credits?"

**Result:** this is the IMPL-NOTES section that is best served. The
"Money-Path Trace Evidence" block lists nine `server.go` line numbers
(2254 / 2266 / 2287 / 2301 / 2324 / 2474 / 2528 / 2551 / 2572) tied to
specific failure modes, and chains to `billing_recorder.go:181` +
`formula.go:112`. Cold-reading this is enough to walk every new failure
path to its `FaultBreakerQualifying` write and to confirm the existing
zero-credit guarantee.

Two narrative gaps that a paranoid reviewer would still flag:

- The kill switch env var (`COORDINATOR_STREAMING_FORCE_BUFFERED=1`)
  exists in code (`streaming_downgrade.go:90`) but is not documented in
  IMPL-NOTES, the commit message, OR the deploy doc. An incident-
  response reviewer asking "what's the operator escape hatch if the
  §8.4 split misbehaves in production?" cannot find the answer from
  the narrative trail. They have to grep code.

- The `X-MacProvider-Streaming-Mode` header values
  (`incremental` | `buffered_kill_switch` | `buffered_provider_downgrade`)
  are named in the commit message but not in IMPL-NOTES. A money-path
  reviewer wanting to confirm "does the buffered-downgrade path also
  settle correctly?" has to chase the header definition from code.

**Severity rollup:** money-path-trace coverage is HIGH-quality, but the
operator-control narrative (kill switch, header mode meanings) is
under-documented. MEDIUM finding overall, scoped to the operator-runbook
surface, not to settlement correctness.

---

## Reader Test 3 — Future Claude starting v0.3 IMPL

**Scenario:** a v0.3 IMPL session opens with no transcript carryover.
The session needs to know:

1. What v0.2 amendments to §3.8, §3.9, §8.4, §10c, §10d landed?
2. What interpretation calls were made that v0.3 either inherits or
   reverses?
3. What is explicitly deferred to v0.3?

**Result:** "Interpretation Calls" section answers item 2 cleanly. Five
entries: §3.8 family-keyed input render (hash-keyed deferred to v0.3),
§10d.0 thick envelope (broad — Path A), AC-25a harness skeleton vs full,
AC-46 model-hash exclusion from canonical scope, AC-48 split rationale.
A v0.3 IMPL session reading this knows exactly which calls were
re-litigation-eligible.

Items 1 and 3 are weaker:

- "Deliverable Summary" describes what shipped but does not enumerate
  the v0.2.x deferred items by SPEC section. A v0.3 IMPL session asking
  "is the prompt-echo guard a v0.3 deliverable?" or "is hash-keyed
  registry enforcement a v0.3 deliverable?" gets only an oblique hint
  ("Hash-keyed registry enforcement remains deferred to v0.3 per the
  locked spec amendments"). The prompt-echo guard (§3.9 deletion in
  v0.2.3) is not named in IMPL-NOTES at all; a future-Claude would
  need to read the v0.2.3/v0.2.4 SPEC change-log entries to discover
  the deferred work.

- AC coverage by number is fine for what's listed, but a v0.3 IMPL
  scoping session would benefit from a "deferred to v0.3" pointer
  list. AC-44 second branch / hash-registry / structured `usage.macprovider_malformed_tool_call`
  are all v0.3 candidates per the SPEC change log; none are named in
  IMPL-NOTES.

- `docs/operations/spec-018-v0.2-deploy.md` ships as the operator
  release-gate artifact but the file itself is 11 lines covering only
  NTP. The BUILD prompt's "Operator kill switch" + "AC-44 prerequisite"
  + "X-MacProvider-Streaming-Mode header" topics never reach the
  operator doc. A v0.3 IMPL session reusing this artifact as a template
  inherits a thin doc.

**Severity rollup:** MEDIUM. v0.3 IMPL session can still execute; it
just has to re-derive deferred-item list from the SPEC change-log
instead of consuming a v0.2-IMPL-side index.

---

## Findings

### CRITICAL findings

None. The narrative trail does not break the money-path, ship a SPEC
violation, or make a false claim about test coverage. All three reader
tests can be completed with re-reading; none requires session
reconstruction.

### HIGH findings

None. Where IMPL-NOTES is under-specified, the commit message
`23266e7` (`git log -1 --format=%B 23266e7`) carries the missing
content. A reviewer with access to both can reconstruct intent. This
keeps every finding below HIGH.

### MEDIUM findings

**M1. IMPL-NOTES under-claims relative to what shipped.**
Six AC numbers (AC-50, AC-51, AC-52, AC-53, AC-54, AC-55) are
implemented + tested but never named in `specs/SPEC-018-v0_2-IMPL-NOTES.md`.
AC-47 + AC-23s + AC-25b are implemented/discharged but unnamed.
Fix: add an "Acceptance Criteria Coverage" subsection naming every
v0.2.4 AC and its discharge mechanism (test file, integration script,
manual smoke, deferred-to-v0.3). The notes' present "AC-25 through
AC-29" range shorthand under-counts the work in the diff.

**M2. Operator-control surface not documented in narrative.**
The kill switch env var `COORDINATOR_STREAMING_FORCE_BUFFERED=1`
exists in `phase4-coordinator/internal/buyer/streaming_downgrade.go:90`
and is the operator escape hatch for §8.4-split-induced regressions in
production. It is referenced in neither IMPL-NOTES, commit message,
nor `docs/operations/spec-018-v0.2-deploy.md`. The header values
`incremental` / `buffered_kill_switch` / `buffered_provider_downgrade`
are partially documented in the commit message but not in IMPL-NOTES
or the deploy doc.
Fix: extend `docs/operations/spec-018-v0.2-deploy.md` with a
"Streaming control surface" section covering the env var, the three
header states, and the per-(buyer, provider) downgrade thresholds
(3 malformed / 5 min window / 10 min recovery from `streaming_downgrade.go`).
Cross-reference from IMPL-NOTES.

**M3. v0.3 deferred-work index missing from IMPL-NOTES.**
Section "Interpretation Calls" lists what shipped but not what
explicitly defers to v0.3. The v0.2.3 §3.9 prompt-echo guard deletion
(deletion is a v0.2 amendment, full guard is a v0.3 candidate) is not
named in IMPL-NOTES. Hash-keyed registry enforcement is mentioned
obliquely under the §3.8 entry but is not in a deferred-items index.
AC-44 second branch (full deterministic provider benchmark commit)
and structured `usage.macprovider_malformed_tool_call` are also v0.3
candidates per SPEC change-log entries but not catalogued here.
Fix: add a "Deferred to v0.3" subsection mirroring the structure of
the §10c.1 amendment log in the SPEC body.

### Minor findings

**m1. Verification commands have a path bug.**
The "Verification Commands" block in IMPL-NOTES line 47–48 reads:
```
cd ../test/integration/cline_session && ./run-cline-session.sh
cd ../streaming_terminal_error && ./run-ac48a.sh && ./run-ac48b.sh
```
The relative-cd chain assumes the previous command's cwd lands in
`test/integration/cline_session`, then `cd ../streaming_terminal_error`
moves to `test/integration/streaming_terminal_error`. This is correct
only if the reader runs the block top-to-bottom in a single shell.
A reader running line 48 in isolation gets a wrong-directory error.
Fix: absolute-path each cd, or use a single `cd` to a known anchor at
block entry.

**m2. `BUILD_SPEC_018_v0_2_IMPL_CONTINUATION_PROMPT.md` is checked
into the commit but its existence is not flagged in IMPL-NOTES.**
A future reader doing forensics on "why was this IMPL session a
continuation?" finds the answer only by listing the specs/ dir or
reading the commit-message line "5 r1 swift test failures resolved".
The continuation prompt itself is a valuable audit-trail artifact;
the IMPL-NOTES should name it under "Authoritative inputs" or a new
"Build history" section so the continuation context is discoverable
from one entry point.

**m3. `docs/operations/spec-018-v0.2-deploy.md` is 11 lines and
under-serves its named role.**
The file covers only NTP. The BUILD prompt enumerates an operator
checklist that includes the kill switch flag, the streaming mode
header semantics, and the AC-44 skew enforcement workflow. The deploy
doc is a real artifact that operators will read first when an issue
opens against `coordinator.streamvc.live`; it should be the
single-source operator runbook for v0.2.
Fix: expand to cover kill switch, header values, downgrade thresholds,
and `/metrics/streaming` Prometheus surface.

**m4. Package.swift unhandled-resources warning is named in commit
message but not in IMPL-NOTES.**
The commit message says: "Known non-blocking polish (audit loop will
catch): Package.swift unhandled-resources warning for 3 fixture files".
This is exactly the kind of pre-disclosed minor finding that should
also live in IMPL-NOTES so it survives the eventual squash-merge and
reaches a future-Claude reading the merged main.

### Open questions

**Q1.** AC-25b release-evidence requirement is acknowledged but
unscheduled. Who is the human running the recorded smoke before
v0.2.4 IMPL ships behind a release tag, and where does the artifact
live? IMPL-NOTES does not name a path. The SPEC body at AC-25b says
"video or screenshot set plus transcript/log artifact". Without a
scheduled run + artifact path, AC-25b is at risk of becoming the
"perpetual unblocking blocker" that ships only because nobody
remembers it was a gate.

**Q2.** The IMPL-NOTES claim "`usage.macprovider_model_hash_observed`
is emitted in non-streaming responses, streaming final usage chunks,
and relay zero-usage terminal frames" maps to AC-46 first branch
(buyer-side type assertion). AC-46 second branch (provider self-test:
when local hash subsystem reports known hash, field MUST be that
value) is named in the commit message ("provider-side self-test
coverage") but not surfaced in IMPL-NOTES. Where is the AC-46
second-branch test? `MultiTurnTests.swift` is the most likely host
per IMPL-NOTES line 19 but is not explicitly cited for AC-46 there.

---

## Verdict justification

**FIX REQUIRED**, scoped to narrative-only edits. No code change
needed.

The IMPL diff itself is internally consistent, money-path-protective,
and tests are green (576 swift / 0 failures; `internal/buyer` ok). The
codex 4-lane audits are the right surface to ratify the code. This
audit is about the narrative trail that future readers — codex
auditors, PR reviewers, v0.3-IMPL Claude, on-call operators — will
inherit.

The narrative trail right now relies on the commit message to carry
content that should be in `specs/SPEC-018-v0_2-IMPL-NOTES.md`. Squash-
merge will preserve the commit message, but the convention established
by [[feedback-three-lane-codex-audits]] + [[feedback-audit-prompts-file-not-chat]]
treats the SPEC-side IMPL-NOTES file as the canonical absorption
record, separate from the commit log. The bar should be that
IMPL-NOTES is a sufficient cold-read.

To clear MEDIUM:

1. Add full AC coverage map to IMPL-NOTES (M1).
2. Document operator-control surface in `docs/operations/spec-018-v0.2-deploy.md`
   and cross-reference from IMPL-NOTES (M2 + m3).
3. Add "Deferred to v0.3" subsection to IMPL-NOTES (M3).

Minor + Q items can be batched into the same edit pass.

Estimated time: 30–60 minutes of doc-only work. No code review impact;
no test re-run required. After the doc edit, re-audit can be a single
narrative-r2 lane.
