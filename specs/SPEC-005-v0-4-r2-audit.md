# SPEC-005 v0.4 — R2..R5 three-lane codex audit narrative

Continuation of `specs/SPEC-005-v0-4-r1-audit.md`. R1 ran against
the initial v0.4 draft (commit `032d31a`) and produced 0/8/9/3
across the three lenses; R1 fix-pass landed in `b8afc03`.

## R2 (against `b8afc03`)

| Lens | Tally | Notes |
|---|---|---|
| CODE | 0/4/3/0 | 401/403 contradiction, UNIQUE index naming, §11.3 example missing field, settlement-sweep INSERT OR settle |
| SECURITY | 0/1/2/1 | Settlement pause runbook targeted non-existent runner control |
| ARCHITECT | 0/2/1/0 | Pre-payout deferral had no safe correction path; launch gate was advisory |

R2 fix-pass landed in `c54e834`: response-code table, UNIQUE
auto-index, §11.3 field add, sequential sweep order, MUST default-
disabled at route layer with two flags + SPEC-016 503 gate.

## R3 (against `c54e834`)

| Lens | Tally | Notes |
|---|---|---|
| CODE | 0/5/0/0 | 401/403 mismatch with §16.1, AC-Q040 dropped-index reference, settlement-threshold bypass, §13 config flag missing, AC-Q054 flag-flip mismatch |
| SECURITY | 0/1/2/0 | `payout.spec016_enabled` is not the SPEC-016 runner authority |
| ARCHITECT | 0/1/0/0 | Request-time 503 gate misses SPEC-016 activation transitions |

**Structural finding.** The R3 audits converged on a fundamental
issue: v0.4 force-credit is unsafe without the v0.5 pre-payout
hold primitive. SPEC-016 USDC payout consumes
`ledger_payout_ready` rows on the next settlement tick after a
mistaken force-credit; no in-process pause primitive exists. The
route-layer flag + SPEC-016 503 gate were not sufficient to close
the architect-lens finding.

## R3 → R4 scope cut

**Decision:** v0.4 ships force-VOID only. Force-credit + pre-payout
hold + UNIQUE-relaxation for corrective resolutions move to v0.5
as one coordinated design. Pointer: `docs/OPEN_QUESTIONS.md` row
`SPEC-005/OQ-5` flips to PARTIAL.

Force-void produces no money-out — it removes a row from
`quarantined_count` without adding to the payable set. The audit-
discovered risks (mistaken force-credit → SPEC-016 chain payout)
do not apply.

Scope-cut commit: `355006f`.

## R4 (against `355006f`)

| Lens | Tally | Notes |
|---|---|---|
| CODE | 0/0/1/0 | Config-flag audit startup semantics undefined |
| SECURITY | 0/0/1/0 | DICP reject list incomplete (U+00AD, U+180F, U+206A-F, …) |
| ARCHITECT | 0/0/1/0 | v0.5 UNIQUE relaxation needs explorer cardinality scope |

**Zero HIGH across all three lanes** — convergence inflection. R4
fix-pass landed in `711425c`: `reload_source` enum narrowed to
actual reload mechanisms (drop `startup`); Unicode 16.0 DICP
explicit reference list pinned with all DerivedCoreProperties.txt
ranges; v0.5 deferral list extended with SPEC-007 explorer
current-vs-history projection.

## R5 (against `711425c`)

| Lens | Tally | Notes |
|---|---|---|
| CODE | **0/0/0/0 ACCEPT** | clean |
| SECURITY | 0/0/0/1 | LOW: DICP list omits U+E0002..U+E001F (reserved tag range) — fixed inline |
| ARCHITECT | **0/0/0/0 ACCEPT** | clean |

R5 fix-pass adds U+E0002..U+E001F to the DICP reference list per
the SECURITY LOW. All three lanes are at 0 CRITICAL / 0 HIGH /
0 MEDIUM. Per the locked three-lane codex audit convention (user
memory `feedback-three-lane-codex-audits`), v0.4 is converged and
ready to PR.

## Convergence summary

| Round | CODE | SEC | ARCH | Highlight |
|---|---|---|---|---|
| R1 | 0/5/3/0 | 0/1/2/2 | 0/2/4/1 | initial draft; large fix surface |
| R2 | 0/4/3/0 | 0/1/2/1 | 0/2/1/0 | precision + runbook + 503 gate |
| R3 | 0/5/0/0 | 0/1/2/0 | 0/1/0/0 | structural finding — force-credit unsafe |
| R4 | 0/0/1/0 | 0/0/1/0 | 0/0/1/0 | post-scope-cut; only MEDIUMs |
| R5 | **0/0/0/0** | 0/0/0/1 | **0/0/0/0** | LOW absorbed inline; ACCEPT |

R5 SEC LOW (DICP range omission) absorbed in the same fix-pass.
Zero outstanding C/H/M findings.

## Deferred to v0.5 (final list)

- Force-credit endpoint (`POST /admin/ledger/quarantine/{id}/force-credit`)
- Pre-payout hold (default 24h between resolution commit and §7
  sweep eligibility)
- Corrective-resolution rule (lifting `UNIQUE(request_credit_id)`
  during the hold window so a force-credit can be force-voided
  while still correctable)
- SPEC-016 USDC payout interaction normative text
- Settlement-sweep snapshot ordering normative text
- Existing-payout-ready interaction
- Mistaken-resolution operator runbook
- First-class `GET /admin/ledger/quarantine?status=open` list
  endpoint
- SPEC-007 explorer current-vs-history projection

Tracking issue to be filed alongside the v0.4 PR.
