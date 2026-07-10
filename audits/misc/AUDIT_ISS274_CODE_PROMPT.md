# AUDIT — Issue #274 — CODE lane

## Goal
Lock-step code-quality audit on PR-pending commit `0e4dce2` (branch `fix/iss274-provider-id-validator`). Bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW + INFO allowed.

## Scope (read these files only — do NOT propose changes outside)

- `phase4-coordinator/internal/config/config.go` (lines 15-35 new export; line ~1040 refactored call site)
- `phase4-coordinator/internal/ws/messages.go` (lines 1-10 imports; ParseHello around line 287; parseAuthInitial around line 395; parseAuthProof around line 530)
- `phase4-coordinator/internal/auth/tokens.go` (lines 1-22 imports; IssueToken around line 412; MintAdmissionTokenAndPairOT around line 834)
- `phase4-coordinator/internal/config/iss274_provider_id_validator_test.go` (new)
- `phase4-coordinator/internal/ws/iss274_provider_id_validator_test.go` (new)
- `phase4-coordinator/internal/auth/iss274_provider_id_validator_test.go` (new)

## Context

Issue #274 was filed today (2026-06-30) as a SECURITY codex audit follow-up from #266 Tranche 3. The pool.Provider.SortKey method (introduced by #266 T3a) concatenates `ProviderID + "/" + AssignedID` and is used as a map key across the routing pipeline (excluded sets, balanced-score cache, faulted-route tracking). The "/" delimiter is only unambiguous when no ProviderID contains a literal "/".

Pre-#274:
- Configured pinned providers: gated on `providerIDPattern = ^[a-zA-Z0-9_.-]{1,64}$` via `config.validateProviders`
- WS self-serve (Hello, auth_request initial/proof): only `requireString` (non-empty + non-control-char)
- Admission `IssueToken`, `MintAdmissionTokenAndPairOT`: only `strings.TrimSpace` + non-empty

The fix exports `config.ValidateProviderID(s string) error` and wires it through all five paths. Existing config validation refactored to use the new helper.

## Lens — CODE

Audit for:

- Style consistency with house conventions (naming, error-wrapping, log-emission patterns)
- Test coverage adequacy (positive + negative cases for each new path; do tests exercise what the fix claims)
- Refactor cleanliness — was the existing `providerIDPattern.MatchString` call site genuinely replaced (no dead branches; no duplicated logic)?
- Error semantics — does the badField surface to the WS close-frame still produce a usable error envelope?
- Idiomaticity — is exporting `ValidateProviderID` from `internal/config` the right home, or does it belong on `internal/pool` (where the consumer lives)?
- Import-cycle risk — does the new edge (`internal/auth` → `internal/config`, `internal/ws` → `internal/config`) introduce new cycles or worsen package coupling?
- Are the validator call sites placed BEFORE other transformations that would mask the bad ID (e.g. before lookups, before TrimSpace logic)?

## Out of scope

- Security analysis (handled by SECURITY lane)
- Architectural placement vs SPEC alignment (handled by ARCHITECT lane)

## Output format

```
SEVERITY-N (CRITICAL|HIGH|MEDIUM|LOW|INFO) — <one-line title>
File: <path>:<line>
Finding: <what>
Risk: <why it matters>
Recommendation: <concrete fix>
```

At the end, summarize the count by severity: `C/H/M/L/INFO = a/b/c/d/e`.

If you find nothing above LOW, say `ACCEPT — 0 C/H/M`.
