# code review — OpenRouter Qwen3.6-only listing + SPEC-018 multi-turn tool gate

Repo: /Users/augstar/macprovider-or-features (branch fix/openrouter-models-features, commit 01e75985c). Review the FULL diff `git diff origin/main...HEAD` as a code reviewer. Read governing specs SPEC-006 (§5.3.2 OpenRouter ingest, R010), SPEC-018 (§3.2/§3.5/§3.8), SPEC-019 (structured outputs, LOCKED) and specs/CONFORMANCE.json mappings.

Change summary:
- Gateway /v1/openrouter/models (phase5-gateway/internal/router/openrouter_models.go) now lists only mlx-community/Qwen3.6-35B-A3B-4bit (paid, no free alias) and declares tools / tool_choice(auto) / response_format(text,json_object,json_schema) / structured_outputs descriptors only for SPEC-018 §3.8 multi-turn families.
- Coordinator (phase4-coordinator/internal/buyer/server.go, sensitive money/buyer path) adds unsupportedMultiTurnToolModel: pre-dispatch 400 unsupported_modelID_for_multi_turn for catalogued non-family models when request carries role:tool or assistant tool_calls, global/native routes only. Previously provider 400 collapsed to WS error_internal -> 502 and could degrade the provider.
- Probe script + tests, SPEC-006 v0.9.40, CONFORMANCE, runbook.

Focus for code: correctness, edge cases (tool_calls empty arrays, content parts, BYOM/pool/engine routes, nil catalog), test adequacy, regressions in existing tests/golden docs, probe validator logic.

Output: findings list with severity CRITICAL/HIGH/MEDIUM/LOW/INFO, file:line, concrete failure scenario, and fix. End with a line: VERDICT: C=<n> H=<n> M=<n> L=<n>.
