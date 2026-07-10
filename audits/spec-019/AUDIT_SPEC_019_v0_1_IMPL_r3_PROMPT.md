# SPEC-019 v0.1.5 IMPL — round-3 final defensive audit (TIGHT)

Audit SPEC-019 v0.1.5 IMPL at HEAD `70b5c44` on branch
`impl/spec-019-v0-1` (worktree
`/Users/augstar/macprovider-impl-spec-019-v0-1`).

**Final defensive round.** r2 absorbed 1 CRITICAL + 1 HIGH + 1 MEDIUM
across 3 surfaces. 3-of-6 lanes (codex code, claude critic, claude
narrative) returned READY TO MERGE at r2.

r2 surfaces touched in `70b5c44`:

- **A**: `server.go:2125-2131` — `forwardWSNonStreaming` end-handling
  sets `FaultFlag: billing.FaultBreakerQualifying` when `end.Status`
  is a SPEC-019 detail code. Closes architect C-1 + security H-1
  (convergent).
- **B**: new `phase4-coordinator/internal/buyer/structured_output_provider_error_test.go`
  WS-path money-path regression test (mirrors HTTP-path test).
- **C**: `JSONSchemaValidator.swift:46-54` — `validateJSONObjectOrArray`
  error message extended with prose-buyer migration hint. Closes
  PD-M1.

Smoke baseline:
- Swift: 618 tests / 0 failures (was 617; +1 new test).
- Go coord + gateway: green.

Bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM** = READY TO MERGE → IMPL PR
opens. If r3 returns 0/0/0, no r4 needed.

## Per-lane lens

For each lane:

1. **Closure check** of your r2 findings (in
   `specs/SPEC-019-v0_1-IMPL-{lane}-r2-audit.md`).
2. **Regression probe** of the 3 r2 surfaces.

Specifically:

### Architect (had 1 CRITICAL at r2)

- Closure of C-1 (WS-tunneled FaultBreakerQualifying): verify
  `server.go:2125-2131` actually sets `FaultFlag` on the SPEC-019
  branch, AND that the path to `recordRow` carries it through.

- Probe: does the new branch trigger on EXACTLY the 2 SPEC-019 codes
  (`malformed_json_response`, `json_schema_validation_failed`) and
  nothing else? Or could a legacy code accidentally trigger
  FaultBreakerQualifying now?

### Code (was 0/0/0 at r2)

- Closure: re-verify r1 closures still hold (no regression from r2
  edits in the surrounding 5 lines).
- Probe: the new WS test mirrors the HTTP test. Does it use the same
  assertion library + fixture pattern, or has it drifted? Grep the
  two test bodies.

### Security (had 1 HIGH at r2)

- Closure of H-1 (WS-tunneled FaultBreakerQualifying): same as
  architect C-1 — verify the fix lands AND that the existing HTTP
  classification didn't drift.
- Probe: is there a third path (e.g., streaming WS) that needs the
  same treatment? Grep all `requestLogAttempt{...}` constructors and
  verify which ones already set `FaultFlag` for SPEC-019 codes vs
  which don't (and shouldn't).

### Product-design (had 1 MEDIUM at r2)

- Closure of PD-M1 (json_object scalar-root migration hint): verify
  `validateJSONObjectOrArray` message now includes
  `response_format: {"type":"text"}` or `omit the field`.
- Probe: the message is now longer. Is it still fit-for-purpose as
  a buyer-facing string (not too verbose, no unexpanded
  placeholders)?

### Critic (Claude blind-spot — was READY TO MERGE at r2)

- Confirm closure on the architecture/security/PD r2 fixes.
- Fresh probe topics:
  - Does the new WS path correctly propagate `retryable` from the
    end-frame envelope into the buyer envelope, OR is the buyer-side
    `retryable` always hardcoded?
  - The HTTP path uses `isSpec019ProviderDetailCode` helper. Is the
    WS path using the same helper or a duplicated check?
  - Could the r2 fix introduce a regression where existing legacy
    WS error codes accidentally pick up FaultBreakerQualifying
    because the predicate is too broad?

### Narrative (Claude blind-spot — was READY TO MERGE at r2)

- Confirm r2 commit message at `70b5c44` is coherent.
- New WS test is named clearly?
- IMPL chain now 5 commits long — does the chronological story still
  read for a PR reviewer?
- Any TODO/FIXME left from the absorption?

## Output format

Write findings to `specs/SPEC-019-v0_1-IMPL-{lane}-r3-audit.md`:

```
**Verdict:** {READY TO MERGE | FIX REQUIRED}
**Tally:** C/H/M/m/Q = N/N/N/N/N

## Closure verified
- r2 finding: CLOSED | PARTIAL | REGRESSED (cite file:line)

## Fresh findings
{if any, under None. if 0/0/0}

## Verdict justification
```

Bar: 0/0/0 across all 6 = READY TO MERGE → IMPL PR opens.
