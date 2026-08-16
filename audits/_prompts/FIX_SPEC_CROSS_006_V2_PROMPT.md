# Fix prompt — SPEC-006 v0.3 → v0.4 (cross-spec regression closing)

Operator-paste prompt to apply the cross-spec regression audit's two
narrow MAJOR findings. Single-spec bump: SPEC-006 v0.3 → v0.4.

Audit report: `specs/SPEC-CROSS-006-v2-audit.md`. Verdict was
READY WITH NARROW FIX. Both findings are spec-text precision issues
in SPEC-006 only; SPEC-002 v1.1.4 and SPEC-003 v0.6 are not touched.

Run in **Claude Code** or **Codex CLI**. Expected duration: ~30-45 min
(two surgical text edits + AC tightening for four ACs).

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are applying two narrow regression findings to SPEC-006. The
regression audit is at specs/SPEC-CROSS-006-v2-audit.md. Verdict:
READY WITH NARROW FIX. Both findings are SPEC-006-only; do NOT edit
SPEC-002, SPEC-003, or SPEC-001 in this pass.

You will edit two files in place:
  /Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md  v0.3 → v0.4
  /Users/augstar/macprovider-poc/phase5-gateway/implementation-notes.html
    (append "Resolved in v0.4 regression" section)

## Critical constraints

**1. SPEC-006-only patch.** SPEC-002 v1.1.4, SPEC-003 v0.6, SPEC-001
v1.2.2 stay UNTOUCHED. Verify with `git diff specs/SPEC-002-coordinator.md
specs/SPEC-003-open-onboarding.md specs/SPEC-001-phase3-binary.md` —
should return empty.

**2. Locked design choices stay locked.** SPEC-006 § 2 is read-only.
D-CROSS-1 through D-CROSS-6 already encoded; do NOT modify them.

**3. Surgical scope.** Two MAJOR findings. Each has a specific fix
below. Do NOT add new normative content beyond what closes these
findings.

**4. d-inference clean-room.** Do not inspect d-inference source.

## Required reading

1. `specs/SPEC-CROSS-006-v2-audit.md` — the regression audit. Two
   findings: M1 (degraded cross-reference + duplicate rule), M2
   (AC-26/29/30/34 alternate branches missing status/body).

2. `specs/SPEC-006-buyer-api.md` v0.3 — the spec under revision.

3. `specs/SPEC-002-coordinator.md` v1.1.4 — read ONLY to find the
   actual section number where degraded is normatively defined.
   Most likely it's in § 7.5 (per D-CROSS-4 lock) but the audit
   says SPEC-002 put it elsewhere. Confirm the actual location.
   Do NOT edit SPEC-002.

4. `specs/FIX_SPEC_CROSS_006_PROMPT.md` — the prior FIX prompt's
   D-CROSS-4 lock paragraph for reference on what SPEC-006 should
   cross-reference TO.

## Findings to fix

### F-606-V2-1 (regression M1) — degraded boolean: fix cross-reference + remove duplicate.

**Locations:** SPEC-006 v0.3 § 5.6 and § 12.2 (per F-606-3 intent).

**Problem:** Two issues compound:
1. SPEC-006 v0.3 cites SPEC-002 § 7.5 for the degraded definition,
   but SPEC-002 v1.1.4 actually defines it in a different section.
   The cross-reference is broken.
2. SPEC-006 v0.3 § 5.6 / § 12.2 ALSO repeats the rule locally
   (re-states the "any unavailable/draining, <50% ready, all
   slots_free=0" criterion), creating a parallel definition that
   could drift from SPEC-002's authoritative version.

**Fix:** Two steps:

1. **Find the actual SPEC-002 section.** Read SPEC-002 v1.1.4 and
   locate where degraded is normatively defined. Common candidates:
   - § 7.5 (where D-CROSS-4 lock specified it should land)
   - § 7.5.X subsection (e.g., § 7.5.3)
   - § 5 routing or § 7.5 /v1/models extension fields
   Record the actual section number for the cross-reference.

2. **Update SPEC-006 § 5.6 and § 12.2** to:
   - Replace the broken cross-reference (e.g., "see SPEC-002 § 7.5")
     with the correct section number found in step 1
   - Remove the duplicate rule restatement entirely
   - Replace with prose like: "Per-model `degraded` is defined
     normatively in SPEC-002 v1.1.4 § <ACTUAL_SECTION>. The gateway
     computes degraded from /poolz aggregation using SPEC-002's
     rules."

The audit's complaint is BOTH problems together. Fixing only the
cross-reference (without removing the duplicate) is INCOMPLETE.

If you cannot find a degraded definition in SPEC-002 v1.1.4 (i.e.,
F-602-3 didn't actually land), that's a deeper issue — STOP and
report. Do not edit SPEC-002 to add the missing definition; flag for
operator decision (cross-spec FIX V2 might be needed).

### F-606-V2-2 (regression M2) — AC-26 / AC-29 / AC-30 / AC-34 alternate branches.

**Location:** SPEC-006 v0.3 § 18, ACs 26, 29, 30, 34.

**Problem:** F-606-11 in the v0.3 FIX pass tightened all 12 new ACs
to require explicit status code + response body shape + verification
command. Four ACs (AC-26, AC-29, AC-30, AC-34) have branched
verification logic (e.g., "if input X then expect 200, else expect
400") where the spec specifies the body shape for ONLY one branch.

The four ACs cover:
- AC-26: OAuth callback URL allowlist enforcement (likely "valid
  callback → 200/302 redirect; mismatched callback → 4xx with envelope")
- AC-29: OAuth state CSRF defense (likely "valid state → 200/302;
  forged state → 400")
- AC-30: OAuth scope minimization (likely "valid scope → 200; elevated
  scope callback → 4xx")
- AC-34: Provider-pinning header strip (likely "request without
  X-MacProvider-* → success path; request WITH header → success path
  AND verify response doesn't reflect the header")

**Fix:** Pass through the four ACs. For each branch in each AC,
specify:
1. The exact HTTP status code expected
2. The expected response body shape (OpenAI envelope or specific
   JSON schema)
3. The verification command for that branch (typically `curl -i`
   plus assertion via grep/jq)

Format each branch as a separate "branch:" sub-bullet:

```
AC-26 (OAuth callback URL allowlist):
  Precondition: gateway running with auth.oauth.callback_allowlist
  configured to ["https://api.malibu.tech/auth/github/callback"].
  Branch A (matching callback):
    Action: GET /auth/github/callback?code=<valid>&state=<valid>&redirect_uri=https://api.malibu.tech/auth/github/callback
    Expected: HTTP 302 redirect to /account
    Verification: curl -i -o /dev/null -w "%{http_code}\n" "..." | grep -q "302"
  Branch B (mismatched callback):
    Action: GET /auth/github/callback?code=<valid>&state=<valid>&redirect_uri=https://evil.example.com/cb
    Expected: HTTP 400 with body {"error": {"message": "...", "type": "invalid_request_error", "code": "redirect_uri_mismatch"}}
    Verification: curl -s "..." | jq -e '.error.code == "redirect_uri_mismatch"'
```

Each branch is independently verifiable.

## Output requirements

1. SPEC-006 updated in place. Version 0.3 → 0.4. Change log entry
   covers F-606-V2-1 and F-606-V2-2 with reference to
   specs/SPEC-CROSS-006-v2-audit.md.

2. Header "Depends on:" line UNCHANGED (no SPEC-002 / SPEC-003
   version bumps in this cycle).

3. § 5.6 and § 12.2 have:
   - Correct cross-reference to SPEC-002 v1.1.4 § <ACTUAL_SECTION>
   - No duplicate degraded rule
   - Prose flows cleanly without the rule text

4. § 18 AC-26, AC-29, AC-30, AC-34 each have two named branches
   with status code + body shape + verification command per branch.

5. `phase5-gateway/implementation-notes.html` gains "Resolved in
   v0.4 regression" section with one-line entries for the two
   findings.

## Self-verification checklist

- [ ] SPEC-006 version 0.3 → 0.4 in header.
- [ ] Change log entry references the regression audit.
- [ ] § 5.6 and § 12.2 cite SPEC-002 by an actual section that
      contains the degraded definition.
- [ ] § 5.6 and § 12.2 do NOT restate the degraded rule.
- [ ] AC-26, AC-29, AC-30, AC-34 each have explicit branches with
      status code + body shape + verification per branch.
- [ ] No other ACs accidentally modified.
- [ ] SPEC-002 v1.1.4 untouched (empty diff).
- [ ] SPEC-003 v0.6 untouched (empty diff).
- [ ] SPEC-001 v1.2.2 untouched (empty diff).
- [ ] D-CROSS-1 through D-CROSS-6 spec text unchanged.
- [ ] § 2 locked decisions unchanged.

If your edits exceed ~80 added lines in SPEC-006, STOP — that's
scope creep. The two findings are surgical.

When done, print a 120-word handback summary:
- Both findings closed (or partial/blocked with rationale).
- The actual SPEC-002 section number used in the cross-reference.
- Any open question for operator (e.g., if degraded definition was
  missing from SPEC-002 entirely).
- Whether SPEC-006 v0.4 is now READY TO LOCK.

Then stop. Do NOT begin implementation. Operator decides whether to
run one final lock audit or proceed to BUILD_PHASE5.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~10 min):

1. `git diff specs/SPEC-006-buyer-api.md` — confirm version bumped,
   change log entry references the regression audit.
2. Verify § 5.6 / § 12.2 cross-reference points to a real SPEC-002 §
   that contains the degraded definition (cross-check by reading the
   referenced section).
3. Verify no duplicate degraded rule in SPEC-006.
4. Verify the four ACs each have two explicit branches.
5. `git diff specs/SPEC-002-coordinator.md specs/SPEC-003-open-onboarding.md
   specs/SPEC-001-phase3-binary.md` — should be empty.

Then commit. Suggested message:

```
SPEC-006 v0.4: cross-spec regression closing fix pass

Closes 2 MAJOR findings from specs/SPEC-CROSS-006-v2-audit.md (Codex
regression check, verdict READY WITH NARROW FIX).

F-606-V2-1: degraded boolean cross-reference fix + duplicate rule
removal. SPEC-006 now cites the actual SPEC-002 v1.1.4 section that
normatively defines degraded, with no parallel restatement.

F-606-V2-2: AC-26 / AC-29 / AC-30 / AC-34 alternate-branch tightening.
Each AC now has explicit status code + response body shape +
verification command per branch.

SPEC-002 v1.1.4, SPEC-003 v0.6, SPEC-001 v1.2.2 untouched. No
operator decisions changed.

Corpus is now ready to lock at:
- SPEC-001 v1.2.2
- SPEC-002 v1.1.4
- SPEC-003 v0.6
- SPEC-006 v0.4
```

After commit, decide:

- **Lock corpus and proceed to BUILD_PHASE5_PROMPT.md**: defensible
  because the two findings were the last narrow issues identified
  across two audit rounds + regression. Implementation begins.
- **One more lightweight regression check**: optional, but the
  diminishing-returns curve suggests skipping. The cross-spec FIX V2
  surfaced 2 findings from 17; a check on a 2-finding patch typically
  surfaces 0 findings. Probably overkill.

Recommendation: lock the corpus and start BUILD_PHASE5.
