# SPEC-018 v0.1.3 — Security-lane round-4 audit

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## v0.1.3-delta verification
[per delta listed above: CONFIRMED | RESIDUAL | NEW-ISSUE]

## Net residual threat model for v0.1.3
[2-4 sentences updated from r3]

## Findings (if any)

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**.

## Final prompt

# SPEC-018 v0.1.3 — SECURITY-lane round-4 audit (lock confirmation after Claude blind-spot absorption)

You are the **security** lane of a round-4 audit of `specs/SPEC-018-agentic-tool-calling.md` v0.1.3. This is a lock confirmation round after Claude critic blind-spot absorption.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1.3 (commit `db6bd19`)
- Round-3 returned READY TO LOCK; v0.1.3 absorbed Claude critic blind-spot findings including 3 HIGH security-adjacent issues.
- Critic findings: `specs/SPEC-018-critic-blindspot-audit.md`

## What changed in v0.1.3 (security lane lens)

1. **§3.6 mixed-sentinel rule dropped** (Critic H-3) — was a buyer-prompt DoS vector. Verify dropping it does NOT reopen any cross-family bypass: a Qwen-modelID request never runs the Llama parser; §3.2 modelID-match is the sole defense; is that genuinely sufficient?
2. **§3.4 + §8.4 + AC-21 depth/byte caps** (Critic M-1) — 32 depth / 256 KiB byte caps on parser + commit-validator. Verify the caps actually close the JSON-parser DoS and that 32 is not too small (e.g. legitimate tool-call argument structures with deeper-than-32 nesting from real frameworks).
3. **§10c relocated v0.2 unknown-hash fail-closed invariant** (Critic M-2 + Narrative Q-1). The clause now says:
   - Provider operator-only overrides without buyer consent are non-compliant
   - Buyer-consent override requires explicit consent header + mandatory response field at `choices[0].message`
   - Does this language actually close the trust-transfer loophole, or can a sufficiently bad-faith v0.2 implementer still self-grant? Particularly: who validates the "explicit consent header" — provider, coordinator, or buyer? If provider, this is again honor-system.
4. **§10c `call_` ID prefix protection** (Critic M-4) — future ID rescope MUST preserve prefix or major bump. Security implication: does prefix-stripping unlock any session-tracking / correlation attack?
5. **§2.3 sorted-keys recursive** (Critic M-5) — closes SPEC-015 receipts binding mismatch. Verify this doesn't introduce a new canonicalization attack (e.g. timing-side-channel on key sort).
6. **§3.2 modelID empty/whitespace fallback rule added** — closes an edge case. Verify the rule is consistent with SPEC-001 request validation.

## Round-4 lane scope

1. **Verify each v0.1.3 security delta absorbs its corresponding critic finding cleanly.**
2. **Updated net residual threat model.** v0.1.3 closes 3 HIGH + 5 MEDIUM from the critic lane. Restate the worst realistic v0.1.3 attack in 2-4 sentences. Has it moved from v0.1.2's baseline?
3. **Find any new security surface introduced by v0.1.3's edits.** Specifically:
   - The new buyer-consent override path (§10c) creates a new wire signal (`X-MacProvider-Allow-Unregistered-Hash` header + `model_hash_unregistered` response field). Does this create a new attack vector (forged header, response field stripping by malicious gateway, etc.)?
   - The AC-7 "at framing positions only" reword — could a malicious provider use this to smuggle framing markup inside `arguments` values?
   - The §3.6 drop — any defense-in-depth lost vs the modelID-match-only approach?

## Output format

```
# SPEC-018 v0.1.3 — Security-lane round-4 audit

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## v0.1.3-delta verification
[per delta listed above: CONFIRMED | RESIDUAL | NEW-ISSUE]

## Net residual threat model for v0.1.3
[2-4 sentences updated from r3]

## Findings (if any)

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**.

## Raw output

```text
# SPEC-018 v0.1.3 — Security-lane round-4 audit

## Counts
CRITICAL: 0  
HIGH: 0  
MEDIUM: 0  
MINOR: 0  
QUESTIONS: 0

## v0.1.3-delta verification
1. §3.6 mixed-sentinel rule dropped: CONFIRMED. §3.2 + §3.6 now pin parser selection to the matched `modelID`; a Qwen-modelID request never runs the Llama parser. No cross-family bypass reopens.

2. §3.4 + §8.4 + AC-21 depth/byte caps: CONFIRMED. The 32-depth / 256 KiB caps close the unbounded parser and commit-validator DoS path. Local examples/tests use shallow ordinary tool arguments; 32 levels is not plausibly too small for real tool-call argument objects.

3. §10c unknown-hash fail-closed + buyer-consent override: CONFIRMED. The provider-operator-only override is now explicitly non-compliant, and the buyer-consent path requires both a request-level consent header and a response-visible `choices[0].message` field. A v0.2 implementer must still allocate this through SPEC-006 header allowlisting, but the v0.1.3 invariant closes the trust-transfer loophole.

4. §10c `call_` ID prefix protection: CONFIRMED. Prefix preservation protects existing SDK/tooling assumptions. Prefix stripping would mainly break validators/correlation tooling, not create a new session-tracking attack; preserving `call_` is the right compatibility lock.

5. §2.3 recursive sorted keys: CONFIRMED. Recursive sort aligns wire bytes with SPEC-015 canonical receipt binding. It does not introduce a meaningful canonicalization attack; timing side channels from sorting model-produced arguments are not security-relevant here.

6. §3.2 missing/empty/whitespace `modelID`: CONFIRMED. SPEC-001 requires `model`; §3.2’s fallback is a defensive default if validation is loosened or bypassed, and is consistent with fail-closed parser selection.

## Net residual threat model for v0.1.3
The worst realistic v0.1.3 attack remains a tool-capable or falsely advertised supported-family model emitting syntactically valid tool-call markup for a buyer-declared tool, causing macprovider to synthesize `tool_calls[]` even though the intent is hostile or prompt-echoed. The mitigation remains buyer-side policy validation before execution; v0.2’s model-hash-bound grammar selection and prompt-echo guard are still required to close this at the provider layer. Compared with v0.1.2, v0.1.3 improves the baseline by removing the mixed-sentinel DoS and adding bounded JSON validation; the primary residual trust boundary is unchanged.

## Findings (if any)
None.

## Verdict
READY TO LOCK

