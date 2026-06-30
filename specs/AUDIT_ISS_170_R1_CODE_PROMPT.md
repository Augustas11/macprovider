You are auditing `specs/BUILD_SPEC_004_PILLARS_BCDA_PROMPT.md` from
a CODE lens. This is a BUILD prompt — paste-ready instructions for
an implementer LLM session to ship SPEC-004 v0.3.1 Pillars B / C /
D / A in the coordinator.

# Repository context

- Branch `spec/004-build-prompt-bcda` in `Augustas11/macprovider`.
- The BUILD prompt is the only added normative file (plus this
  audit prompt).
- SPEC-004 v0.3.1 is LOCKED (`specs/SPEC-004-smart-router.md`). The
  BUILD prompt MUST NOT contradict it. Verify by reading
  `specs/SPEC-004-smart-router.md` end-to-end.
- The CODE lens on a BUILD prompt asks: does the implementer
  reading this prompt cold have ENOUGH PRECISE information to
  produce correct, deterministic, SPEC-compliant code?

# Audit scope (CODE lens)

For each phase (B / C / D / A) in the BUILD prompt, verify:

- **File-path accuracy.** Every `phase4-coordinator/internal/...`
  path named exists on `origin/main` OR is explicitly declared
  "NEW package, see Phase X". Stale paths (e.g., a file moved or
  renamed since the BUILD prompt was drafted) produce confusing
  implementer behavior.
- **R-rule citation completeness.** Every FR-SR-N rule listed
  per phase as "implemented in this PR" actually maps to one or
  more concrete code edits the prompt names. A phase that lists
  FR-SR-X but does not name the file/function/test that proves
  it leaves the implementer guessing.
- **Config-key consistency with SPEC-004 §5.** Every config key
  named (e.g., `routing.tiebreak_epsilon`, `routing.max_retries`,
  `routing.sticky_ttl_s`) MUST match SPEC-004 §5 in name, default,
  and validation. Drift here causes config-load failures or
  silent semantic divergence.
- **AC citation accuracy.** Every AC name cited (AC-SR-1
  through AC-SR-16) actually exists in SPEC-004 §8. The prompt
  says e.g. "ACs proven in Phase B: AC-SR-1, AC-SR-4 partial,
  AC-SR-14 partial" — verify each.
- **Dependency-version freshness.** The prompt cites SPEC-001
  v1.3, SPEC-002 v1.5.2, SPEC-005 v0.4, SPEC-006 v0.8.1. Verify
  these are the CURRENT versions on `origin/main`. A stale
  version cite forces the implementer to re-derive the dep
  graph mid-PR.
- **Default-config preservation correctness.** Per C2 in the
  prompt, defaults preserve SPEC-002 v1.3.3 behavior. Does the
  per-phase wiring actually preserve this? Specifically:
  - Phase B: does epsilon=0.0 + randomize=false maintain
    SPEC-002 v1.3.3 connected_at fallback?
  - Phase D: does max_retries=0 actually short-circuit the
    retry loop, or could a coding error make it iterate once?
  - Phase A: does sticky_enabled=false mean ZERO sticky-map
    state allocation, or just "no sticky reads"?
- **SPEC-005 `request_log.retried` write contract.** Per C5 in
  the prompt, the column counts ONLY explicit
  X-MacProvider-Retry-driven attempts. Does the Phase D
  guidance EXPLICITLY tell the implementer NOT to share
  attempt-counter plumbing with F-4 failover?
- **Cross-phase ordering.** B → C → D → A. Does the prompt
  ENFORCE this ordering (e.g., Phase C's filter helper IS
  referenced by Phase D and Phase A — Phase A cannot land
  before Phase C without orphaning the contract)?
- **Test discipline (FR-SR-7a).** Per SPEC-004 FR-SR-7a, every
  class-alias routing test MUST assert on the model field of the
  body delivered to the provider. Does the Phase D guidance
  ECHO this discipline, or does it allow inline mocks that
  silently ignore the body?

# Severity vocabulary

- **CRITICAL** = the BUILD prompt would cause the implementer to
  produce money-path-corrupting code (e.g., a Phase D retry that
  double-emits, a Phase A sticky write that races at the mutex).
- **HIGH** = the BUILD prompt has a gap that the implementer
  would likely fill INCORRECTLY (ambiguous wiring, stale path,
  missing R-rule citation).
- **MEDIUM** = a precision improvement the prompt should ship
  with for predictable convergence.
- **LOW** = wording or framing.

# Output

```
[SEVERITY] <short title>

Location: <heading or topic>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End: `Tally: <C>/<H>/<M>/<L>` or `Tally: 0/0/0/0 ACCEPT`.

Audit the BUILD prompt AS WRITTEN against current `origin/main`
state. Do not invent extra requirements.
