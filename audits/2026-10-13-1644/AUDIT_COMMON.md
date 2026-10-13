# Audit brief: cross-provider compute-integrity scoring (#1644), round R3 (final)

Method constraint: this is a first-party software-correctness and design review.
Do NOT author or construct malformed payloads or exploit code. Evaluate by
reading source and running EXISTING tests only. Describe gaps abstractly
(component, field, condition) in prose.

Repository: the current working directory. Review the complete diff as it will
land: `git diff origin/main...HEAD` (commits on branch feat/1644-compute-integrity).
Read the governing text first:
- specs/SPEC-036-compute-integrity-receipt.md, section 5A (FR-19..FR-25) and 7A
- specs/SPEC-022-verified-model-settlement.md, R-16 (SPEC-022-R016)

What landed:
- Provider (Swift, phase3-binary): compute_score_request_v1 / compute_score_result_v1
  scoring job (MacProviderCore/ComputeScoreProtocol.swift,
  macprovider-cli/ComputeScoreRuntime.swift, CoordinatorClient.swift handler,
  tier2_capabilities.compute_score_v1).
- Coordinator (Go, phase4-coordinator):
  internal/computeintegrity/scoring*.go (metrics, tolerance band, state machine,
  scorer selection/integrity, corpus, store), internal/ws/compute_scoring*.go
  (engine, wire parsing, admin/status), internal/buyer/compute_integrity_probe.go
  (in-process dispatch through /v1/chat/completions), internal/pool suspension,
  internal/billing/compute_integrity_holds.go + payable view, weekly settlement
  predicate and earnings-rollup triggers, internal/stats/metrics, config, main wiring.
- test/integration end-to-end test.

Severity rubric:
- CRITICAL: money loss/creation, auth bypass, data corruption, or a defect that
  fails honest providers network-wide.
- HIGH: a realistic path that breaks a SPEC-036 §5A / SPEC-022 R-16 MUST, leaks
  prompts/outputs, or lets a substituting provider evade detection by a cheap,
  generic trick the design claims to stop.
- MEDIUM: a contract or robustness defect with bounded impact that should be
  fixed before merge.
- LOW / INFO: everything else.
Pre-existing issues untouched by this diff are out of scope; if you mention one,
label it PRE-EXISTING and give it no severity.

Output format: a numbered list of findings, each with severity, file:line,
the problem, and the concrete fix. End with exactly one line:
VERDICT: CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n>

Round 3 (anchored, final): audits/2026-10-13-1644/R1_DISPOSITION.md and
R2_DISPOSITION.md list every earlier finding and how it was fixed or why it is
carried. Verify each fix in the code, then review the full diff again. Report an
earlier finding again only if its fix is incomplete or wrong, or if a carried
item is actually a CRITICAL/HIGH/MEDIUM defect.
