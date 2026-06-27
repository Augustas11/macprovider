# SPEC-018 v0.1.1 — CODE-lane round-2 audit

You are the **code** lane of a four-lane round-2 audit of `specs/SPEC-018-agentic-tool-calling.md` v0.1.1. Stay narrowly in your lane.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1.1 (commit `14d0319`)
- Round-1 code findings: `specs/SPEC-018-code-r1-audit.md`
- Round-1 absorbed: every code r1 finding (M-1, M-2, M-3, Q-1, Q-2, Q-3) was marked absorbed in the round narrative.

## Round-2 lane scope

1. **Verify r1 absorption.** For each code r1 finding, confirm the v0.1.1 body actually closes it. Specifically:
   - **M-1** family table: §3.1 now states "`arguments` preferred; `parameters` accepted as fallback" for Qwen and inverse for Llama. Open `ToolCallParser.swift:52-74` and `:473-479` and verify the §3.1 table matches the actual fallback in code.
   - **M-2** Python duplicate cite: §3.4 now cites `:96-123` + `:266-448`. Verify both ranges contain the cited behavior.
   - **M-3** InferenceRelay non-streaming cite: §8.2 now adds `:269-309`. Verify that range contains the non-streaming `data` forward.
   - **Q-1** AC-15 split: AC-15a is CI-verifiable code default + validation; AC-15b is deploy artifact. Are both mechanically verifiable in their lanes?
   - **Q-2** AC-18 parametric: AC-18 no longer names `api.streamvc.live`. Verify the parametric phrasing is mechanically verifiable.
   - **Q-3** AC-4 collision: AC-4 now says "observed unique within the test response" and "non-collision is invariant by construction." Does this remove the false-precision problem from r1?

2. **Verify all new citations in v0.1.1.** The SPEC added or moved several `Source:` lines:
   - §2.3 unchanged but verify the `:96-123` and `:169-188` citations.
   - §3.1 cites `:451-491` and `:77-123` — recheck for §3.1 row content.
   - §3.4 — recheck.
   - §3.5 — recheck.
   - §6 — recheck SPEC-001:950-979 + SPEC-002:2280-2318.
   - §7 — recheck `phase5-gateway/internal/config/config.go` ranges + `cmd/gateway/main.go:81-95`.
   - §8.4 — `phase4-coordinator/internal/buyer/server.go:1982-2195, 2320-2473, 2482-2605` + `server_internal_test.go:70-103`.
   - §10a #2 — `phase4-coordinator/internal/pool/provider.go:158-162`, `phase4-coordinator/internal/buyer/server.go:3743-3764`. Verify these contain the SPEC-008/011 model_hash infrastructure the SPEC claims they do.

3. **Verify new ACs are mechanically verifiable.**
   - AC-19 modelID-match-required: can a test write this against the current as-built? Note the SPEC says §3.2 is a SPEC-driven IMPL change — the as-built today does NOT enforce modelID-match-required (see `ToolCallParser.swift:486` which is OR-based). Is AC-19 verifiable today, or only after the IMPL prompt patches the parser? If the latter, flag explicitly so the IMPL prompt knows.
   - AC-20 buyer-side validation visibility: tests `README.md`, examples, test harnesses for the obligation string. CI-verifiable?
   - AC-21 commit-worthy validation: new normative rule in §8.4. AC-21 says "verified by a new coordinator test on the commit-signal path." Is the test specified concretely enough to write?
   - AC-22 mixed-sentinel: per §3.6 — verifiable today against the as-built parser? Check `ToolCallParser.swift` for the mixed-sentinel behavior.

4. **Find new code-lane drift.** v0.1.1's rewrite touched §3 + §5 + §6 + §7 + §8 + §9 + §10. Any new behavioral claim that disagrees with the as-built source is a finding.

## Output format

```
# SPEC-018 v0.1.1 — Code-lane round-2 audit

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## r1-absorption verification
[per r1 finding: CONFIRMED | RESIDUAL | UNCHANGED | NEW-ISSUE]

## Findings
### C-1 / H-1 / M-1 / m-1 / Q-1 — Title
- SPEC location: §N or AC-N
- Code location: file:line-range
- What the SPEC claims:
- What the code does:
- Drift summary:
- Recommended fix to SPEC body (or QUESTION):

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**. MINORs + QUESTIONS deferrable. Stay in code lane.
