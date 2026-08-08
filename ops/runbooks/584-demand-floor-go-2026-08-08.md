# #584 demand-floor go/no-go — 2026-08-08

**Verdict: GO — liveness-only, provider-continuity first**

Supersedes [`584-demand-floor-go-nogo-2026-08-07.md`](./584-demand-floor-go-nogo-2026-08-07.md) (NO-GO).

## Non-negotiable (operator caveat)

Prebeta outside providers are the product. They must **keep running and keep
serving** while we learn how the fleet behaves. Canary / demand-floor is
secondary. If those goals conflict, **canary loses**: hit the kill switch and
leave it off.

This GO does **not** authorize qualification load, aggressive probing, or any
mode that can knock providers offline for “science.”

## Why GO is allowed now

| Gate | Status |
|------|--------|
| #584 redesign (budgets, FR-CAN22/23, fail-closed) | Pass |
| Physical warm baselines (draft floors on file) | Pass — T-M1-8×Llama-3B (n=30 AC); T-M-series-high×Qwen3-8B (n=30 battery). Unsigned draft floors; enough to arm **tiny** liveness only |
| Pearl emergency-disable drill | **PASS** 2026-08-08 — `/var/tmp/macprovider-584-emergency-disable-20260808T145328Z` · [#584 comment](https://github.com/Augustas11/macprovider/issues/584#issuecomment-5226634456) |
| Operator signed GO | **This document** |

## What this GO authorizes

1. **Liveness-only** scheduled canary on Pearl (smoke checks), behind enable gate.
2. Hard budgets already shipped: ≤4 requests / ≤32 completion tokens / ≤90s run;
   `CANARY_DEGRADED_RETRIES=0`; `--fail-on-degraded`; safety observer abort.
3. Immediate rollback via `emergency-disable.sh` on any abort signal below.

## What this GO forbids

- Qualification / sustained / thermal fault-injection on live Pearl fleet
- Raising budgets or enabling retries without a new signed GO
- Leaving canary on after a degradation trip (“watch and hope”)
- Clearing `exc-canary-disabled-enable-gate` until a clean ~24h liveness watch
- Any change whose purpose is demand-floor UX if it risks provider continuity

## How we make sure this does not degrade the network / provider UX

Plain version of the safety stack:

1. **Tiny load** — a few tokens, few requests, short deadline. Not a soak test.
2. **Stop on first bad smell** — memory pressure, disconnect, thermal/RSS trip,
   pool Ready regression → abort that run; no automatic retry storm.
3. **Red button ready** — kill-switch drill just proved we can leave canary
   fail-closed in one command.
4. **Providers stay the priority** — if Ready count drops, heartbeats go stale,
   or operators see “needs attention” / restart loops correlated with canary
   ticks → **disable immediately**, keep studying the fleet with canary off.
5. **Watch window** — after arm, watch ~24h. Abort criteria (any one is enough):
   - provider disconnect/restart wave attributed to canary
   - Ready/routable pool shrinks vs pre-arm baseline without other cause
   - repeated `memory_pressure` / degraded canary aborts on the same hosts
   - support signal that providers look “broken” during canary minutes

## Arm procedure (separate step; still requires following this GO)

Follow [`prebeta-demand-floor.md`](./prebeta-demand-floor.md) re-enable checklist
**only** with liveness budgets and with an operator on watch for the first hour.
First action on abort: `sudo /opt/macprovider-canary-buyer/emergency-disable.sh`.

## Evidence pointers (operator-local)

- `~/584-baselines/2026-08-08-t-m1-8/` (8GB Llama cell)
- `~/584-baselines/2026-08-08-t-m-high-qwen3-8b/` (+ Pearl host `/var/tmp/...`)
- Pearl drill: `/var/tmp/macprovider-584-emergency-disable-20260808T145328Z`

## Approver

Operator session 2026-08-08 — directed “sign GO” with explicit caveat that
providers must stay running during prebeta data collection.

**Not** a blank check. Continuity > canary.
