# Root cause: prompt-token reconciliation freeze

Date: 2026-08-05

## Summary

The prompt-token drift is real but was not the direct zero-tolerance mismatch
that froze the anchor provider's enforce-mode rows.

Provider Macs report prompt tokens from the MLX prepared prompt. The coordinator
caps the ledger charge with its independent `len(raw_body)/4` byte heuristic and
preserves the provider value in `provider_reported_prompt_tokens`. Production
rows show that split exactly: sampled frozen anchor rows have
`request_log.prompt_tokens = ledger_request_credits.prompt_tokens =
charged_prompt_tokens` at 38 or 40, while `provider_reported_prompt_tokens` is
44 or 45.

The freeze rule is recovery's zero-tolerance comparison between already-
persisted ledger rows and a freshly reconstructed `HotPathInput`. The sampled
frozen rows are internally consistent: request-log prompt tokens already match
charged ledger prompt tokens, provider plus operator credits sum to gross, and
the stored rates/multiplier/share reproduce the stored gross/provider credits.
The risk is that recovery can reinterpret historical rows through current
rate-card/model-resolution behavior instead of accepting the row's bounded,
persisted rate contract where that contract is still tied to the historical
snapshot. When that reinterpretation changes the recomputed gross/provider
amount, recovery sets `quarantine_reason='reconciliation_mismatch'` and the
SPEC-022 payable view excludes the row.

## Code Findings

Provider-reported prompt origin:

- Non-streaming Swift prepares the chat input with MLX and counts
  `lmInput.text.tokens` before constructing `CompletionResult.promptTokens`
  ([ModelRuntime.swift](../../phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1938),
  [ModelRuntime.swift](../../phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2087)).
- Streaming does the same prepared-token count
  ([ModelRuntime.swift](../../phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2389),
  [ModelRuntime.swift](../../phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2485)).

Charged prompt origin:

- The coordinator snapshots a prompt upper bound from `estimateTokens(req.raw)`
  before routing ([server.go](../../phase4-coordinator/internal/buyer/server.go:1979)).
  `estimateTokens` is `len(raw)/4`, minimum 1
  ([server.go](../../phase4-coordinator/internal/buyer/server.go:7492)).
- `WriteHotPath` preserves the provider's value in
  `ProviderReportedPromptTokens`, then caps `PromptTokens` to the coordinator
  bound before computing/storing credits
  ([hotpath.go](../../phase4-coordinator/internal/billing/hotpath.go:237)).
- Settlement evidence intentionally keeps the provider-observed input count for
  receipt verification and documents that the byte heuristic cannot be
  reproduced by the provider
  ([billing_recorder.go](../../phase4-coordinator/internal/buyer/billing_recorder.go:521)).

Why the counts differ:

- The provider counts the rendered MLX chat-template/BOS/special-token prompt.
- The coordinator charge cap is an approximate byte heuristic over the raw JSON
  request body. For short Llama prompts, MLX prepared input exceeds the
  heuristic by roughly 4 to 7 tokens.
- This is expected under the existing contract: `provider_reported_prompt_tokens`
  is diagnostic, while `prompt_tokens`/`charged_prompt_tokens` is the bounded
  charged amount.

Freeze rule:

- Recovery loads request-log rows, reconstructs a `HotPathInput`, and calls
  `reconcileExistingCreditTx` for existing ledger rows
  ([recovery.go](../../phase4-coordinator/internal/billing/recovery.go:276)).
- The mismatch predicate is zero tolerance over recomputed gross/provider
  credits, fault/usage source, cache shape, operator row count, and split sum
  ([recovery.go](../../phase4-coordinator/internal/billing/recovery.go:522)).
- Before this fix, `reconcileExistingCreditTx` recomputed existing rows from
  `input.RateEntry`, which was derived by applying the active `RateFor`
  resolver to the historical model string. This makes recovery sensitive to
  model alias/rate-card resolver changes even when the existing row carries a
  coherent persisted prompt/completion rate contract
  ([formula.go](../../phase4-coordinator/internal/billing/formula.go:65)).
- Enforce rows are the visible blast radius because enforce-mode payout
  eligibility flows through `spec022_payable_request_credits`, which excludes
  quarantined rows unless a matured `force_credit` resolution exists.
  Observe/legacy rows with the same prompt drift can remain payable because they
  are not receipt-gated in the same way.

## Read-only Pearl Evidence

Snapshot: 2026-08-05.

- Anchor provider:
  `mp-bcacdf97b91c1505709204bf76ae59d0`.
- Sample frozen rows:
  `lrc_prompt=40`, `charged=40`, `reported=44`, `rl_prompt=40`,
  `lrc_comp=34`, `rl_comp=34`, `gross_credits=54`,
  `provider_credits=49`, `quarantine_reason='reconciliation_mismatch'`.
- Same rows:
  stored rate contract `prompt_rate_per_mtok=500000`,
  `completion_rate_per_mtok=1000000`, `global_multiplier_ppm=1000000`,
  `provider_share_bps=9000`, one operator row, and provider plus operator
  credits sum to gross.
- Snapshot 195 contains both `default` at `500000/1000000` and
  `meta-llama/llama-3.2-3b-instruct` at `13500/27000`. The sampled anchor rows
  were inserted with the `default` entry and remain arithmetically coherent at
  that persisted rate. Current `origin/main` falls back to `default` for this
  exact served Llama alias; the compatibility fix is deliberately bounded so a
  future or deployed alias resolver change cannot re-freeze those historical
  rows while also preventing post-cutoff default-rate inflation.

Fleet-wide rows with this quarantine reason include:

| model | stored prompt/completion rate | rows |
| --- | --- | ---: |
| `mlx-community/Llama-3.2-3B-Instruct-4bit` | `500000/1000000` | 745 |
| `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | `117500/235000` | 25 |
| `mlx-community/Qwen3-8B-4bit` | `13500/27000` | 23 |
| `qwen3-coder-30b-a3b-instruct` | `117500/235000` | 19 |
| `mlx-community/gpt-oss-20b-MXFP4-Q8` | `50000/100000` | 2 |

## Fix

Recovery now reconciles existing non-cache ledger rows with the row's persisted
prompt/completion rates only when those rates either match the reconstructed
snapshot rate or match the bounded pre-cutoff served-alias default fallback for
the historical Llama rows. The fallback is rejected if the snapshot already has
an exact, lowercased, or `NormalizeModelKey` rate for the served model.
Multiplier and provider share remain bound to the historical config snapshot.
Recovery still validates gross/provider/operator arithmetic, usage source,
fault flag, token/cache shape, and the split sum. Cache-discount rows continue
to use snapshot-derived validation because the cache-hit rate is not a separate
persisted column.

Regression test:
`TestRecoverLedger_ExistingCreditUsesPersistedRateContract` reproduces the
production-required shape: a historical pre-cutoff
`mlx-community/Llama-3.2-3B-Instruct-4bit` row stored at default rates, without
a historically applicable normalized snapshot key. Recovery must leave the row
unquarantined and preserve the stored gross credits.

Security regressions:
`TestRecoverLedger_QuarantinesPersistedMultiplierShareDrift` verifies coherent
multiplier/share drift still quarantines, and
`TestRecoverLedger_QuarantinesPreCutoffNormalizedDefaultRateTamper` plus
`TestRecoverLedger_QuarantinesPostCutoffDefaultRateTamper` verify rows with a
normalized model-specific rate cannot be rewritten to the snapshot default rate
and accepted. `TestRecoverLedger_QuarantinesUnknownPersistedRateContract` also
checks that quarantined unknown-rate tampering records a nonzero
snapshot-authoritative reconciliation delta.

## Release Gate

Release of already-frozen production rows is an in-scope deliverable for this
handoff, but it is blocked on explicit operator sign-off before any production
mutation. The operator must approve the exact `ledger_request_credits.id` list
and provide the `operator_key` used by the admin endpoint.

Current read-only enumeration shows 814 candidate rows across four providers,
with total provider credits of 42432 uUSD. Of those rows, 751 have
`provider_reported_prompt_tokens > prompt_tokens`, with a total diagnostic
prompt-token delta of 12498. This prompt-token delta must not be repaid; the
release amount is the stored `provider_credits` already on the quarantined
ledger rows.

The settlement gate is currently off. Do not emergency-restart the gate or
advance settlement eligibility as part of this fix. After the code fix lands
and the operator signs off, release must use the existing admin force-credit
endpoint and then verify no overpay by checking that the rows' original
`provider_credits` are the only payable amounts made eligible.
