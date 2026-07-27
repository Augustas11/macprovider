# Seam-Hardening Findings & Remediation

Verdicts against the eight seams. `file:line` are in our own repo. Tripwire tests (where
built) live in `harness/` and are named `TestSeam*`.

## Scorecard

| Seam | Verdict | One-line |
|---|---|---|
| 1 · settlement / deadline | **FAIL** | one flat request wall-clock; two money-integrity gaps |
| 2 · cache-tenant-isolation | **PASS by construction** | server-authored account-HMAC scope; KV in-memory only |
| 3 · backend-rollout-safety | **PASS** (gap closed, #764) | strong flags/canary/self-update; perf telemetry now segmented by `binary_version` on `/poolz` |
| 4 · attestation-honesty | **FAIL (client-facing)** | prose honest, but stat surfaces over-claim hardware trust |
| 5 · fleet-version-floor | **PASS (1 gap)** | blocks incompatible/known-bad builds; capacity now clamped at ingest (#764); version floor still unset in prod (P2-2) |

Fundamentals are strong (cache isolation, rollout discipline, signed-catalog admission,
honest prose). Exposure concentrates in two client-facing FAILs (settlement flat-wall,
attestation schema) plus a shared observability gap (capacity/backend telemetry).

---

## Findings by severity

### P0 — before enrolling on OpenRouter

**P0-1 · Attestation surfaces report hardware trust that a software key satisfies** — `credibility`
Two machine-readable surfaces — `nodes_hardware_attested` (public network-stats) and the
`/v1/models` `hardware_attestation` state — are computed from `AttestationStatus == "attested"`,
which a self-signed software P-256 key satisfies (`phase4-coordinator/.../poolsnapshot.go:77-78`,
`internal/buyer/server.go:898-925`). The `hardware` tier is never emitted, and the hardware-rooted
controls are gated off in prod. A client trusting the field over-trusts the fleet.
**Fix:** gate both surfaces on `AttestationTier == "hardware"` (never true today) or rename to
key-custody (e.g. `nodes_key_attested`). Buyer prose already says "no hardware attestation" — bring
the schema up to the prose. *Tripwire: none yet (add a pool-snapshot unit test).*

**P0-2 · Single request wall-clock kills healthy long generations** — `ranking` — test `TestSeamH1`
**FIXED gateway-side (issue #760).** `upCtx = context.WithTimeout(r.Context(), CoordinatorTimeout())`
(`phase5-gateway/.../chat_proxy.go:122`, default 300s) spanned the whole request; it was enforced on a
mid-stream generation via the transport closing the body on `upCtx` expiry (the read loop is on
`r.Context()`+the idle timer). A legitimate long stream that kept emitting was cut at the wall → 5xx
against our public error rate. The wall had a second, hidden copy in `http.Client.Timeout`
(`cmd/gateway/main.go`), which also covers body reads.
**Fix (shipped):** one cancel funnel (`context.WithCancelCause`) with per-phase budgets in
`phase5-gateway/internal/router/request_deadlines.go` — `admission` (120s) → `first_token` (120s) →
a never-re-armed `stream_ceiling` = clamp(60s + `max_tokens`×250ms, ≥ `coordinator_request_seconds`,
≤ 900s) — plus the decode-idle timer converted from "any byte" to CONTENT progress, `Client.Timeout`
dropped to 0 with the connect budget moved to dial/TLS, and the concurrency lease scaled to the
effective ceiling. Non-streaming keeps a flat wall (`non_stream_request_seconds`, 300s, unchanged).
`TestSeamH1` flipped to `ProgressingStreamSurvivesLegacyWall` (PASS = certifies the fix).
**Residual (not fixed here):** the coordinator has the same flat-wall shape one hop up
(`phase4-coordinator/internal/buyer/server.go` attempt ctx, `routing.request_timeout_s` 280s;
`providerhttp/client.go` 300s), so buyer-visible improvement past ~280s needs the prod overlay raised
to ≥ the gateway ceiling and `check-deploy-config.sh` C2/C2b retargeted at the streaming ceiling.
Structured-output streams also keep a hard 300s sub-ceiling: SPEC-019 v0.2.4 §AC-V2-9 pins that
number, and raising it is a contract change requiring a spec amendment.

**P0-3 · Provider health struck on buyer/gateway cancellation** — `supply` — test `TestSeamH3`
The `ErrRelayTimeout` branch (`phase4-coordinator/internal/buyer/server.go:2994-2996`) calls
`recordBreakerFault` unconditionally; its `ErrRelayClosed` sibling (`:2997-3002`) guards on
`r.Context().Err() != nil`. A buyer cancel racing a relay timeout strikes the provider; two strikes
in 120s degrade it (`pool/provider.go:1574`) → dropped from routing.
**Fix:** add the `r.Context().Err()` guard to the `ErrRelayTimeout` branch; twin fix on the streaming
path (`forwardWSStreamingBuffered:3299`).

### P1 — before real volume

**P1-1 · Retry double-bill without a stable request id** — `money` — test `TestSeamH5a` · issue #762
**FIXED gateway-side (issue #762).** An id-less buyer retry (which OpenRouter does by default) minted a
fresh request_id (`phase5-gateway/.../server.go:240-244`), so the durable `(account_id, request_id)`
reservation key never matched and each attempt reserved + settled independently → one buyer intent,
N bills.
**Fix (shipped):** a bounded in-memory fingerprint index
(`phase5-gateway/internal/router/idless_dedupe.go`) over `"mpg-idless-v1"` ‖ account ‖ demo-token-hash ‖
conversation tag ‖ SHA-256 of the RAW body bytes, consulted only for gateway-minted ids with no
`Idempotency-Key` (both are higher-precedence dedupe contracts and bypass this path). An identical
re-send inside `quotas.idless_dedupe_window_seconds` (default 60s, measured from attempt 1's TERMINAL;
`0` disables) REPLAYS attempt 1's buyer-visible response, and an identical attempt arriving while
attempt 1 is still in flight COALESCES onto it — holding no reservation and no concurrency lease while
it waits (cap 4 waiters).
**What is and is not authoritative:** the money invariant remains the durable reservation key. The
index is a UX layer: on any miss — process restart, LRU/body eviction, oversize response, poisoned
(truncated) stream, waiter-cap overflow — the retry adopts attempt 1's request id and falls through to
the existing `duplicate_request_id` 409. Degraded UX, never a second bill. Publish is gated on a
buyer-visible 2xx, NOT on settlement finality, so SPEC-022 hold entries still replay; replays call no
Reserve/Settle/Hold and are invisible to the settlement reconciler by construction. Replayed headers
are a whitelist (`Content-Type`, `X-Provider-Id`, `X-Request-ID`, new `X-MacProvider-Dedupe: replay`,
plus freshly recomputed rate-limit headers); `X-MacProvider-Settlement-*` and `Retry-After` are never
replayed. Metrics: `gateway_idless_dedupe_{replay,inflight_wait,conflict,uncacheable}_total`.
`TestSeamH5a` flipped to `IdlessRetryBillsOnce` (PASS = certifies the fix); the miss and bypass paths
are covered by `TestIdlessDedupe_*` in `phase5-gateway/internal/router/idless_dedupe_test.go`.
**Residual (not fixed here):** the index is per-process and in-memory, so a gateway restart between
attempts still double-bills — identical to today's behavior, not a regression. A durable
`request_fingerprints` table (fingerprint → request_id, no body) is the named follow-up. The one real
false positive is a deliberate re-roll at temperature > 0: same account, same demo token, same
conversation tag, byte-identical body, no ids, inside 60s of attempt 1's terminal. It is bounded by the
window, the five opt-outs, and the conflict counter — not by "did the buyer receive it", which the
tripwire forecloses. Buyer-supplied `Idempotency-Key` dedupe on the coordinator path remains #200.

**P1-2 · Settlement not crash-durable** — `money` — test `TestSeamH7` · issue #763
**FIXED gateway-side (issue #763).** On the streaming after-commit path, if `SettleReservation` and
the `EnsureUsageEvent` fallback both failed, the gateway logged, refunded, and dropped the usage row —
the buyer already had a committed 200. Tokens delivered, nobody billed, no durable record. The
refunded reservation carries `settlement_hold=0`, so it was invisible to the SPEC-022 reconciler
(`ListSettlementHeldReservations` selects active + hold=1): nothing else would ever have found it.
**Fix (shipped):** a durable append-only **JSONL settlement journal**
(`phase5-gateway/internal/settlement/journal`), NOT a table in `gateway.db`. Same-DB storage would
have produced a green test and an unchanged risk — every failure class that takes out the settle write
(the `MaxOpenConns=1` write connection, a DB-file pathology, a torn WAL after power loss) takes the
journal write out with it; a second sqlite file is the same driver and the same page cache. Segments
`effects-<unixmilli>-<pid>.jsonl`, dir `0700` / files `0600`, records keyed
`(account_id, request_id, effect)` in three kinds — `effect` / `seal` / `quarantine` — and **never**
any prompt or response text.
**Durability contract:** `WriteEffect` is one `write(2)` + `fsync` BEFORE returning, so the effect is
on stable storage before the settle attempt begins (`TestSettlementJournal_EffectWriteFsyncs` pins the
call order through the real file). Seals are deliberately NOT fsynced — a lost seal costs one
idempotent re-drive, never a bill. Segment create/unlink fsync the parent directory.
**Where it arms:** `settleAfterCommit` only — the single choke point every after-commit terminal
funnels through, and the only place where the buyer has been served and the durable bill has not been
written. The reservation IS the pre-dispatch arm, so v1 adds no second one: a pre-dispatch record
would carry no token payload and would scale the journal with traffic rather than with settlements.
Journal write failures are **fail-open** — the settle proceeds, an error log and
`gateway_settlement_journal_write_failures_total` fire, and only recovery coverage is lost
(`TestSettlementJournal_WriteFailureDoesNotBlockSettle`).
**Recovery:** `RecoverSettlementJournal` (`internal/router/settlement_journal_recovery.go`) re-drives
unsealed effects through the SAME ladder — `SettleReservation`/`SettleDemoReservation` → seal
`settled`; reservation missing/terminal → `EnsureUsageEvent` (+`EnsureDemoUsageEvent`) →
`RefundReservation` → seal `usage_event`; `ErrUsageEventConflict` → no seal, quarantine after 10
attempts with a CRITICAL log + gauge. It runs BOTH as a bounded startup pass and on its own ticker
(`settlement.journal_recovery_interval_s`, default 30s, separate from the SPEC-022 reconciler):
startup alone would not help, because the H7 failure is a logical double failure inside a running
process that nothing restarts. A 60s grace window keeps recovery off effects whose request may still
be in flight; the batch limit (100) protects the single write connection; fully-sealed,
quarantine-free segments prune after 168h. Every rung is idempotent, so a re-drive of an
already-settled request matches the existing row and bills nothing
(`TestSettlementJournal_SettleLandedButSealLost`).
**Config:** `settlement.journal_{enabled,dir,fsync,segment_max_bytes,max_total_bytes,retention_hours,
recovery_interval_s,recovery_batch_limit,recovery_grace_s}`. `journal_enabled` and `journal_fsync` are
REQUIRED true by `Validate` (mirroring `reconcile_enabled`) and default true, so a pre-#763
`gateway.yaml` that sets none of them still boots with the journal on. `journal_dir` defaults to a
sibling of `storage.db_path`. `cmd/gateway` opens the journal right after `sqlite.Open` and exits on
failure — a silently-disabled journal has no other symptom, which is why
`TestGatewayRouterCarriesSettlementJournal` pins the wiring. Metrics:
`gateway_settlement_journal_{effects,seals,quarantines,write_failures,recovered}_total`,
`_unsealed`, `_quarantined`, `_bytes`.
`TestSeamH7` flipped to `SettlementRecoveredFromJournal` (PASS = certifies the fix): the in-band drop
is UNCHANGED (`usageRows=0`, refunded=1 — the in-band drop was never the bug, the PERMANENCE was), and
a second Server over the same store and journal recovers the bill to `usageRows=1` / 20 tokens, refund
intact, seal `usage_event`, second pass a no-op.
**Deliberately NOT covered:** (a) **disk full** (failure class C6) — untestable locally; the hard
`journal_max_total_bytes` cap refuses records with a CRITICAL log rather than filling the volume
sqlite lives on, which is the lesser harm but still a coverage gap. (b) **A journal-write failure AND
the settle double-failure in the same request** — metric-visible (`write_failures_total` plus the
§ 17.7 error log) but unrecoverable by construction. (c) **Crash mid-stream before any terminal** — no
effect is armed; the reservation reaper refunds, unchanged. (d) **The SPEC-022 hold-marker sibling
leak** — the debit/hold terminals never call `settleAfterCommit`, so a lost hold marker is still only
reconcilable coordinator-side; the `effect` key field is future-proofed for it, but it is NOT a v1
effect kind. (e) **Multi-instance arbitration** — the journal is single-writer, matching today's
single-gateway deployment; two gateways over one directory would each re-drive the other's effects.
(f) **Non-streaming settles** — they run BEFORE the response and 500 the buyer on failure, so there is
no delivered-but-unbilled window to journal. **Residual:** the conflict-attempt counter is
process-local, so a restart resets it — that only delays a quarantine, it can never double-bill.

**P1-3 · Capacity trusted blindly; no clamp, no tripwire** — `ranking`/`supply` (closes a slice-3 + slice-5 gap)
**FIXED coordinator-side (issue #764).** Nothing gateway-side: the gateway never reads
provider capacity — the claim enters at the coordinator's provider-WS ingest and is consumed
by coordinator routing and relay admission, so the clamp belongs there and there only.
Provider-reported `max_concurrency` was granted verbatim (`phase4-coordinator/internal/ws/server.go:2249`,
`:4196`, `relay.go:423`); the only drift signal was observe-only + default-off (`pow/drift.go:218`,
`config.go:104`). A stale/over-claiming build served silently.
**Shipped:**
- `pool.max_concurrency_ceiling` (default **8**, `0` = disabled) — sized off the Mac/MLX reality
  where requests serialize and the autotune recommender refuses `max_concurrency_override > 1`.
- `pool.ClampCapacity` (`internal/pool/capacity_clamp.go`) applies `min(reported, ceiling)` and
  keeps slots coherent: `slots_total <= clamped max`, `used = total - free` carried across the
  clamp, `free` never negative and never above total.
- Applied at **all three** provider-controlled ingest points, upstream of `pool.Registry`:
  hello/registration, heartbeat, and `state_update` (the third one was not in the original
  finding — an unclamped `state_update` would have restored inflated free slots right after a
  clamped heartbeat). `relay.go` admission reads the clamped pool entry, so it needs no change.
- Permanent tripwire `provider_capacity_over_claim_total{phase}` (prometheus counter; monotonic
  for the process lifetime, incremented on **every** offending frame) + a
  `provider_capacity_over_claim` warn log with provider_id / reported / ceiling / effective.
- TTFT/TPS segmentation: the SPEC-017 rollup has no TTFT/TPS aggregate to extend (its overview
  schema is a locked 14-field counter set with no latency), so the segmentation is additive on
  the live snapshot surface — a `by_binary_version` block in the `/poolz` summary carrying
  per-version provider/slot counts, canary-measured TTFT (avg + max) and sustained TPS, and the
  provider-reported TPS estimate alongside. Fed by new
  `pool.Registry.RecordCanaryLatency`, the coordinator's only live latency measurement.
**Residual:** the segmentation covers canary-probed providers only — a provider that has never
been probed (or a deployment with `pool.canary_enabled` off) contributes to the counts but not
the latency averages; `*_samples` fields make that explicit rather than letting a zero read as
"fast". Buyer-relay TTFT is still not timed into the pool. `/poolz` is operator-authenticated,
so the segmentation is not a public surface.
*Tripwire tests:* `internal/pool/capacity_clamp_test.go`, `internal/ws/capacity_clamp_test.go`,
`internal/ws/poolz_version_segments_test.go`.

**P1-4 · Runtime perf gate fails open on absent benchmark** — `ranking`
**FIXED coordinator-side (issue #765), shipped dormant.** Nothing gateway-side: routing
eligibility is a coordinator concept. `pow/drift.go` skipped the TPS/hash check when
`!hasBenchmark` — un-benchmarked providers were silently un-gated.
**Shipped:** absence of a verified benchmark is now a distinct suspect bucket.
- `pow.EvaluateHeartbeatWithVerdict` returns a tri-state `BenchmarkVerdict`
  (Verified / Missing / Unknown) from the SAME evidence lookup the alerts already do — no extra
  evidence-store round trip. Both silent-exit paths are covered: no verified evidence at all,
  and evidence carrying no benchmark for the model actually being served.
- A store **error** stays `Unknown` on purpose. Fail-suspect applies to provider claims, not to
  infrastructure: a database blip must not quarantine the fleet.
- Enforcement reuses the existing gating mechanism rather than inventing one — a
  `BenchmarkQuarantined` flag on `pool.Provider` checked by `RoutingEligible()` /
  `ServingCapable()`, exactly how the other suspect buckets (`AuthSelfMinted`, legacy catalog
  admission, `PendingReceiptPubkey`) are expressed. No new state machine, no canary/breaker hold
  collision.
- **Config gate:** `proof_of_weights.telemetry_drift.quarantine_missing_benchmark`, default
  false, and `Validate()` rejects it without `telemetry_drift.enabled` (itself default-off). Both
  flags must be set before an un-benchmarked provider stops receiving buyer traffic, because the
  verified-evidence pipeline does not yet cover the whole fleet. With the gate off the verdict is
  always `Unknown` and routing is byte-for-byte pre-#765 — pinned by a unit test.
**Residual:** enabling the gate on the current fleet would quarantine every provider without
verified autotune hardware evidence; measuring that fraction on the live pool is a prerequisite
to the rollout and has not been done. Release is per-heartbeat, so a provider that produces a
benchmark is un-quarantined on its next heartbeat with no operator action.
*Tripwire tests:* `internal/pow/drift_missing_benchmark_test.go`,
`internal/pool/benchmark_quarantine_test.go`, `internal/ws/poolz_version_segments_test.go`.

### P2 — debt

**P2-1 · Single-terminal-wins request arbiter** — `money` — H4 (blocked)
No arbiter joins the billing terminal (`billing_recorder.go:220`) and the buyer-504 terminal
(`server.go:2996`); billing can complete while the buyer is told it timed out. **Fix:** a terminal
latch/actor. Not unit-testable until it exists (see `harness/` H4).

**P2-2 · Version floor unset in prod + client can't parse the rejection** — `supply`
`required_binary_version` is set nowhere in prod config, and the Swift client has no `case 4004`
(`phase3-binary/.../CoordinatorClient.swift:1460-1499`) → a below-floor close is a silent reconnect
loop, not an upgrade directive. **Fix:** set the floor in the prod overlay, add a `4004` handler + an
upgrade directive, add a `doctor` subcommand.

**P2-3 · No per-model version floor** — `supply`
Only a per-model *hardware-tier* gate exists; an old-but-hardware-eligible build can serve a model that
needs a newer engine. **Fix:** add a per-model minimum-version floor to the routing gate.

**P2-4 · Hygiene: hello-gate spec vs prod config; same-account timing risk** — `hygiene` — **FIXED (#769)**
Live Pearl posture verified 2026-07-27 against the RUNNING process (`--config-overlay
/etc/macprovider/coordinator.pearl-overlays.yaml`, overlay keys override): the overlay EXPLICITLY
sets `require_autotune_hello_gate: false` (revised 2026-07-22; SPEC-032 v0.2-draft corrects its five
prod-on claims — accurate at the 2026-07-11 baseline, drifted since) and `telemetry_drift.enabled:
true` (observe — #764/#765 missing_benchmark alerts fire live; quarantine dormant); canary OFF
(explicit overlay false + timer inactive + DISABLED sentinel — the accepted P0 #584 exception);
`warmup_gate_enabled` false live vs true committed (DRIFT — surfaced, operator decision, not
auto-fixed); `sticky_enabled` true →
the same-account TTFT side-channel risk-acceptance is written, with an explicit MUST-re-evaluate
trigger before OpenRouter enrollment (a marketplace credential collapses "same account" into "same
marketplace"). All in `ops/runbooks/seam-769-gate-posture-2026-07-27.md`. **Residual:** hello-gate
enable-after-survey shares the #765 live-pool survey prerequisite; warmup drift unresolved by design.

---

## Verified strengths — do not regress

- **Cache-tenant isolation (seam 2):** conversation/cache scope = `HMAC(secret, scope‖accountID‖tag)`
  server-side (`phase5-gateway/.../chat_proxy.go:2061`); KV cache in-memory only. No cross-tenant oracle.
- **Rollout discipline (seam 3):** default-OFF engine flags + kill switches; signed compatibility-set
  floor with mandatory rollback set; correctness canary; verified-predecessor self-update + quarantine.
- **Admission (seam 5):** compat-set + signed-catalog + model-hash, enforced at connect **and** reconnect,
  ON in prod. Blocks incompatible/known-bad builds cleanly.
- **Honest buyer prose (seam 4):** copy that says "no hardware attestation" + a MUST-NOT-claim list.

## Cheapest-first sequence

1. **P0-1** + **P0-3** — two-line changes, highest stakes-per-character.
2. **P0-2** — the flat-wall decomposition.
3. ~~**P1-3**~~ — **DONE (#764)**: one clamp+tripwire closed the seam-3 and seam-5 gaps together.
   **P1-4** landed with it (#765) but ships dormant behind
   `telemetry_drift.quarantine_missing_benchmark`; enabling it needs a live-fleet measurement of
   how many providers lack verified benchmarks.
4. ~~**P1-1 / P1-2**~~ — **DONE (#762, #763)**: money integrity before real buyer volume. #762 makes an
   id-less retry bill once; #763 makes an after-commit settle recoverable. Both keep the durable
   `(account_id, request_id)` key as the invariant — neither adds a second source of truth for money.
5. P2 as debt burn-down.
