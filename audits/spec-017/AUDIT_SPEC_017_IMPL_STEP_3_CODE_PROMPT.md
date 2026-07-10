# AUDIT_SPEC_017_IMPL_STEP_3 — Code lane

Operator-paste prompt to audit the **Step 3 IMPL code** (handlers
+ middleware + store) under PR `Augustas11/macprovider#173` from
the code-correctness lens.

Audit target is the **Step 3 implementation diff** layered on top
of the converged Step 2 (HEAD `bd68a0a` or later). SPEC-017
v0.1.8 is LOCKED.

Severity: **CRITICAL / HIGH / MEDIUM / LOW / INFO**. Lock target:
0 CRITICAL + 0 HIGH + 0 MEDIUM.

Each round writes
`specs/SPEC-017-IMPL-STEP_3-code-rM-audit.md` — fresh file per
round, NEVER append.

---

```
=== BEGIN PROMPT ===

You are auditing the Step 3 IMPL diff for SPEC-017 at branch
`impl/spec-017-step-1` (PR #173) of github.com/Augustas11/macprovider,
from the CODE lens (handler-level SQL + Go correctness, JSON
shape, header semantics, idempotency, idiomatic Go, dependency
hygiene, test adequacy).

Output: specs/SPEC-017-IMPL-STEP_3-code-rM-audit.md (round M;
fresh file per round, never append).

Severity model:
- CRITICAL — handler/middleware bug that ships wrong contract:
  partner-key leak through public projection field; raw token /
  token_hash in any structured log; non-constant-time secret
  comparison; absent-Authorization auth-failure debit;
  `last_used_at` UPDATE in v0.1; rate-limit bucket leak across
  endpoints; HEAD returns body bytes; 304 carries extra header.
- HIGH — would force a v0.2 fix-round: wrong JSON shape on any
  endpoint, wrong Cache-Control / Vary / X-Stats-Generated-At
  on any response shape, ETag computed over headers (not body)
  or recomputed per request; rate-limit bucket key off-by-one;
  `meta.rewards_populated` computed against
  `provider_rewards_ledger` instead of read from
  `stats_rewards_populated`; `partial_history_since` emitted
  on 24h/7d.
- MEDIUM — handler code-correctness slip without a wrong-on-
  the-wire outcome: missing test, helper naming, error
  wrapping, dead code path.
- LOW — polish.
- INFO — verifications that passed; evidence captured.

Required reading (before writing findings):
- `specs/SPEC-017-network-stats-api.md` v0.1.8 §1.5, §4.3,
  §5.1, §5.2, §5.3, §5.4, §5.6, §5.7, §5.8, §5.9, §9.1, §9.5,
  §9.7.
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 3 block + the
  AC-to-step matrix tail.
- All CODE r1..r(M-1) audit files for Step 3.
- Step 3 source: `phase4-coordinator/internal/stats/`
  handlers, middleware, mux, store; `cmd/coordinator/main.go`
  delta.
- `internal/auth/tokens.go` — match the production
  `sha256(token_utf8_bytes)` discipline.

Category sweep (every category must produce evidence):

A. **JSON shape vs locked §5.1/§5.2/§5.3** — overview's 14
   fields + 30-point timeseries (missing minute = `null`, NOT
   `0`); leaderboard public projection field set vs partner
   projection extension; `meta.rewards_populated` boolean
   present on every leaderboard response; `partial_history_since`
   inclusion logic; health derives `status` at request time
   from `stats_components_health` rows + §9.5 thresholds (no
   `status` column SELECT); health components map has exactly
   7 keys.

B. **Header correctness** — Cache-Control exact strings per
   the four-row table (overview, leader public, leader partner,
   health); Vary exact strings per the four-row table; 304
   carries only ETag + Cache-Control + Vary + empty body
   (no X-Stats-Generated-At, no JSON); X-Stats-Generated-At
   present on every non-304 response; ETag = `sha256(body)`
   computed once per snapshot (consistent within a tick).

C. **Authn flow + crypto** — `sha256(<token>_utf8_bytes)`
   hashing matches `internal/auth/tokens.go` discipline; the
   constant-time comparison is `subtle.ConstantTimeCompare`
   (not `==` / `bytes.Equal`); row 5 origin-rejection performs
   the same hash+SELECT BEFORE Origin evaluation; row 3
   absent-Origin-but-allowlist-non-empty rejects with the same
   work; RFC 6454 normalization is applied before allowlist
   compare (lowercase scheme/host, IDN→Punycode, strip default
   ports, treat trailing-slash/path/query as absent Origin).

D. **Rate-limit buckets** — keys are exactly
   `(client_ip, endpoint)` for public + auth-failure tiers
   and `(partner_keys.id, endpoint)` for partner tier;
   absent-Authorization NEVER debits auth-failure;
   reserve-then-refund pattern on the auth-failure bucket so
   200 partner does not double-count; 503 stale path does NOT
   debit the success bucket; client-IP derivation honors
   trusted-proxy allowlist (untrusted XFF ignored, trusted XFF
   parsed first-hop-after-proxy).

E. **Error envelope vocabulary** — only the six §5.9 codes
   (`bad_request`, `unauthorized`, `method_not_allowed`,
   `rate_limited`, `stats_stale`, `internal`) appear in
   response bodies. No new codes. 304 is exempt — empty body,
   RFC 7232 headers only.

F. **Store correctness** — `internal/stats/store` reads via
   `stats_reader` `*sql.DB` only; SELECTs match the locked
   §9.1 column lists; no UPDATE/INSERT/DELETE on any stats_*
   table from the handler stack; no SELECT against
   `provider_rewards_ledger`, `provider_tokens`,
   `provider_visibility_audit`, `ledger_*` (the per-role
   grant set was authored in Step 1 to enforce this — the
   handler-side code MUST respect it); leaderboard handler
   reads from `stats_leaderboard_*` + LEFT JOIN
   `provider_visibility` (the §6.1 left-join also runs at
   handler time per §5.2 — but the rollup ALSO carries the
   default tuple per round-5/round-6 fixes; pick one and pin
   the semantic in tests).

G. **HEAD support + 405 path** — HEAD on every GET returns
   identical headers, empty body; 405 on POST/PUT/DELETE
   includes `Allow: GET, HEAD, OPTIONS` header + §5.9 envelope.

H. **Tests** — AC coverage per the Step 3 list (AC-1 through
   AC-22 ownership matrix); each AC has a clear pass/fail
   assertion; HEAD test pins identical-headers + zero-body;
   timing test (AC-18) runs below the auth-failure threshold;
   503-not-debited test issues 100 stale + 60 fresh requests;
   metric-label and nginx-log assertions are NOT in this step
   (Step 4.B/4.C).

Validation (run before findings):
- `go build ./...` from `phase4-coordinator/`.
- `go test ./internal/stats/... -count=1`.
- `go test -tags=integration -c ./internal/stats -o
  /tmp/stats-integ.test`.
- `gofmt -l phase4-coordinator/internal/stats
  phase4-coordinator/cmd/coordinator/main.go`.
- `golangci-lint run --config=.golangci.yml ./...` (or
  `make lint-coordinator`).
- `git diff --check origin/main...HEAD`.
- `grep -rn "log\.Println\|fmt\.Print\|os\.Exit\|log\.Fatal"
  phase4-coordinator/internal/stats/` — Step 1 banned these.

Output structure (one document per round, fresh file):

```
# SPEC-017 IMPL Step 3 — Code Audit Round M

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `<sha>` (`<subject>`)
Prior round: `specs/SPEC-017-IMPL-STEP_3-code-r(M-1)-audit.md`
Lens: CODE — SQL/JSON correctness, header semantics, auth-flow
crypto, idempotency, idiomatic Go, dependency hygiene, test
adequacy.

## Category Verdicts
A. JSON shape: PASS/FAIL — ...
B. Header correctness: PASS/FAIL — ...
C. Authn flow + crypto: PASS/FAIL — ...
D. Rate-limit buckets: PASS/FAIL — ...
E. Error envelope: PASS/FAIL — ...
F. Store correctness: PASS/FAIL — ...
G. HEAD + 405: PASS/FAIL — ...
H. Tests: PASS/FAIL — ...

## Findings
### CRITICAL
1. <file:line>
   - Evidence: ...
   - Why: ...
   - Fix: ...

### HIGH
...

### MEDIUM
...

### LOW
...

### INFO
- ...

## Final Verdict
Counts: 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW / N INFO
Verdict: <READY TO LOCK | NOT READY TO LOCK>
```

`READY TO LOCK` requires 0 CRITICAL + 0 HIGH + 0 MEDIUM.

=== END PROMPT ===
```
