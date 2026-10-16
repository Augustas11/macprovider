# FR-CAN23 correlation epoch — design + Partial delivery (2026-07-23)

**Issue:** [#584](https://github.com/Augustas11/macprovider/issues/584)  
**Normative:** `specs/SPEC-031-canary-degrade-sanctions.md` FR-CAN23, FR-CAN29a, §14  
**Code:** `phase4-coordinator/internal/canarycorr`  
**Status:** **Partial (wired 2026-07-23)** — pure state machine + hermetic tests + live
`ws` canary path wiring landed. Pearl canary stays **disabled** (`exc-canary-disabled-enable-gate`
active); wiring is inert until re-enable.

## Why a package-first Partial

FR-CAN23 is the remaining multi-provider outage guard before re-enable at ≥2
providers. Prior Partial #690 shipped FR-CAN22 (sole-provider floor) and the
buyer-path liveness redesign. Wiring correlation into the live dispatch loop
touches money-path sanction timing and must not ship without:

1. a hermetically proven Sybil-safe resolve function;
2. observed-serving capacity residual for floor lifts;
3. physical baselines + emergency-disable drill (#584 ops gates).

This Partial delivers (1) and the design for (2)–(3). It deliberately does **not**
flip `pool.canary_enabled`, create enable gates, or start timers.

## Threat model fixed point (reaffirmed)

| Automatic effect of correlated majority | Allowed? |
|------------------------------------------|----------|
| Discard staged results for this epoch | **Yes** |
| Fire-and-forget operator alert (FR-CAN29a) | **Yes** |
| Bank rollback | **No** (operator only) |
| Persistent fingerprint suspension | **No** |
| Config-fault attribution | **No** (operator only) |
| Any durable containment a Sybil majority could farm | **No** |

Ordinary per-provider FR-CAN11/15 sanctions for **non-correlated** committed
failures remain allowed.

Suspicion threshold: strict majority of snapshot `N` (`failing * 2 > N`) **and**
`failing >= 2`. One malicious provider alone can never open suspicion.

## Algorithm (implemented)

```
NewEpoch(model, fingerprint, bankGen, snapshotIDs)
  freeze Snapshot denominator N

Stage(result)  # unapplied; reject out-of-snapshot / fp / gen / dup
  record BuyerServing + ObservedServing flags from caller

Resolve():
  failing = count(staged class in {nonce_mismatch, incomplete})
  if failing >= 2 AND failing*2 > N:
    return Suspicious + Discarded + OperatorAlert  # zero commits
  else:
    for each staged result:
      plan pass / failure / neutral
    apply FR-CAN22 floor using ObservedServing capacity only:
      sole observed-serving failure → FloorHeld (no ApplyFailure)
      non-observed-serving failures → normal ApplyFailure
    return Commits
```

Relay soft/status and neutral classes never open suspicion and never apply
counters.

## Observed-serving residual (FR-CAN22 → FR-CAN23)

Request-independent routability (`RoutingEligible` + transport + `MaxContextTokens>0`
+ not Tier-2-excluded) remains necessary but **not sufficient** for a peer to lift
the floor when committing multi-provider sanctions.

`ObservedServing` must be true from caller evidence, typically:

- coordinator-relayed buyer success within `ObservedServingWindow` (default 90s), or
- full request-aware eligibility once lock-coupling with admission quota is solved.

`HasRecentObservedServing(lastSuccess, now, window)` is provided for callers.
**Not in this Partial:** writing `LastBuyerSuccessAt` on the Provider struct or
changing `canaryBuyerServing`. That is the wiring Partial.

## Wiring plan (next code Partial — not this PR)

1. On successful buyer relay completion, stamp `Provider.LastBuyerSuccessAt`.
2. Canary sweep: for each model with `BuyerServingCountForModel >= 2` and canary
   sanctions enabled, build `NewEpoch` over a fixed snapshot; re-dispatch the
   **same** fingerprint; `Stage` results without calling `RecordCanaryResult`.
3. Resolve only when `StagedCount==N` **or** the FR-CAN12 window has elapsed
   (then `ResolveOptions{AllowIncomplete: true}`). Never resolve on the first
   failure alone — that would re-break first-responder sanctioning.
4. On epoch resolve:
   - suspicion → log/page FR-CAN29a fields; do not touch counters;
   - commit → for each `CommitAction`:
     - `ApplyPass` → `RecordCanaryResult(..., true, ...)`;
     - `ApplyFailure` (including `FloorHeld`) → `RecordCanaryResult(..., false, ...)`
       so the fail counter accrues; map `FloorHeld` to `CanaryTripFloorHeld`
       telemetry / suppress only the tier sanction branch (FR-CAN22 parity).
5. Bank-generation fencing: FR-CAN26 (config generation snapshot) is still a
   **Gap** on the live path. Wiring MUST introduce an interim monotonic canary
   bank/config generation (or land FR-CAN26 first) and bind each epoch at
   dispatch. Do not claim FR-CAN26 is already present.
6. Keep canary disabled on Pearl until ops matrix + drill + go/no-go pass.

### Floor residual (package contract)

| Role | Predicate |
|------|-----------|
| Target eligible for floor spare | `BuyerServing` (FR-CAN22) |
| Peer may lift the floor | `ObservedServing` (FR-CAN23 residual) |
| `FloorHeld` + `ApplyFailure` | both true: counter accrues, sanction suppressed |

## Explicit non-wiring (this Partial)

- No changes to `RecordCanaryResult` signature beyond what already exists.
- No production config defaults changed.
- No Pearl mutation.
- No enable-gate / timer / `require_hash_verified` interaction (#609/#608).

## Tests

```bash
cd phase4-coordinator
go test ./internal/canarycorr/ -count=1
```

Coverage includes: input fencing, Sybil-safe majority, ≥2 failure requirement,
relay/neutral neutrality, sole observed-serving floor residual, non-serving
targets still sanction, no second resolve, observed-serving window helper.

## Ops companions in this Partial

| Artifact | Role |
|----------|------|
| `ops/runbooks/584-emergency-disable-drill.md` | Pearl kill-switch drill paper |
| `ops/runbooks/584-physical-baseline-matrix.md` | Per-tier floors + thermal/memory notes |
| `test/e2e/canary-buyer/run-canary.test.sh` | Existing hermetic emergency-disable coverage (unchanged contract) |

## Issue status after merge

Keep **#584 OPEN**. This Partial advances software readiness for FR-CAN23 and
documents the remaining physical bar; it does not clear
`exc-canary-disabled-enable-gate`.
