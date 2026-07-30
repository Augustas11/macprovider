# SPEC-018 v0.2.4 IMPL — Narrative Blind-Spot r2 Audit

**Date:** 2026-06-28
**Reviewer:** claude narrative-blind-spot
**Commit audited:** `42476b7` on `impl/spec-018-v0-2`
**Verdict:** READY TO MERGE

## Tally: C/H/M/m/Q

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- minor: 1 (residual; non-blocking)
- Q: 0

## Scope of this audit

Round 2 narrative-only audit. r1 ran the three reader tests against the
50-line IMPL-NOTES + 11-line deploy doc and surfaced 3 MEDIUM + 4 minor
+ 2 Q. Absorption commit `42476b7` expanded IMPL-NOTES to 262 lines
(`wc -l`: confirmed) and the deploy doc to 203 lines. This pass re-runs
the same three reader tests against the expanded artifacts to verify
each r1 finding actually closes, then sweeps for fresh narrative-trail
gaps the expansion may have introduced.

---

## r1 finding closure status

### MEDIUM closures

**M1 (r1): IMPL-NOTES under-claims relative to what shipped.** — CLOSED.

Verified by enumerating AC numbers named in IMPL-NOTES:

```
grep -oE "AC-[0-9]+[a-z]?" specs/SPEC-018-v0_2-IMPL-NOTES.md | sort -u
```

Returns 36 unique AC mentions including all six aggregate ACs flagged
in r1 (AC-50/51/52/53/54/55 on lines 85–91), AC-47 (line 54), AC-23s
(line 41, paired with AC-43), and AC-25b (line 21). The notes now ship
a "Deliverable summary (per-AC mapping)" section that is the structure
M1 requested. Each AC entry names a discharge mechanism: test file, Go
test path, integration script, or "manual recorded smoke" classification.
The original "AC-25 through AC-29" range shorthand from r1 is gone;
each AC has its own line.

**M2 (r1): Operator-control surface not documented in narrative.** — CLOSED.

Two-part closure:

1. IMPL-NOTES added an "Operator-control surface" table at lines 108–119
   covering the kill-switch env var, all three `X-MacProvider-Streaming-Mode`
   header values, all three timing headers (provider tool-call-open,
   coordinator first-forward, gateway first-byte), the NTP skew header,
   `/metrics/streaming`, and the NTP service requirement. Each row names
   "Where", "Default", and "Effect" — exactly the operator-incident
   columns. Line 121 cross-references the deploy doc.

2. `docs/operations/spec-018-v0.2-deploy.md` expanded from 11 lines
   (NTP only) to 203 lines. Coverage verified:
   - Kill switch with explicit "Use this when" criteria (lines 41–60)
   - Three header values in a single table at lines 73–77 with operator
     action per value
   - Three timing headers documented individually (lines 84–98) with
     "what triggers emission"
   - Auto-downgrade thresholds (3 malformed / 5 min window / 10 min
     recovery) at lines 107–122 with AC-45c attribution
   - `/metrics/streaming` sample Prometheus output + M4 / M2-M3
     thresholds + troubleshooting steps (lines 126–155)
   - Rollback procedures (lines 167–179) covering both kill-switch
     toggle and full v0.1.5 revert
   - "Known limitations / v0.3 candidates" at lines 181–196 mirroring
     the IMPL-NOTES deferred-to-v0.3 index

The 3-AM-pager test now passes: an on-call operator can find the kill
switch, understand what each header value means, and execute a rollback
without paging in code knowledge.

**M3 (r1): v0.3 deferred-work index missing from IMPL-NOTES.** — CLOSED.

IMPL-NOTES lines 184–205 add a "Deferred to v0.3 (NOT in this PR)"
section explicitly enumerating:

1. §3.9 prompt-echo guard (DELETED in v0.2.3 per Amendment 2) — named
   exactly as r1 requested
2. Model-hash → tool-call-family registry enforcement (§10a #2, §10c
   Amendment 1)
3. Structured `usage.macprovider_malformed_tool_call` signal (§10a #5)
4. AC-44 second-leg server-side latency rendering
5. AC-25a full live VS Code + Cline automation
6. Per-(buyer, provider) downgrade state persistence + multi-coordinator
   propagation — this is a new (good) addition not in r1, anchoring
   the in-memory-state caveat

The deploy doc carries a parallel "Known limitations / v0.3 candidates"
list at lines 182–196 so the operator-facing artifact also surfaces what
operators should NOT expect from v0.2. A v0.3 IMPL session reading
either file gets a clean deferred-items index without re-deriving from
the SPEC change-log.

### Minor closures

**m1 (r1): Verification commands path bug.** — PARTIALLY CLOSED. See
fresh minor finding m1-r2 below. The block now starts at repo root
(`cd phase3-binary && swift test`) instead of an unstated cwd, and
the relative chain is self-consistent if run top-to-bottom in a single
shell. Still has the failure mode r1 named (line 222 in isolation breaks).
Carried forward as minor-r2; not blocking.

**m2 (r1): CONTINUATION_PROMPT not surfaced.** — CLOSED. IMPL-NOTES
line 243 names `specs/BUILD_SPEC_018_v0_2_IMPL_CONTINUATION_PROMPT.md`
under "Audit trail", giving forensics a single discoverable entry point
for "why was this IMPL a continuation".

**m3 (r1): deploy doc under-serves its named role.** — CLOSED. See M2
closure detail. 11 → 203 lines covers everything the BUILD prompt
enumerated (kill switch, header values, downgrade thresholds, NTP,
`/metrics/streaming`).

**m4 (r1): Package.swift unhandled-resources warning not in IMPL-NOTES.**
— CLOSED. Lines 256–262 add a "Known non-blocking polish (audit may
catch)" section naming the Package.swift fixture-resources warning AND
the Sendable closure-capture warnings on `streamedAnyToolCallDelta`.
The Sendable note is a good addition not in r1 — it acknowledges a
finding the critic blind-spot lane raised about Swift 6 forward-compat.

### Q closures

**Q1 (r1): AC-25b release-evidence path unscheduled.** — CLOSED. IMPL-NOTES
line 22 redirects to `cline_session/README.md` ("documented as release-
gate manual step in cline_session/README.md — recorded video against
actual extension, not CI"). The deploy doc is silent on this, which is
correct — release-evidence is not an operator concern. The README path
discharges the "where does AC-25b live" question.

**Q2 (r1): AC-46 second-branch test location.** — CLOSED. Line 96
states AC-46 implementation as "`HTTPServer.swift` + relay emission"
and lines 167–170 in "Interpretation calls" lock the canonicalization-
exclusion rule. The provider self-test for "known hash → must be that
value" is implicit in the AC-46 line on the deliverable mapping;
combined with the audit-prompt's mention that AC-46 self-test now
treats non-hex from "known" branch as mismatch, this is locatable.
A pedantic reviewer could still ask for a test file path; the rest of
the entries name files, this one does not. But not blocking — the code
lane will mechanically verify.

---

## Reader Test 1 (r2) — IMPL reviewer reading the diff cold + IMPL-NOTES

**Scenario:** GitHub reviewer opens the PR, reads commit `42476b7`
message, `SPEC-018-v0_2-IMPL-NOTES.md` (262 lines), and the diff.
Decides whether to approve.

**Result:** PASS. The IMPL-NOTES is now the primary narrative artifact;
the commit message is a faithful summary of the absorption deltas but
no longer carries load-bearing AC mapping that the file omits. Every
v0.2.4 AC is named with discharge mechanism. The "Money-path trace
evidence" block at lines 142–155 enumerates nine `server.go` line
numbers (carry-over from r1, validated as still accurate against the
absorption diff). The "Interpretation calls" block at lines 157–182
adds a new entry for the streaming token-incremental architecture
explaining the `StreamChunk` enum + `streamedAnyToolCallDelta` flag
purpose, which closes the architect r1 finding's narrative half.

No MEDIUM or HIGH carry-over. A cold-reading reviewer can approve or
flag concerns from IMPL-NOTES alone.

## Reader Test 2 (r2) — money-path security review with no prior context

**Scenario:** reviewer arrives with one question: "does any new failure
path settle non-zero credits?"

**Result:** PASS. Same money-path-trace block as r1 carries the same
9 `server.go` line numbers, validated. The kill-switch + downgrade-
thresholds gaps r1 flagged are now closed:

- IMPL-NOTES line 49 names the env var explicitly
- IMPL-NOTES lines 108–119 table maps every operator-visible surface
- Deploy doc explicitly states (lines 41–60) what the kill switch does
- Deploy doc explicitly states (lines 107–122) the AC-45c attribution
  bound preventing fleet-wide downgrade abuse

A paranoid reviewer asking "what's the operator escape hatch if §8.4
split misbehaves" finds the answer in three different places
(IMPL-NOTES table, deploy doc kill-switch section, deploy doc rollback
section).

## Reader Test 3 (r2) — Future Claude starting v0.3 IMPL

**Scenario:** v0.3 IMPL session opens cold and needs to know what
v0.2 amended, what's deferred, and what calls v0.3 can re-litigate.

**Result:** PASS.

1. v0.2 amendments to §3.8 / §3.9 / §8.4 / §10c / §10d are summarized
   in the per-AC mapping + interpretation calls. v0.3 author reads
   §10c.1 in the SPEC body alongside; both artifacts agree.

2. Interpretation calls section (lines 157–182) now includes the
   streaming-architecture entry. Five interpretation calls are named,
   each with a "v0.2 chose X" + "v0.3 may revisit" framing.

3. Deferred-to-v0.3 enumeration (lines 184–205) gives six explicit
   entries with SPEC §-references where applicable. Two of these
   (in-memory downgrade state, AC-44 second leg) were not in r1 but
   are now caught — improving the v0.3-scoping signal.

A v0.3 IMPL session reading IMPL-NOTES + deploy doc + SPEC body has
a complete enough picture to write a v0.3 BUILD prompt without
re-tracing from the v0.2 commit log.

---

## Fresh findings (r2)

### CRITICAL findings

None.

### HIGH findings

None.

### MEDIUM findings

None.

### Minor findings

**m1-r2 (r1 carry-over). Verification-commands block still relies on
top-to-bottom single-shell execution.**

Lines 209–227 in IMPL-NOTES read:

```
cd phase3-binary && swift test
cd ../phase4-coordinator && go vet ./... && go test -count=1 ./internal/buyer
cd ../test/integration && ./run-ac23s.sh
cd cline_session && ./run-cline-session.sh
cd ../streaming_terminal_error && ./run-ac48a.sh && ./run-ac48b.sh
cd ../../.. && git diff --check
```

If a reader copy-pastes any single command in isolation (e.g., to
re-run AC-48b after a fix), the relative `cd` chain breaks. Each line
assumes the previous `cd` landed.

**Severity:** minor. Not blocking. Fix is one-line per command —
either absolute-anchor each block with `cd $(git rev-parse --show-toplevel)`
or change to `(cd phase3-binary && swift test)` subshell syntax. The
r1 finding was identical; carry-forward acknowledged for future cleanup
but does not block READY-TO-MERGE.

### Open questions

None. r1 Q1 + Q2 closed (see above).

---

## Coherence sweep: did the expansion introduce contradictions?

Cross-checked the following potential drift surfaces:

1. **AC count consistency.** IMPL-NOTES lists AC-25 / AC-25a / AC-25b
   / AC-26..29 (deliverable 1), AC-30..34 (deliverable 6), AC-35..39
   (deliverable 7), AC-40..47 (deliverable 4), AC-50..55 (aggregate
   caps), AC-46 + AC-48a/b (supporting). Counted: 36 unique. Matches
   the grep output. No SPEC §-claimed AC orphaned.

2. **Smoke results consistency.** IMPL-NOTES line 231 claims "576 swift
   tests, 0 failures, 7 skipped" at commit `23266e7`; line 234 claims
   "swift test PASS" after r1 absorption. Audit prompt smoke says "577
   tests / 0 failures / 7 skipped (~37.3s)" post-absorption. The +1 in
   the audit prompt vs IMPL-NOTES is the absorption-added test (likely
   the per-code retryable lookup assertion). IMPL-NOTES under-claims by
   one test — not a contradiction, just stale. Already covered under
   m1-r2 spirit (post-absorption smoke could be re-run); not material
   to merge.

3. **Deferred-list consistency between IMPL-NOTES and deploy doc.**
   IMPL-NOTES lists six deferred items; deploy doc lists five (drops
   "AC-44 second leg" which is a buyer-side concern, not operator).
   This is a correct elision, not a drift.

4. **Header-mode value consistency.** Three values
   (`incremental` / `buffered_kill_switch` / `buffered_provider_downgrade`)
   appear identically across IMPL-NOTES line 47–49, IMPL-NOTES table
   line 113, deploy doc table line 75–77, deploy doc rollback line 172.
   No drift.

5. **Kill-switch env var spelling.** `COORDINATOR_STREAMING_FORCE_BUFFERED=1`
   spelled identically in all four narrative references (lines 49, 112
   in IMPL-NOTES; lines 41, 170 in deploy doc). No drift.

6. **Downgrade thresholds.** "3 malformed in 5 min" + "10 min recovery"
   in IMPL-NOTES lines 51–53 and deploy doc lines 111–119. Identical.
   Both attribute AC-45c. No drift.

---

## Verdict justification

**READY TO MERGE** on the narrative lane.

All three r1 MEDIUM findings (M1 AC-coverage, M2 operator surface, M3
v0.3 deferred index) have explicit closures verifiable by reading the
expanded IMPL-NOTES and deploy doc. Three of four r1 minor findings
fully closed; one (m1 verification-commands relative cd chain) carries
forward as minor-r2, non-blocking. Both r1 Q items closed via inline
content additions.

The three reader tests now all pass cold. A reviewer, a money-path
auditor, and a future v0.3 IMPL session each get a complete enough
picture from the v0.2 narrative trail without paging in this session
or the commit log.

The expansion did not introduce contradictions across the IMPL-NOTES /
deploy doc / commit message / SPEC body trio. Header values, env var
spelling, AC counts, downgrade thresholds, and deferred lists are
internally consistent.

Recommended merge action: ship as-is. The remaining minor (m1-r2) is
appropriate for a follow-up doc-polish PR or to fold into the same
batch as the Sendable strict-concurrency cleanup.

## Bar achieved

0 CRITICAL + 0 HIGH + 0 MEDIUM. Narrative lane clears the merge bar.
