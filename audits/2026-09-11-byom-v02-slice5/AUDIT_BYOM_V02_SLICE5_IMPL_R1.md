# BYOM v0.2 slice 5 IMPL audit — round 1 (2026-09-11)

Reviewed: `git diff origin/main -- phase4-coordinator scripts docs/runbooks specs/CONFORMANCE.json` at `815c8821` plus the two uncommitted files (`cmd/coordinator/main.go`, `internal/config/config.go`). Three codex lanes over `AUDIT_BYOM_V02_SLICE5_IMPL_PROMPT.md`.

| Lane | C | H | M | L | I |
|---|---|---|---|---|---|
| code-reviewer | 0 | 4 | 7 | — | — |
| security-reviewer | 0 | 0 | 5 | 2 | — |
| architect | 0 | 4 | 4 | — | — |

## Findings and dispositions (fixed in the slice-5 fix-pass commit)

- **Raw unmatched model string and account persisted together in `request_log`** (code H, arch H1, sec 1): the unserved-model failure row carries a blank model and a constant message; the aggregator is the string's only consumer. Test: `TestRequestLogModelFieldSanitized` asserts the string is absent from every persisted column.
- **Sanction evaluation has no linearization point; trust evaluated against `clock_timestamp()`; registration custody silently fails open** (arch H4): trust state evaluated at the declared build instant (`ProviderHardwareTrustState(ctx, id, at)`); an issuer wired without custody history is an error (snapshot unavailable, previous retained); eligibility evaluated once per provider after the pair scan as of `generated_at`.
- **Persisted windows bypass the aggregator's emission invariants; nil `WindowEnd` dereference** (code M, sec 2, arch M1): `intake.ValidateWindow` on every persisted and aggregator window; duplicate ids within one set and across sets fail closed; nil end is a contract violation, never dereferenced.
- **Future-dated hardware reports inflate fleet fit** (code M): `last_reported_at <= window_end`.
- **Provider-offer intake ignores `catalog_match_state`** (sec 3) — resolved the other way on SPEC grounds: an offer-time `intake_model_key` resolved against every row/verified artifact names the key, so unadmitted keys are countable; `catalog_match_state` is irrelevant to counting (SPEC-047 R001 v0.1.6 counting rule, R009).
- **Standard catalog `verify` skips intake re-derivation without a previous release** (sec 4, code M): the manifest is validated against the release inputs and retained sources without the previous release; only the transition rule needs it.
- **Intake source parsing not closed; window selection compares timestamps lexically** (sec 5, code M): closed `methodology`; one timestamp form (`YYYY-MM-DDTHH:MM:SSZ`) enforced so lexical order equals chronological order; exact 30-day windows; ≤ 3 windows; fleet reconciliation.
- **Configured memory bounds and cap arithmetic have no upper limits** (sec 6): maxima in `intake.Params.Validate` and `config`; `principal_cap_pct` ≤ 10.
- **Raw principal lifetime asserted, not shortened** (sec 7, L): token derived before any state mutation; the account id is cleared immediately after.
- **Offer-pairs scan unbounded by event volume; window predicate not inclusive at second granularity** (code H, arch H): DISTINCT `(provider, intake_model_key)` scan with second-truncated inclusive bounds on both stores; pair ceiling; index `(state, created_at_utc)`.
- **Eligibility policy id not reproducible** (arch H): HMAC under `stats.intake.policy_salt` (see the SPEC independent record).
- **Intake path never routable through the stats mux** (found while fixing AC-INTAKE-2): `trimEndpointFromPath` lacked `intake`; added with a mux-level test (`TestIntakeEndpointRoutedThroughMuxRequiresPartnerKey`) — a key-less GET answers 401, never 404, and never consults the public tier.
- LOW: log-line wording, comment drift — applied inline.
