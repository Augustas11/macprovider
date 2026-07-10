# AUDIT — Fix iss-190 (concurrency rate-limit headers + N=3) — R1 ARCHITECT lane

## Scope

Same as the CODE prompt — the four files in
`/Users/augstar/macprovider-fix-190`. Read
`git diff origin/main..HEAD`.

## Context

Same as the CODE prompt. Note especially:

- Issue's open product decision was N=3 (issue's recommendation),
  N=2 (current / conservative), or scale dynamically with provider
  capacity (codex view). This PR picks N=3.
- Per-API-key tier configuration is mentioned in the issue but
  deferred (would require DB schema work); for now N is a global
  config value (`AccountConcurrency` / `DemoConcurrency`).
- `Retry-After: 1` is a constant; the issue suggested "min
  seconds-until-an-in-flight-completes". The constant is documented
  as "conservative pending completion-time telemetry".

## You are the ARCHITECT auditor

Score CRITICAL / HIGH / MEDIUM / LOW / NOTE. Bar is **0 C/H/M**.

Focus on whether the design holds up, composes with the rest of
the platform, and doesn't paint us into a corner.

Specifically check:

1. **N decision documentation.** Is the rationale for picking N=3
   over per-API-key tiering captured well enough that future
   readers (or auditors) understand why the simpler choice was
   made? Will the per-tier extension need to break the API or
   header shape later?
2. **Header taxonomy.** We now have two header schemes:
   - `X-RateLimit-Limit / -Remaining / -Reset` for daily-token
     quota
   - `X-RateLimit-Limit-Requests / -Remaining-Requests / -Reset-Requests`
     for per-account concurrency
   Is this consistent with OpenAI's actual headers (the
   `*-Requests` and `*-Tokens` variants)? Does the gateway expose
   `*-Tokens` variants too, or does the unsuffixed scheme stay?
   Will future per-tier limits (e.g. RPM) need a third scheme?
3. **Retry-After as a constant.** The issue explicitly recommended
   "min seconds-until-an-in-flight-completes, cap at 60". This PR
   ships a constant 1. Is the deferral defensible? Should we add
   a follow-up tracking issue for completion-time telemetry?
4. **`decision.Active` exposure via `Remaining`.** The remaining
   count is computed as `concurrencyLimit - concurrencyDecision.Active`.
   For paying buyers this is fine. For demo buyers (keyed on
   `demo:<ip>`), it reveals other concurrent demo sessions on the
   same /64. Is this OK, or should demo responses suppress
   `Remaining`?
5. **Phase-A composability.** Scenario `02_capacity_contention.yaml`
   was the original repro (10 concurrent buyers from 1 account
   → 7×429 + 2×503 + 1×200). With N=3 + headers, the same
   scenario becomes 7×429 (with helpful headers) + ~3×200 if
   the cold-start race from #185 also lands. Will the harness
   need to be updated to capture and assert the new headers?
   (Issue body says "tracked separately".)
6. **`coordinator_timeout + 1 minute` expiry on the row.** Not
   changed by this PR, but the new `decision.Active` exposure
   in the header makes any drift in this expiry observable. Is
   the lazy-expire-on-acquire path tight enough that stale rows
   don't inflate `Active`?
7. **Test coverage shape.** The two new tests assert headers on
   429 and 200 paths. Is there a meaningful coverage gap (e.g.,
   the streaming path, the demo path on admit, a verification
   that the headers survive coordinator-side errors)?

Out of scope: anything outside the four files.

## Output format

Same as CODE prompt — per-finding SEVERITY / Location / What / Why
it matters / Suggested fix, then `SUMMARY: <C>/<H>/<M>/<L>/<N>`.
