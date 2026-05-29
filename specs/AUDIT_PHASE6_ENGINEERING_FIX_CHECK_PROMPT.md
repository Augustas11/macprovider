# Audit prompt — Phase 6 engineering FIX-correctness check

Operator-paste prompt for a narrow regression-style audit on the
Phase 6 engineering FIX commit. This is NOT a full re-audit of the
whole arc; it is a focused check that:

1. Every finding from the previous engineering audit was actually
   addressed by the FIX
2. The FIX itself did not introduce new defects in the modified code
   (the bug class identified in Decision log Entry 27: "FIX cycles
   can themselves regress")

Pattern model: this prompt mirrors `AUDIT_PHASE5_GATEWAY_V2_PROMPT.md`
(the regression audit that caught the AC-37 shortcut and reaper
hardcoding after the Phase 5 FIX). The expectation is similar:
narrow scope, structured findings, classified by severity, machine-
parseable for the FIX-if-needed cycle.

Locked spec corpus this audit references (do NOT propose changes
to specs in this audit):

  SPEC-001 v1.2.4 (or v1.2.5 if 6E3 produced one — verify which
                   version is on main when audit starts)
  SPEC-002 v1.1.6 (the version landed by the FIX)
  SPEC-003 v0.7
  SPEC-006 v0.6

Output: a single deliverable file at
`specs/PHASE6_ENGINEERING_AUDIT_FIX_CHECK.md` with one finding entry
per defect (or "no findings" if green).

Run in **Claude Code** (Opus recommended — cancellation semantics
and dead-WS branching are subtle; this is exactly the surface where
Opus tracks state better than Sonnet). Expected duration: **~1-2
hours of focused review** with one summary report at the end.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are running a regression-style audit on the Phase 6 engineering
FIX commit. The BUILD pass + first audit + FIX pass have all
completed. Your job is to verify the FIX did what it claimed AND did
not introduce new defects.

You are NOT auditing the original BUILD code from scratch. You are
NOT proposing spec changes. You are NOT exploring new failure modes
that the first audit did not consider. Your scope is bounded.

## Identify the diff to audit

The operator will tell you the exact commit SHA(s) of the FIX. If
not provided, find them via:

  git log --oneline --grep="audit" --grep="fix" -i | head -10

The FIX commit's title likely contains "audit" or "fix" or
"regression". Confirm with the operator before proceeding.

Once identified, the audit scope is:

  git diff <FIX-base>..<FIX-head>

Where FIX-base is the commit BEFORE the FIX landed (the BUILD-pass
state that the first audit reviewed) and FIX-head is the FIX commit
itself.

Optionally include the uncommitted worktree if the FIX has not yet
landed in git:

  git diff HEAD

Or both, depending on operator instruction.

## Audit categories — exhaustive list

Run each category below in order. Produce one finding per defect;
classify each as CRITICAL / MAJOR / MINOR / OK-with-note. Skip a
category only if it does not apply (and say so explicitly in the
report).

### Category α — FIX completeness

For each finding from the previous engineering audit (operator will
provide or point you at `specs/PHASE6_ENGINEERING_AUDIT.md` or
similar), verify:

- Was the specific code change called for actually applied?
- Does the applied change match the recommendation in spirit AND in
  letter? (A FIX that addresses "lower the heartbeat threshold" by
  adding a comment but not changing the value is INCOMPLETE)
- Did the FIX cover ALL the places the bug manifested, not just one?

Output per finding: PASS / PARTIAL / REGRESS / SKIPPED, with a
one-line justification and a pointer to the lines in the FIX diff.

### Category β — FIX-introduced defects

For each file the FIX modified, read the NEW code (not the diff —
the resulting file) and look for:

- Off-by-one errors in new loop / counter logic
- Resource leaks (goroutines, file handles, db connections,
  contexts not cancelled in some path)
- Race conditions in new concurrent code
- Panics on nil dereference in new error paths
- Logging that emits secrets / tokens / URL credentials
- Tests that pass via implementation copy rather than spec assertion

This is the "did the FIX introduce new bugs" pass. The reference
case from Entry 27 is: the Phase 5 FIX itself added an invented
/cancel endpoint that the V2 audit caught. Look for the analog
pattern here: did this FIX add something that shouldn't exist?

### Category γ — Cancellation semantics deep dive

This is the SPECIFIC bug surface for the gateway change. The FIX
moved upstream context to `context.WithTimeout(r.Context(), ...)`.
Verify:

- If the buyer hangs up, does the upstream goroutine receive the
  cancellation? Trace the path manually.
- If the timeout fires while the upstream is mid-call, is the
  Response.Body closed before the buyer goroutine returns?
- If failover triggers, does the SECOND upstream call also derive
  its context from `r.Context()`? Or does it lose the buyer
  cancellation chain?
- Are there any `context.Background()` calls in the modified files
  that should be `r.Context()` instead?
- Does `defer cancelUpstream()` actually run in every code path,
  including panic recovery?

Output per finding: PASS / DEFECT (with severity), with the trace
that produced the finding.

### Category δ — Failover correctness deep dive

This is the SPECIFIC bug surface for the coordinator change. Verify
the at-most-once failover invariant rigorously:

- Can the failover retry trigger another failover? (must be no)
- Is "pinned provider" determined consistently across all the
  decision points? A request that is pinned via header vs pinned
  via session vs pinned via SPEC-002 normative tier1 routing — all
  three MUST be classified consistently and MUST suppress failover
- Does the failover candidate set exclude the failed provider? An
  off-by-one in the exclusion logic could re-route to the dead
  provider
- If only ONE provider runs a given model AND it dies mid-inference,
  does the code correctly return 502 instead of trying to failover
  to an empty candidate set?
- Are the request_id values (original / current / external) propagated
  consistently? In particular, is the EXTERNAL request_id (the one
  the buyer sees) stable across the failover boundary?

### Category ε — Streaming dead-WS post-first-byte SSE

This is the SPECIFIC bug surface added by the streaming pre/post-
first-byte split. Once the response status code is sent to the
buyer, the status code CANNOT change. The FIX handles this by
emitting a terminal SSE event. Verify:

- The terminal SSE event respects the OpenAI envelope shape for SSE
  errors (`data: {"error":{...}}\n\n` then `data: [DONE]\n\n` per
  OpenAI's SSE convention, or whatever convention SPEC-006 v0.6
  defines)
- The terminal SSE event is followed by `\n\n` to flush the event
  boundary properly
- The terminal SSE event is NOT JSON-corrupt (no half-written
  envelope from the original provider mixed in)
- The buyer's parser can distinguish "provider died" from "provider
  finished normally" (different `finish_reason` or error code)
- If the buyer has already received `[DONE]` from the original
  provider before the WS died, the FIX does NOT emit a redundant
  error event (would confuse the buyer's parser)
- If the FIX uses the http.Flusher interface, verify it actually
  flushes after the terminal event (otherwise the buyer sits on a
  half-buffered chunk waiting for connection close)

### Category ζ — Test rig isolation

The fault-injection rig in `phase4-coordinator/internal/testfaults/`
must NOT compile into production binaries. Verify:

- The build tag at the top of every file in `internal/testfaults/`
  is consistent (e.g. all `//go:build testfaults` not mixed with
  `//go:build !production`)
- The empty marker package mentioned in the operator's report
  actually exists for the non-tagged build — `go build ./...`
  without the tag should produce a binary that has zero symbols
  from `testfaults`. Verify with `go tool nm` or equivalent.
- No production code path can reach a testfaults function via
  interface-type erasure (e.g. a function registered in an init()
  that also runs in production). Grep for `init()` in testfaults
  files; should be zero.
- The fault-injection panic endpoint from sub-phase 6E4 is gated
  with the testfaults build tag, not just by an admin-token check
  (admin tokens are operator-only but mistakes happen; defense in
  depth)
- Test helpers do not bypass auth or quota in ways that could leak
  out if the build tag flips

### Category η — Spec-text drift

For SPEC-002 v1.1.5 → v1.1.6 specifically, verify:

- The new normative finding (F-{N} fast-fail on dead WS) has a
  unique number consistent with the existing F-1, F-2 numbering
- The text references the new failover_timeout_s and
  failover_enabled config keys exactly as they are spelled in
  coordinator.yaml.example
- The example values in the spec match the defaults in code
- The changelog at the top of SPEC-002.md was updated v1.1.5 →
  v1.1.6 with a one-line summary
- No other normative text changed (only the addition; existing
  F-1, F-2 etc. remain byte-identical)

Compare with `git diff <FIX-base>..<FIX-head> -- specs/SPEC-002-coordinator.md`.

### Category θ — Keepalive URL redaction

The FIX added redaction for coordinator URL userinfo, query, and
fragment in verbose keepalive logs. Verify:

- The redaction matches a robust regex that catches all three URL
  components, not just userinfo (which is the common one to
  remember)
- The redaction is applied at the LOG-EMIT layer, not at the
  CONFIG-LOAD layer (config-load redaction means the URL is
  redacted in OTHER logs too where it should be visible)
- The verbose tarball at the new SHA256 was rebuilt FROM the
  redacted code; verify by extracting the tarball and grepping for
  unredacted URLs

## Severity classification

- **CRITICAL** — defect that would manifest as customer-visible
  failure under normal usage (e.g. failover that double-charges
  quota; cancellation that hangs forever; testfaults endpoint
  reachable in production)
- **MAJOR** — defect that would manifest under specific but
  plausible conditions (e.g. failover that picks the failed
  provider when N=2; SSE chunk that confuses some buyer SDKs but
  not OpenAI's)
- **MINOR** — defect that is real but unlikely to manifest, or
  that does manifest but with bounded impact (e.g. log line emits
  trailing space; comment refers to old config key)
- **OK-with-note** — code is correct but the implementation choice
  warrants future revisit (file as Phase 7 backlog candidate)

## Deliverable

A single file at `specs/PHASE6_ENGINEERING_AUDIT_FIX_CHECK.md` with:

1. **Summary table** — one row per category α-θ, showing
   PASS / PARTIAL / DEFECT (with count) / SKIPPED
2. **Findings list** — one entry per finding, with:
   - ID (`α-1`, `β-3`, etc. — category prefix + sequential)
   - Severity
   - File + line range
   - One-paragraph explanation
   - Recommended fix (concrete code suggestion, not "improve this")
3. **Reverse verification** — for each finding from the previous
   engineering audit, confirm whether the FIX addressed it (this
   becomes the regression baseline for ANY future FIX cycle)
4. **No-finding categories** — explicitly list categories where the
   audit found nothing, so the operator can see that those areas
   were reviewed (not skipped)

If the audit finds ZERO defects (best outcome), the file is still
produced as proof-of-work, with all categories marked PASS and an
explicit "no findings" statement at the end. Operator commits the
audit report alongside the FIX commit.

## What NOT to do

- Do NOT propose spec changes. SPEC-001 v1.2.4 (or v1.2.5), SPEC-002
  v1.1.6, SPEC-003 v0.7, SPEC-006 v0.6 are locked for this audit
  pass. If a spec defect IS found, file as candidate for a separate
  spec session.
- Do NOT re-audit the original BUILD code. Your scope is the FIX
  diff only.
- Do NOT propose architectural alternatives. Categories α-θ are the
  audit surface. Things outside this surface are out of scope.
- Do NOT decide unilaterally on findings classified as MINOR or
  OK-with-note. Surface them to the operator for triage.
- Do NOT modify code in this session. You are read-only. The FIX
  cycle (if needed) is a separate session with a separate prompt.

## Sequence the audit categories

Suggested order (least to most expensive in time):

1. **η** (spec-text drift — fastest; pure diff inspection)
2. **ζ** (test rig isolation — easy to verify mechanically)
3. **θ** (keepalive URL redaction — small surface)
4. **α** (FIX completeness — depends on prior audit being available
   as input; if not, defer)
5. **β** (FIX-introduced defects — read the new files end-to-end)
6. **γ** (cancellation semantics — manual trace)
7. **δ** (failover correctness — manual trace)
8. **ε** (streaming dead-WS post-first-byte — manual trace +
   knowledge of SSE conventions)

Categories γ, δ, ε are the highest-leverage ones — they target the
exact code that the FIX changed, on the exact behavioral surfaces
where the FIX is most likely to be subtly wrong.

## Reporting back to the operator

When done, report:

1. The deliverable file path
2. Summary table (8 categories, color-coded if your output supports
   it)
3. Top 3 findings by severity (with one-line summaries)
4. A single recommendation: PROCEED-TO-DEPLOY, SECOND-FIX-CYCLE,
   ESCALATE-TO-FULL-RE-AUDIT (rare; only if categories β/γ/δ/ε
   produced multiple CRITICALs)
5. Estimated time spent in the audit (for calibration of future
   audit prompts)

Then STOP. The operator decides next steps based on your report.

=== END PROMPT ===
```

---

## Operator notes (not part of pasted prompt)

**When to run this:** After the Phase 6 engineering BUILD + first
audit + FIX pass has landed in repo (or in the worktree the operator
intends to commit). Run BEFORE Pearl deploy.

**Inputs the operator should have ready before paste:**

- The FIX commit SHA(s) — should match `a5786b8` or whatever the FIX
  pass produced
- The previous engineering audit report (the input to category α) —
  if it lives at `specs/PHASE6_ENGINEERING_AUDIT.md` or similar, no
  prep needed; if it lives only in another session's transcript,
  copy-paste the findings list into the operator's local notes for
  category α reference

**Expected outcomes:**

- **Best case (most likely):** ZERO defects. Audit produces a
  proof-of-work file confirming the FIX was correct. Operator
  commits the audit report and proceeds to Pearl deploy.
- **Common case:** 1-3 MINOR or OK-with-note findings. Operator
  triages: small enough to FIX in-place inline, or defer to Phase 7
  backlog.
- **Concerning case:** 1+ MAJOR or CRITICAL finding. Operator opens
  a second FIX cycle in a separate session with a narrow scope
  matching the finding.
- **Worst case (very unlikely):** Multiple CRITICALs across
  categories β/γ/δ/ε. Escalate to a full re-audit of the engineering
  arc. Pearl deploy delayed.

**Calendar time:** ~1-2 focused hours of audit + however long any
FIX-of-FIX cycle takes (usually small if scoped right).

**Follow-on artifacts the audit produces (in repo):**

- `specs/PHASE6_ENGINEERING_AUDIT_FIX_CHECK.md` — the audit report
  (always produced, even if empty)
- If findings: `specs/FIX_PHASE6_ENGINEERING_V2_PROMPT.md` — the
  follow-on FIX prompt (only if needed)

---

## Filing this audit

1. Read the audit prompt top-to-bottom
2. Confirm the FIX commit SHA you want audited (likely `a5786b8` or
   the latest commit on main)
3. Paste the `=== BEGIN PROMPT === ... === END PROMPT ===` block
   into a fresh Claude Code session rooted at the repo
4. Read the deliverable report
5. Decide: proceed to deploy, run a second FIX cycle, or escalate
6. Commit the audit report regardless

After this audit passes (zero or only-MINOR findings), Pearl deploy
of coord + gateway is the next operator action. The pattern from
Entry 27 (cross-compile + SCP + restart + smoke + watch journal 1h)
applies directly.

After Pearl deploy + air5 24h observation + G1/G2 timeout relaxation,
Decision log Entry 29 captures the full engineering arc closure.
