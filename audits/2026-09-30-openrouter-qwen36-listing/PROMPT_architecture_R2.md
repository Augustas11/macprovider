# architecture review — OpenRouter Qwen3.6-only listing + SPEC-018 multi-turn tool gate

Repo: /Users/augstar/macprovider-or-features (branch fix/openrouter-models-features, commits 01e75985c + 868248c8b). Review the FULL diff `git diff origin/main...HEAD` as a architecture reviewer. Read governing specs SPEC-006 (§5.3.2 OpenRouter ingest, R010), SPEC-018 (§3.2/§3.5/§3.8), SPEC-019 (structured outputs, LOCKED) and specs/CONFORMANCE.json mappings.

Change summary:
- Gateway /v1/openrouter/models (phase5-gateway/internal/router/openrouter_models.go) now lists only mlx-community/Qwen3.6-35B-A3B-4bit (paid, no free alias) and declares tools / tool_choice(auto) / response_format(text,json_object,json_schema) / structured_outputs descriptors only for SPEC-018 §3.8 multi-turn families.
- Coordinator (phase4-coordinator/internal/buyer/server.go, sensitive money/buyer path) adds unsupportedMultiTurnToolModel: pre-dispatch 400 unsupported_modelID_for_multi_turn for catalogued non-family models when request carries role:tool or assistant tool_calls, global/native routes only. Previously provider 400 collapsed to WS error_internal -> 502 and could degrade the provider.
- Probe script + tests, SPEC-006 v0.9.40, CONFORMANCE, runbook.

Focus for architecture: spec consistency (SPEC-006 vs SPEC-018 vs SPEC-019 wording and every restatement), CONFORMANCE mapping accuracy, source-of-truth duplication (family predicate in gateway vs coordinator vs provider Swift), deploy ordering gateway vs coordinator, OpenRouter provider schema v2.4 conformance of the new descriptors.

Output: findings list with severity CRITICAL/HIGH/MEDIUM/LOW/INFO, file:line, concrete failure scenario, and fix. End with a line: VERDICT: C=<n> H=<n> M=<n> L=<n>.


ROUND 2: round-1 findings are in audits/2026-09-30-openrouter-qwen36-listing/RESULT_{code,security,architecture}_R1.md; the fixes are commit 868248c8b. Verify each R1 finding is actually fixed, then review the FULL combined diff fresh for new issues. Carried LOW accepted: family predicate duplication across gateway/coordinator/probe/Swift.
