# Regression audit prompt — SPEC-006 v0.2 narrow check

Operator-paste prompt for a narrowly scoped regression audit of
SPEC-006 v0.2 (`specs/SPEC-006-buyer-api.md`). This is NOT a full
re-audit. It targets only the v0.1 → v0.2 delta and verifies the
22 closed findings + 12 new ACs are clean.

**Cross-model pattern:** Run with **Codex CLI** for cross-model
independence — Claude did the fix pass and would self-validate.
Codex round 2 of the v0.1 audit ran the same prompt with the same
discipline; using Codex again here keeps the audit lineage clean.
A single round is sufficient for a regression check (the bulk audit
of the spec is the v0.1 cross-model audit at
`specs/SPEC-006-audit.md`).

Expected duration: ~30-45 min (regression scope, not full audit).
Pattern matches the SPEC-003 v0.4 regression check that closed the
round-1 audit's three remaining findings in one targeted pass.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Codex CLI session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are running a narrow regression audit of SPEC-006 v0.2 at
/Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md. The v0.1
cross-model audit is at specs/SPEC-006-audit.md and closed with
verdict READY WITH FIX PASS. The fix pass executed
specs/FIX_SPEC_006_V0_2_PROMPT.md and produced v0.2.

Your job: verify the 22 closed findings + 12 new ACs are clean. You
are NOT here to re-audit the entire spec, propose architectural
changes, or relitigate locked design choices.

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-006-v0-2-audit.md

Format: structured regression report. Findings tagged with severity
(CRITICAL / MAJOR / MINOR) and location. Match the rigor of prior
audit reports in this repo (specs/SPEC-001-v1-1-audit.md,
specs/SPEC-002-v1-0-2-audit.md, specs/SPEC-003-audit.md round 2).

## Scope discipline (HARD CONSTRAINTS)

**1. Regression scope only.** Verify only the v0.1 → v0.2 delta:
- 1 CRITICAL closed (F-C2 OAuth callback allowlist)
- 21 MAJOR closed (F-M1 through F-M21)
- 9 MINOR closed (F-m1 through F-m2-9)
- 3 operator-locked decisions encoded (D1, D2, D3)
- 12 new ACs added (AC-26 through AC-37)

Do NOT re-audit sections unchanged from v0.1. They were already
audited in round 1 (Codex) + round 2 (Claude).

**2. Locked design choices remain off-limits.** § 2 of SPEC-006 is
the operator pre-commitments ledger. Any finding that recommends
changing a locked decision is REJECTED.

**3. No upstream spec changes.** SPEC-001 v1.2.2 and SPEC-002 v1.1.3
are locked. Any v0.2 finding that proposes mutations to upstream
specs is a CRITICAL.

**4. d-inference clean-room.** Do not inspect d-inference source.

**5. Three categories of regression to specifically watch for:**
- **Closure regression**: a finding labeled "closed" but the spec
  text doesn't actually resolve the finding (or resolves it
  incompletely). MAJOR or CRITICAL depending on the finding's
  original severity.
- **Coherence regression**: D1, D2, or D3 is encoded in one
  section but contradicted or under-supported in another. CRITICAL
  (the D3 contradiction caught at FIX-prompt review time was the
  reason this audit exists; check for similar internal drift).
- **AC quality regression**: a new AC (AC-26..AC-37) is named but
  doesn't have precondition + action + expected outcome +
  verification command. MAJOR.

## Required reading (in order)

1. `/Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md`
   v0.2 — the current spec. Read the change log header, then
   focus on the sections touched by v0.2:
   - § 1.3 (out-of-scope additions for Donations literal, m2-7 dedup)
   - § 1.8 (D1 single-instance acknowledgment)
   - § 2 (the verbatim-quote header note — F-M1)
   - § 2.11 (median/p50 cleanup — m2-1)
   - § 5.1 (X-Request-ID MUST, X-RateLimit-Reset Unix timestamp,
     rate-limit post-decision semantics — F-m1, m2-2, m2-3)
   - § 5.2 (panic recovery middleware — m2-6)
   - § 5.4 (missing OpenAI fields F-M2, provider-pinning header
     strip F-M21, SSE framing m2-9)
   - § 5.6 / § 12.2 (coordinator status bridge F-M19)
   - § 5.7 (feedback scope field F-M11, XSS defense F-M20)
   - § 5.8 (OAuth callback allowlist F-C2)
   - § 6.1 (OAuth scope minimization F-M3, OAuth state entropy m2-4)
   - § 6.4 (API key 256-bit entropy F-M4)
   - § 6.6 (token revocation latency F-M5, key rotation history m2-5)
   - § 6.8 (demo token HMAC mechanism F-M14 / D2)
   - § 7.2 (atomic reservation F-M6, streaming + refund F-M7 / D3)
   - § 9.3 (kill switch latency MUST + persistence F-M8)
   - § 10 (capacity signal table F-M9, tier de-escalation F-M10,
     budget audit event m5)
   - § 11.3 / § 11.5 / § 11.6 (feedback scope, summary shape,
     iteration trigger F-M11/12/13)
   - § 14 (audit log coverage F-M17, single-instance F-M18,
     encryption-at-rest deferral m3/m2-7, tamper-evidence deferral
     m4/m2-8)
   - § 17 (405/413 codes F-M16, refund matrix F-M15 / D3)
   - § 18 ACs (the 12 new ones: AC-26..AC-37)

2. `/Users/augstar/macprovider-poc/specs/SPEC-006-audit.md` — the
   v0.1 cross-model audit. Use this as your delta reference: every
   F-* fix in the FIX prompt MUST close the corresponding finding
   here.

3. `/Users/augstar/macprovider-poc/specs/FIX_SPEC_006_V0_2_PROMPT.md`
   — the operator's instructions to the fix session. Every fix you
   verify maps to a specific F-* in this prompt with specific
   spec-location guidance.

4. `/Users/augstar/macprovider-poc/specs/BUILD_SPEC_006_PROMPT.md`
   — locked design choices. Cross-check § 2 of SPEC-006 against
   this for verbatim fidelity.

5. (Optional, only if needed for F-M19 or F-M21 verification)
   `/Users/augstar/macprovider-poc/phase4-coordinator/internal/`
   — confirm coordinator's actual /poolz shape and the
   X-MacProvider-* header semantics if the spec's references seem
   inaccurate.

## Audit categories — narrow regression checks

### Category A: Closure verification (highest priority)

For each of the 22 closed findings (1 CRITICAL + 21 MAJOR), verify
the spec text actually resolves the finding. Walk through them in
F-* order:

A.1  **F-C2** (OAuth callback URL allowlist) — § 5.8 + § 6.1 must
     contain the allowlist requirement, `auth.oauth.callback_allowlist`
     config field, startup validation. AC-26 must verify this
     deterministically.

A.2  **F-M1** (§ 2 verbatim quotation) — § 2 must open with the
     header note from FIX prompt. Substantive content must match
     BUILD prompt's locked-design header semantically.

A.3  **F-M2** (missing OpenAI fields) — § 5.4 must list `n`,
     `stream_options`, `user`, `logprobs` with the documented
     behaviors (n=1 v1, stream_options.include_usage forwarding,
     user as opaque diagnostics, logprobs syntactic).

A.4  **F-M3** (OAuth scope minimization) — § 6.1 must require only
     `read:user` (and optionally `user:email`); forbid broader scopes.

A.5  **F-M4** (API key 256-bit entropy) — § 6.4 must require ≥256
     bits CSPRNG before encoding.

A.6  **F-M5** (token revocation latency bound) — § 6.6 must require
     <60s. AC-27 must test this.

A.7  **F-M6** (atomic quota enforcement) — § 7.2 / § 14.4 must
     define the reservation ledger pattern with transactional /
     CAS primitives. SQLite v1 specifically uses BEGIN IMMEDIATE.

A.8  **F-M7** (streaming quota debit timing) — § 7.2 / § 5.4 must
     describe the reserve-then-settle pattern matching D3.

A.9  **F-M8** (kill switch latency + persistence) — § 9.3 must
     have MUST not SHOULD on <5s activation; persistence mechanism
     defined. AC-28 must test persistence across restart.

A.10 **F-M9** (capacity signal measurement table) — § 10.2-10.4
     must contain the signal table with source, cadence, window,
     threshold, hysteresis for CPU, memory, bandwidth, provider
     feedback, cost, provider drops, operator load.

A.11 **F-M10** (tier de-escalation) — § 10.5 must define both
     automatic (cooldown-based) and manual de-escalation. AC-32
     must test.

A.12 **F-M11** (feedback scope field) — § 5.7 schema must include
     `scope` with the four enum values, default behavior, and the
     two-path auth (bearer for request/session/account, demo token
     for playground).

A.13 **F-M12** (feedback summary shape) — § 11.5 must define the
     response JSON with window, count, mean, distribution,
     by_scope, trend, comment_samples.

A.14 **F-M13** (iteration trigger threshold) — § 11.6 must define
     the 40%/20-event threshold, hourly polling.

A.15 **F-M14** (demo token HMAC) — § 6.8 must contain the full
     HMAC-SHA256 mechanism per D2: payload shape, signing,
     /auth/demo-session issuance, rate-limit. AC-35 must test
     forgery rejection.

A.16 **F-M15** (quota refund matrix) — § 17.4-17.7 must contain
     the matrix matching D3 exactly: 503 → none, 502/504 zero
     completion → prompt only (provider reached), partial → prompt
     + actual. AC-36 must test 504 with zero completion.

A.17 **F-M16** (405/413 codes) — § 17 must map 405 to
     `invalid_request_error / method_not_allowed` and 413 to
     `invalid_request_error / request_too_large`.

A.18 **F-M17** (audit log coverage) — § 14.3 must enumerate
     kill switch toggles, quota config changes, key revocations,
     account blocks, capacity tier transitions, budget cap mutations
     as required audit events.

A.19 **F-M18** (v1 single-instance) — § 1.8 + § 14.2 must
     acknowledge single-instance SQLite per D1; multi-instance
     requires storage migration.

A.20 **F-M19** (coordinator status bridge) — § 5.6 / § 12.2 must
     define gateway consuming coordinator's /poolz internally with
     explicit redaction list (provider_id, hostname, RAM/CPU,
     operator identity). MAY note a SPEC-002 v1.1.4 follow-up if
     /poolz shape is insufficient.

A.21 **F-M20** (stored XSS on feedback comments) — § 5.7 must
     require comment treated as untrusted, output-time HTML escape,
     no pre-rendered HTML in JSON responses.

A.22 **F-M21** (provider-pinning header strip) — § 5.4 / § 8 must
     require stripping `X-MacProvider-Provider`,
     `X-MacProvider-Session`, and undocumented `X-MacProvider-*`
     headers BEFORE authentication. AC-34 must test injection
     attempt.

For each finding: if the spec text resolves the finding completely,
note as "CLOSED". If partial, note "PARTIAL — explain gap". If the
spec text is present but contradicts another section, note
"CONTRADICTORY — flag location of contradiction" (this is the same
class of bug that the D3 review caught at FIX-prompt time).

### Category B: Operator decision coherence (D1, D2, D3)

B.1  **D1 (single-instance)** — verify the acknowledgment appears
     in § 1.8 AND § 14.2 with consistent semantics. The "stateless
     handlers" requirement from § 1.8 must remain compatible with
     "single-instance" — § 1.8 must clarify that statelessness
     preserves multi-instance feasibility but v1 doesn't exercise
     it.

B.2  **D2 (demo HMAC)** — verify the mechanism is fully described
     in § 6.8. Sub-checks:
     - Token format (payload + HMAC encoding)
     - Payload fields (v, ip, iat, exp)
     - Signing secret in `gateway.yaml` under documented config key
     - /auth/demo-session issuance endpoint rate-limited per IP
     - IP-match validation (exact for IPv4, /64 for IPv6)
     - Max 24h TTL
     - Forbids static shared secrets
     Any sub-check missing = MAJOR.

B.3  **D3 (refund matrix)** — verify the matrix in § 17 matches
     D3's provider-reached-vs-not framing:
     - 200 → prompt + completion
     - 503 → none (no provider was reached)
     - 502/504 zero completion → prompt only (provider was reached
       and processed prompt)
     - 502/504 partial → prompt + actual
     - Client disconnect → prompt + actual at disconnect
     Any deviation, or contradiction between § 7.2 D3 paragraph and
     § 17 matrix = CRITICAL (this is the same bug-class the FIX-
     prompt review caught pre-execution).

### Category C: New AC quality (AC-26 through AC-37)

Each new AC MUST have:
- A precondition stating environment setup
- A specific action (curl / SDK call / admin endpoint POST)
- An expected outcome (status code + response body shape)
- A verification command (executable, idempotent, deterministic)

For each AC:
- If all four present and the verification is executable: PASS
- If any missing or hand-wavy ("the system should work"): MAJOR
- If the AC tests an unrelated property to its label: MAJOR

Specifically scrutinize:
- **AC-26** OAuth callback allowlist enforcement
- **AC-27** Token revocation latency <60s
- **AC-28** Kill switch persistence across restart
- **AC-29** OAuth state CSRF defense
- **AC-30** OAuth scope minimization
- **AC-31** Key rotation preserves usage history
- **AC-32** Capacity tier de-escalation
- **AC-33** Feedback summary aggregation shape
- **AC-34** Provider-pinning header strip
- **AC-35** Demo token forgery rejected
- **AC-36** Quota refund on 504 with zero completion
- **AC-37** Streaming quota reservation + settlement

### Category D: MINOR cleanup verification

Walk through the 9 MINOR fixes (F-m1 through F-m2-9). Each should
appear in the spec but is lower priority — a missed MINOR is at
worst a v0.3 patch, not a v0.2 blocker.

D.1  X-Request-ID MUST (was SHOULD) — § 5.1
D.2  Donations literal in out-of-scope — § 1.3
D.3  SQLite encryption-at-rest decision — § 14.2 (note: m3 and
     m2-7 covered the same point; verify dedup)
D.4  Audit log tamper resistance deferral — § 4.8 / § 14.3 (m4 +
     m2-8 dedup)
D.5  Capacity expansion budget audit event — § 10.5 / § 15.2
D.6  median(p50) and p95 instead of median+p50+p95 — § 2.11
D.7  X-RateLimit-Reset Unix timestamp — § 7.3
D.8  Rate-limit post-decision semantics — § 5.1 / § 7.6
D.9  OAuth state ≥128-bit CSPRNG — § 5.8
D.10 Key rotation preserves usage history — § 6.6
D.11 Panic recovery middleware → 500 OpenAI envelope — § 5.2
D.12 SSE framing explicit — § 5.4

### Category E: Scope discipline (sanity check)

E.1  Did v0.2 introduce any new normative content beyond what
     closed findings? CRITICAL if yes (scope creep).

E.2  Did v0.2 propose SPEC-001 or SPEC-002 changes? CRITICAL if yes.

E.3  Did § 2 (Locked decisions) acquire any new content or
     "improvements"? CRITICAL if yes — § 2 was supposed to gain
     only the verbatim-quote header note.

E.4  Did v0.2 introduce premium positioning, Tier-3 deprecation,
     or buyer personas? CRITICAL if yes (these were explicit pre-
     commitment violations in the audit prompt's constraint set).

E.5  Did the out-of-scope list in § 1.3 shrink? It should have
     grown (Donations literal added). MAJOR if shrunk.

## Output format

```
# SPEC-006 v0.2 regression audit

## Summary
- N CRITICAL findings
- M MAJOR findings
- K MINOR findings
- Overall verdict: READY TO LOCK / READY WITH NARROW FIX / NEEDS FIX ROUND

## Closure verification (Category A)
For each F-* from v0.1 → v0.2:
- CLOSED / PARTIAL / CONTRADICTORY / MISSING

## D1/D2/D3 coherence (Category B)
- D1 verdict + notes
- D2 verdict + notes
- D3 verdict + notes

## AC quality (Category C)
- AC-26 through AC-37 individual verdicts

## MINOR cleanups (Category D)
- D.1 through D.12 individual verdicts

## Scope discipline (Category E)
- Findings if any

## Critical findings (if any)
[full description, severity, location, fix recommendation]

## Major findings (if any)
[same]

## Minor findings (if any)
[same]

## Verdict + rationale
[200 words, with explicit recommendation: lock at v1.0, or run one
more narrow fix pass to close N findings]
```

## Self-verification before declaring complete

- [ ] Read v0.2 sections touched by the fix pass (per Required reading list above).
- [ ] Walked each of 22 F-* closure checks (Category A).
- [ ] Verified D1, D2, D3 coherence across spec sections (Category B).
- [ ] Verified all 12 new ACs have precondition + action + outcome + verification (Category C).
- [ ] Verified all 9 MINOR fixes appear (Category D).
- [ ] No scope creep, no premium positioning, no Tier-3 deprecation, no upstream spec edits (Category E).
- [ ] Verdict and rationale.

When done, print a 150-word handback summary:
- Findings count by severity
- Top 3 most impactful findings (if any)
- Verdict (READY TO LOCK / READY WITH NARROW FIX / NEEDS FIX ROUND)
- One-sentence rationale

Then stop. Do NOT begin drafting a fix prompt. Operator decides
next move.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~15 min — much shorter than v0.1 audit):

1. Read `specs/SPEC-006-v0-2-audit.md`.
2. If verdict is **READY TO LOCK**: rename SPEC-006 v0.2 → v1.0 (single version bump commit), then proceed to `BUILD_PHASE5_PROMPT.md` for gateway implementation.
3. If verdict is **READY WITH NARROW FIX**: draft `FIX_SPEC_006_V0_3_PROMPT.md` covering only the narrow findings. Run, lock at v1.0.
4. If verdict is **NEEDS FIX ROUND** (unlikely given the v0.1 audit consensus): the v0.2 fix introduced regression; investigate root cause.

## Why this regression check matters

The v0.1 audit was cross-model (Codex + Claude). The v0.2 fix pass was single-model (Claude executed the FIX prompt). Independence is preserved by running this regression audit in Codex — same discipline as round 2 of the v0.1 audit. A narrow Codex pass on v0.2 closes the audit lineage cleanly without rerunning the full 21-MAJOR sweep.

Historical precedent: SPEC-003 v0.4's narrow regression check closed three round-1 findings in one pass. SPEC-006 v0.2 has a wider delta (22 + 12 ACs vs SPEC-003's three) so expect 3-5 regression findings rather than zero. Targeting `FIX_SPEC_006_V0_3_PROMPT.md` as a probable narrow follow-up is reasonable.
