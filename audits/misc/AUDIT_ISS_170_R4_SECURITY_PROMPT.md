You are auditing `specs/BUILD_SPEC_004_PILLARS_BCDA_PROMPT.md` from
a SECURITY lens. This is a BUILD prompt — paste-ready instructions
for an implementer LLM session to ship SPEC-004 v0.3.1 Pillars B /
C / D / A in the coordinator (money path).

# Repository context

- Branch `spec/004-build-prompt-bcda` in `Augustas11/macprovider`,
  HEAD at commit `0770e7d` (R3 fix-pass).
- SPEC-004 v0.3.1 is LOCKED (`specs/SPEC-004-smart-router.md`).
- origin/main current spec versions: SPEC-001 v1.6, SPEC-002
  v1.5.2, SPEC-004 v0.3.1, SPEC-005 v0.4, SPEC-006 v0.9.1.
- This is a money-path codebase (provider billing, payouts,
  routing). SECURITY findings on the build prompt directly map to
  SECURITY findings on the eventual IMPL.

# R3 security-relevant absorbed findings (verify each fix landed)

- S-M1: Phase A sticky-lifecycle ACs — verify the four gating
  regression tests (bounded-map LRU eviction, TTL expiry under
  synthetic clock, concurrent mixed-op race, InvalidateClass under
  concurrent reads) are explicit and labeled as gating, not
  optional.
- S-L1: "Sticky bounded-map SECURITY / DoS boundary" block in
  Phase A — verify it explicitly names the cap as release-blocker
  territory.
- C-L1: Sticky-disabled allocation allowance — verify it does NOT
  open a side-channel that re-enables sticky reads/writes when
  `sticky_enabled=false`.

# Audit scope (SECURITY lens)

For each phase, verify the BUILD prompt's invariants close every
HIGH-blast-radius failure mode an implementer could realistically
introduce:

- **Sticky source authority (Pillar A).** The prompt's "Sticky
  source invariant" block forbids any buyer-supplied header from
  populating the sticky map. Verify the wording is strong enough
  that an implementer cannot read it as "but if the gateway is
  bypassed in test mode it's OK" — the path MUST be hard-closed
  even on direct-buyer-traffic paths.
- **Sticky-map DoS boundary (Pillar A).** With the R3 SECURITY/DoS
  boundary block in place, verify:
  - bounded-map eviction is explicit at `routing.sticky_max_entries`;
  - mutex coverage spans ALL five FR-SR-5 operations (read, write,
    `last_used_at` update, TTL expiry, LRU eviction);
  - `InvalidateClass` is mutex-serialized with active reads;
  - the new four regression tests are gating, not optional.
- **Sticky-disabled allocation allowance (Pillar A C2).** Verify
  the wording "request handling MUST perform no sticky read, no
  sticky write, no `last_used_at` update, no TTL expiry sweep, no
  LRU eviction, and no sticky-log mutation" is exhaustive — no
  other sticky operation (e.g., a metrics tick, a config-snapshot
  read) can leak when the flag is off.
- **Hostile-body invariant (FR-SR-7a — Pillar D).** The body's
  top-level `model` field is buyer input. Duplicate / case-variant
  keys MUST be rejected BEFORE candidate selection. Verify the
  prompt's wording is strong enough that an implementer cannot
  re-use the post-rewrite `model` for selection (which would let
  a buyer forge the routing decision).
- **`X-MacProvider-Retry` budget (FR-SR-14 — Pillar D).** Verify
  the per-request breaker fault cap is described with explicit
  abort + return semantics, and the FR-SR-14 (NOT AC-SR-14)
  re-labeling is consistent everywhere.
- **`request_log.retried` write contract (FR-SR-14 — Pillar D).**
  Verify the prompt forbids sharing attempt-counter plumbing with
  F-4 one-shot failover; verify the v0.4 update note does not
  weaken this.
- **Class-objective score gaming (Pillar D).** Verify the
  `balanced` score formula's component-level logging requirement
  is explicit (so an attacker spiking one component to dominate
  selection is detectable in logs).
- **FR-SR-17 reproducibility log security.** The new
  `internal/routing/log.go` random_seed field MUST be derivable
  from `request id + daily key`, NEVER from `time.Now()` alone.
  Verify this is mandatory wording — an implementer using
  `time.Now()` would make routing decisions non-reproducible AND
  potentially predictable to an attacker.

# Severity vocabulary

- **CRITICAL** = the BUILD prompt would cause the implementer to
  produce a money-path security vulnerability (sticky-key
  steal, retry budget bypass, double-emit, log forgery).
- **HIGH** = a gap an implementer would likely fill in a way that
  opens a vulnerability (ambiguous source authority, missing
  invariant statement, race-window not closed).
- **MEDIUM** = a precision improvement that prevents an unlikely-
  but-possible misimplementation.
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

Goal: 0/0/0/0 on R4. Any HIGH or MEDIUM finding blocks merge.

Read the BUILD prompt + SPEC-004 + SPEC-005 v0.4 + SPEC-006 v0.9.1
+ relevant origin/main code before writing any finding. Do not
speculate; cite quotes.
