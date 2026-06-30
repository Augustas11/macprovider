You are auditing `specs/BUILD_SPEC_004_PILLARS_BCDA_PROMPT.md` from
a CODE lens. This is a BUILD prompt — paste-ready instructions for
an implementer LLM session to ship SPEC-004 v0.3.1 Pillars B / C /
D / A in the coordinator.

# Repository context

- Branch `spec/004-build-prompt-bcda` in `Augustas11/macprovider`,
  HEAD at commit `cc55003` (R4 fix-pass).
- R1, R2, R3, R4 audit fix-passes have already landed; THIS round
  verifies the R4 absorptions and surfaces anything new the R4
  edits introduced.
- SPEC-004 v0.3.1 is LOCKED (`specs/SPEC-004-smart-router.md`).
- origin/main current spec versions: SPEC-001 v1.6, SPEC-002
  v1.5.2, SPEC-004 v0.3.1, SPEC-005 v0.4 (PR #257 / commit
  5519d77), SPEC-006 v0.9.1.

# R4 absorbed findings (verify each fix actually landed correctly)

- CODE-M1: FR-SR-17 logging fields expanded to match SPEC-004 §7
  in full (request_id, external_request_id, chosen_peer_id,
  epsilon, epsilon_mode, cohort_size, random_seed, random_draw,
  full candidate_set parallel array with provider_id, assigned_id,
  objective_metric, state, slots, effective_throughput,
  model_params, connected_at, tier per candidate). Verify no
  required field from SPEC-004 §7 is still missing.
- CODE-L1: Top dependency preamble updated to SPEC-006 v0.9.1.
  Verify all SPEC-006 references in the prompt are consistent.

# Audit scope (CODE lens)

For each phase (B / C / D / A) in the BUILD prompt, verify:

- **File-path accuracy.** Every `phase4-coordinator/internal/...`
  path named exists on `origin/main` OR is explicitly declared
  "NEW package, see Phase X". Pay attention to the R4-added
  `sticky.Map.PurgeAccount(accountID)` API surface — does it
  composes correctly with the existing
  `handleInternalStickyDelete` / `purgeStickyAccount` on
  origin/main?
- **R-rule citation completeness.** Every FR-SR-N rule listed per
  phase maps to a named edit.
- **Config-key consistency with SPEC-004 §5.** Verify the R3-added
  Phase D `max_providers_faulted_per_request` default-2 +
  positive-when-max_retries>0 validation is internally consistent.
- **AC citation accuracy.** Verify the R3-added AC-SR-14 staging
  (leg-0 / leg-1 / leg-2 / leg-3-4) is internally consistent.
- **Dependency-version freshness.** SPEC-005 v0.4, SPEC-006
  v0.9.1, SPEC-002 v1.5.2 — verify no stale version mention.
- **Default-config preservation (C2).** Phase B / D / A default
  semantics still hold; the new Phase A "Sticky-disabled
  allocation allowance" remains compatible with the C2 invariant.
- **SPEC-005 v0.4 quarantine surface preservation (Pillar D gate).**
  Verify the R4-rewritten Pillar D gate item (d) is testable:
  "no writes to `ledger_quarantine_resolutions`", "no POST
  force-void route changes", "no new `billing_config_flag_changed`
  audits", AC-Q042/AC-Q045 byte-identity. Are these gates
  concrete enough that a reviewer can refuse a merge?
- **SPEC-006 internal-conv boundary (Pillar A gate).** Verify
  the R4-rewritten gate tests cover the three named cases
  (direct-buyer with internal-conv header but no auth-frame;
  malformed internal conv under valid auth; well-formed under
  valid auth). Is the wording strong enough to refuse merge?
- **FR-SR-17 logging completeness.** Re-verify against SPEC-004
  §7 line-by-line — is any required field still missing?
- **Cross-phase ordering** B → C → D → A still enforced.
- **Test discipline (FR-SR-7a).** Phase D body class tests still
  assert on the body delivered to the provider.

# Severity vocabulary

- **CRITICAL** = money-path-corrupting code.
- **HIGH** = an implementer would likely fill INCORRECTLY.
- **MEDIUM** = precision improvement for predictable convergence.
- **LOW** = wording or framing.

# Output format

For each finding:

```
Location: <heading or topic>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End with `Tally: C/H/M/L`. Goal: 0/0/0/0. Any HIGH or MEDIUM blocks
merge.

Read the BUILD prompt + SPEC-004 + SPEC-005 v0.4 + SPEC-006 v0.9.1
+ relevant origin/main code before writing any finding. Do not
speculate; cite quotes.
