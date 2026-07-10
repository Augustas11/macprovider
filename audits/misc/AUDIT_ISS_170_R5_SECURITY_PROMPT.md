You are auditing `specs/BUILD_SPEC_004_PILLARS_BCDA_PROMPT.md` from
a SECURITY lens. R4 returned 0/0/0/0 ACCEPT on this lane — R5
re-verifies that the R4 fix-pass (CODE + ARCH edits) did not
introduce any new security gap.

# Repository context

- Branch `spec/004-build-prompt-bcda` in `Augustas11/macprovider`,
  HEAD at commit `cc55003` (R4 fix-pass).
- SPEC-004 v0.3.1 LOCKED; SPEC-005 v0.4, SPEC-006 v0.9.1 on
  origin/main.
- This is a money-path codebase.

# R4 changes to re-audit from a SECURITY lens

- CODE-M1 expanded FR-SR-17 log fields. Verify the expanded set
  does not introduce a leak surface (e.g., the new
  `external_request_id` carries a buyer-supplied header — the log
  should treat it as untrusted; the new `model_params` per
  candidate must not include any provider-side secret).
- ARCH-M3 added Phase A gate tests around
  `X-MacProvider-Internal-Conv` direct-buyer rejection. Verify
  the wording closes the boundary; an implementer must not be
  able to read this as "OK to accept the header in tests".
- ARCH-M4 added `sticky.Map.PurgeAccount(accountID)`. Verify
  this primitive does not open a cross-account purge vector
  (e.g., wrong account_id passed by a hostile caller wiping
  another buyer's sticky map).
- ARCH-M2 made Pillar D quarantine gates concrete. Verify the
  gate forbids ALL writes / route additions / audit emissions —
  is the wording exhaustive?

# Audit scope (SECURITY lens)

- **Sticky source authority (Pillar A).** Re-verify the source-
  authority invariant is hard-closed (no path where a buyer
  header populates the sticky map). The R4 gate tests should
  make this provable.
- **Sticky-map DoS boundary (Pillar A).** Bounded-map, TTL/LRU,
  mutex coverage on all five FR-SR-5 operations. R3's regression
  tests + R4's PurgeAccount addition together cover all five
  operations plus account-scoped purge — verify no operation is
  missing mutex coverage in the API surface.
- **Account-scoped purge (PurgeAccount).** Verify the gate test
  description forbids cross-account purge.
- **Hostile-body invariant (FR-SR-7a — Pillar D).** Unchanged
  from R4; verify no R4 edit weakened it.
- **`X-MacProvider-Retry` budget (FR-SR-14 — Pillar D).** Unchanged.
- **`request_log.retried` write contract (FR-SR-14 — Pillar D).**
  Unchanged.
- **Class-objective score gaming (Pillar D).** Unchanged.
- **FR-SR-17 reproducibility log security.** Re-verify
  `random_seed` mandate (request id + daily key, never
  time.Now()) remains. The expanded field list MUST NOT include
  a field that compromises seed unpredictability.
- **SPEC-005 v0.4 quarantine surface preservation.** The R4-added
  Pillar D gate explicitly forbids writes/route changes/audits —
  verify no other Phase D guidance can be read as overriding
  these forbiddances.

# Severity vocabulary

- **CRITICAL** = money-path security vulnerability.
- **HIGH** = a vulnerability an implementer would likely open.
- **MEDIUM** = precision improvement preventing unlikely-but-
  possible misimplementation.
- **LOW** = wording or framing.

# Output format

For each finding:

```
Location: <heading or topic>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End with `Tally: C/H/M/L`. Goal: sustain 0/0/0/0 ACCEPT. Any HIGH
or MEDIUM blocks merge.

Read the BUILD prompt + SPEC-004 + SPEC-005 v0.4 + SPEC-006 v0.9.1
+ relevant origin/main code before writing any finding. Do not
speculate; cite quotes.
