# IMPL audit prompt — SPEC-016 Step 1, **CODE REVIEW lane**

Lane 1 of 3 parallel codex audit lanes for SPEC-016 Step 1 IMPL
(branch `impl/spec-016`, current SPEC v0.1.21 LOCKED at `f0152c0`,
Step 1 IMPL commit `1df0235`).

**House practice:** three codex lanes fire in parallel —
`code-reviewer` / `security-reviewer` / `architect`. This is the
code-reviewer lane. Findings from all three lanes consolidate at
the end of the round into the fix-pass triage.

Fire via:

```
omc ask codex --agent-prompt code-reviewer --prompt "<this file's body>"
```

Expected wall-clock: 25–40 min (one dimension scope; the master
prompt's three-dimension scope was 40–60 min).

This is **read-only** — codex MUST NOT modify any file, commit,
push, or change git state.

---

```
=== BEGIN PROMPT ===

You are the **code-reviewer** lane (1 of 3) auditing SPEC-016 Step
1 IMPL. Two sibling lanes (security-reviewer + architect) are
firing in parallel and will produce their own findings files; you
do NOT need to consider security or architecture concerns — those
are explicitly out-of-scope for your lane so that the three lenses
stay independent and diverse.

## Shared context

Read `specs/AUDIT_SPEC_016_IMPL_STEP_1_PROMPT.md` for the FULL
shared context block (PR consolidation note, version history
v0.1.19 → v0.1.21, Step 1 IMPL ∩ v0.1.21 deltas intersection,
threat model recap, required reading in order, file/LOC catalog
of what Step 1 added, severity scale, discipline rules). Treat
that file's lines 1–247 as your full context preamble — do NOT
re-derive it from scratch.

The SPEC is LOCKED at `specs/SPEC-016-payout-pipeline.md` v0.1.21
on branch `impl/spec-016` at commit `f0152c0`. Step 1 IMPL is
commit `1df0235` on the same branch. Working tree is clean.

## Your lane scope: CODE REVIEW only

From `specs/AUDIT_SPEC_016_IMPL_STEP_1_PROMPT.md`, attend ONLY to
the **Dimension 1: CODE REVIEW** focus areas. Do NOT report
findings in security or architecture — those land in the sibling
lanes' files.

The Dimension 1 focus-area list in the master prompt covers:

1. Migration byte-identity vs SPEC (every CREATE TABLE / INDEX /
   TRIGGER in `internal/payout/migrations/0001..0008.sql` MUST
   byte-match SPEC §3.1 / §3.2 / §4.5 / §4.7 / §4.8 / §4.8a /
   §4.8b / §4.8c / §4.9 modulo whitespace + comments).
2. EIP-55 canonicalisation off-by-one + EIP-55 reference vectors.
3. EIP-712 typed-data hash string byte-match (a typo in the
   typehash string silently invalidates every signature).
4. EIP-712 wire-format conversion (r||s||v → v||r||s for decred;
   v ∈ {27,28} enforcement; v=0/1 rejection rationale).
5. EIP-712 field-by-field equality at handler boundary (verify
   inputs construction wires every body field into typed-data).
6. TOCTOU pause re-check uses BEGIN IMMEDIATE on raw `*sql.Conn`
   (modernc.org/sqlite BeginTx defaults to DEFERRED; the IMPL
   uses the auth-store pattern at `internal/auth/tokens.go:927`).
   Run `go test -race ./internal/payout/...` and report.
7. DisallowUnknownFields prohibition (§3.4 silent-ignore is
   load-bearing; confirm the decoder posture is correct).
8. Same-DB pin coverage in `AssertSameDB` table list.
9. Trigger-presence list completeness in `RequiredTriggers`.
10. Bootstrap-seed action table (four branches; sentinel
    asymmetry both directions).
11. `payout_runner_state` INSERT OR IGNORE BEFORE runner.Start
    (Step 1 has no runner yet, but the bootstrap-flip trigger
    needs the row from process start).
12. Anti-replay table lifecycle + 10-minute pruner cadence.
13. DSN durability bump (synchronous=NORMAL → FULL); quantify the
    regression risk on requestlog/billing/audit write throughput.
14. chi path-table verification (walk semantics + Step 2/3 future-
    proofing against silently-slipping route registrations).
15. Address fingerprint discipline (raw-bytes log-injection
    defense; only path that echoes submitted bytes to logs).
16. `payout.enabled=false` posture (schema applied, handlers
    idle, no partial state on flip).

Findings format (per master prompt Dimension 1 spec):

```
[code:N.M] [SEVERITY] <short title>
  File: <path>:<line>
  What: <one-paragraph description of the issue>
  Why: <impact — what breaks, when, and how bad>
  Fix: <suggested remediation; cite the binding SPEC rule if applicable>
```

Severity scale (from master prompt):

- **CRITICAL** — money loss vector, signature-verification bypass,
  silent migration corruption, or any defect that would let a
  stolen `provider_token` register a wallet the holder doesn't
  control. MUST be fixed before next step.
- **MAJOR** — real bug with confirmed reproduction, not on the
  money path. SHOULD be fixed or explicitly deferred to Appendix B.
- **MEDIUM** — defect or SPEC deviation that survives to
  production but does not obviously enable an exploit immediately.
  Fix before merge OR Appendix B.
- **LOW** — style / idiom / comment polish. MAY be deferred.

The audit-loop discipline at `specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md`
§3 requires 0 CRITICAL / 0 MAJOR / 0 MEDIUM across **all three
lanes combined** before push/PR.

## Output

Write findings to `specs/SPEC-016-IMPL-STEP_1-code-audit.md` with
this structure:

```
# SPEC-016 IMPL Step 1 — codex CODE REVIEW lane, round 1

## Verdict (code review lane only)

<one-line summary: CLEAN | FIX-THEN-PROCEED | BLOCK>

## Counts

| CRITICAL | MAJOR | MEDIUM | LOW |
|----------|-------|--------|-----|
| <N>      | <N>   | <N>    | <N> |

## Findings

[code:1.1] [SEVERITY] ...
[code:1.2] [SEVERITY] ...

## Tests run

<list of go test invocations + pass/fail summary>

## SPEC drift catalog (code-side only)

<any normative SPEC §-paragraph Step 1 code does not implement
faithfully; cite SPEC line numbers + IMPL file:line>

## What I didn't review

<files/areas you intentionally skipped, with rationale>

## Cross-cutting code observations

<patterns spanning multiple findings>

## Note on sibling lanes

You are explicitly NOT reporting security or architecture findings
here. If a code-review observation overlaps with security or
architecture concerns, note the overlap in "Cross-cutting code
observations" but defer the verdict to the sibling lane.
```

## Discipline

- Be specific. Cite `<file>:<line>` for every finding.
- Be conservative on CRITICAL. Concrete failure mode + impact
  describable in one sentence.
- Honest uncertainty: MAJOR + "needs verification" tag over
  CRITICAL when you can't confirm without runtime evidence.
- Do not invent findings to fill quota. Zero findings is a valid
  result on a Step 1 surface that got the SPEC right.
- Cite the binding SPEC rule for every violation claim.

You may run shell commands (git log, grep, find, `go vet`,
`go test -count=1 ./...`, `go test -race ./internal/payout/...`).
You MUST NOT modify any file.

You may take up to 40 minutes wall-clock. If you finish earlier
with a clean report, that's fine — do not pad.

=== END PROMPT ===
```

---

## Operator notes (out-of-band)

- This is **Lane 1 of 3** in a parallel codex audit fan-out
  pattern. Sibling lanes:
  - `AUDIT_SPEC_016_IMPL_STEP_1_SECURITY_PROMPT.md` — security-reviewer lane
  - `AUDIT_SPEC_016_IMPL_STEP_1_ARCH_PROMPT.md` — architect lane
- Findings files:
  - `specs/SPEC-016-IMPL-STEP_1-code-audit.md` (this lane)
  - `specs/SPEC-016-IMPL-STEP_1-security-audit.md`
  - `specs/SPEC-016-IMPL-STEP_1-arch-audit.md`
- Loop until **all three lanes combined** return
  0 CRITICAL / 0 MAJOR / 0 MEDIUM before push/PR per the
  audit-loop discipline at `specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md`
  §3 + [[feedback-build-audit-loop]] + [[feedback-codex-only-audits]].

🤖 Generated with [Claude Code](https://claude.com/claude-code) (Opus
4.7) for the SPEC-016 v0.1.21 IMPL Step 1.
