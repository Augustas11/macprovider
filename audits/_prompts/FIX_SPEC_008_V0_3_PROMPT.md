# Fix prompt — SPEC-008 v0.3

Operator-paste prompt that produces **SPEC-008 v0.3** by resolving every
finding from the Round 2 audit report (`specs/SPEC-008-audit.md`).

Round 2 found 1 CRITICAL, 4 MAJOR, 5 MINOR, and 2 QUESTIONS. The CRITICAL
is a one-line self-contradiction inside AC-T2-5 (introduced by the v0.2 fix
pass itself). No architectural reopening is required. The verdict was
**READY WITH FIX PASS**.

**Before running this prompt, the operator MUST answer q1 and q2 below.**
Those answers determine the exact wording of the M1 and M2 fixes. Record
them in the session invocation.

Run in **Codex** or **Claude Code**. Expected duration: ~1-2 hours.
Input: `specs/SPEC-008-tier2.md` (v0.2). Output: same file, bumped to v0.3.
No code is written; this is a spec revision session.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

## Operator pre-flight: answer these before running

**q1 — Disclosure version string policy.**
When should `tier1_disclosure.version` bump from `"v0.8"` to a Tier-2 string?

- **Option A (recommended):** Bump only when §4.3 permits Tier-2 response
  changes (catalog_path set, a require_* true, or observe_enabled true).
  Default-config deployments keep `"v0.8"` for byte-identity.
- **Option B:** Always bump once a SPEC-008 binary is deployed, regardless
  of config. Breaks AC-T2-5's byte-identity guarantee and §13.2's prose.

Record the choice as `q1=A` or `q1=B` in your session prompt.
*(Option A is required to satisfy §13.2 and AC-T2-5; Option B requires
reopening both. Option A is the expected answer.)*

**q2 — `"enforced"` disclosure semantics.**
What does `untrusted_provider_safety: "enforced"` claim to a buyer?

- **Option A (config state):** All three Pillar D controls are configured on.
  Rename the value to `"all_controls_enabled"` to make semantics explicit.
- **Option B (upgrade §8.5):** Upgrade TTFT anomaly logging from SHOULD to
  MUST when `response_time_anomaly_enabled: true`, making `"enforced"` a
  truthful hard-enforcement claim.
- **Option C (annotated guarantee):** Keep `"enforced"` but add a normative
  note that it means "size cap + encoding validation enforced; TTFT anomaly
  logging enabled (best-effort signal)." No name change; no §8.5 upgrade.

Record the choice as `q2=A`, `q2=B`, or `q2=C` in your session prompt.

---

```
=== BEGIN PROMPT ===

You are revising SPEC-008 v0.2 to produce v0.3.

Input:  /Users/augstar/macprovider-poc/specs/SPEC-008-tier2.md
Audit:  /Users/augstar/macprovider-poc/specs/SPEC-008-audit.md  (Round 2)
Output: same file, in-place.  Bump version header to 0.3 and add a v0.3
change-log entry listing every finding ID resolved (C1, M1-M4, m1-m5).

You are NOT redesigning the spec.  The four-pillar structure, phase order,
Tier-1 default-preservation rule, clean-room constraint, and survivability
certificate all stand.  Fix precisely what Round 2 found; do not expand
scope, reorganize sections, or touch text not called out below.

Before starting: read the full Round 2 section of specs/SPEC-008-audit.md
(section "Round 2 (Claude, 2026-05-31...)").  Understand each finding and
its suggested fix before writing a single character of the spec.

Also read (focus sections only):
- /Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md  §5.3.1
  (the locked tier1_disclosure baseline — confirms which fields belong
  to the SPEC-006 baseline and which are additive Tier-2 fields)
- /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md  §3, §6.2
  (verify §2 citations before touching them)

The operator has answered q1 and q2 above.  Apply the chosen options
exactly as specified.

Work finding-by-finding in the order below.  After all fixes, do one final
pass to confirm internal cross-references and AC numbering are still
consistent.

---

## CRITICAL fix (must land before Phase 1 BUILD)

### C1 — AC-T2-5 forbids `tier2_milestone`, a locked SPEC-006 baseline field

**Audit location:** §14 AC-T2-5; SPEC-006 v0.8.1 §5.3.1.

**What is wrong:** AC-T2-5 says "no Tier-2 fields (`hash_verified`,
`hash_verification`, `attested`, `attestation`, `tier2_session`,
`tier2_milestone`) appear in any response" under default config. But
`tier2_milestone: "future"` is a mandatory field of the SPEC-006 v0.8.1
`tier1_disclosure` baseline (§5.3.1 operator override forbidden). The
two AC-T2-5 clauses are mutually exclusive: a response cannot be
byte-identical to the SPEC-006 baseline while also omitting
`tier2_milestone`. An implementation that passes the AC literally strips a
locked baseline field on binary upgrade — the opposite of the AC's intent.

**Required fix:**

Remove `tier2_milestone` from the forbidden-field list in AC-T2-5. It
belongs to the Tier-1 baseline, not the Tier-2 evidence layer.

Restate AC-T2-5 using an explicit allowlist-plus-denylist pattern:

  AC-T2-5: Default Tier-1 behavior preservation

  With every `tier2.*` key at its default value, no `catalog_path`, no
  `observe_enabled: true`, and a Tier-1 provider pool:

  - Provider selection is unchanged from Tier-1 behavior.
  - The `tier1_disclosure` block in `/v1/models` contains EXACTLY the
    SPEC-006 v0.8.1 baseline keys — `version: "v0.8"`, `plaintext_to_
    provider`, `model_identity`, `hardware_attestation`, `tier2_milestone`,
    `sticky_affinity` — and NONE of the additive Tier-2 keys
    (`model_hash_verified`, `provider_leg_encryption`,
    `untrusted_provider_safety`, `tier2`).
  - The `version` string is unchanged from `"v0.8"`. [Apply q1 answer
    to confirm the bump condition.]
  - No `hash_verified`, `hash_verification`, `attested`, `attestation`,
    or `tier2_session` fields appear in any response.
  - No `T2.*` audit or log events are emitted.
  - `/v1/chat/completions` response bytes are identical to the Tier-1
    baseline.

The six fields formerly in the forbidden list become: `hash_verified`,
`hash_verification`, `attested`, `attestation`, `tier2_session` (five,
not six — `tier2_milestone` removed).

---

## MAJOR fixes (Phase 1 blocking: C1 and M1 must land together)

### M1 — §13.2 prose claims byte-identical default but the example beneath it is NOT byte-identical to the SPEC-006 baseline

**Audit location:** §13.2 (disclosure block JSON example).

**What is wrong:** §13.2 states "With default config, the disclosure block
MUST remain byte-identical to the SPEC-006 Tier-1 baseline." The JSON
example immediately following sets `"version": "v0.8+tier2-v0.2"` and
shows the full additive `tier2` object, `model_hash_verified`,
`provider_leg_encryption`, and `untrusted_provider_safety` fields. The
example is unlabeled. Two implementers will diverge on whether this is
the default render or the active render.

**Required fix:**

Split the §13.2 example into two clearly labeled blocks:

**Block 1 — Default-config render (byte-identical to SPEC-006 baseline):**

```json
{
  "tier1_disclosure": {
    "version": "v0.8",
    "plaintext_to_provider": true,
    "model_identity": "provider_reported",
    "hardware_attestation": "none",
    "tier2_milestone": "future",
    "sticky_affinity": {
      "enabled": false,
      "ttl_seconds": 0,
      "description": "Sticky affinity is disabled; related requests are not preferentially routed to the same provider."
    }
  }
}
```

Label this: *"Default-config render — byte-identical to SPEC-006 v0.8.1
baseline. No Tier-2 keys present. `version` string unchanged."*

**Block 2 — Active-state render (when §4.3 permits Tier-2 response changes):**

Keep the existing example (with `"v0.8+tier2-v0.2"`, `model_hash_verified`,
`provider_leg_encryption`, `untrusted_provider_safety`, and the full `tier2`
sub-object).

Label this: *"Active-state render — only when catalog_path is non-empty,
any require_* key is true, or observe_enabled: true. `version` string bumps
to reflect active Tier-2 state."* [Apply q1 answer — if q1=A, confirm
`version` bumps only under §4.3 conditions; if q1=B, note the version always
bumps and update §13.2's prose + AC-T2-5 accordingly.]

Add a sentence after the split: "`version` MUST remain `"v0.8"` unless
§4.3 permits Tier-2 response changes."

---

### M2 — `"enforced"` disclosure overstates §8.5 TTFT logging (SHOULD, not MUST)

**Audit location:** §8.6 flag precedence matrix + closing paragraph; §8.5;
§13.3 `untrusted_provider_safety` values.

**What is wrong:** §8.6 maps (size cap > 0, encoding on, TTFT on) to
`untrusted_provider_safety: "enforced"`. But §8.5 says "the coordinator
SHOULD log a WARN audit event" for TTFT anomaly — a best-effort signal, not
hard enforcement. The non-overrideable disclosure value `"enforced"` implies
a hard guarantee that §8.5 does not provide, which violates §1.4's north-star.

**Required fix — apply q2 answer:**

- **If q2=A:** Rename `"enforced"` to `"all_controls_enabled"` in §8.6,
  §13.3, and all references. Update the §8.6 closing paragraph. Update
  AC-T2-21 to reference `"all_controls_enabled"`. No §8.5 change needed.

- **If q2=B:** In §8.5, upgrade the TTFT anomaly log line from:
  "the coordinator SHOULD log a WARN audit event"
  to:
  "the coordinator MUST log a WARN audit event at T2.D when
  `response_time_anomaly_enabled: true`"
  Keep the existing sentence that the coordinator SHOULD NOT reject
  solely for TTFT. This makes `"enforced"` truthful as a hard-enforcement
  claim for the logging obligation. No name change needed.

- **If q2=C:** Keep `"enforced"` and add a parenthetical to the §8.6
  closing paragraph: "`"enforced"` means size cap and encoding validation
  are hard-enforced; TTFT anomaly logging is a best-effort WARN signal
  that does not reject responses." No §8.5 change. No name change.

---

### M3 — §11.2 startup validation gates on the helper key, not the active cap key

**Audit location:** §11.2 (startup failure conditions for Pillar D).

**What is wrong:** The §11.2 validation rule:
  "Startup MUST fail when `behavioral_safety_enabled: true` and
   `default_output_size_cap_bytes <= 0`"
references `default_output_size_cap_bytes` (a non-binding operator helper,
default 1048576) rather than `output_size_cap_bytes` (the key that actually
activates the size-cap control, default 0). Per §8.3, `behavioral_safety_
enabled: true` with `output_size_cap_bytes: 0` is explicitly valid (size cap
disabled, framework enabled). The rule inspects the inert helper key and
cannot fire against a misconfigured active cap.

**Required fix:**

Replace the Pillar D startup failure rule with:

  "Startup MUST fail when:
   - `output_bytes_per_token_ceiling <= 0`.
   - `default_output_size_cap_bytes <= 0` (helper must be sane if operator
     uses it for cap selection).
   - `behavioral_safety_enabled: true` and `encoding_validation_enabled:
     true` and `output_size_cap_bytes < 0` (negative cap is nonsensical;
     zero is valid per §8.3 and means size-cap control disabled)."

Remove the rule `behavioral_safety_enabled: true and
default_output_size_cap_bytes <= 0` from the startup-failure list.

Add a note: "`output_size_cap_bytes: 0` with `behavioral_safety_enabled:
true` is valid — the size-cap control is disabled while the Pillar D
framework is active (§8.3 matrix row 2)."

---

### M4 — `hardware_attestation` none vs unsupported boundary is undefined for the not-required-but-present case

**Audit location:** §7.7 per-model `attested` values; §13.3
`hardware_attestation` top-level values; §13.2 default example.

**What is wrong:** §7.7 maps "every routable provider is unsupported OR
not required" to `attested: "unsupported"`. §13.3 offers both `"none"` and
`"unsupported"` for `hardware_attestation`. The spec never says which value
applies when Pillar C observation is active, `require_attestation: false`,
and providers present no token. Both `"none"` and `"unsupported"` are
plausible. The disclosure is non-overrideable and must be mechanically
derivable; two implementations will diverge.

**Required fix:**

After §13.3's `hardware_attestation` value definitions, add an explicit
derivation truth table:

| Pillar C active? | require_attestation | Pool attested / unsupported / failed | hardware_attestation |
|---|---|---|---|
| No (default config) | false | any | `"none"` |
| Yes (observe or enforce) | false | all unsupported or no token | `"unsupported"` |
| Yes | false | mixed (some attested, some not) | `"partial"` |
| Yes | false | all attested | `"all"` |
| Yes | true | all attested | `"all"` |
| Yes | true | any failed/stale/unsupported | `"partial"` or `"none"` per count |

Where "Pillar C active" means: `require_attestation: true`, OR
`observe_enabled: true`, OR an attested provider exists in pool.

The key rule to normalize: `"none"` applies only under default-config
(Pillar C not active). Once observation is active, `"unsupported"` is
the floor (not `"none"`), and providers presenting no token are counted
as `"unsupported"`, not `"none"`.

---

## MINOR fixes (fold into same pass)

### m1 — §2 cites SPEC-006 section numbers that do not exist in v0.8.1

**Audit location:** §2.1 (cites "SPEC-006 §1.3 and SPEC-006 §F-1.5");
§2.3 (cites "SPEC-006 §5.3.4").

**Fix:** In §2.1 replace "SPEC-006 §1.3 and SPEC-006 §F-1.5" with
"SPEC-006 §1.3 (the F-1.5 survivability clause)".

In §2.3 replace "SPEC-006 §5.3.4" with "SPEC-006 §1.3 (DELETE /v1/sticky
definition)".

Do not change the substance of either invariant argument — only the
citation labels are wrong.

---

### m2 — §6.5.2 and §10.7 are missing the symmetry note for p2c AAD

**Audit location:** §6.5.2 response AAD; §10.7 encrypted chunk example.

**Fix:** At the end of §6.5.2 add one sentence:
"Both c2p and p2c AAD authenticate `provider_id`, `assigned_id`,
`request_id`, `seq`, and `direction` so both parties commit to identical
associated data for every frame."

In §10.7 add a comment inline with `enc.aad`:
`// aad: base64url-canonical p2c AAD per §6.5.2 (direction: "p2c")`

---

### m3 — Helper keys `output_bytes_per_token_ceiling` and `default_output_size_cap_bytes` are easy to confuse with the active cap key

**Audit location:** §11.1 config YAML block.

**Fix:** In the §11.1 config block add inline comments next to these keys:
```yaml
  output_bytes_per_token_ceiling: 16    # helper only — never activates enforcement
  default_output_size_cap_bytes: 1048576 # helper only — never activates enforcement
```

In §8.3 where the helpers are mentioned ("Implementations MAY use
`request.max_tokens * tier2.output_bytes_per_token_ceiling` or
`tier2.default_output_size_cap_bytes` to choose an operator-recommended
cap"), append: "These helper values MUST NOT activate the size-cap control
while `output_size_cap_bytes` remains `0`." (This sentence already exists
in v0.2; verify it is present and not removed by M3's fix above.)

---

### m4 — Shadow mode is referenced four times without being marked out of normative scope

**Audit location:** §9.3, §11.4, §12.5, §15.4.

**Fix:** In §9.3 where shadow mode is mentioned ("Enable `behavioral_safety_
enabled` in shadow/log-only mode if the implementation supports shadow
decisions") add a parenthetical: "(shadow mode is optional and out of
normative scope for v0.2)".

In §12.5 Pillar D events where `behavioral_safety_disabled_shadow_hit` is
listed, add a note: "Optional event; only emitted if the implementation
provides a shadow mode, which is out of normative scope for v0.2."

In §15.4 severity table for INFO shadow-mode findings, add "only when
shadow mode is implemented (out of normative scope for v0.2)".

No change needed to §11.4 (production sequence advisory).

---

## Self-verification before declaring fix complete

Walk this checklist before writing the final version header:

- [ ] AC-T2-5 no longer includes `tier2_milestone` in the forbidden-field
  list. The new allowlist exactly matches the SPEC-006 v0.8.1 §5.3.1
  baseline (six keys: `version`, `plaintext_to_provider`, `model_identity`,
  `hardware_attestation`, `tier2_milestone`, `sticky_affinity`) plus the
  five forbidden additive fields.
- [ ] §13.2 has two labeled examples: one for default-config (byte-identical
  to SPEC-006, `version: "v0.8"`, no `tier2` object) and one for
  active-state (with `"v0.8+tier2-v0.2"` and the full `tier2` block).
- [ ] §13.2 prose and AC-T2-5 are internally consistent on when
  `version` bumps (q1 answer applied).
- [ ] M2 fix (q2 answer) applied consistently in §8.5, §8.6, §13.3, and
  any AC that references `untrusted_provider_safety: "enforced"`.
- [ ] §11.2 startup failure rules no longer gate on
  `default_output_size_cap_bytes` for behavioral safety; the helper's
  own sanity rule remains. No behavioral change to §8.3's matrix.
- [ ] §13.3 hardware_attestation truth table present, and the `"none"` vs
  `"unsupported"` boundary is deterministic.
- [ ] §2.1 and §2.3 SPEC-006 citations corrected (no §F-1.5 header, no
  §5.3.4 header in SPEC-006 v0.8.1).
- [ ] m2, m3, m4 minor clarifications added; no substantive spec changes.
- [ ] Version header updated to 0.3 (2026-MM-DD, round-2 audit fix pass).
- [ ] v0.3 changelog entry lists: C1, M1, M2, M3, M4, m1, m2, m3, m4.
- [ ] AC count is still exactly 26. No ACs added or removed.
- [ ] No tier2.* key defaults changed.
- [ ] No section numbers changed (to avoid breaking audit cross-references).
- [ ] No changes to §§1–2, §3 (unless adding a term), §§5–9, or §§12–16
  beyond the specific sentences called out above.

When done, print a handback summary:
- Findings resolved
- Any finding where the q1/q2 operator answer forced a deviation from the
  suggested fix
- Verdict: READY TO LOCK for Phase 1 BUILD, or remaining issues

Then stop. Do NOT draft a Phase 1 BUILD prompt. The operator decides next.

=== END PROMPT ===
```

---

## After running this prompt

Operator checklist (~20 min):

1. Read the v0.3 changelog entry. Confirm all nine IDs are listed.
2. Read AC-T2-5 in full. Confirm `tier2_milestone` is NOT in the
   forbidden list. Confirm the allowlist matches SPEC-006 §5.3.1.
3. Read §13.2. Confirm two labeled examples exist. Confirm the default
   example matches SPEC-006 baseline (`version: "v0.8"`, no `tier2`
   object).
4. Spot-check M2 fix: find `untrusted_provider_safety` in §8.6 / §13.3
   and confirm the q2 answer was applied consistently.
5. Spot-check M3 fix: find §11.2 startup failure list. Confirm
   `default_output_size_cap_bytes` is NOT the gate for behavioral safety.
6. If the checks pass: the spec is READY TO LOCK at v0.3. Proceed to
   `BUILD_SPEC_008_PHASE1_PROMPT.md` (Pillar A coordinator catalog
   service, no SPEC-001 wire change).
7. If any check fails: open a narrow FIX_SPEC_008_V0_4 targeting only
   the failed item. Do not re-run the full audit.

## Phase unlock sequence (unchanged)

1. ✅ SPEC-008 v0.3 locked
2. Phase 1 BUILD: Pillar A only — coordinator catalog load, hash
   verification, provider-pool state, `/v1/models` disclosure update.
   No SPEC-001 wire change. Backward compatible.
3. Phase 2 SPEC: SPEC-001 v2.0 wire extensions (§10 annotations).
4. Phase 2 BUILD: Pillars B + C together.
5. Phase 3 BUILD: Pillar D, incremental.
