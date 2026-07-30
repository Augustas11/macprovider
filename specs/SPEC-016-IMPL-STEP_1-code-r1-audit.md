# SPEC-016 IMPL Step 1 — codex CODE REVIEW lane, round 1

## Verdict (code review lane only)

BLOCK

## Counts

| CRITICAL | MAJOR | MEDIUM | LOW |
|----------|-------|--------|-----|
| 1 | 0 | 1 | 0 |

## Findings

[code:1.1] [CRITICAL] Rotation bypasses `payout_allowed=0` and re-enables payouts  
  File: `phase4-coordinator/internal/payout/addresses.go:408`  
  What: On rotation, the handler updates `provider_payout_addresses` with `payout_allowed=1` unconditionally. It only reads the existing `address` before the update and never checks an existing `payout_allowed=0` row. This violates SPEC-016 §3.3’s required `409 Conflict — payout_allowed=0` operator gate and §3.5’s settlement exclusion for disabled rows.  
  Why: A provider with a disabled payout row can submit a valid rotation and flip the compliance gate back to allowed, making queued payouts eligible after cooling-off. That is a money-out gate bypass.  
  Fix: In the same `BEGIN IMMEDIATE` transaction, select `address, payout_allowed`; if `payout_allowed=0`, roll back and return 409. On valid rotations, preserve the existing `payout_allowed` value instead of setting it to `1`.

[code:1.2] [MEDIUM] Uppercase `0X` nonce prefix splits anti-replay keys  
  File: `phase4-coordinator/internal/payout/addresses.go:333`  
  What: `DecodeNonce32` accepts both `0x` and `0X`, but nonce storage canonicalization only trims lowercase `0x`. A request with `0X...` stores `0x0x...`, while the same bytes with `0x...` stores `0x...`.  
  Why: The same EIP-712 signature over the same bytes32 nonce can be replayed once with uppercase prefix and once with lowercase prefix because the anti-replay primary key sees different nonce strings. This violates SPEC-016 §3.2’s nonce replay table contract.  
  Fix: Canonicalize from decoded bytes, e.g. `nonceLowerHex := "0x" + hex.EncodeToString(nonce32[:])`, or reject non-lowercase `0x` at decode.

## Tests run

- `go test -race ./internal/payout/...` — passed
- `go test ./...` — passed
- `go vet ./...` — passed
- `git diff --check 1df0235^..1df0235` — passed
- `go test -count=1 ./...` — passed

`lsp_diagnostics` was not available in this session; Go test/vet were used as the type/static diagnostic substitute.

## SPEC drift catalog (code-side only)

- SPEC-016 §3.3 line 660 requires 409 when `payout_allowed=0`; implementation at `addresses.go:408` resets the flag to 1.
- SPEC-016 §3.2 anti-replay table requires one PK per `(canonical_address, nonce)`; implementation at `addresses.go:333` can create two string keys for the same bytes32 nonce.

## What I didn't review

Security-only and architecture-only concerns were left to the sibling lanes as requested. I did not review Step 2/3/4 runner/admin endpoint behavior beyond Step 1 schema and startup invariants.

## Cross-cutting code observations

The `BEGIN IMMEDIATE` TOCTOU pause re-check is present and the race test passes. EIP-55 vectors, EIP-712 typehash/wire conversion, `v ∈ {27,28}` rejection, trigger presence, same-DB assertions, and startup `payout_runner_state` initialization are covered by focused tests.

## Note on sibling lanes

This report is code-review scoped. The CRITICAL finding overlaps with money-path safety, but the defect is reported here as a direct SPEC compliance and control-flow bug.


---

_Persisted by Claude session from codex artifact codex-impl-audit-prompt-spec-016-step-1-code-review-lane-lane-1-of-2026-06-25T15-01-42-077Z.md; agent-role tools (Write/Edit) were disallowed so codex returned the report in its artifact body. Claude transcribed verbatim — no edits._
