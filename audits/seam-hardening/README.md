# Seam Hardening — pre-OpenRouter-enrollment audit

Before enrolling our gateway as an upstream provider on OpenRouter, we audited the
**seams** between buyer ↔ gateway ↔ coordinator ↔ provider for correctness and
robustness gaps. These seams — not the model or inference quality — are where a
marketplace enrollment puts us at risk: OpenRouter publicly scores providers on
latency + error rate (and routes buyers away on strikes), reconciles billing on
reported usage, and retries requests. Gaps here are cheap to fix now and
costly/visible once we take scored traffic.

**Scenario under test:** our `phase5-gateway` enrolled as an OpenRouter upstream,
driven by buyer traffic.

## Method

Each finding is grounded two ways:
1. **Located** — a concrete `file:line` in our own codebase and a failure scenario.
2. **Checked** — where practical, an executable regression test that asserts the
   buggy behavior today and flips red when the fix lands (see `harness/`).

Only checked/located findings are carried into `findings.md`.

## Seam taxonomy

1. **request-lifecycle / deadlines** — per-phase leases vs one flat wall-clock
2. **error-classification** — 5xx-fault vs capacity-shed vs buyer-cancel
3. **usage & settlement** — reserve→settle, partial-usage survival, idempotency, durability
4. **fault-attribution / reputation** — never strike provider health for platform/cancel failures
5. **cache-tenant-isolation** — server-authored scope; no cross-account timing/at-rest oracle
6. **backend-rollout-safety** — canary + kill-switch + per-slot telemetry; absence is its own bucket
7. **attestation-honesty** — claim only load-bearing, end-to-end-verified controls
8. **fleet-version-floor** — provider version floors + stale-build defense + auto-update

## Contents

| File | What |
|---|---|
| `findings.md` | Risk register: per-finding verdict, `file:line`, failure scenario, fix, tripwire test |
| `harness/` | Executable regression tests (Go), results table, and run commands |

The prioritized remediation (P0/P1/P2) at the end of `findings.md` is the source for the
tracked GitHub issues under the **Seam hardening before OpenRouter enrollment** epic.
