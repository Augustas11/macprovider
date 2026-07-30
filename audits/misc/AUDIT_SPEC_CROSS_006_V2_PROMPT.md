# Regression audit prompt — cross-spec patches (SPEC-006 v0.3 + SPEC-002 v1.1.4 + SPEC-003 v0.6)

Operator-paste prompt for a narrowly scoped regression audit of the
cross-spec patches landed at commit `990a07e`. This is NOT a full
re-audit of the corpus. It targets only the v1.1.3→v1.1.4 +
v0.5→v0.6 + v0.2→v0.3 delta and verifies the 17 closed findings + 6
operator decisions land coherently across three specs.

**Cross-model pattern:** Run with **Codex CLI** for cross-model
independence — Claude executed the FIX session and would self-validate.
Codex is the alternate model for any spec corpus audit.

A single round is sufficient for a regression check. The full
cross-spec audit (`specs/SPEC-CROSS-006-audit.md`, both rounds) already
covered the architecture; this audit only verifies the patches landed
cleanly.

Expected duration: ~30-45 min.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Codex CLI session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are running a narrow regression audit of the cross-spec patches
landed in commit 990a07e at:

  specs/SPEC-006-buyer-api.md       v0.2 → v0.3
  specs/SPEC-002-coordinator.md     v1.1.3 → v1.1.4
  specs/SPEC-003-open-onboarding.md v0.5 → v0.6

The original cross-spec coherence audit is at
specs/SPEC-CROSS-006-audit.md (both rounds, READY WITH NARROW
PATCHES). The fix prompt was specs/FIX_SPEC_CROSS_006_PROMPT.md.

Your job: verify the 17 closed findings + 6 operator decisions
(D-CROSS-1 through D-CROSS-6) land coherently across the three
specs. You are NOT here to re-audit the full corpus, propose
architectural changes, or relitigate locked decisions.

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-CROSS-006-v2-audit.md

Format: structured regression report. Findings tagged with severity
(CRITICAL / MAJOR / MINOR) and location (which spec, which section).
Match the rigor of prior regression audits in this repo
(specs/SPEC-006-v0-2-audit.md is the most recent precedent).

## Scope discipline (HARD CONSTRAINTS)

**1. Regression scope only.** Verify only the v0.2→v0.3, v1.1.3→v1.1.4,
v0.5→v0.6 delta. Closed findings count:
- SPEC-006 v0.3: 11 items (F-606-1 through F-606-8 plus 3 regression
  AC fixes)
- SPEC-002 v1.1.4: 6 items (F-602-1 through F-602-6)
- SPEC-003 v0.6: 2 items (F-603-1 and F-603-2)
Plus D-CROSS-1 through D-CROSS-6 encoded as spec text.

Do NOT re-audit sections unchanged from the prior versions. They
were already audited in their own audit cycles.

**2. SPEC-001 v1.2.2 is untouched.** The FIX session verified an
empty diff for SPEC-001. If your audit detects ANY change to
SPEC-001, that is a CRITICAL finding ("FIX session violated the
SPEC-001-untouched constraint").

**3. Locked design choices remain off-limits.** SPEC-006 § 2 is the
operator pre-commitments ledger. Any finding that recommends
changing a locked decision is REJECTED.

**4. Three classes of regression to specifically watch for:**
- **Closure regression**: a finding labeled "closed" but the spec
  text doesn't actually resolve the finding (or resolves it
  incompletely). MAJOR or CRITICAL depending on the original
  severity.
- **Cross-spec coherence regression**: D-CROSS-1 through D-CROSS-6
  encoded in one spec but contradicted or under-supported in another.
  CRITICAL (the D3 contradiction caught at FIX-prompt time was the
  reason this pattern exists).
- **Dependency-line desync**: each spec's "Depends on:" line must
  reflect the new versions of the others (SPEC-006 v0.3 → SPEC-002
  v1.1.4 + SPEC-003 v0.6; SPEC-002 v1.1.4 → SPEC-001 v1.2.2; SPEC-003
  v0.6 → SPEC-001 v1.2.2 + SPEC-002 v1.1.4). Any stale dependency =
  MINOR.

**5. d-inference clean-room.** Do not inspect d-inference source.

## Required reading (in order)

1. `/Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md` v0.3
   — current state. Focus on the sections touched by F-606-*:
   - § 5.4 (chat completions field list + outbound header strip
     F-606-1)
   - § 5.6 / § 12.2 (status endpoint + degraded boolean
     cross-reference F-606-3)
   - § 7.2 (quota reservation + disconnect estimation D-CROSS-1)
   - § 8.3 (provider transparency invariants)
   - § 10 (capacity tiers + independence statement D-CROSS-5)
   - § 15 (gateway.yaml schema + coordinator config F-606-4)
   - § 17 (failure modes + 502 normalization F-606-5; refund matrix
     update D-CROSS-1)
   - § 18 (AC-26 through AC-37 — regression fixes for status codes,
     body shapes, method correction)
   - § 19 (audit categories — F-606-6 SPEC-003 inheritance)

2. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.1.4 — focus on:
   - § 7.2 (X-Request-ID propagation F-602-1)
   - § 7.5 (/v1/pool/check normative F-602-2; degraded boolean
     F-602-3; /poolz summary F-602-5)
   - § 7 deployment notes (buyer port rebind F-602-6)
   - "Depends on" line (F-602-4)
   - nginx routing block from F-602-2

3. `/Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md`
   v0.6 — focus on:
   - § 5 (installer self-test referencing SPEC-002 v1.1.4
     /v1/pool/check F-603-1)
   - "Depends on" line (F-603-2)

4. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.2.2 — read just the header to confirm it's still v1.2.2 (not
   accidentally bumped). The body is OUT OF SCOPE for this audit.

5. `/Users/augstar/macprovider-poc/specs/SPEC-CROSS-006-audit.md`
   — the source-of-truth audit. Every F-* finding must close
   cleanly.

6. `/Users/augstar/macprovider-poc/specs/FIX_SPEC_CROSS_006_PROMPT.md`
   — the FIX prompt's locked language. Every D-CROSS-* decision must
   appear in spec text.

7. `/Users/augstar/macprovider-poc/specs/SPEC-006-v0-2-audit.md`
   — the SPEC-006 v0.2 regression audit. Its three AC fixes were
   folded into v0.3; verify they actually closed.

## Audit categories — narrow regression checks

### Category A: Closure verification (highest priority)

For each closed finding, verify the spec text actually resolves it.
Walk through in F-* order:

**SPEC-006 v0.3 (11 items):**

A.1  **F-606-1** (response header strip) — § 5.4 / § 8.3 must
     explicitly name `X-MacProvider-Provider` and `X-MacProvider-Route`
     in the OUTBOUND strip list (separate from inbound F-M21 list).

A.2  **F-606-2** (disconnect estimation D-CROSS-1) — § 7.2 / § 17.5
     must specify `ceil(bytes_emitted_so_far / 4)`. Refund matrix
     must mark client disconnect as estimated, not actual.

A.3  **F-606-3** (degraded cross-ref) — § 5.6 / § 12.2 must reference
     SPEC-002 v1.1.4 § 7.5 for the degraded boolean rules. No
     redefinition.

A.4  **F-606-4** (gateway.yaml /poolz config) — § 15 must include
     `coordinator.operator_url`, `coordinator.operator_key`,
     `coordinator.poolz_poll_interval_s`. Startup-validation rule
     for missing keys.

A.5  **F-606-5** (502 normalization) — § 17 must use consistent
     terminology: 502 = `type: api_error, code: upstream_provider_error`.

A.6  **F-606-6** (SPEC-003 audit category inheritance) — § 19 must
     reference SPEC-003 v0.6's shell-script integration-test
     category.

A.7  **F-606-7** (upstream-modification governance) — § 1.5 must
     allow cross-spec FIX cycles to coordinate patches; sole-author
     edits to upstream specs remain forbidden.

A.8  **F-606-8** (status cache staleness) — § 5.6 must specify 10s
     /poolz cache TTL + flush-on-unreachable.

A.9  **AC-26 method fix** — § 18, AC-26 must say GET, not POST.

A.10 **AC-27 latency proof** — § 18, AC-27 must poll every 5s and
     assert first 401 by T+60s, not "retry at 65s".

A.11 **AC-26..AC-37 status/body** — each of the 12 ACs must include
     explicit HTTP status code + response body shape + curl -i
     verification command.

**SPEC-002 v1.1.4 (6 items):**

A.12 **F-602-1** (X-Request-ID correlation D-CROSS-3) — § 7.2 must
     normatively require coordinator to honor inbound X-Request-ID
     header from gateway and include in request_log row. UUID v4
     format documented.

A.13 **F-602-2** (/v1/pool/check normative D-CROSS-2) — § 7.5 must
     contain the full /v1/pool/check subsection with method, path,
     auth, response schema, purpose. nginx routing block must
     document the gateway/coordinator path split.

A.14 **F-602-3** (degraded boolean D-CROSS-4) — § 7.5 must contain
     the normative definition: ANY of (all unavailable/draining, <50%
     ready, all slots_free=0) → degraded:true.

A.15 **F-602-4** (dependency line) — line 4 must say "Depends on:
     SPEC-001 v1.2.2" (was v1.2.1).

A.16 **F-602-5** (/poolz summary) — § 7.5 must add the `summary`
     block with by_model counts, separate from the detailed
     `providers` array.

A.17 **F-602-6** (buyer port rebind doc) — § 7 deployment notes must
     mention 8443 rebinds to 127.0.0.1 when gateway co-deployed.

**SPEC-003 v0.6 (2 items):**

A.18 **F-603-1** (installer /v1/pool/check) — § 5 must reference
     SPEC-002 v1.1.4 § 7.5 /v1/pool/check definition. Must clarify
     installer calls coordinator.streamvc.live (NOT
     api.streamvc.live) for this path.

A.19 **F-603-2** (dependency line) — line 4 must say "Depends on:
     SPEC-001 v1.2.2, SPEC-002 v1.1.4" (was older).

For each finding: CLOSED / PARTIAL / CONTRADICTORY / MISSING.

### Category B: Cross-spec coherence (D-CROSS-1 through D-CROSS-6)

B.1  **D-CROSS-1 (estimation)** — SPEC-006 v0.3 § 7.2 + § 17.5 must
     coherently describe gateway estimation. The refund matrix must
     match the prose. SPEC-001 v1.2.3 candidate filing must be
     mentioned in v0.3 prose (as a future-cycle reference, not a
     normative requirement).

B.2  **D-CROSS-2 (/v1/pool/check ownership)** — SPEC-002 v1.1.4 §
     7.5 normative definition + nginx routing block must align with
     SPEC-006 v0.3's NON-claim on this path + SPEC-003 v0.6's
     installer reference. All three specs tell the same story.

B.3  **D-CROSS-3 (X-Request-ID UUID v4)** — SPEC-002 v1.1.4
     correlation rule + SPEC-006 v0.3 audit-events generation
     specify the same UUID v4 format and the same gateway-generates-
     coordinator-honors flow.

B.4  **D-CROSS-4 (degraded boolean)** — SPEC-002 v1.1.4 defines;
     SPEC-006 v0.3 references. No second definition in SPEC-006.

B.5  **D-CROSS-5 (capacity tier independence)** — SPEC-006 v0.3 §
     10 must explicitly state independence from SPEC-002 admission
     tiers. SPEC-002 v1.1.4 admission-tier text MAY note SPEC-006
     independence but is NOT required to (SPEC-006's statement is
     authoritative).

B.6  **D-CROSS-6 (logprobs)** — SPEC-006 v0.3 § 5.4 logprobs note
     references SPEC-001 v1.2.2 unknown-field tolerance. SPEC-001 +
     SPEC-002 field tables are UNCHANGED for logprobs (just
     unknown-field tolerance is the backstop).

If any D-CROSS-* decision is encoded in one spec but contradicted or
under-supported in another: CRITICAL.

### Category C: Dependency-line synchronization

C.1  SPEC-006 v0.3 line 4 says "Depends on: SPEC-001 v1.2.2, SPEC-002
     v1.1.4, SPEC-003 v0.6". Any other version = MINOR.

C.2  SPEC-002 v1.1.4 line 4 says "Depends on: SPEC-001 v1.2.2". Any
     other version = MINOR.

C.3  SPEC-003 v0.6 line 4 says "Depends on: SPEC-001 v1.2.2, SPEC-002
     v1.1.4". Any other version = MINOR.

C.4  SPEC-001 v1.2.2 line 3-4 unchanged (no new version). If bumped =
     CRITICAL.

### Category D: New normative text quality

D.1  nginx routing block in SPEC-002 v1.1.4 § 7 is consistent with
     real nginx syntax (`location` directives, `proxy_pass`). Any
     syntactic error = MINOR.

D.2  gateway.yaml schema in SPEC-006 v0.3 § 15 is consistent with
     YAML syntax and previous schema sections. Any contradiction =
     MAJOR.

D.3  The 502 error envelope in SPEC-006 v0.3 § 17 matches OpenAI
     envelope shape exactly. `{"error": {"message": ..., "type":
     "api_error", "code": "upstream_provider_error"}}`. Any drift =
     MAJOR.

D.4  Status code AC bodies for AC-26..AC-37 are realistic (curl -i
     followed by jq or grep assertions). Hand-wavy assertions =
     MAJOR.

### Category E: Scope discipline

E.1  Did v0.3 / v1.1.4 / v0.6 introduce content beyond what closed
     findings or encoded D-CROSS-* decisions? CRITICAL if yes
     (scope creep).

E.2  Did the FIX session edit SPEC-001? CRITICAL if yes. Verify by
     comparing line-1 version header to v1.2.2.

E.3  Did the FIX session add a Tier-3 deprecation clause to
     SPEC-006? CRITICAL if yes (operator pre-commitment violated).

E.4  Did out-of-scope lists in SPEC-006 § 1.3 shrink? MAJOR if yes
     (out-of-scope items should remain at minimum).

## Output format

```
# Cross-spec patches v0.3/v1.1.4/v0.6 regression audit

## Summary
- N CRITICAL findings
- M MAJOR findings
- K MINOR findings
- Overall verdict: READY TO LOCK / READY WITH NARROW FIX / NEEDS FIX ROUND

## Closure verification (Category A, 19 items)

### SPEC-006 v0.3 (11 items)
- F-606-1: CLOSED / PARTIAL / etc.
- F-606-2: ...
- ...

### SPEC-002 v1.1.4 (6 items)
- F-602-1: ...
- ...

### SPEC-003 v0.6 (2 items)
- F-603-1: ...
- F-603-2: ...

## Cross-spec coherence (Category B)
- D-CROSS-1: verdict + cross-spec consistency notes
- D-CROSS-2: ...
- D-CROSS-3: ...
- D-CROSS-4: ...
- D-CROSS-5: ...
- D-CROSS-6: ...

## Dependency synchronization (Category C)
- C.1 SPEC-006: ...
- C.2 SPEC-002: ...
- C.3 SPEC-003: ...
- C.4 SPEC-001 (must be unchanged): ...

## New normative text quality (Category D)
- D.1 nginx block: ...
- D.2 gateway.yaml schema: ...
- D.3 502 envelope: ...
- D.4 AC quality: ...

## Scope discipline (Category E)
- Any findings

## Critical findings (if any)
[full description, severity, location, fix recommendation]

## Major findings (if any)

## Minor findings (if any)

## Verdict + rationale
[200 words, with explicit recommendation: CORPUS LOCKED (proceed to
BUILD_PHASE5), or NARROW FIX needed for v0.4/v1.1.5/v0.7]
```

## Self-verification before declaring complete

- [ ] Read all three patched specs at their new versions.
- [ ] Walked Category A's 19 closure checks.
- [ ] Verified D-CROSS-1 through D-CROSS-6 coherence across the
      three specs (Category B).
- [ ] Verified dependency-line synchronization (Category C).
- [ ] Confirmed SPEC-001 v1.2.2 untouched (Category C.4).
- [ ] Verified new normative text quality (Category D).
- [ ] No scope creep (Category E).
- [ ] Verdict.

When done, print a 150-word handback summary:
- Findings count by severity
- Top 3 most impactful findings (if any)
- Verdict (CORPUS LOCKED / NARROW FIX / NEEDS FIX ROUND)
- One-sentence rationale

Then stop. Do NOT begin drafting a fix prompt. Operator decides
next move.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~15 min):

1. Read `specs/SPEC-CROSS-006-v2-audit.md`.
2. If verdict is **CORPUS LOCKED**: SPEC-001 v1.2.2 + SPEC-002 v1.1.4
   + SPEC-003 v0.6 + SPEC-006 v0.3 are the locked spec corpus.
   Proceed to `BUILD_PHASE5_PROMPT.md` for gateway implementation.
3. If verdict is **NARROW FIX**: draft `FIX_SPEC_CROSS_006_V2_PROMPT.md`
   covering only the regression findings. Run, lock the corpus.
4. If verdict is **NEEDS FIX ROUND** (unlikely): regression introduced
   by the FIX session. Investigate.

## Why this regression check matters

The cross-spec FIX was the corpus's largest coordinated patch ever
(three specs, 17 findings, 6 operator decisions). The cross-spec
audit was cross-model (Codex round 1 + Claude round 2). The FIX pass
was single-model (Claude). Independence is preserved by running this
regression in Codex — same discipline applied to SPEC-006 v0.1→v0.2
fix verification.

Historical pattern: small fix passes (3-5 findings) typically have
regression audits that close READY TO LOCK with zero findings. Larger
fix passes (10+ findings) typically have regression audits that
surface 1-3 narrow issues. This pass had 17 findings, so 1-3
regression findings is a realistic expectation. Single-FIX session
should close them.

If this audit produces architectural CRITICALs (e.g., the D-CROSS-*
encodings are inconsistent across specs), that's the signal to
re-open the FIX cycle. Cheaper at spec phase than at implementation
phase.
