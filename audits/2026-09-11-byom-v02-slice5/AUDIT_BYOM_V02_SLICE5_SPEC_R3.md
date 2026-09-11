# BYOM v0.2 slice 5 SPEC audit — round 3 (2026-09-11)

Reviewed: `git diff origin/main -- specs/` at `823c7f6c`. Three codex lanes.

| Lane | C | H | M | L | I |
|---|---|---|---|---|---|
| code-reviewer | 0 | 1 | 7 | 2 | 0 |
| security-reviewer | 0 | 0 | 1 | 3 | 0 |
| architect | 0 | 2 | 3 | 3 | 0 |

## Findings and dispositions (fixed in the R3 fix commit unless noted)

- **Audit-store retention has no lifecycle** (code H): rule 9 — fetched with identity encoding, written byte-exact BEFORE the manifest is authored, append-only, kept ≥ 24 months after the ledger row and while any later release lists the key; loss is detectable via the ledger-bound digest and MUST be recorded in the next release notes.
- **AC-CAT-13 contradicts the k-AND-floor emission** (arch H1): AC-CAT-13 amended — three principals satisfy only the principal condition; ten at the cap make the key present.
- **Promotion example carries a non-null envelope** (arch H2, code M): example set to `null`; AC-CAT-21 promotion test asserts the null envelope.
- **Change-log still says "commits"** (sec M1, code L, arch L2): change-log and example digest comments say "privately retained (rule 9)".
- **`parameters` lacks the raw cap percentage** (code M): `principal_cap_pct` added; `principal_cap_requests` must reproduce; generator compares raw to raw.
- **`window_id` uniqueness undefined** (code M): 128-bit CSPRNG at open; merge fails closed on one id with two byte representations.
- **Memory bound overclaims** (code M): restated as the traffic-dependent bound plus constant per-window metadata.
- **Incomplete windows had no bounded lifecycle** (arch M1): destroyed at close after a constant-size local close record; AC-INTAKE-4 churn test.
- **Disabled intake vs the nine-key health schema** (arch M2): the `intake` rollup component always runs when stats is enabled (empty windows + fleet histogram); only the aggregator and endpoint are disabled.
- **"Exact response bytes" vs content encoding** (arch M3): `Accept-Encoding: identity`, non-identity encoding rejected, body octets hashed and retained.
- **SPEC-047 column/index names** (code M): `created_at_utc` and `(state, created_at_utc)`.
- **SPEC-047 step-10 test plan lacks failure paths** (code M): enumerated (materialization, staleness, ceiling/timeout, unreadable source, boundaries, auth, method/query, rate limit).
- **Cross-store consistency at build time** (code M, open question): consistency rule stated — offers scanned once, sanctions evaluated after, monotone in the safe direction, pointer swapped once.
- **Public manifest distinguishes sub-k from zero offers** (sec L3): rule 4 — the public manifest never records key-attributable suppression against the v0.10.4 sources; `*_suppressed` always false, suppressed and absent both `no_observations`.
- **Rolling fleet snapshots allow ±1 inference** (sec L1): the `intake` component runs on a 15-minute privacy cadence; §9.2/§9.5/§5.8 updated (budget 45 min).
- **Intake CORS undefined** (sec L2): per-key §5.4.3 Origin decision, never wildcard; AC-INTAKE-2 cases.
- **"Exactly once" wording** (code L, arch L1): "repeatedly but always the same immutable record".
- **Provenance** (arch L3): accepted residual (Q17).

## Anchored loop closed at R3
Per the standing rule the anchored loop stops here; an independent cold-context review (three Claude lanes, neutral prompt, no access to `audits/` or `.omc/`) runs on the FULL `git diff origin/main -- specs/` next, then codex closure passes.
