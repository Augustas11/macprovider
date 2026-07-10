# Network harness v0.6 baseline - issue #303 settlement regressions

Internal. Created 2026-07-06 for issue #303. This baseline adds
network-harness coverage for the three streaming settlement paths that
PR #288 already closed in production.

## Scope

The v0.6 scenario set adds:

| Scenario | Path | Required live model rows | Expected closed signal |
|---|---|---|---|
| `12_moe_mid_stream_projection.yaml` | A - MoE mid-stream byte projection | `mlx-community/gpt-oss-20b-MXFP4-Q8`, `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | I1 requires `gateway_outcome=ok` and `gateway_token_source=provider_reported` on matched successes |
| `13_dense_token_count_regression.yaml` | B - dense content downclamp | `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit` | buyer and gateway completion-token counts agree within 2 tokens; gateway and coordinator still agree exactly |
| `14_sparse_provider_reported_tokens.yaml` | C - sparse English byte-estimate override | `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` or issue-approved English-heavy Llama fallback | I1 requires `gateway_token_source=provider_reported`; `gateway_estimated` is a regression signal |

Scenario number 11 is already committed as
`11_sku_earn_viability.yaml`, so the issue #303 scenarios start at 12
per the issue's "or per convention" acceptance clause.

## Local validation baseline

As of this baseline note, the scenarios have been validated for harness
shape and schema compatibility, but not yet run as a live Pearl
acceptance baseline.

| Check | Result |
|---|---|
| `go test ./... -count=1` from `test/network-harness` | PASS |
| dry-run `12_moe_mid_stream_projection.yaml` | PASS - scenario valid |
| dry-run `13_dense_token_count_regression.yaml` | PASS - scenario valid |
| dry-run `14_sparse_provider_reported_tokens.yaml` | PASS - scenario valid |

## Live v0.6 baseline status

Live v0.6 execution is pending fleet availability. Issue #303 requires
the MoE, Qwen2.5-Coder-32B, and Llama sparse-English model classes to be
actively serving on Pearl before the acceptance run is meaningful.

When those model rows are available, run scenarios 12-14 against Pearl
and record:

| Scenario | I1 | I2 | I3 | I4 | Path closure evidence |
|---|---|---|---|---|---|
| 12 | PENDING | PENDING | PENDING | PENDING | record `gateway_outcome` and `gateway_token_source` from `ledger_reconcile.json` |
| 13 | PENDING | PENDING | PENDING | PENDING | record max buyer/gateway/coordinator completion-token delta |
| 14 | PENDING | PENDING | PENDING | PENDING | record `gateway_token_source` from `ledger_reconcile.json` |

## Comparison against v0.5

The repository has v0.1 and v0.2 benchmark baseline documents, but no
committed v0.5 network-harness baseline file at the time this note was
created. The v0.6 comparison therefore cannot quantify live deltas yet.

Expected comparison once v0.5/v0.6 live artifacts are available:

- Path A remains closed when no successful buyer stream maps to
  `gateway_outcome=stream_output_exceeded`.
- Path B remains closed when the largest successful buyer/gateway
  completion-token delta is <= 2 tokens and gateway/coordinator settlement
  still agrees exactly.
- Path C remains closed when every successful matched pair reports
  `gateway_token_source=provider_reported`.

This document is intentionally not a substitute for the live acceptance
run. It records the committed coverage surface and the evidence still
needed to lock the live v0.6 baseline.
