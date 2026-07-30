# Fix prompt — SPEC-006 v0.4 → v0.5 (estimation → actuals swap)

Operator-paste prompt to swap SPEC-006's gateway byte-estimation for
provider-reported actuals now that SPEC-001 v1.2.3 + phase3-binary
v1.2.4 mandates `usage` tokens in cancel-response
`inference_response_end`.

Single-spec narrow patch:
  SPEC-006 v0.4 → v0.5
  "Depends on" updated: SPEC-001 v1.2.2 → v1.2.3

This is the SPEC-006 v0.5 follow-up filed in `FIX_SPEC_001_V1_2_3_PROMPT.md`
and in Decision log Entry 22's open-follow-ups list. Closes the loop
on D-CROSS-1.

**Backward-compat preserved.** Pre-v1.2.4 providers (v1.2.0..v1.2.3
phase3-binaries) MAY omit `usage` in cancel-response. The gateway
MUST fall back to byte-estimation when `usage` is absent. M4 and M1
partner Macs that don't upgrade to v1.2.4 still work; their cancel
events are settled via estimation.

Run in **Claude Code** or **Codex CLI**. Expected duration: ~30 min
(surgical edits to two SPEC-006 sections + AC update).

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are applying one narrow follow-up to SPEC-006 now that SPEC-001
v1.2.3 + phase3-binary v1.2.4 (commit c94da11, tag v1.2.4) mandate
that providers include `usage` tokens in cancel-response
inference_response_end messages.

You will edit two files in place:
  /Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md  v0.4 → v0.5
  /Users/augstar/macprovider-poc/phase5-gateway/implementation-notes.html
    (append "Resolved in v0.5" section)

## Critical constraints

**1. SPEC-006-only patch.** SPEC-001 v1.2.3, SPEC-002 v1.1.4,
SPEC-003 v0.6 stay UNTOUCHED. Verify with
`git diff specs/SPEC-001-phase3-binary.md specs/SPEC-002-coordinator.md
specs/SPEC-003-open-onboarding.md` — should return empty.

**2. Backward-compat preserved.** Pre-v1.2.4 providers may omit
`usage` in cancel-response. The gateway MUST detect this and fall
back to byte-estimation (the existing rule from v0.4). The new rule
is "prefer actuals; fall back to estimation," not "require actuals."

**3. Locked design choices stay locked.** SPEC-006 § 2 is read-only.
D-CROSS-1's high-level lock (provider-reached-vs-not framing for
quota debit) is unchanged; only the cancellation-specific
sub-clause changes from "estimate" to "prefer actuals; estimate as
fallback."

**4. Surgical scope.** This patch touches § 7.2 (streaming
reservation pattern), § 17.5 (client disconnect refund row), and
one or two ACs. Do NOT add unrelated content.

**5. d-inference clean-room.** Do not inspect d-inference source.

## Required reading

1. `specs/SPEC-006-buyer-api.md` v0.4 — the spec under revision.
   Focus on:
   - § 7.2 (streaming quota debit timing; the "ceil(bytes/4)"
     estimation rule)
   - § 17.4-17.7 (failure modes refund matrix; the client-
     disconnect row)
   - § 18 ACs (AC-36 quota refund on 504 zero completion;
     AC-37 streaming quota reservation + settlement — may need
     update or new sibling AC)
   - "Depends on" line at the top

2. `specs/SPEC-001-phase3-binary.md` v1.2.3 — read § 6.6's new
   cancel-usage normative paragraph + AC-17. Verify the actuals
   you'll be consuming are normatively guaranteed (subject to
   backward-compat for pre-v1.2.4 binaries).

3. `specs/FIX_SPEC_001_V1_2_3_PROMPT.md` — context: the prior FIX
   cycle that produced SPEC-001 v1.2.3. Confirms the SPEC-006 v0.5
   follow-up is what gets done here.

4. `beta/DECISION_CRITERIA.md` Entry 22 — the operator's pre-commit
   for "BUILD_PHASE5 against fully-clean spec corpus." This FIX
   closes the last spec-side gap before BUILD_PHASE5 unlocks.

## Findings to fix

### F-606-V3-1 (Entry 22 follow-up) — Streaming quota debit: prefer actuals, fall back to estimation.

**Locations:** SPEC-006 v0.4 § 7.2 (streaming reservation) and §
17.5 (client disconnect refund row in the matrix).

**Problem:** SPEC-006 v0.4 D-CROSS-1 specifies gateway-side
estimation via `ceil(bytes_emitted_so_far / 4)` for cancellation
token accounting. SPEC-001 v1.2.3 now mandates provider-reported
actuals in inference_response_end's `usage` field when triggered by
cancel_request. The gateway should prefer the provider's reported
value (exact) over the byte-divided estimate (coarse).

**Fix (spec text in § 7.2):** Replace the existing estimation
paragraph with:

> For streaming requests where the buyer disconnects mid-stream,
> the gateway settles the daily-quota reservation as follows:
>
> 1. The gateway sends a cancel_request to the coordinator (which
>    forwards to the provider) per the existing cancellation path.
> 2. The provider responds with inference_response_end carrying a
>    `usage` field per SPEC-001 v1.2.3 § 6.6. The gateway MUST
>    settle the reservation to `usage.prompt_tokens +
>    usage.completion_tokens` — the exact tokens the provider
>    actually consumed and emitted.
> 3. If the provider's inference_response_end OMITS the `usage`
>    field (pre-v1.2.4 binaries: v1.2.0 through v1.2.3 do not
>    guarantee usage on cancel), the gateway MUST fall back to
>    `estimated_completion_tokens = ceil(bytes_emitted_so_far / 4)`
>    plus the original prompt-token reservation. The 4-bytes-per-
>    token constant remains the documented coarse approximation
>    for English-leaning content.
>
> Once all production-active providers run phase3-binary v1.2.4 or
> later, the estimation fallback path becomes unreachable in
> practice. A future SPEC-006 patch (v0.6 candidate) may remove
> the fallback when the operator confirms no pre-v1.2.4 binaries
> remain in the pool.

**Fix (spec text in § 17.5 refund matrix):** Update the client-
disconnect row:

| Status | Completion tokens | Quota debited | Rationale |
|--------|-------------------|---------------|-----------|
| ...prior rows unchanged... | | | |
| Client disconnect (v1.2.4+ provider) | provider-reported actual | prompt + actual completion (exact, from usage field) | Provider performed exactly this much work; report is normative per SPEC-001 v1.2.3 |
| Client disconnect (pre-v1.2.4 provider, usage absent) | byte-estimated | prompt + ceil(bytes_emitted/4) (estimated, ±5 tokens typical) | Fallback when usage not yet normatively guaranteed |

(Keep all other rows unchanged.)

### F-606-V3-2 (Entry 22 follow-up) — AC update for cancel-usage path.

**Location:** SPEC-006 v0.4 § 18 ACs. Likely AC-37 (streaming
reservation + settlement) or a new AC-38.

**Problem:** AC-37 in v0.4 tests streaming quota reservation +
settlement under the assumption of byte-estimation. With v0.5's
prefer-actuals rule, the AC should cover both branches: provider
reports usage → settle to exact; provider omits usage → fall back
to estimation.

**Fix:** Either expand AC-37 with two named branches, or split into
AC-37 (v1.2.4+ provider) and a new AC-38 (pre-v1.2.4 fallback).
Prefer the two-branch expansion (matches the AC-26/29/30/34
pattern from v0.4):

```
AC-37 (Streaming quota reservation + settlement):
  Precondition: gateway running with default 100K-token daily quota;
  one v1.2.4+ provider in pool; one pre-v1.2.4 provider in pool.

  Branch A (v1.2.4+ provider — actuals):
    Action: POST /v1/chat/completions with stream=true, max_tokens=200,
            routed to v1.2.4+ provider. Buyer disconnects after
            receiving ~30 completion tokens (~120 bytes).
    Expected: Gateway sends cancel_request; provider's
              inference_response_end includes usage={prompt_tokens=N,
              completion_tokens=30, total_tokens=N+30}. /v1/usage
              shows daily quota decremented by N+30 (exact).
    Verification:
      curl -i -X POST $GATEWAY/v1/chat/completions ... &
      sleep 2 && kill %1
      curl -s $GATEWAY/v1/usage | jq -e '.daily_used == <expected_exact>'

  Branch B (pre-v1.2.4 provider — fallback estimation):
    Action: Same call, routed to pre-v1.2.4 provider. Buyer
            disconnects after ~120 bytes of SSE chunk content.
    Expected: Provider's inference_response_end omits usage. Gateway
              estimates: ceil(120/4) = 30 completion tokens. /v1/usage
              shows daily quota decremented by N+30 (estimated).
    Verification:
      Same curl pattern; assert /v1/usage delta is N+30 (±5 tolerance
      acknowledged in spec prose).
```

If the spec implementer prefers single-AC with branches, this is
the canonical form. If they prefer one-AC-per-branch, AC-37 = Branch
A and AC-38 = Branch B.

## Output requirements

1. SPEC-006 updated in place. Version 0.4 → 0.5. Change log entry at
   the top covering F-606-V3-1 and F-606-V3-2 with reference to
   `specs/FIX_SPEC_001_V1_2_3_PROMPT.md` + commit c94da11 + tag
   v1.2.4.

2. Header "Depends on:" line updated: "SPEC-001 v1.2.2, SPEC-002
   v1.1.4, SPEC-003 v0.6" → "SPEC-001 v1.2.3, SPEC-002 v1.1.4,
   SPEC-003 v0.6". Note SPEC-002 and SPEC-003 versions UNCHANGED;
   only SPEC-001 bumped.

3. § 7.2 has the prefer-actuals + fallback paragraph.

4. § 17.5 refund matrix has separate rows for v1.2.4+ provider and
   pre-v1.2.4 provider client-disconnect cases.

5. § 18 AC-37 expanded with Branch A (v1.2.4+ actuals) and Branch B
   (pre-v1.2.4 fallback), OR AC-37 + AC-38 if split. Both branches
   have explicit status code + body shape + verification command per
   v0.2's F-606-11 AC tightening discipline.

6. `phase5-gateway/implementation-notes.html` gains "Resolved in
   v0.5" section with one-line entries for the two F-* items.

## Self-verification checklist

- [ ] SPEC-006 version 0.4 → 0.5 in header.
- [ ] "Depends on" updated: SPEC-001 v1.2.3 (not v1.2.2). SPEC-002
      v1.1.4 unchanged. SPEC-003 v0.6 unchanged.
- [ ] § 7.2 has the prefer-actuals normative rule + fallback for
      pre-v1.2.4 providers.
- [ ] § 17.5 refund matrix has the v1.2.4+ row (exact, from usage)
      and the pre-v1.2.4 row (estimated, ±5 tolerance).
- [ ] § 18 AC-37 (and possibly AC-38) covers both branches with
      executable verification commands.
- [ ] SPEC-001, SPEC-002, SPEC-003 untouched (empty diffs).
- [ ] D-CROSS-1 lock paragraph in § 2 unchanged (still says
      "provider-reached vs not"); only the cancellation sub-clause
      updates.
- [ ] No new normative content beyond what closes the two F-*
      items.
- [ ] Backward-compat acknowledged: pre-v1.2.4 binaries still work;
      fallback path remains in spec.

If your edits exceed ~80 added lines in SPEC-006, STOP — that's
scope creep. This is a surgical swap.

When done, print a 150-word handback summary:
- F-606-V3-1 and F-606-V3-2 closure
- Whether SPEC-006 v0.5 is READY TO LOCK
- Whether any open question requires operator input (probably none
  expected)
- Note that with v0.5 locked, the spec corpus is fully clean for
  BUILD_PHASE5: SPEC-001 v1.2.3, SPEC-002 v1.1.4, SPEC-003 v0.6,
  SPEC-006 v0.5

Then stop. Do NOT begin implementation. Operator decides next move
(likely: lock corpus, draft BUILD_PHASE5_PROMPT.md).

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~10 min):

1. `git diff specs/SPEC-006-buyer-api.md` — version + "Depends on"
   updated; § 7.2 + § 17 + AC-37 (or 37+38) revised; small change set.
2. `git diff specs/SPEC-001-phase3-binary.md specs/SPEC-002-coordinator.md
   specs/SPEC-003-open-onboarding.md` — should be empty.
3. Verify the spec text explicitly preserves backward-compat for
   pre-v1.2.4 providers (M4/M1 if they haven't upgraded yet) —
   estimation fallback remains.
4. Verify AC-37 (or 37+38) has both branches with executable
   verification.

Then commit. Suggested message:

```
SPEC-006 v0.5: swap estimation for provider-reported actuals

Closes the v0.5 follow-up filed at SPEC-001 v1.2.3 release (commit
c94da11, tag v1.2.4). Provider-reported usage from cancel-response
inference_response_end is now preferred for streaming-disconnect
quota settlement; byte-estimation remains as backward-compat
fallback for pre-v1.2.4 providers.

§ 7.2 — prefer-actuals + fallback paragraph
§ 17.5 — refund matrix splits client-disconnect into v1.2.4+ (exact)
        and pre-v1.2.4 (estimated, ±5 tolerance)
§ 18 AC-37 — expanded with Branch A (actuals) + Branch B (fallback)

"Depends on" updated to SPEC-001 v1.2.3.

Spec corpus now fully clean for BUILD_PHASE5:
- SPEC-001 v1.2.3
- SPEC-002 v1.1.4
- SPEC-003 v0.6
- SPEC-006 v0.5

No upstream spec edits.
```

After commit, decide:

- **Skip regression audit** — defensible. The patch is surgical (80
  lines max), narrow in scope, has no architectural CRITICAL risk.
- **Run a narrow regression check** (Codex single-round, ~20-30 min)
  — only worthwhile if you want belt-and-suspenders before
  BUILD_PHASE5. Historic pattern for ~2-finding patches: regression
  closes with zero findings.

My recommendation: **skip the regression audit** and draft
`BUILD_PHASE5_PROMPT.md` next. The cross-spec audit + 2 prior
regression checks already verified the surrounding architecture;
this is the smallest possible patch on the cleanest possible
corpus state. Diminishing returns curve is steep.

After SPEC-006 v0.5 locks, the spec-design phase is complete and
BUILD_PHASE5 unlocks. Gateway implementation begins as a separate
multi-day session.
