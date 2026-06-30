You are auditing `specs/BUILD_SPEC_004_PILLARS_BCDA_PROMPT.md` from
a CODE lens. This is a BUILD prompt — paste-ready instructions for
an implementer LLM session to ship SPEC-004 v0.3.1 Pillars B / C /
D / A in the coordinator.

# Repository context

- Branch `spec/004-build-prompt-bcda` in `Augustas11/macprovider`,
  HEAD at commit `0770e7d` (R3 fix-pass).
- The BUILD prompt is the only normative file under audit. R1, R2,
  and R3 audit fix-passes have already landed; THIS round verifies
  the R3 absorptions and surfaces anything new the R3 edits
  introduced.
- SPEC-004 v0.3.1 is LOCKED (`specs/SPEC-004-smart-router.md`). The
  BUILD prompt MUST NOT contradict it. Verify by reading
  `specs/SPEC-004-smart-router.md` end-to-end.
- origin/main current spec versions to verify: SPEC-001 v1.6,
  SPEC-002 v1.5.2, SPEC-004 v0.3.1, SPEC-005 v0.4 (PR #257 merged
  commit 5519d77), SPEC-006 v0.9.1.

# R3 absorbed findings (verify each fix actually landed correctly)

R3 audit fix-pass at commit `0770e7d` absorbed:

**HIGH:**
- A-H1: Pillar naming ambiguity — verify "Phase-letter regrouping"
  block (line ~23) is unambiguous: an implementer reading it cold
  must understand THIS prompt's Phase B/C/D/A letters are not the
  same as SPEC-004 §11's pillar letters.
- A-H2 / C-H1: Phase B `tiebreak_randomize=true` is no longer
  described as "runtime error if set"; verify Phase B's "SPEC-004
  rules implemented" paragraph and the `internal/config/config.go`
  bullet are mutually consistent (both accept `true` as valid,
  neither activates randomization until Phase D).
- C-H2: FR-SR-17 logging target — verify `internal/routing/log.go`
  (NEW) is named in Phase D Files-touched with explicit field list
  AND its call site is pinned in `internal/buyer/server.go`.

**MEDIUM:**
- A-M1: SPEC-008 §5.7 / SPEC-010 §6.3 additive-only constraint
  now in Phase D body (not just operator notes), with a regression-
  test requirement.
- A-M2: SPEC-005 OQ-5 quarantine-resolution + SPEC-008 hash +
  SPEC-010 cold-supported-model bullets in NOT-cover list.
- C-M1: AC-SR-14 staging — verify it is correctly described as
  "composition gates hold" (SPEC-004 §8) and staged across Phase
  B leg-0 / Phase C leg-2 / Phase D legs 3/4 / Phase A leg-1; the
  per-request breaker fault cap is labeled FR-SR-14 regression
  coverage (NOT AC-SR-14).
- C-M2: SPEC-005 references updated to v0.4; verify no stale
  v0.3.3 references remain.
- C-M3: Phase D MaxProvidersFaultedPerRequest reconcile is
  explicit (default `2`, validation requires positive when
  `routing.max_retries > 0`).

**LOW:**
- S-L1: Sticky bounded-map SECURITY/DoS boundary block in Phase A.
- C-L1: Sticky-disabled allocation allowance (inert construction OK,
  no read/write/sweep/eviction/log-mutation).

# Audit scope (CODE lens)

For each phase (B / C / D / A) in the BUILD prompt:

- **File-path accuracy.** Every `phase4-coordinator/internal/...`
  path named exists on `origin/main` OR is explicitly declared
  "NEW package, see Phase X". Stale paths produce confusing
  implementer behavior. Pay special attention to the newly-added
  `internal/routing/log.go` (NEW) introduced in R3.
- **R-rule citation completeness.** Every FR-SR-N rule listed
  per phase as "implemented in this PR" maps to one or more
  concrete code edits the prompt names.
- **Config-key consistency with SPEC-004 §5.** Every config key
  matches name, default, and validation. Specifically verify:
  - `routing.tiebreak_randomize` Phase B contract (accept true,
    don't activate).
  - `routing.max_providers_faulted_per_request` Phase D contract
    (default 2, positive-when-max_retries>0 validation).
- **AC citation accuracy.** Every AC name cited maps to SPEC-004
  §8. Re-check the AC-SR-14 staging across all four phases is
  internally consistent (leg-0 / leg-1 / leg-2 / leg-3/4) and that
  no phase double-counts.
- **Dependency-version freshness.** Verify SPEC-005 v0.4 is correct
  on origin/main (`specs/SPEC-005-billing.md` line 3 = `Version: 0.4`).
  Verify no stale v0.3.3 or older mentions remain.
- **Default-config preservation correctness.** Per C2 in the
  prompt, defaults preserve SPEC-002 v1.3.3 behavior:
  - Phase B: does epsilon=0.0 + randomize=false maintain SPEC-002
    v1.3.3 connected_at fallback?
  - Phase D: does max_retries=0 actually short-circuit the retry
    loop?
  - Phase A: with the new "Sticky-disabled allocation allowance"
    block, is the allowed-allocation surface clearly bounded?
- **SPEC-005 `request_log.retried` write contract** (C5) is still
  explicit and the v0.4 update did not introduce ambiguity.
- **Cross-phase ordering** B → C → D → A is still enforced.
- **Test discipline (FR-SR-7a).** Phase D class-alias routing tests
  assert on the body delivered to the provider.
- **NEW: FR-SR-17 logging completeness.** The
  `internal/routing/log.go` field list is sufficient for the
  implementer to write a reproducibility regression test (given
  the same request id + daily key, the same candidate set produces
  the same chosen_peer_id).
- **NEW: Sticky-disabled allocation allowance vs AC-SR-1.** Verify
  the C2 invariant + the Phase A clarifier do not contradict each
  other (e.g., AC-SR-1 byte-identity allows allocation OR inert-
  construction; the C2 invariant must not forbid allocation if the
  Phase A clarifier permits it).

# Severity vocabulary

- **CRITICAL** = the BUILD prompt would cause the implementer to
  produce money-path-corrupting code.
- **HIGH** = the BUILD prompt has a gap that the implementer would
  likely fill INCORRECTLY (ambiguous wiring, stale path, missing
  R-rule citation).
- **MEDIUM** = a precision improvement the prompt should ship with
  for predictable convergence.
- **LOW** = wording or framing.

# Output format

For each finding:

```
Location: <heading or topic>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End with:

```
Tally: C/H/M/L
```

Where C = CRITICAL count, H = HIGH count, M = MEDIUM count,
L = LOW count. If you find no findings of a severity, write 0.
Goal: 0/0/0/0 on this round (R4). Any HIGH or MEDIUM finding
blocks merge.

Read the BUILD prompt + SPEC-004 + SPEC-005 v0.4 (verify line 3
header) + SPEC-006 v0.9.1 + relevant origin/main code before
writing any finding. Do not speculate; cite quotes.
