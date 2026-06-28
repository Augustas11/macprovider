# SPEC-018 v0.2.4 IMPL — Narrative Blind-Spot r4 Audit

**Date:** 2026-06-28
**Reviewer:** claude narrative-blind-spot
**Commit audited:** `a27d129` on `impl/spec-018-v0-2` (r3 absorption — 1C SSE wire-shape fix)
**4-commit chain:** `23266e7` → `42476b7` → `125aacc` → `a27d129`
**Verdict:** READY TO MERGE

## Tally: C/H/M/m/Q

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- minor: 1 (single stale code-comment phrasing — non-blocking, see §minor)
- Q: 0

---

## Scope of this audit

r3 narrative lane was already **READY TO MERGE** (verified at
`specs/SPEC-018-v0_2-IMPL-narrative-r3-audit.md:7`, tally
`0/0/0/2/0`). r4 narrative is therefore a **regression check** on the
single absorption commit `a27d129`:

1. Does the r3 absorption commit introduce narrative drift that would
   confuse an IMPL reviewer reading the PR?
2. Does the 4-commit chain
   (`23266e7 → 42476b7 → 125aacc → a27d129`) tell a coherent story
   that a PR reviewer can scroll through and understand round-by-round?
3. Are commit messages clear about what each absorption round
   addressed (round number, severity tally, root cause)?

Inputs read:

- `git show a27d129 --stat` (2 src files + 8 spec/audit files;
  +19/−21 LOC on source)
- `git show a27d129` (full diff on source files)
- Subject lines + full bodies for all 4 commits in the chain
- `specs/SPEC-018-v0_2-IMPL-narrative-r3-audit.md` (r3 baseline)
- `specs/SPEC-018-agentic-tool-calling.md` lines 1–70 (§10c
  forward-compat invariant, lock-amendment narrative)
- Code sites: `HTTPServer.swift:487–498`, `:1051–1106`,
  `streaming_timing.go:24–27`, `:106–121`
- Cross-tree grep for `macprovider_tool_call_open` across `.swift`,
  `.go`, `.py`, `.ts` (no stale-fixture references)

---

## Closure verified

### r3 1C — SSE wire-shape §10c forward-compat violation

VERIFIED CLOSED at the two cited sites.

**Emit site —**
`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:491`:

```swift
writer.writeRawSSE(": macprovider_tool_call_open unix_ms=\(unixMs)\n\n")
```

Format is byte-exact `: macprovider_tool_call_open unix_ms=<N>\n\n`,
matching the SPEC §10c forward-compat invariant requirement that
"additions MUST NOT break existing parsing" (`specs/SPEC-018-agentic-tool-calling.md:67`).
Per HTML5 EventSource §9.2, a line beginning with `:` is a comment
that all conformant SSE parsers (Vercel AI SDK, openai-python,
@ai-sdk/openai-compatible) silently discard.

**Parse site —**
`phase4-coordinator/internal/buyer/streaming_timing.go:108–121`:

```go
const prefix = ": macprovider_tool_call_open unix_ms="
text := strings.TrimSpace(string(line))
if !strings.HasPrefix(text, prefix) {
    return time.Time{}, false
}
s := strings.TrimSpace(strings.TrimPrefix(text, prefix))
if v, err := strconv.ParseInt(s, 10, 64); err == nil {
    return time.UnixMilli(v).UTC(), true
}
return time.Time{}, false
```

Parser is symmetric with the emit format. Rejects malformed input
(non-numeric tail, missing prefix, leading data: line) by falling
through to the final `return time.Time{}, false`. The old
`bytes.Contains` + `data:` + `json.Unmarshal` path has been fully
removed (verified — `bytes` and `encoding/json` imports are gone,
no stale fragments).

**Cross-tree confirmation:** grep across `.swift|.go|.py|.ts` finds
exactly three references to `macprovider_tool_call_open`:
1. The Swift emit site
2. The Go parse site
3. The Go file's package doc comment

No stale test fixtures, no integration-test JSON fixtures, no
`writeSSEJSON({...macprovider_tool_call_open...})` remnant — the
mechanical change is total and self-consistent.

**InferenceRelay verification** claim in the commit body is correct:
the relay layer does not emit a parallel timing event, so the fix is
single-site on the emit path. No drift between commit narrative and
actual diff.

---

## 4-commit chain reader-coherence test

A reviewer landing on the IMPL PR reads commits top-to-bottom. The
chain has to tell a coherent story without external context.

**Subject line scan:**

```
23266e7 SPEC-018 IMPL v0.2.4 — narrow Cline drop-in (#1 multi-turn + #4 streaming + #6 tool_call_id + #7 byte cap)
42476b7 SPEC-018 IMPL v0.2.4 — r1 absorption (2C + 10H + 13M closed)
125aacc SPEC-018 IMPL v0.2.4 — r2 absorption (2C + 7H + 6M closed)
a27d129 SPEC-018 IMPL v0.2.4 — r3 absorption (1C closed: SSE wire-shape §10c fix)
```

This is **textbook narrative shape** for an audit-loop PR:
- Commit 1 names the SPEC version and the four scoped sub-features
  it implements
- Commits 2–4 are explicitly numbered `r1/r2/r3 absorption` with
  closed-severity tallies in the subject
- Severity counts **monotonically decrease** (10H+13M → 7H+6M →
  single-C-only), which is the expected shape of a convergent audit
  loop. A reviewer reading the chain sees the work narrowing toward
  zero blockers
- The r3 subject names the specific root cause ("SSE wire-shape
  §10c fix") so a reviewer skimming `git log` knows what's
  load-bearing without opening the commit body

**Body scan — `a27d129`:** the body is well-organized with five
explicit sections (`The problem (r3 finding)` / `The fix` / `Tests` /
audit trail / files-changed summary). It:

- Cites the convergent finding ("1 CRITICAL convergent across Claude
  critic + 4 codex lanes (architect/code/security/PD each
  independently raised 1 HIGH)") so the reviewer trusts the prior
  audit consensus
- Quotes the failing wire shape (`data: {"type":"..."}`) and explains
  the SDK schema mismatch (`chunkBaseSchema requires choices:` /
  `errorSchema requires error.message`)
- Names the SPEC clause violated (§10c forward-compat)
- States the fix mechanism (SSE comment line, EventSource spec
  silent-discard semantics) so a reviewer who knows SSE will nod and
  approve without re-deriving
- Provides smoke evidence (`swift test 578/0`, `go test ./internal/buyer ok`)
- Calls out money-path posture explicitly ("Money-path settlement
  protection: unchanged") which is the load-bearing reviewer concern
- Notes the AC-44 observability-tradeoff with the right framing
  (buyer-invisible by design, operator-visible via `/metrics/streaming`)
- Lists the preserved r3 audit trail (6 lane files + prompt + fix
  prompt) for the reviewer to drill into

**Audit-trail cross-reference:** the commit lists
`specs/SPEC-018-v0_2-IMPL-{architect,code,security,product-design,critic,narrative}-r3-audit.md`.
All six files exist in the tree at HEAD (verified). A reviewer who
wants to read the prior round can.

**Round-number monotonicity:** r0 (drop-in) → r1 → r2 → r3 with no
gaps. Audit-prompt files match (`AUDIT_SPEC_018_v0_2_IMPL_r{1,2,3}_PROMPT.md`
all present in tree at HEAD). r2 commit reuses the discipline; r3
commit reuses the discipline. No drift.

**Closure verification of the r2 chain:** r3 narrative already
verified the r2 chain (3 commits) reads coherently. r4 only adds
one commit on top; the r2 closures are not regressed (verified by
spot-check — `streaming_timing.go` still has the parser logic for
the timing event; `HTTPServer.swift` still has the
`toolCallOpenEmitted.setIfUnset()` guard at `:489` that r2 H-1
introduced; the only change is what gets written *after* that guard
fires).

---

## Fresh findings

### Minor — comment text drift on `streaming_timing.go:24–27` (non-blocking)

The doc comment above `streamingTimingCollector` still reads:

> Streaming timing samples are triggered by the provider's
> macprovider_tool_call_open **SSE event**, emitted when phase3
> observes the first ModelRuntime.stream .toolCallDelta.

After r3 absorption, the wire-shape is an **SSE comment line**, not
an SSE `event:`/`data:` event. The technical meaning is preserved
(an SSE comment IS an SSE line carried inside the response stream),
and the parser correctly handles the new form, but the comment
phrasing has minor drift.

**Severity:** minor. Reading-comprehension nit only — does not
mislead about behavior in a way that would cause a wrong fix. The
function name `toolCallOpenFromSSELine` is already lane-neutral and
correct. A future-touch reviewer who reads this comment will not
mis-implement based on it.

**Suggested follow-up (post-merge):** in any next-touch commit on
this file, refresh the comment to say `macprovider_tool_call_open
SSE comment line, emitted...`. Not worth a fresh r5 round.

**Why this stays minor and does not block:** the commit body is
already explicit and correct about the new wire shape ("Switch from
a JSON data: event to an SSE comment line. Per SSE/EventSource
spec, lines starting with `:` are comments..."). The commit body
beats the source comment for any reviewer who reads both. A
reviewer who reads only the source comment still gets correct
behavior; the parser is right.

---

## Regression check against r3 verdict

r3 narrative READY TO MERGE was conditioned on the 3-commit chain
(`23266e7 → 42476b7 → 125aacc`). r4 introduces exactly one new
commit (`a27d129`) carrying:

- 2 surgical source-file edits (+19 / −21 LOC)
- 8 audit-trail spec files (preserved for downstream review)

**Does r4 regress the r3 narrative verdict?** No.

- Commit message discipline preserved (subject format identical;
  body structure identical sections; audit-trail citation
  identical)
- Severity-tally monotonicity preserved (1C-only vs r2's 2C+7H+6M,
  smaller and tighter)
- SPEC-clause citation preserved (§10c forward-compat — the same
  clause family r1/r2 closures touched)
- Money-path posture explicitly restated as unchanged (the
  load-bearing IMPL-reviewer concern)
- Single-site fix means no cross-cutting drift (no scope creep,
  no opportunistic refactors)
- The r3-verdict minor (1 carry-over, 1 fresh narrative-staleness)
  is not re-triggered. The new minor here is a *different* one
  (stale code comment, post-r3-fix), and is also non-blocking

---

## Verdict justification

**READY TO MERGE** on the narrative lane.

Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM. Met: 0/0/0.

The r3 absorption commit `a27d129` is **maximally narrow** — it
fixes the one convergent r3 finding (SSE wire-shape §10c violation)
with a single conceptual mechanism (switch JSON `data:` event to
SSE comment line, parser updated symmetrically) across two files
and no peripheral changes. The commit body cites the audit
consensus, names the SPEC clause, quotes the failing wire shape,
states the EventSource-spec basis for the fix, provides smoke
evidence, and restates money-path posture.

The 4-commit chain (`23266e7 → 42476b7 → 125aacc → a27d129`) reads
as a convergent audit loop with monotonically decreasing severity
tallies and uniform commit-message discipline. A PR reviewer can
scroll the chain top-to-bottom and understand: scope of the
drop-in, three rounds of audit absorption with closed-finding
counts, and a final tight single-C fix. The narrative lane has no
fresh blocking finding.

One non-blocking minor (`streaming_timing.go:24–27` comment text
says "SSE event" where "SSE comment line" would be more precise
post-r3-fix). Documented for a future-touch refresh.

If all six r4 lane verdicts (architect / code / security /
product-design / critic / narrative) return 0C + 0H + 0M, the
absorption loop terminates and IMPL PR opens against `main` for
SPEC-018 v0.2.4.

