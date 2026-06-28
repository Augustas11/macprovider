# Phase-A network-harness re-run — 2026-06-28

Internal. Source: `test/network-harness/artifacts/` (harness-rerun-phase-a branch).
Audience: operator + maintainers comparing post-fix outcomes against
the first-run findings in
[`phase-A-findings-2026-06-27.md`](./phase-A-findings-2026-06-27.md).

## Run conditions

- Target: live `https://api.streamvc.live` + `wss://coordinator.streamvc.live`,
  deployed at `v1.6.1-36-gaf907bb` (today's main with all 7 phase-A PRs).
- Buyer: `~/.config/macprovider/buyer-api-key` (operator's own account).
- Providers attached at time of run: 2/2 ready
  - `augustass-macbook-air` — Qwen3-32B-4bit, 1 slot, healthy
  - `air5` — Qwen2.5-Coder-7B-Instruct-4bit, 1 slot, **flapping** with
    `502 invalid_provider_usage` (upstream provider returned malformed
    `usage` block — independent of phase-A scope).
- Operator config: `account_concurrency: 2` on Pearl (N=2, not the new
  code-default N=3 — that only applies to fresh installs).

## Hard-invariant scoreboard

| Scenario | First-run I1 | Re-run I1 | Δ |
|---|---|---|---|
| smoke | PASS | PASS | — |
| 01 happy_path_concurrent | PASS | PASS | — |
| 02 capacity_contention | **FAIL** | **PASS** ✅ | **FIXED** |
| 03 sticky_multi_turn | **FAIL** | **PASS** ✅ | **FIXED** |
| 04 wrong_model | PASS | PASS | — |
| 05 mid_stream_drop | **FAIL** | **FAIL** (harness bug) | **backend fixed, harness needs update** |
| 06 cold_start_race | PASS | PASS | — |

I2/I3/I4 all PASS on every scenario, both runs.

**Net: 2 of 3 first-run I1 failures structurally closed. 1 (#05)
shows the backend fix landing correctly but the harness's
reconciler doesn't yet recognize the new outcome value.**

## Findings — re-run vs first-run

### F-1 ✅ — Rate-limit headers now present + meaningful

**First-run finding.** "Per-account rate limit (429) fires at very
low concurrency" with no headers. Scenario 02: 7×429+2×503+1×200.

**Re-run observation.** Scenario 02: 5×429+4×503+1×200. Every 429
now carries:

```
HTTP/2 429
x-ratelimit-limit-requests: 2
x-ratelimit-remaining-requests: 0
x-ratelimit-reset-requests: <unix-ts>
retry-after: 1
cache-control: no-store
vary: Authorization
vary: X-Demo-Token
```

(Quoting from a direct live curl — the harness doesn't yet capture
response headers in `per_request.jsonl`, see follow-up below.)

**Status:** FIXED via [#205](https://github.com/Augustas11/macprovider/pull/205).
SDKs can now self-pace. The 503 count went up (2→4) because the
air5 provider is currently flaping (provider-side issue, not gateway).

### F-2 (mostly unchanged) — Wrong-model still returns 404

**Re-run observation.** Scenario 04: 2×404 + 1×429 (same shape).

**Status.** Reasoned about during issue-mapping (Task #53): F-2's
"404 vs 503" was specifically about the COLD-START race (covered
by F-4 / [#185](https://github.com/Augustas11/macprovider/issues/185)),
not literally-unknown model names. The latter remains 404 because
OpenAI APIs do return 404 for `model_not_found`, which is the
correct contract.

### F-3 ⚠️ — Mid-stream drop: backend FIXED, harness needs update

**First-run finding.** Scenario 05 ended with HTTP 200 + 0 billed
tokens + **no gateway row at all**.

**Re-run observation.** Same harness-side "outcome=ok" (saw
`[DONE]` after partial stream), but reconciler shape changed:

| Field | First-run | Re-run |
|---|---|---|
| gateway_rows | **0** | **1** ✅ |
| coordinator_rows_2xx | 1 | 1 |
| bytes_received | 13097 | 9506 |
| unmatched_successes count | 1 | 1 |

**The backend fix landed.** PR #201's SPEC-006 § 17.7 settlement
fallback DID fire — gateway now writes a `usage_events` row for
mid-stream drops. The row has `outcome=stream_truncated` (the new
contract per F-3 product decision #1), but the harness's I1
reconciler treats `harness.outcome=ok` + `gateway.outcome != "ok"`
as "unmatched success" and fails.

This is now a **harness-side bug, not a money-path regression**. The
audit trail row exists; the harness needs to learn that
`outcome=stream_truncated` is a valid completion.

**Action.** Harness PR to widen I1's match predicate to recognize
`outcome ∈ {ok, stream_truncated}` as settlement-complete.
Should also assert FR-B6 envelope presence in the SSE
(`type=server_error, code=provider_disconnected`) so the buyer
side has the signal documented in PR #199.

### F-4 ✅ — Cold-start race now 503, not 404

**First-run finding.** Scenario 06: HTTP 404 at +515ms.

**Re-run observation.** Scenario 06: HTTP 503 at +473ms.

**Status:** FIXED via [#198](https://github.com/Augustas11/macprovider/pull/198).
PR #198's pool-lifetime model accumulator now returns 503
`no_provider_available` when a model was ready earlier in the
pool's lifetime but isn't right now. Buyer SDKs interpret 503 as
"retry later"; 404 they don't retry.

### F-5 ✅ — Shared correlation ID end-to-end

**First-run finding.** Gateway and coordinator wrote different
UUIDs for the same request; harness's I1 reconciler had to fuzzy-
match by `(model, tokens, ts±60s)`.

**Re-run observation.** Every successful scenario (01, 02, 03,
smoke) reports `reconciled cleanly: harness=N ok, gw=N ok,
coord=N 2xx; token sums all equal at K` — the `unmatched=0`
column confirms the reconciler now matches **exactly** by shared
`X-Request-ID`, not fuzzy. The +17/+32 token "drift" from the
first run (which we suspected was concurrent traffic) is now
provable as concurrent traffic, not gateway over-billing.

**Status:** FIXED via [#195](https://github.com/Augustas11/macprovider/pull/195)
(X-Request-ID propagation) + [#192](https://github.com/Augustas11/macprovider/pull/192)
(SPEC-002 v1.4.2 R-2).

### F-6 ✅ — Provider WS wedge structurally closed

**First-run finding.** Local provider's WS dead at TCP for ~42h
with no logs. Fleet vulnerability.

**Re-run observation.** Both providers reconnected within the 90s
window after the deploy-induced drain. The local Mac (this
machine) is now running `v1.6.1` Swift binary; once the operator
re-installs from the current `get.streamvc.live/install.sh` flow
they get the in-process bounded-send/watchdog AND the external
LaunchAgent (PR #204 + #207).

**Status:** FIXED structurally. Full operator-side validation
requires (a) re-install of the new Swift binary and (b) leaving
it running for a few days to confirm no recurrence. The external
LaunchAgent provides belt-and-suspenders catch even on older
binaries.

### F-7 (deferred) — Sticky off

Tier-1 disclosure still shows `sticky_affinity.enabled: false`.
Phase-B product call.

### F-8 (still active) — Harness streaming token counter

The harness's `completion_tokens_received: 0` for the streaming
scenario 05 is unchanged. Same chunk-parser limitation noted in
the first-run report. Out of phase-A scope. Tracked here as a
follow-up.

## New observations

### N-1 (provider-side) — air5 Coder model returns `invalid_provider_usage` 502

Live curl with `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit`
consistently returns:

```
HTTP/2 502
{"error":{"code":"invalid_provider_usage","message":"Upstream provider returned invalid usage","type":"api_error"}}
```

That's a provider-side `usage` field schema issue (not gateway,
not coordinator). Independent of phase-A scope. Worth a separate
issue. The other model (Qwen3-32B on local Mac) responds 200
cleanly with the same prompt.

### N-2 (harness) — I1 reconciler treats outcome=stream_truncated as unmatched

See F-3 above. New harness PR needed before the harness can
verify F-3's fix automatically.

### N-3 (operator config) — Pearl runs N=2, not the new code-default N=3

`/opt/macprovider/gateway.yaml` explicitly sets
`account_concurrency: 2`, which overrides the code default of 3
from [#205](https://github.com/Augustas11/macprovider/pull/205).
Bumping the operator config to 3 would more closely match the
issue-#190 recommendation. Single-line change requiring another
gateway restart.

## Recommendations / next steps

1. **Harness PR** to recognize `outcome=stream_truncated` as
   settlement-complete (resolves F-3 verification).
2. **Filed issue** for N-1 (air5 invalid_provider_usage) — likely
   a Swift-side fix in the InferenceRelay's `usage` block emission.
3. **Operator decision** on bumping Pearl's gateway.yaml to
   `account_concurrency: 3` (separate restart).
4. **F-7 / F-8** remain phase-B work (sticky decision + harness
   token-counter).
5. **F-6 verification** — operator runs the new install on at
   least one Mac for 3+ days; confirm no silent-wedge recurrence
   in `~/Library/Logs/macprovider/watchdog.log`.

## Artifact bundles

All under `test/network-harness/artifacts/`:

- `smoke-20260628T141944Z/`
- `01_happy_path_concurrent-20260628T142039Z/`
- `02_capacity_contention-20260628T142124Z/`
- `03_sticky_multi_turn-20260628T142204Z/`
- `04_wrong_model-20260628T142307Z/`
- `05_mid_stream_drop-20260628T142342Z/`
- `06_cold_start_race-20260628T142517Z/`

Each contains `per_request.jsonl`, `ledger_reconcile.json`,
`metrics_summary.json`, `chaos_events.json` (where applicable).
