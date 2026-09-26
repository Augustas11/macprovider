Review the complete uncommitted M6 promotion-economics diff in /Users/augstar/macprovider-1646-rest against HEAD as a code-review lane.

Scope includes these untracked files:
- scripts/measure_cb_promotion_economics.py
- scripts/tests/test_measure_cb_promotion_economics.py
- docs/runbooks/continuous-batching-m6-promotion-economics-2026-09-26.md

The intended contract is a deterministic offline modeled earnings/hour proxy over the checked-in Qwen3.6 continuous-batching performance matrix and exact catalog rate-card row. The matrix records median prompt tokens per request, aggregate completion tokens, and wall time; it does not retain individual per-request token counts. SPEC-005 rounds gross/provider credits per request, so this tool must not claim exact settled credits. It instead uses exact rational arithmetic over median_prompt_tokens * rows and aggregate completion tokens, applies the published rate/multiplier/share without ledger rounding, and labels every economic output as modeled. It validates exact input hashes in tests and the rate-card projection hash, but does not verify a signature. It must not affect live configuration or services.

Find concrete correctness bugs, arithmetic mistakes, schema-validation gaps, determinism problems, misleading claims, mismatches between the generated values and evidence table, and missing tests. Pay special attention to anything that can turn a modeled proxy into an apparent exact settlement claim or produce a materially wrong promotion conclusion. Rank each finding CRITICAL/HIGH/MEDIUM/LOW/INFO with file:line evidence and an actionable fix. If there are no CRITICAL/HIGH/MEDIUM findings, say PASS and list LOW/INFO separately. Do not edit files.
