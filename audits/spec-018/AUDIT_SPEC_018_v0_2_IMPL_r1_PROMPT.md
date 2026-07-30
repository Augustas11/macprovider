# AUDIT_SPEC_018_v0_2_IMPL_r1 (codex 4-lane + Claude blind-spot, shared brief)

## Task

Audit the SPEC-018 v0.2.4 IMPL diff committed as `23266e7` on `impl/spec-018-v0-2` branch.

This is the IMPL companion to SPEC-018 v0.2.4 LOCKED (PR #202, commit `7e508324`). The SPEC PR went through 4 codex rounds + 2 Claude blind-spot rounds before lock. The IMPL diff implements 4 deliverables + 5 supporting work items.

## Authoritative inputs

1. **The IMPL diff**: `git show 23266e7 --stat` lists 46 files; `git diff 7e50832..HEAD -- phase3-binary phase4-coordinator test docs tools` shows the full change.
2. `specs/SPEC-018-agentic-tool-calling.md` v0.2.4 LOCKED — the SPEC the IMPL implements.
3. `specs/SPEC-018-v0_2-IMPL-NOTES.md` — codex's IMPL absorption notes covering per-deliverable AC mapping, fixture locations, money-path trace, normative interpretation calls.
4. `specs/BUILD_SPEC_018_v0_2_IMPL_PROMPT.md` + `specs/BUILD_SPEC_018_v0_2_IMPL_CONTINUATION_PROMPT.md` — the BUILD prompts codex executed.

## Smoke evidence

- `cd phase3-binary && swift test` — 576 tests / 0 failures / 7 skipped (~37.5s)
- `cd phase4-coordinator && go vet ./... && go test -count=1 ./internal/buyer` — ok internal/buyer ~2.7s

Tests pass. Audit is about correctness depth, not whether it compiles.

## Per-lane lens

**Architect lane** — structural integrity, code organization, dependency-chain, separation between SPEC #1/#4/#6/#7 deliverables, modular boundary between `ToolPromptRenderer.swift` + `OutputCanonicalizer.swift` + `HTTPServer.swift`, coordinator §8.4 split clarity, AC-25a harness skeleton-vs-full design choice coherence.

**Code lane** — mechanical implementation accuracy, citation correctness against live repo, regex implementation (provider-emitted `^call_[a-f0-9]{32}$` + request-accepted `^call_[A-Za-z0-9]{16,64}$`), byte-cap arithmetic (1 MiB / 2 MiB UTF-8 unescaped), aggregate caps O(N) validation runtime, streaming `incremental-open` + `final-close` validator split mechanics, error envelope thicker fields consistency, NTP-anchored AC-44 timing instrumentation in `streaming_timing.go`.

**Security lane** — money-path settlement protection END-TO-END (each new failure path → `FaultBreakerQualifying` → zero credits), `FaultBreakerQualifying` flag set on EVERY incomplete-stream failure mode (server.go:2254/2266/2287/2301/2324/2474/2528/2551/2572 per IMPL-NOTES), `OutputCanonicalizer.macprovider_model_hash_observed` exclusion from canonical scope (per §10d.0.1 normative requirement; codex updated JCS fixtures), per-(buyer, provider) downgrade attribution rigor (AC-45c adversarial test actually verifies competitor-buyer DoS isolation), Cline workspace SPEC-018.md `read_file` case (§3.9 deletion didn't reintroduce self-DoS).

**Product-design lane** — Cline integration usability (AC-25a harness contract matches what Cline runtime expects), error envelope actionability for Cline (the thicker fields actually help Cline decide retry vs abandon), streaming-mode header observability, `model_hash_observed` UX (buyers correctly know they MUST NOT branch on this in v0.2), AC-25b manual smoke vs AC-25a CI fixture role clarity, deploy doc (`docs/operations/spec-018-v0.2-deploy.md`) operator-friendly.

**Claude critic blind-spot** — what codex 4 lanes will miss. Specifically check:
- Did codex actually verify `OutputCanonicalizer.canonicalOutputObject` excludes `model_hash_observed`? Or did they only update the test fixtures + assume the code path is right?
- Does the `@ai-sdk/openai-compatible@2.0.38` pin match what Cline `main@92806c60` actually uses? Verify.
- AC-25a harness skeleton vs full VS Code automation choice — does the IMPL deliver enough that an AC-25a release-gate run could be done by hand if needed?
- Is `unsupported_modelID_for_multi_turn` error code emitted by `ToolPromptRenderer` actually thrown when modelID doesn't match Qwen/Llama family? Or is it a stub that never fires?
- Does the per-(buyer, provider) downgrade state actually survive across HTTP requests (process-restart, distributed coordinator)?

**Claude narrative blind-spot** — does the IMPL-NOTES read coherently? Does an IMPL reviewer learn what they need from the notes alone? Does the BUILD prompt + continuation prompt + IMPL-NOTES form a complete audit trail?

## Output format

Write findings to `specs/SPEC-018-v0_2-IMPL-{lane}-r1-audit.md` (lane ∈ {architect, code, security, product-design, critic, narrative}) with standard structure:

```markdown
# SPEC-018 v0.2.4 IMPL — {Lane} r1 Audit

**Date:** 2026-06-28
**Reviewer:** {codex|claude} {lane}
**Verdict:** {READY TO MERGE | FIX REQUIRED}

## Tally: C/H/M/m/Q

## Findings

### CRITICAL findings
### HIGH findings
### MEDIUM findings
### Minor findings
### Open questions

## Verdict justification
```

## Severity bar

- **CRITICAL** — IMPL breaks money-path settlement, ships a SPEC violation (e.g., `model_hash_observed` in canonical scope), or test claim is wrong (test claims to verify X but doesn't).
- **HIGH** — IMPL has a real bug that would cause Cline session failures, or AC-25a/AC-48 harness is structurally unsound, or a normative interpretation call diverges from SPEC intent.
- **MEDIUM** — code-citation drift, AC test fixture under-specified, edge case unhandled.
- **minor** — polish (e.g., Package.swift unhandled-resources warning).
- **Q** — design clarification needed.

Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM = READY TO MERGE from your lane.

Goal: find AT LEAST one HIGH/MEDIUM if anything is wrong. v0.2 IMPL is the first to actually exercise the Path B amendments + Cline anchor; do not just rubber-stamp.
