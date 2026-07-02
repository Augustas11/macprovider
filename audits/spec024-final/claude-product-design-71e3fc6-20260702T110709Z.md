The staged output file write requires permission, and the task specified read-only — so I'll deliver the audit here instead.

# SPEC-024 Prefix-cache billing — Product / Contract Design Critic

**Target:** local HEAD `71e3fc6` on `spec/024-prefix-cache-billing-impl-prompt` · read-only · audited against `specs/SPEC-024-prefix-cache-billing.md` (v0.1) and the BUILD prompt.
**Build/tests:** coordinator `go test ./internal/billing ./internal/buyer ./internal/config` → PASS. Prior lanes (product-design + adversarial at `ae10111`) returned 0 C/H/M; this pass re-audits the whole product surface plus the `ae10111`→`71e3fc6` delta (usage-forwarding hardening + streaming invalid-cache latch).

## Verified conformant
- **Buyer-visible compat (§8):** coordinator injects `cached_prompt_tokens` only into already-complete usage (`server.go:5673`); incomplete usage is *completed* not partially augmented (`chatResponseWithCompleteUsage:5702`); gateway synthesizes a full flat usage object incl. `cached_prompt_tokens:0` when provider usage absent (`chat_proxy.go:398,1515`). Sanitized `0` on non-hit/legacy/absent/quarantined routes everywhere.
- **Provider usage handling (§3):** absence→`nil`(→0, ledger `NULL`); explicit `null`/string/float→`-1` sentinel→`invalid_cached_prompt_tokens`; `cached>prompt`/negative→quarantine; positive-on-non-hit→`ambiguous_cache`. The three "effective cached" deciders (buyer / request_log / ledger) are semantically consistent.
- **Discount arithmetic (§6):** `ComputeCreditsWithCache` (`formula.go:150`) overflow-guarded split, `null_error` guard preserved, byte-identical when cached NULL/0.
- **Incentives/abuse (§7):** over-report is provider-adverse; discount gated to `attempt_n=0 && sticky_result="hit"`.
- **Quarantine:** nulls field, `quarantined=1`, `zeroCredits` (`hotpath.go:179`).
- **Admin reconcile:** buyer-equivalent threads the cached split (`endpoints.go:560`).
- **Rate-card default/validation (§5):** omitted config → prompt rate (byte-identical rollout), explicit `0` honored via `promptCacheHitRateSet`, `Validate` rejects cache-rate > prompt-rate (`config.go:1133-1139`).
- **Streaming latch (`71e3fc6`):** `mergeStreamUsagePointers:5573` latches `-1` so a later valid frame can't launder the quarantine; gateway independently latches + re-clamps.
- **Regression coverage** broad and dedicated for sticky-hit-only discount, quarantine variants, usage synthesis, and the new latch (buffered/unbuffered × coordinator/gateway).

## Findings

**Critical — none. High — none.**

### Medium
**M1 — Billing-time `routing_decision` observability (§3 MUST + the *sole* v0.1 fraud safeguard per §7) has zero regression coverage.**
`SPEC-024 §3` (`:56`) mandates a billing-time `routing_decision` row carrying `cached_prompt_tokens`/`sticky_result`/`sticky_miss_reason`/`attempt_n`, and §7 makes it the only v0.1 under-reporting safeguard (cross-checking deferred to v0.2). It is correctly wired (`billing_recorder.go:249` → `hotpath.go:132` → `billing_recorder.go:109`) but **nothing asserts it** — the only `routing_decision` tests (`routing/log_test.go:36`, `iss266_t1_test.go:212`) cover the *selection-time* SPEC-004 row, not the billing-time row or any SPEC-024 field. Loss would be silent (buyer/ledger arithmetic unaffected → no other test fails). This repo has already been bitten by exactly this: per memory `feedback-audit-prompts-log-shape-backcompat`, a dropped sticky-miss log field passed three codex lanes and was caught only by integration tests. **Fix (cheap):** one test asserting the billing-time row emits `cached_prompt_tokens` (incl. explicit `0`-on-hit) + `sticky_result` on a hit and `cache_validation_reason`+`cached_prompt_tokens=0` on a quarantine.

### Low
- **L1 — `mergeStreamUsagePointers` valid path (`server.go:5589`) drops the fallback-merged prompt/completion** that the invalid-latch path (`:5585-5587`) keeps. Split usage frames (prompt in one, completion in another) lose the earlier field → `null_error`/estimate fallback. Bounded (never over-charges/over-credits), non-conformant-provider only, but an asymmetry worth aligning.
- **L2 — Error-fallback insert path skips the billing-time `routing_decision`.** It fires inside `WriteHotPath`; the `WriteRequestLogWithIdentity` fallback (`billing_recorder.go:256`) doesn't, so a pre-`:132` hot-path failure writes a row with no cache-observability event.

### Info
- **I1 — Quarantine zeroes the *entire* buyer debit, not just the cached fraction** (`GrossCredits=0`). Spec-conformant (§3) and fails safe toward not overcharging, but a misreporting provider yields free buyer inference + zero operator revenue for those requests — worth an operator note.
- **I2 — Coordinator-direct (non-gateway) callers may see absent `cached_prompt_tokens`.** §8 scopes the presence MUST to the gateway, which synthesizes it → conformant.

## Gate verdict
**BLOCKED on 1 Medium (M1).** No Critical/High. Buyer-visible compatibility, discount arithmetic, quarantine semantics, sticky-hit-only eligibility, admin reconcile, rate-card default/validation, and the new streaming latch are all conformant and well-tested. M1 is a test-adequacy gap on the one money-path fraud control that ships in v0.1 — clear it with a single log-assertion test, **or** make an explicit maintainer decision to accept it as Low with PR-body documentation of the untested safeguard. L1/L2 ship-with-note; I1/I2 informational.

Note: I did not write to the staged `audits/spec024-final/claude-product-design-71e3fc6-*.md` file (write permission wasn't granted, and the task was read-only). If you want the report persisted there, approve the write and I'll drop this content in verbatim.
