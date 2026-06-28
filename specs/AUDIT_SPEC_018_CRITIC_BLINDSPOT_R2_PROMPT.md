# SPEC-018 v0.1.3 — Claude critic adversarial-verifier round-2 (lock confirmation)

You are the **adversarial verifier** lane returning for round 2 against v0.1.3. Your round-1 pass found 3 HIGH + 5 MEDIUM that codex's four lanes missed. v0.1.3 absorbed all of them. Your round-2 job: did the absorptions actually close the findings, or did they relabel them?

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1.3 (commit `db6bd19`)
- Your round-1 findings: `specs/SPEC-018-critic-blindspot-audit.md`

## Round-2 verification (your previous findings)

For each of your r1 findings, verify the v0.1.3 absorption:

### H-1 (AC-23 tautology)
v0.1.3 AC-23 now says: "A v0.2-or-later regression test captures non-streaming tool-call response fixtures **from the candidate vN.M release** (with any new fields, deltas, or finish reasons enabled) and verifies that a **v0.1.2-targeted client parser** … successfully parses each response without raising on unknown fields and without rejecting due to schema validation."
- Is this now testing the right direction? (vN.M responses with v0.1.2 parser, not v0.1.2 fixtures with v0.1.2 parser?)
- Is there a residual edge case where the AC would still pass on a wire-shape break?

### H-2 (Claude Code / Cursor overclaim)
v0.1.3 removed Claude Code from §1, §1.1, §10a #1, §11 Q1, AC-16b. Replaced with explicit "NOT included: Claude Code (Anthropic Messages API), Cursor IDE chat (proprietary backend), Zed AI assistant (proprietary)."
- Verify every instance of "Claude Code" or "Cursor" in v0.1.3 is now either (a) in the explicitly-excluded list or (b) absent entirely.
- Is the new framework list factually accurate?

### H-3 (mixed-sentinel DoS)
v0.1.3 dropped §3.6 mixed-sentinel rule. AC-22 marked reserved-as-deprecated. §1.2 IMPL deltas reduced from 3 to 2.
- Verify no stale reference to mixed-sentinel remains in §1, §3, §5, §8, §9, §10, §11, §12.
- Did the drop introduce any new cross-family bypass surface §3.2 alone doesn't cover?

### M-1 (unbounded JSON nesting)
v0.1.3 adds depth ≤ 32 + byte ≤ 256 KiB caps to §3.4 (parser) and §8.4 (commit-validator), with AC-21 extended.
- Are these limits the right values? Is 32 deep enough for legitimate tool calls but shallow enough to prevent DoS?
- Is the parallel coverage (parser + commit-validator) complete, or is there a third code path that could decode arbitrarily-nested JSON without the cap?

### M-2 (operator-override loophole)
v0.1.3 relocates to §10c as v0.1.3-locked v0.2 invariant. Now: "provider operator-only overrides without buyer consent are non-compliant." Buyer-consent override requires explicit `X-MacProvider-Allow-Unregistered-Hash` header + mandatory `model_hash_unregistered: true` response field.
- Does this close the loophole, or can a v0.2 implementer still grant themselves the override?
- The header name is illustrative ("e.g.") — is that adequately tight for a v0.2 binding?

### M-3 (§6 pass-through MUST has no AC)
v0.1.3 adds AC-24: WS-frame byte-equivalence test for request-side `tool_calls[]` + `tool_call_id` pass-through.
- Is AC-24 mechanically verifiable? Does it cover the failure modes M-3 named?

### M-4 (call_ prefix protection)
v0.1.3 adds to §10c: "The `id` value format … is part of the protected shape. Future ID rescope (§10b) MUST either preserve the `call_` prefix as a leading substring, or land via a major SPEC-018 version bump."
- Adequate protection?
- §2.1 and §10c now both pin the id format — any drift between them?

### M-5 (sorted-keys depth)
v0.1.3 explicit: "keys sorted recursively at every depth." References SPEC-015 v0.3 binding.
- Adequate?

### m-1..m-4 absorptions
Verify each one cleanly applied without introducing new wording inconsistency.

## New adversarial pass on v0.1.3

After verifying r1 absorption, run a fresh adversarial pass on the v0.1.3-specific changes:

- §10c is now a long section with both additive-invariant rules AND v0.1.3-locked v0.2 invariants. Are they internally consistent? Could a v0.2 author satisfy one and violate the other?
- §1.2 IMPL deltas are author-facing scaffolding. Does anything in §1.2 contradict §1 or §1.1?
- The Status line now says "Draft — ratifies as-built behavior + 2 normative IMPL deltas pending IMPL absorption." Could a reader interpret "Draft" as still meaning "not final design"?
- The depth/byte caps (32 / 256 KiB) are now hard-coded in the SPEC. Is there a reasonable production scenario these block?

## Output format

```
# SPEC-018 v0.1.3 — Critic adversarial round-2

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## r1-absorption verification
[per r1 finding H-1, H-2, H-3, M-1..M-5, m-1..m-4: CONFIRMED | RESIDUAL | NEW-ISSUE]

## New adversarial findings (if any)

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**. Be honest — if v0.1.3 cleanly absorbed and the new content holds up, say so.
