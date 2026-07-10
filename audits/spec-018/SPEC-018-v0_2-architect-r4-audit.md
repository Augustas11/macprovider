# SPEC-018 v0.2.3 - Architect Lane r4 Audit

**Date:** 2026-06-28
**Reviewer:** codex architect lane
**Verdict:** READY TO LOCK from architect lens

## Tally: C/H/M/m/Q

C=0 CRITICAL / H=0 HIGH / M=0 MEDIUM / m=1 minor / Q=0 questions

## Scope

This defensive r4 audit reviewed:

- `specs/SPEC-018-agentic-tool-calling.md` v0.2.3
- `specs/SPEC-018-v0_2-architect-r3-audit.md`
- `specs/SPEC-018-v0_2-blindspot-audit.md`
- `specs/SPEC-018-v0_2-blindspot-absorption-prompt.md`
- `specs/SPEC-018-v0_2_3-DRAFT-NOTES.md`
- `specs/SPEC-018-v0_2-critic-blindspot-audit.md`
- `specs/SPEC-018-v0_2-product-narrative-blindspot-audit.md`

Review was limited to r3 regression risk, prior blind-spot closure, and v0.2.3 additions. Locked v0.1.5 remains out of scope except where v0.2.3 explicitly amends or supersedes earlier target prose.

## Summary

No architect-level lock blocker found. The v0.2.3 body absorbs the load-bearing blind-spot fixes without reintroducing the r3 `prompt_echo_blocked` ambiguity, and the new section 10c.1 amendment discipline is concrete enough to prevent silent locked-invariant scope cuts.

One non-blocking stale-reference cleanup remains: section 12 still says model-hash registry and prompt-echo prevention are "reserved for v0.2" even though v0.2.3 now defers both to v0.3. Active normative sections point the right way, so this is minor housekeeping rather than a lock blocker.

## Analysis

### r3 architect verdict regression check

Status: HOLDS.

The r3 architect audit was READY TO LOCK with 0/0/0/0/0 and focused on v0.2.2 consistency around `prompt_echo_blocked`, AC-50 through AC-55, section 10d subsection numbering, and `invalid_tools` inheritance (`specs/SPEC-018-v0_2-architect-r3-audit.md:23`, `:45`, `:55`, `:66`, `:72`, `:82`).

v0.2.3 changes the architecture by deleting the active prompt-echo guard instead of preserving the v0.2.2 internal fallback reason. That does not regress the r3 code-domain closure: v0.2.3 explicitly says it ships without prompt-echo mitigation (`specs/SPEC-018-agentic-tool-calling.md:23`, `:29`), records the deletion as an AMENDED v0.2.3 clause (`:686`), logs Amendment 2 in section 10c.1 (`:705`), and states that there is no `prompt_echo_blocked` buyer-visible or internal guard-trigger path in v0.2.3 (`:740`). The AC list moves from AC-48b directly to AC-50 (`:624`, `:626`, `:628`), and the draft notes confirm AC-49 removal (`specs/SPEC-018-v0_2_3-DRAFT-NOTES.md:25`).

### Load-bearing v0.2.3 closure checks

PASS: section 3.9 deletion is fenced as an amendment.

The absorption prompt required deleting section 3.9 and AC-49, then documenting residual same-family echo risk (`specs/SPEC-018-v0_2-blindspot-absorption-prompt.md:31`, `:35`). The spec now states the deletion in the v0.2.3 change-log entry with residual risk, rationale, and v0.3 mitigation (`specs/SPEC-018-agentic-tool-calling.md:29`), repeats the AMENDED v0.2.3 clause at the original lock-amendment site (`:686`), logs it in section 10c.1 (`:705`), and marks the full guard as a v0.3 candidate (`:973`, `:976`). This closes the architect concern that deletion might become an undocumented scope cut.

PASS: section 10c.1 is concrete enough for lock discipline.

The new rule requires later amendments to name the clause, state rationale, name replacement mitigation or residual risk, carry an AMENDED label at the original clause location, and enumerate the amendment in the log (`specs/SPEC-018-agentic-tool-calling.md:692`, `:694`, `:696`, `:698`, `:699`, `:701`, `:703`). That directly addresses the blind-spot concern that "explicit named amendment with rationale" was under-specified (`specs/SPEC-018-v0_2-blindspot-audit.md:98`, `:100`, `:105`). Tradeoff: the rule is process discipline, not an approval workflow; it prevents silent edits but does not define who approves future weakening. For this v0.2.3 lock candidate, that is acceptable because the prompt requested the (a)-(d) discipline rule, not a governance regime.

PASS: AC-48 split removes the impossible openai-python+Cline fixture.

The critic finding was that Cline uses `@ai-sdk/openai-compatible`, not openai-python (`specs/SPEC-018-v0_2-blindspot-audit.md:19`, `:23`, `:27`). v0.2.3 splits the gates: AC-48a covers openai-python terminal-error behavior (`specs/SPEC-018-agentic-tool-calling.md:624`), AC-48b covers Cline v4.0.0 through the Vercel AI SDK OpenAI-compatible provider path (`:626`), and section 10d.4 states the same separation (`:828`, `:858`). The money-path question is therefore no longer hidden behind the wrong SDK fixture.

PASS: auto-downgrade is now scoped to the buyer/provider tuple.

The critic H-3 attack was buyer-vs-buyer downgrade DoS from per-provider attribution (`specs/SPEC-018-v0_2-blindspot-audit.md:42`, `:44`, `:46`). v0.2.3 changes AC-45 to per-(buyer, provider), sets 3 malformed streams in 5 minutes, adds 10-minute clean recovery, and adds AC-45c to prove one buyer cannot downgrade others (`specs/SPEC-018-agentic-tool-calling.md:618`). Section 10d.4 matches that tuple model and recovery rule (`:824`, `:826`). No architect-level blast-radius contradiction found.

PASS: mechanical additions are internally aligned.

AC-44 now defines NTP-anchored skew, heartbeat verification, and skew-corrected p95 calculation (`specs/SPEC-018-agentic-tool-calling.md:616`), closing the cross-clock arithmetic gap described by the critic (`specs/SPEC-018-v0_2-blindspot-audit.md:112`, `:117`). AC-56 adds the 6 MiB total decoded prompt aggregate cap (`specs/SPEC-018-agentic-tool-calling.md:640`), section 10d.0 includes `prompt_aggregate_too_large` as a non-retryable invalid-request code (`:755`), and section 10d.1 maps the same cap and code before inference (`:787`, `:809`). AC-46 and section 10d.0.1 both frame model-hash observation as buyer-visible field/type assertion plus provider-side self-test (`:620`, `:768`).

## Root Cause

The only residual issue is version-layer drift: v0.2.3 correctly moved active scope to v0.3 for model-hash registry and prompt-echo prevention, but old forward-looking prose remains in section 12 saying those items are "reserved for v0.2" (`specs/SPEC-018-agentic-tool-calling.md:1003`, `:1005`). That stale text survived because v0.2.3 added explicit superseding notes in the header, section 10a, section 10c.1, section 10d, and section 10d.8, but did not sweep the non-goals appendix.

## Fresh Findings

### m-1 - Stale section 12 v0.2 references for deferred trust-boundary work

Severity: minor.

Section 12 still says provider-side model-fingerprint validation is reserved for v0.2 per section 10a #2 and prompt-echo injection prevention is reserved for v0.2 per section 10a #3 (`specs/SPEC-018-agentic-tool-calling.md:1003`, `:1005`). Active v0.2.3 sections say the opposite for current scope: quick orientation defers both to v0.3 (`:13`), the v0.2.3 change-log says the prompt-echo guard is deleted and v0.3 owns the full guard (`:23`, `:29`), section 10d.0 says deliverables #2 and #3 are deferred to v0.3 (`:713`), and section 10d.8 says those deliverables MUST NOT be v0.2 public wire requirements beyond the explicit amendments (`:973`, `:976`).

Architect assessment: not a MEDIUM because the active normative path is clear and repeated, and section 10d explicitly supersedes section 10a for v0.2.0+ scope (`specs/SPEC-018-agentic-tool-calling.md:713`). It is still worth cleaning before publication because section 12 is active-looking prose and can confuse a reader who jumps to non-goals.

## Recommendations

1. Lock v0.2.3 from the architect lane - low effort - high impact. No Critical, High, or Medium architect findings remain.
2. Optional housekeeping: update section 12 lines 1003 and 1005 to say model-hash registry binding and prompt-echo prevention are deferred to v0.3 per section 10c.1 and section 10d.8 - low effort - low risk. This removes stale wording without changing behavior.

## Trade-offs

| Option | Pros | Cons |
|---|---|---|
| Lock v0.2.3 as-is | Preserves momentum; active normative sections already resolve scope correctly; no C/H/M blocker remains. | Leaves a minor stale-reference cleanup for later readers. |
| Patch section 12 before lock | Eliminates the only stale active-looking prose; aligns non-goals with v0.2.3 deletion and deferral. | Touches the lock candidate again for a non-blocking clarity fix, requiring at least a quick recheck. |

## References

- `specs/SPEC-018-v0_2-architect-r3-audit.md:23` - r3 closure-status section begins; r3 found no architect blockers.
- `specs/SPEC-018-v0_2-architect-r3-audit.md:55` - r3 `prompt_echo_blocked` consistency check.
- `specs/SPEC-018-v0_2-blindspot-audit.md:19` - critic H-1 openai-python/Cline mismatch.
- `specs/SPEC-018-v0_2-blindspot-audit.md:31` - critic H-2 prompt-echo guard deletion decision.
- `specs/SPEC-018-v0_2-blindspot-audit.md:42` - critic H-3 per-provider auto-downgrade DoS.
- `specs/SPEC-018-v0_2-blindspot-audit.md:98` - section 10c.1 amendment-discipline requirements.
- `specs/SPEC-018-v0_2-blindspot-absorption-prompt.md:31` - required section 3.9 deletion and section 10c second amendment.
- `specs/SPEC-018-v0_2_3-DRAFT-NOTES.md:10` - absorption note for section 3.9 and AC-49 deletion.
- `specs/SPEC-018-agentic-tool-calling.md:7` - Quick orientation block starts.
- `specs/SPEC-018-agentic-tool-calling.md:23` - v0.2.3 deletion of prompt-echo guard stated for skimmers.
- `specs/SPEC-018-agentic-tool-calling.md:29` - v0.2.3 load-bearing amendment and mechanics summary.
- `specs/SPEC-018-agentic-tool-calling.md:574` - AC-25a SPEC-018 self-reading requirement.
- `specs/SPEC-018-agentic-tool-calling.md:616` - AC-44 NTP-skew-corrected timing.
- `specs/SPEC-018-agentic-tool-calling.md:618` - AC-45 per-(buyer, provider) downgrade and AC-45c.
- `specs/SPEC-018-agentic-tool-calling.md:620` - AC-46 buyer-side type assertion plus provider self-test.
- `specs/SPEC-018-agentic-tool-calling.md:624` - AC-48a openai-python ecosystem terminal-error gate.
- `specs/SPEC-018-agentic-tool-calling.md:626` - AC-48b Cline/Vercel AI SDK terminal-error gate.
- `specs/SPEC-018-agentic-tool-calling.md:640` - AC-56 total decoded prompt aggregate cap.
- `specs/SPEC-018-agentic-tool-calling.md:646` - section 10a reader note.
- `specs/SPEC-018-agentic-tool-calling.md:686` - AMENDED v0.2.3 section 3.9 deletion.
- `specs/SPEC-018-agentic-tool-calling.md:692` - section 10c.1 lock-amendment discipline starts.
- `specs/SPEC-018-agentic-tool-calling.md:705` - Amendment 2 log entry.
- `specs/SPEC-018-agentic-tool-calling.md:713` - section 10d.0+ reader note superseding section 10a for active v0.2 scope.
- `specs/SPEC-018-agentic-tool-calling.md:740` - no `prompt_echo_blocked` buyer-visible or internal guard-trigger path in v0.2.3.
- `specs/SPEC-018-agentic-tool-calling.md:755` - `prompt_aggregate_too_large` stable error code.
- `specs/SPEC-018-agentic-tool-calling.md:768` - section 10d.0.1 model-hash observation contract.
- `specs/SPEC-018-agentic-tool-calling.md:824` - section 10d.4 per-(buyer, provider) downgrade rule.
- `specs/SPEC-018-agentic-tool-calling.md:828` - Cline uses Vercel AI SDK, with Cline behavior gated by AC-48b.
- `specs/SPEC-018-agentic-tool-calling.md:973` - section 10d.8 states deferred deliverables must not become v0.2 public wire requirements.
- `specs/SPEC-018-agentic-tool-calling.md:976` - v0.2.3 ships without prompt-echo mitigation per Amendment 2.
- `specs/SPEC-018-agentic-tool-calling.md:1003` - stale section 12 model-hash "reserved for v0.2" wording.
- `specs/SPEC-018-agentic-tool-calling.md:1005` - stale section 12 prompt-echo "reserved for v0.2" wording.
