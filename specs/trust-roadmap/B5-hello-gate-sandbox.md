# B5 — Hello-gate-on, no-buyer-traffic sandbox

**Type**: deferred design brief — a FUTURE separate SPEC with its own three-lane audit loop. Analysis, not a commitment.

**Gated on**: B2.

## Problem / shape
Turning `require_autotune_hello_gate` on is a one-line ops flip, but naively it
makes dual-control operator approval a hard admission gate on a one-operator
team. Surviving design: unapproved providers may connect and receive
**synthetic/internal probes only, never buyer traffic** — *not* the routable
`admitted_but_unapproved` state, which reintroduces the exact admission bypass
the gate exists to close (`LatestVerified` returns only `status='verified'` rows;
`waiting_trust` is parked by design). **Preconditions**:
config-reload-without-restart (a single-provider-pool restart is a documented
multi-hour outage, incident 2026-07-10); and the registered exception's
`removal_condition` amended first (it demands admission "through durable
hardware-trust approval … without global gate disabling").
