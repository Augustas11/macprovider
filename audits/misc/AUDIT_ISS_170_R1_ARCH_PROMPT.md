You are auditing `specs/BUILD_SPEC_004_PILLARS_BCDA_PROMPT.md` from
an ARCHITECT lens. This is a BUILD prompt — paste-ready instructions
for an implementer LLM session to ship SPEC-004 v0.3.1 Pillars B / C
/ D / A in the coordinator.

# Repository context

- Branch `spec/004-build-prompt-bcda` in `Augustas11/macprovider`.
- The BUILD prompt is the only file added.
- SPEC-004 v0.3.1 is LOCKED (`specs/SPEC-004-smart-router.md`).
- Existing BUILD-prompt templates: `specs/BUILD_SPEC_001_v1_3_PROMPT.md`,
  `specs/BUILD_PHASE5_PROMPT.md` — these are the style baseline.

# Audit scope (ARCHITECT lens)

A BUILD prompt is a contract between the SPEC corpus and an
implementer LLM session. The questions are:

1. **Scope clarity.** Will the implementer reading the prompt cold
   know exactly what is in scope and what is out? Are the four
   pillar boundaries (B / C / D / A) crisp?

2. **Sequencing rationale.** B → C → D → A is the proposed order.
   Is the rationale (Pillar A depends on epsilon-cohort hooks from
   B/C/D) defensible? Would D → B → C → A be safer? Is the
   prompt's sequencing argument adequate?

3. **Dependency completeness.** SPEC-001 v1.3, SPEC-002 v1.5.2,
   SPEC-005 v0.4, SPEC-006 v0.8.1 are cited. Is anything material
   missing? Are any cited dependencies stale (e.g. SPEC-002 is
   actually v1.5.2 not v1.5.1; verify)?

4. **Default-config preservation.** The prompt makes C2 ("SPEC-002
   v1.3.3 default behavior byte-identical") a non-negotiable.
   Does the per-phase wiring actually preserve this? Specifically,
   does Phase B's tiebreak landing at epsilon=0.0 actually
   maintain the SPEC-002 v1.3.3 connected_at fallback?

5. **Per-pillar audit discipline.** Three-lane codex audit per
   pillar PR. Is this discipline ADEQUATE for the money-path
   surface (Pillar D writes `request_log.retried`; Pillar A
   touches the routing decision that flows into SPEC-007 explorer
   audit log)?

6. **Composition with downstream specs.** Does the prompt
   adequately address: SPEC-005 v0.4 `retried` column write
   contract, SPEC-007 explorer `routing_decision` log inclusion,
   SPEC-008 Pillar A hash_block interaction (per SPEC-010 v1.5
   §6.3)?

7. **What this prompt does NOT cover.** The prompt's "What this
   prompt does NOT cover" section names: v0.4 amendments, operator
   green-light, provider-binary changes, gateway derivation. Is
   that list complete? Any other obvious deferral?

8. **Operator notes section.** The non-implementer notes at the
   bottom — are they accurate? Are the "what changes if X" cases
   reasonable, or do they invite scope expansion?

# Severity vocabulary

- **CRITICAL** = the BUILD prompt as written would cause the
  implementer to produce wrong / broken / money-path-corrupting
  code.
- **HIGH** = the BUILD prompt has a gap that the implementer would
  likely fill INCORRECTLY (e.g., ambiguous wiring decision).
- **MEDIUM** = a structural improvement the prompt should ship
  with for predictable convergence.
- **LOW** = wording or framing.

# Output format

```
[SEVERITY] <short title>

Location: <heading or topic>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End: `Tally: <C>/<H>/<M>/<L>` or `Tally: 0/0/0/0 ACCEPT`.

Audit the BUILD prompt AS WRITTEN. Do not invent extra requirements
the prompt isn't claiming.
