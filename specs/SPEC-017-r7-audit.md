# SPEC-017 v0.1.6 audit report — Round 7 (Codex, 2026-06-25T19:48:02Z)

## Summary

- 0 CRITICAL findings
- 0 MAJOR findings
- 0 MINOR findings
- 0 QUESTIONS

Round 7 focused on v0.1.6's closure of Round 6 findings and a final
lock-target sweep. Round 6 M1 is closed: every insert-capable runtime
role that writes a `BIGSERIAL` table now has the required backing-sequence
privilege where applicable. `stats_rollup` receives
`GRANT USAGE, SELECT ON SEQUENCE stats_late_events_id_seq`, and
`provider_portal` receives
`GRANT USAGE, SELECT ON SEQUENCE provider_visibility_audit_id_seq`.
`partner_keys_id_seq` is explicitly scoped to operator CLI / migration
execution, outside the runtime role inventory, so no runtime role grant is
needed. Round 6 m1 is also closed: AC-13 now requires `OPTIONS` to return
204 only, matching §5.7.

## Category sweep

- **Category A — BUILD-prompt directive fidelity:** no findings. The v0.1
  MUST-pin items are covered by the endpoint wire shapes, rollup schemas
  and cadence, partner-key contract, earnings-visibility storage/audit
  model, hosting/isolation contract, versioning policy, and deterministic
  ACs. The explicit deferrals remain either in §1.3 or §11.
- **Category B — Endpoint contract correctness:** no findings. Overview,
  leaderboard, health, window/sort/limit validation, partner projection,
  exact-nullability, stale-503, CORS, `HEAD`/`OPTIONS`, 304, 405, and the
  closed error vocabulary are coherent.
- **Category C — Earnings visibility model:** no findings. Bucketed
  default, no-row default, opt-in exact, same-Origin uniformity, audit
  rows, consent copy, partner-key broader exposure, and operator override
  direction remain internally consistent.
- **Category D — Hosting and isolation:** no findings. `/v1/stats/*` does
  not collide with SPEC-002 paths; DB role grants and sequence grants are
  mechanically sufficient; connection-pool, recover-middleware, nginx,
  read-replica, and import-graph boundaries are stated as MUSTs where
  required.
- **Category E — Versioning and deprecation:** no findings. `/v1` is the
  only version surface; additive/breaking rules handle reserved enum slots;
  RFC 9745 `Deprecation`, RFC 8594 `Sunset`, and changelog location are
  internally consistent and not a LOCK-time file-existence gate.
- **Category F — Rollup pipeline:** no findings. Table schemas, reward
  source deferral, cadences, late-event correction, all-time reconciliation,
  freshness budgets, failure modes, and cutover backfill all have defined
  contract homes.
- **Category G — Acceptance criteria quality:** no findings. AC-1 through
  AC-21 are contiguous and deterministic; the added ACs beyond the prompt's
  stale AC-16 reference cover partner keys, revoked-key timing,
  provider-visibility defaults, operator exact-mode override, and 405.
- **Category H — Cross-spec invariant preservation:** no findings.
  SPEC-002 mount/path conventions are preserved; SPEC-005 work-dollar math
  and null-usage semantics are not redefined; SPEC-006 header namespace is
  not widened by `X-Stats-Generated-At`; SPEC-014 v0.9 remains a candidate
  UI handoff rather than a lock gate; SPEC-016 v0.1.19 remains pinned while
  rewards-source semantics are deferred to §9.1a/Q13.
- **Category I — Honesty about deferrals:** no findings. The current
  in-repo console mismatch remains explicitly surfaced as §11 Q12 rather
  than hidden as a private endpoint requirement. Other v0.2+ deferrals are
  stated in §1.3 or §11.
- **Category J — Spec hygiene:** no findings. Line-3 version is present;
  the change log remains one-line-per-version with audit narrative in
  round files; dependency versions match current line-3 pins; no literal
  `TBD` appears; the checked-in advisor mirror exists.

## CRITICAL findings

None.

## MAJOR findings

None.

## MINOR findings

None.

## Operator questions surfaced

None beyond the existing §11 open questions.

## Round 6 closure notes

- R6 M1 closed: §7.2.2 lines 1285-1287 grants
  `stats_late_events_id_seq` sequence privileges to `stats_rollup`; §7.2.3
  lines 1309-1311 grants `provider_visibility_audit_id_seq` sequence
  privileges to `provider_portal`; §5.4.1 lines 729-736 documents why
  `partner_keys_id_seq` is operator-CLI/migration-only.
- R6 m1 closed: §10 AC-13 lines 1800-1803 requires `OPTIONS
  /v1/stats/leaderboard` to return 204 only, with no remaining "or 200"
  escape hatch.

## Self-verification

- [x] Read every section of SPEC-017 v0.1.6 (§§1-12, ACs 1-21).
- [x] Compared SPEC-017 against the BUILD prompt's "MUST normatively pin"
      and "MUST explicitly defer" lists. No drift found.
- [x] Walked each Category A through J. Categories with no findings are
      noted explicitly.
- [x] Severity for each finding chosen against the prompt definitions.
      No findings required severity assignment.
- [x] Location included for closure evidence and category conclusions.
- [x] Suggested fix for CRITICAL findings. Not applicable; no CRITICAL
      findings.
- [x] Verdict included below.

## Verdict

- READY TO LOCK

SPEC-017 v0.1.6 meets the round-7 lock target: zero CRITICAL and zero
MAJOR findings. The remaining open items are the spec's own §11 v0.2+
operator questions, not hidden v0.1 blockers.
