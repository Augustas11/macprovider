CRITICAL (0):
HIGH (0):
MEDIUM (0):
LOW (1):
  L1. Future-dated last_used_at values are treated as fresh, but no remote write path was found.
      Evidence: phase4-coordinator/cmd/coordinator-cli/main.go:388
      Fix:     Optionally parse last_used_at and flag values later than now plus a small clock-skew allowance as suspicious.
QUESTIONS (0):

Security lane notes:
- SEC-1: The audit catches active rows with last_used_at NULL and active rows older than the cutoff, and it skips revoked rows. The future-timestamp case is not flagged because the code only checks last_used_at < cutoff, but this is not a credential-capture bypass under the reviewed threat model: successful Bearer auth stamps last_used_at via coordinator-owned time, not attacker input.
- SEC-2: Lex comparison is safe for production-written provider_tokens.last_used_at values. WS validation calls ValidateAndMarkTokenUsed, legacy marking calls MarkTokenUsed, and both write nowString() in the canonical UTC RFC3339Z second-precision shape. The direct SQL writes found are tests only.
- SEC-3: The 24h default matches SPEC-003's runbook recommendation. SPEC-003 v0.10.1 also says tighter values such as 1h are appropriate for short deploy windows, which is the right operator guidance.
- SEC-4: pre-flip-audit discloses token_prefix only, not full tokens. That matches the existing list-tokens disclosure surface and the token prefix is the existing 12-character display prefix.
- SEC-5: The audit is a point-in-time operator gate over ListTokens output. Races where a row is used or revoked during/after the run are acceptable because the operator can rerun immediately before flipping; no stale row is hidden by the loop logic itself.
- SEC-6: MUST is the right normative level. The pre-flip audit blocks a security-sensitive flag flip where inheriting an unproven active bearer would preserve the credential-capture surface.

Key evidence:
- pre-flip-audit skips revoked rows, counts active rows, flags NULL last_used_at, and flags last_used_at older than cutoff: phase4-coordinator/cmd/coordinator-cli/main.go:372
- stale result exits non-zero through the command wrapper: phase4-coordinator/cmd/coordinator-cli/main.go:324
- ListTokens reads token_prefix/provider_id/provider_name/created_at/revoked_at/last_used_at from provider_tokens: phase4-coordinator/internal/auth/tokens.go:684
- token prefix length is 12: phase4-coordinator/internal/auth/tokens.go:48
- IssueToken and MintAdmissionTokenAndPairOT create provider_tokens rows with canonical UTC timestamps: phase4-coordinator/internal/auth/tokens.go:428, phase4-coordinator/internal/auth/tokens.go:855
- MarkTokenUsed and ValidateAndMarkTokenUsed stamp last_used_at with nowString(): phase4-coordinator/internal/auth/tokens.go:582, phase4-coordinator/internal/auth/tokens.go:618
- nowString/timeText use UTC RFC3339Z second-precision formatting: phase4-coordinator/internal/auth/tokens.go:1220
- WS Bearer validation uses ValidateAndMarkTokenUsed atomically at upgrade time: phase4-coordinator/internal/ws/server.go:483
- SPEC-003 v0.10.1 requires pipeline integration and allows tighter operator cutoffs: specs/SPEC-003-open-onboarding.md:621
- Tests cover fresh, NULL, old, revoked, JSON output, and non-positive duration behavior: phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:34

VERDICT: security lane READY TO MERGE
