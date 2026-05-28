# Fix prompt — SPEC-003 round-2 findings → v0.4 / v1.1.2

Operator-paste prompt to apply the round-2 audit findings from
`specs/SPEC-003-audit.md` "Round 2 (v0.3) Audit Report" section
(Codex, 2026-05-28T05:54:29Z).

The round-2 audit closed 12/15 round-1 findings cleanly. Three narrow
items remain:

  1 CRITICAL — SPEC-002 § 7.1 validation wording (C1 partial close)
  2 MAJOR    — quota pseudocode undefined symbol; SPEC-003 build gate omits AC-15
  1 MINOR    — SPEC-002 dependency line stale

The auditor explicitly recommends "a targeted regression check against
this Round-2 section" (not another full audit round) after this patch
lands. v0.4 should be the closing pass.

Version bumps:
  SPEC-001 v1.2.1 → unchanged (no fixes touch it)
  SPEC-002 v1.1.1 → v1.1.2
  SPEC-003 v0.3   → v0.4

Run in **Claude Code**. Expected duration: ~30-45 min (much shorter
than v0.3 fix; only four surgical edits).

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Claude Code session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are applying four narrow fixes to the SPEC corpus based on the
round-2 audit (specs/SPEC-003-audit.md, section "Round 2 (v0.3)
Audit Report"). The previous fix pass (commit 74cf00b) closed 12/15
round-1 findings; this pass closes the remaining 3 + 1 minor.

You will edit two files in place and bump versions:
  /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md   v1.1.1 → v1.1.2
  /Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md v0.3 → v0.4

SPEC-001 v1.2.1 needs NO edits in this pass (no round-2 findings touch
it). Do NOT modify it.

## Critical constraints

**1. Backward-compat invariant.** Verbatim backward-compat statement
at SPEC-001 v1.2.1 lines 20-38 stays untouched. § 6.6 normative scope
clause untouched. Do NOT edit SPEC-001 at all in this pass.

**2. d-inference clean-room.** Do not inspect d-inference source.

**3. Buyer API stability.** Zero change to POST /v1/chat/completions,
GET /v1/models, GET /healthz.

**4. Surgical scope.** Four edits total. Each is fully specified
below. Do NOT make additional edits or "improvements" — that's scope
creep and would require another audit round.

## Required reading

1. /Users/augstar/macprovider-poc/specs/SPEC-003-audit.md
   — read the entire "Round 2 (v0.3) Audit Report" section
   (starts after the round-1 report). Specifically: CRITICAL-2.1,
   MAJOR-2.1, MAJOR-2.2, MINOR-2.1.

2. /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md
   v1.1.1 — focus on § 7.1 (validation wording), § 5 routing
   pseudocode (quota state), header dependency line.

3. /Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md
   v0.3 — focus on § 2.2 and § 9 (companion AC references).

4. /Users/augstar/macprovider-poc/specs/FIX_SPEC_003_V0_2_PROMPT.md
   — context on what M1 (quota integration) and M5 (AC-15) were
   supposed to do; the round-2 findings flag where the v0.3 patch
   fell short.

## Findings to fix

### CRITICAL-2.1. SPEC-002 § 7.1 validation wording conflicts with optional endpoint_url

**Location:** `specs/SPEC-002-coordinator.md` § 7.1

**Problem:** § 7.1 hello/hello_ack schemas were refreshed in v1.1.1 to
include optional `endpoint_url` (matching SPEC-001 v1.2.1 § 6.5). But
the coordinator-behavior text in § 7.1 still says it "validates all
fields present and correctly typed." If implementers follow this
literally, v1.1.x binaries (M4, M1) — which do NOT send `endpoint_url`
— would fail registration, breaking the backward-compat invariant.

**Fix:** Change the validation wording in § 7.1 from "validates all
fields present and correctly typed" to:

  "validates all REQUIRED fields are present and correctly typed,
  and validates OPTIONAL fields (such as `endpoint_url`,
  `attestation` in hello; `tier`, `recommended_binary_version` in
  hello_ack) when present and correctly typed. Absent `endpoint_url`
  in hello MUST be normalized to null before passing to § 3 mode
  resolution; this preserves backward compatibility with v1.1.x
  binaries that do not include the field."

If § 7.1 enumerates required vs optional fields elsewhere, ensure
this validation language matches that enumeration. Required (hello):
type, version, tier, provider_id, hostname, model_id, model_params_b,
ram_gb, max_context_tokens, max_concurrency,
throughput_tps_estimate, binary_version. Optional (hello): attestation,
endpoint_url.

### MAJOR-2.1. Quota-only routing failure branch references undefined state

**Location:** `specs/SPEC-002-coordinator.md` § 5 routing pseudocode

**Problem:** The v0.3 patch added `check_provisional_quota()` calls
to filter candidates, then checks `if all_filtered_by_quota` to
return HTTP 429 — but `all_filtered_by_quota` is never defined or
assigned in the pseudocode. The intended behavior (HTTP 429
Retry-After: 3600 when every otherwise-eligible candidate is
quota-blocked) cannot be computed from the algorithm as written.

**Fix:** Introduce an explicit `quota_blocked_candidates` list before
the filter step, then use it to disambiguate the two failure cases:

```
# Before filtering by quota, snapshot the pre-quota candidate set
pre_quota_candidates = candidates  # already filtered by state, model, context

# Apply quota filter
quota_blocked_candidates = [c for c in pre_quota_candidates
                            if not check_provisional_quota(c)]
candidates = [c for c in pre_quota_candidates
              if check_provisional_quota(c)]

# Disambiguate failure modes
if len(candidates) == 0:
    if len(quota_blocked_candidates) > 0 and len(pre_quota_candidates) == len(quota_blocked_candidates):
        # All otherwise-eligible candidates are quota-blocked
        return error(429, code="provisional_quota_exceeded",
                     headers={"Retry-After": "3600"})
    else:
        # No eligible candidates for other reasons (no matching model, all degraded, etc.)
        return error(503, code="no_eligible_providers")
```

Keep the existing 429 vs 503 semantics. The HTTP 429 case applies only
when 100% of pre-quota-filter candidates were quota-blocked; any other
zero-candidate path returns HTTP 503.

Apply the same fix to the pinned-by-header path if it also has the
undefined symbol.

### MAJOR-2.2. SPEC-003 build-complete gate omits SPEC-002 AC-15

**Location:** `specs/SPEC-003-open-onboarding.md` § 2.2 and § 9

**Problem:** SPEC-002 v1.1.1 added AC-15 (`nak unknown_message_type`
routing-mode fallback test, the M5 fix). SPEC-003 v0.3 § 2.2 and § 9
still reference "SPEC-002 AC-11 through AC-14" as the build-complete
companion gate. A build could claim completion without testing AC-15
— the backward-compat fallback for v1.1.x binaries that receive
unexpected § 6.6 messages.

**Fix:** In SPEC-003 v0.4 § 2.2 (companion-spec summary) and § 9
(build-complete gate), replace every occurrence of:

  "SPEC-002 AC-11 through AC-14"

with:

  "SPEC-002 AC-11 through AC-15"

Also fix the stale "SPEC-003 v0.2" build-complete label in § 9 to
"SPEC-003 v0.4".

If any other section of SPEC-003 references the SPEC-002 AC range,
update those too. Use grep to find every occurrence.

### MINOR-2.1. SPEC-002 dependency line names SPEC-001 v1.2 instead of v1.2.1

**Location:** `specs/SPEC-002-coordinator.md` header

**Fix:** Change the `**Depends on:**` line in the header from
"SPEC-001 v1.2" to "SPEC-001 v1.2.1".

## Process

1. Read the required materials above.

2. Edit SPEC-002 v1.1.1 → v1.1.2:
   - Bump version in header
   - Update `**Depends on:**` line to SPEC-001 v1.2.1 (MINOR-2.1)
   - Add v1.1.2 change-log entry listing the three fixes
   - Apply CRITICAL-2.1 (§ 7.1 validation wording)
   - Apply MAJOR-2.1 (§ 5 quota pseudocode with quota_blocked_candidates)

3. Edit SPEC-003 v0.3 → v0.4:
   - Bump version in header
   - Add v0.4 change-log entry listing the one fix
   - Apply MAJOR-2.2 (AC-11 through AC-15 + v0.4 label)

4. Self-review pass:
   - SPEC-001 v1.2.1 truly untouched? (`git diff specs/SPEC-001-phase3-binary.md`
     should show no changes.)
   - SPEC-002 § 7.1 validation language now explicitly allows absent
     endpoint_url?
   - SPEC-002 § 5 pseudocode has no undefined symbols?
   - SPEC-003 has no remaining references to "AC-11 through AC-14"?
   - SPEC-003 has no remaining references to "v0.2" (except in change-log
     mentioning prior versions, which is fine)?
   - Backward-compat statement at SPEC-001 v1.2.1 lines 20-38 verbatim
     identical to round-1?

5. Print a 200-word handback summary to stdout listing:
   - Version bumps applied
   - One-sentence summary per fix
   - Confirmation: SPEC-001 v1.2.1 untouched (no diff)
   - Confirmation: backward-compat invariant holds
   - Any unexpected issues encountered

6. Do NOT commit. Operator reviews + commits.

## What NOT to do

- Do NOT edit SPEC-001 v1.2.1 — round-2 found no issues with it.
- Do NOT add new content beyond the four prescribed fixes.
- Do NOT touch d-inference references.
- Do NOT modify any AC numbering except adding AC-15 to SPEC-003's
  companion gate.
- Do NOT change SPEC-002's existing AC-15 text — only the SPEC-003
  references TO it.
- Do NOT bump SPEC-001's version (no changes).
- Do NOT commit. Operator commits.

## Expected size of diff

  SPEC-002 v1.1.1 → v1.1.2: ~30-50 lines changed (validation wording
  paragraph, ~15 lines of pseudocode replacement, header dependency
  line + change-log entry)

  SPEC-003 v0.3 → v0.4: ~5-10 lines changed (AC range references,
  v0.2→v0.4 label, change-log entry)

If your edits exceed ~100 lines total, you may have introduced scope
creep. Stop and re-check the four prescribed fixes.

When done, print the 200-word handback summary and stop.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (quick — ~5 min):

1. `git diff specs/SPEC-001-phase3-binary.md` returns empty.
2. SPEC-002 § 7.1 validation wording explicitly mentions optional
   `endpoint_url` and absent-as-null normalization.
3. SPEC-002 § 5 pseudocode defines `quota_blocked_candidates` and
   has no undefined symbols.
4. SPEC-003 has no remaining "AC-11 through AC-14" (replaced by AC-15).
5. SPEC-002 `**Depends on:**` line says SPEC-001 v1.2.1.

Then commit. Suggested message:

```
SPEC-002 v1.1.2 + SPEC-003 v0.4: round-2 audit closing fixes

Closes the three remaining round-2 findings (1 CRITICAL, 2 MAJOR,
1 MINOR). Audit recommended targeted regression check, not another
full audit round.

CRITICAL-2.1  SPEC-002 § 7.1 validation wording now explicitly
              allows optional endpoint_url; absent normalized to null
              before § 3 mode resolution. (closes C1 partial)

MAJOR-2.1     SPEC-002 § 5 pseudocode introduces quota_blocked_candidates
              list; 429 vs 503 failure modes disambiguated.
              (closes M1 partial)

MAJOR-2.2     SPEC-003 companion-spec gate now requires SPEC-002
              AC-11 through AC-15 (was AC-14). v0.2 -> v0.4 label
              fixed. (closes M5 partial)

MINOR-2.1     SPEC-002 dependency line bumped to SPEC-001 v1.2.1.

Backward-compat invariant: unchanged. SPEC-001 v1.2.1 untouched.

15/15 audit findings now closed.
```

After commit, decide:

- **Targeted regression check** (recommended by audit): write
  `AUDIT_SPEC_003_V0_4_PROMPT.md` narrowly scoped to verify the four
  v0.4 changes don't introduce regressions. Codex audits in ~15-20 min.
  Likely closes with READY TO BUILD verdict.

- **Skip regression, proceed to build prompts**: lower-risk than after
  round 1 (since round-2 was narrow + this fix is narrower still).
  But the audit explicitly asked for a regression check; skipping
  trades 15 min for slight risk.

After regression check (if run) clears: draft three build prompts
  BUILD_SPEC_001_V1_2_1_PROMPT.md (provider-side phase3-binary v1.2 work)
  BUILD_SPEC_002_V1_1_2_PROMPT.md (coordinator v0.2 work)
  BUILD_SPEC_003_V0_4_PROMPT.md   (install.sh + launchd + GitHub releases)

Then implementation begins.
