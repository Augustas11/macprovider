# BYOM v0.2 slice 5 SPEC closure — pass 4 (2026-09-11)

Reviewed: `git diff origin/main -- specs/` at `7455e2bf`, code-reviewer lane only (security and architect reached bar at closure pass 3 and were not re-fired, per the never-re-fire-a-passed-lane rule).

| Lane | C | H | M | L | I |
|---|---|---|---|---|---|
| code-reviewer | 0 | 0 | 2 | 1 | 0 |

All restatement drift in SPEC-017; fixed in the closure-4 commit:

- **§5.9 generic 304 rule required projection-aware CORS headers, contradicting the intake "CORS: none" rule** (M): carved `/v1/stats/intake` out — its 304 carries the RFC 7232 cache headers only, no `Access-Control-*`.
- **Salt rotation rotated `eligibility_policy_id` with no specified window transition** (M): `stats.intake.policy_salt` is resolved once at load and immutable for the process; a change takes effect only on a restart, which closes the open window (`aggregator_stopped`) — a rotated salt rotates the id at a window boundary, never mid-window.
- **Change-log still labelled v0.2.1 "draft"** (L): "locked".
