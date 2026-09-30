# security review — OpenRouter Qwen3.6-only listing + SPEC-018 multi-turn tool gate

Repo: /Users/augstar/macprovider-or-features (branch fix/openrouter-models-features, commits 01e75985c + 868248c8b + 03be06efe). Review the FULL diff `git diff origin/main...HEAD` as a security reviewer. Read governing specs SPEC-006 (§5.3.2 OpenRouter ingest, R010), SPEC-018 (§3.2/§3.5/§3.8), SPEC-019 (structured outputs, LOCKED) and specs/CONFORMANCE.json mappings.

Change summary:
- Gateway /v1/openrouter/models (phase5-gateway/internal/router/openrouter_models.go) now lists only mlx-community/Qwen3.6-35B-A3B-4bit (paid, no free alias) and declares tools / tool_choice(auto) / response_format(text,json_object,json_schema) / structured_outputs descriptors only for SPEC-018 §3.8 multi-turn families.
- Coordinator (phase4-coordinator/internal/buyer/server.go, sensitive money/buyer path) adds unsupportedMultiTurnToolModel: pre-dispatch 400 unsupported_modelID_for_multi_turn for catalogued non-family models when request carries role:tool or assistant tool_calls, global/native routes only. Previously provider 400 collapsed to WS error_internal -> 502 and could degrade the provider.
- Probe script + tests, SPEC-006 v0.9.40, CONFORMANCE, runbook.

Focus for security: can buyers bypass or abuse the new gate, can it cause provider degradation/DoS, accidental exposure in the public /v1/openrouter/models doc, money-path/settlement side effects of the pre-dispatch 400 (billing, request_log, receipts), honesty of advertised capabilities (declaring features the fleet cannot serve damages OpenRouter uptime).

Output: findings list with severity CRITICAL/HIGH/MEDIUM/LOW/INFO, file:line, concrete failure scenario, and fix. End with a line: VERDICT: C=<n> H=<n> M=<n> L=<n>.


ROUND 3: prior findings in audits/2026-09-30-openrouter-qwen36-listing/RESULT_security_R1.md and RESULT_security_R2.md. R2 HIGH (model-class alias bypass) is addressed in 03be06efe via SPEC-004 FR-SR-7 class-member filtering for tool-history requests (400 only when no profiled member). Verify the fix, then review the FULL combined diff fresh. Carried LOW accepted: family predicate duplication.
