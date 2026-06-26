# SPEC-017 v0.1.7 audit report — Round 8 (Codex, 2026-06-26T04:40:36Z)

## Summary

- 0 CRITICAL findings
- 0 MAJOR findings
- 0 MINOR findings
- 0 QUESTIONS

Round 8 audited the just-committed v0.1.7 fix pass on top of locked
v0.1.6. The review focused on the Claude adversarial/product findings
absorbed in v0.1.7: browser CORS semantics, public-cache fragmentation,
public exact-dollar correlation leaks, `partial_history_since`, origin
rejection timing, split timeseries health components, cumulative-vs-windowed
semantics, `stats_late_events` retention, RFC 6454 normalization, rebuild
atomicity, bucket rounding, preflight max-age, partner-projection launch
sequencing, `rewards_populated`, and removal of per-axis buckets.

## Category sweep

- **Category A — BUILD-prompt directive fidelity:** no findings. The
  endpoint wire shapes, rollup tables/cadence, partner-key lifecycle,
  earnings visibility storage/audit model, hosting/isolation clauses,
  versioning policy, and explicit deferrals remain covered. v0.1.7's
  launch-sequencing gate for production partner-key issuance is an
  implementation/runtime precondition, not a SPEC-017 lock gate.
- **Category B — Endpoint contract correctness:** no findings. The overview
  schema remains internally consistent at 14 `network.*` fields, matching
  the v0.1.6 locked lineage and AC-1. The leaderboard public projection
  strips public `totals.earnings_*`, keeps `exact_earnings` always present,
  adds `partial_history_since` and `meta.rewards_populated` with clear
  presence rules, and keeps the partner-key projection additive.
- **Category C — Earnings visibility model:** no findings. Bucketed remains
  the default for providers with no `provider_visibility` row; public exact
  earnings require provider opt-in; same-origin behavior is uniform; the
  partner-key exact-dollar exposure is explicitly disclosed and launch-gated;
  operator exact-mode overrides remain mechanically forbidden.
- **Category D — Hosting and isolation:** no findings. `/v1/stats/*` does
  not collide with SPEC-002 paths; DB role boundaries remain separated;
  the v0.1.7 additions do not put reward-ledger or billing/session OLTP
  reads on the request path; recover middleware, nginx, and import-graph
  boundaries remain checkable.
- **Category E — Versioning and deprecation:** no findings. `/v1/stats/*`
  remains the only version surface; additive/breaking rules still distinguish
  bucket-value additions from threshold changes; RFC 9745 `Deprecation` and
  RFC 8594 `Sunset` examples are internally consistent.
- **Category F — Rollup pipeline:** no findings. v0.1.7 closes the previous
  ambiguity around independent RPM/TPM health, cumulative overview totals,
  late-event retention, atomic nightly rebuilds, and public rewards
  availability signaling without introducing a new request-path dependency.
- **Category G — Acceptance criteria quality:** no findings. AC-1 through
  AC-21 are contiguous and deterministic. v0.1.7 extends AC coverage for
  public earnings-total absence, revoked/rejected-origin timing equivalence,
  `provider_visibility` no-row defaults, and 405 behavior.
- **Category H — Cross-spec invariant preservation:** no findings.
  SPEC-002 v1.4 mount/path conventions are preserved; SPEC-005 v0.3 work
  dollar arithmetic and null-usage handling are not redefined; SPEC-006 v0.9
  envelope mismatch is explicitly disclaimed; SPEC-014 v0.9 remains a
  candidate UI/disclosure handoff; SPEC-016 remains pinned at v0.1.19 while
  rewards-source semantics stay deferred to §9.1a/Q13.
- **Category I — Honesty about deferrals:** no findings. The canonical UI
  consumer remains a Q12 follow-up, Q11 honestly says the partner-projection
  opt-out column is a v0.1.7 stub not consumed by v0.1 rollup, and Q13 keeps
  rewards source semantics outside v0.1.
- **Category J — Spec hygiene:** no findings. Line 3 carries the v0.1.7
  version of record; the dependency versions match current line-3 pins;
  audit narrative remains in per-round files; no literal `TBD` appears in
  SPEC-017; the checked-in advisor mirror exists at
  `specs/SPEC-017-advisor-round-2026-06-25.md`.

## CRITICAL findings

None.

## MAJOR findings

None.

## MINOR findings

None.

## Operator questions surfaced

None beyond the existing §11 open questions.

## v0.1.7 closure notes

- H1 closed: §5.7 rows 3-5 and §5.2 partner headers no longer allow
  `Access-Control-Allow-Origin: *` on the credentialed partner projection.
- H2 closed: §5.2 public 200 responses use `Vary: Accept-Encoding, Origin`;
  only the private partner projection varies on `Authorization`.
- H3 closed: §5.2 public `totals` contains only `tokens`, `jobs`, and
  `active_accounts`; AC-6 rejects public `totals.earnings_*`.
- H4 closed: `partial_history_since` has a schema home in §5.2 and emission
  rules in §9.7.
- H5 closed: §5.4.3 rule 4 and AC-18 require equivalent hash+SELECT work on
  no-row, revoked, and rejected-origin 401 paths.
- M1-M7 closed: timeseries health split, cumulative/windowed semantics,
  late-event retention, RFC 6454 normalization, rebuild atomicity, bucket
  rounding, and preflight `Max-Age` are pinned in the relevant sections.
- Designer findings closed: partner exact-dollar exposure is disclosure- and
  launch-gated in §6.6.2; `meta.rewards_populated` is required in §5.2; the
  public per-axis buckets are removed from §5.2/§6.2/§9.1.

## Self-verification

- [x] Read every section of SPEC-017 v0.1.7 (§§1-12, ACs 1-21).
- [x] Compared SPEC-017 against the BUILD prompt's "MUST normatively pin"
      and "MUST explicitly defer" lists. No new v0.1.7 drift found.
- [x] Walked each Category A through J. Categories with no findings are
      noted explicitly.
- [x] Severity for each finding chosen against the prompt definitions. No
      findings required severity assignment.
- [x] Location included for closure evidence and category conclusions.
- [x] Suggested fix for CRITICAL findings. Not applicable; no CRITICAL
      findings.
- [x] Verdict included below.

## Verdict

- READY TO LOCK

SPEC-017 v0.1.7 meets the round-8 lock target: zero CRITICAL, zero MAJOR,
zero MINOR, and zero additional QUESTIONS. The v0.1.7 fix pass absorbs the
Claude adversarial/product findings without creating a new v0.1 blocker.
