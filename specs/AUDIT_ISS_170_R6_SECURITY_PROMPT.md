You are auditing `specs/BUILD_SPEC_004_PILLARS_BCDA_PROMPT.md` from
a SECURITY lens. SEC has been at 0/0/0/0 ACCEPT for two consecutive
rounds (R4 + R5). R6 re-verifies that the R5 fix-pass did not
introduce any new security gap.

# Repository context

- Branch `spec/004-build-prompt-bcda`, HEAD at commit `2185f9d`
  (R5 fix-pass). SPEC-004 v0.3.1 LOCKED. Origin/main: SPEC-005
  v0.4, SPEC-006 v0.9.1.

# R5 changes to re-audit from a SECURITY lens

- Sticky API now carries accountID through `Update`. Verify:
  - accountID source is hard-pinned to gateway-authenticated
    X-MacProvider-Account (no direct-buyer fallback).
  - PurgeAccount cannot be tricked into cross-account purge.
- FR-SR-17 log field list expanded to full §7 surface. Verify the
  new fields do not leak secrets (e.g., `model_params` per
  candidate must not include provider auth tokens; `x_request_id`
  is buyer-untrusted and must be treated as such; `random_seed`
  remains derivable from request id + daily key, never time.Now).
- C2 anchor reword (v1.5.2 / origin/main). Verify no security-
  relevant default got loosened.

# Audit scope (SECURITY lens)

- Sticky source authority (Pillar A): hard-closed (no buyer-
  header sticky-write path).
- Sticky-map DoS boundary (Pillar A): bounded, mutex-covered, all
  six operations now (PurgeAccount added in R4).
- Hostile-body invariant (FR-SR-7a): unchanged.
- X-MacProvider-Retry budget (FR-SR-14): unchanged.
- request_log.retried write contract: unchanged; the new `retried`
  log field is the same as the column write contract.
- Class-objective score gaming: unchanged.
- FR-SR-17 reproducibility log security: random_seed remains
  attacker-unpredictable; the expanded surface introduces no leak.
- SPEC-005 v0.4 quarantine surface preservation: unchanged.

# Severity vocabulary

CRITICAL / HIGH / MEDIUM / LOW per prior rounds.

# Output format

```
Location: <heading or topic>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End with `Tally: C/H/M/L`. Goal: sustain 0/0/0/0 ACCEPT.

Read the BUILD prompt + SPEC-004 + SPEC-005 v0.4 + SPEC-006 v0.9.1
+ relevant origin/main code before writing any finding. Do not
speculate; cite quotes.
