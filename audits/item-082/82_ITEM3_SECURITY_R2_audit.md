CRITICAL (0):
HIGH (0):
MEDIUM (0):
LOW (0):
QUESTIONS (0):

Security lane r2 notes:
- Future-dated canonical `last_used_at` rows still pass the freshness gate by design. A timestamp 100 years in the future parses under the strict layout, `parsed.Before(cutoff)` is false, and the row is not stale. That is the right semantic for this audit: the gate asks whether active rows have a non-NULL Bearer-auth timestamp no older than the allowed window, not whether the coordinator DB clock history is globally sane. Flagging `last_used_at > now + skew` would be a separate DB-integrity hardening check, not required to close the credential-capture surface.
- The future-dated concern from r1 L1 is not a remotely exploitable false-pass path under the reviewed threat model. Production code does not accept attacker-controlled `last_used_at`; successful Bearer validation stamps coordinator-owned time through `ValidateAndMarkTokenUsed`, legacy marking uses `MarkTokenUsed`, and token creation paths use `nowString()` / `timeText()` for canonical UTC second-precision values.
- The non-canonical-format reject is defense in depth and does not regress production behavior. `preFlipAuditRun` parses non-NULL `last_used_at` with layout `2006-01-02T15:04:05Z` and treats parse failures as stale; production writers use the same canonical UTC RFC3339Z second-precision format.
- Missing-DB fail-closed closes the operator-typo false-pass class. `preFlipAuditRun` now `os.Stat`s the `--db` path before `auth.OpenStore`, returns "does not exist" on a missing path, and therefore does not create an empty SQLite file that could report `safe_to_flip=true`. I do not see an attacker-controlled exploit path here; `pre-flip-audit` is an operator-run local deploy gate, so the practical risk was confused-operator phantom evidence.

Key evidence:
- Missing DB path is rejected before opening the store: `phase4-coordinator/cmd/coordinator-cli/main.go:352`.
- Strict parse and typed freshness comparison are used for every non-NULL active row: `phase4-coordinator/cmd/coordinator-cli/main.go:372`, `phase4-coordinator/cmd/coordinator-cli/main.go:408`, `phase4-coordinator/cmd/coordinator-cli/main.go:421`.
- NULL `last_used_at` remains stale, and revoked rows remain ignored: `phase4-coordinator/cmd/coordinator-cli/main.go:388`, `phase4-coordinator/cmd/coordinator-cli/main.go:392`.
- Production token writers use canonical coordinator-owned timestamps: `phase4-coordinator/internal/auth/tokens.go:428`, `phase4-coordinator/internal/auth/tokens.go:582`, `phase4-coordinator/internal/auth/tokens.go:619`, `phase4-coordinator/internal/auth/tokens.go:855`, `phase4-coordinator/internal/auth/tokens.go:1220`.
- r2 tests cover missing DB fail-closed, non-canonical timestamp stale behavior, JSON NULL coverage, and widened near-boundary timing: `phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:191`, `phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:211`, `phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:226`, `phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:140`.

VERDICT: security lane r2 READY TO MERGE
