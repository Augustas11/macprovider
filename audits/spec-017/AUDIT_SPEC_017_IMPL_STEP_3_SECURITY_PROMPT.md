# AUDIT_SPEC_017_IMPL_STEP_3 — Security lane

Operator-paste prompt to audit the **Step 3 IMPL code** (handlers
+ middleware + store) under PR `Augustas11/macprovider#173` from
the security lens.

Audit target is the **Step 3 implementation diff** layered on
top of the converged Step 2 (HEAD `bd68a0a` or later). SPEC-017
v0.1.8 is LOCKED. The Step 3 handler is the FIRST place a
partner-key reaches a public attack surface; the security bar
is higher than the Step 1/2 internal-rollup bar.

Severity: **CRITICAL / HIGH / MEDIUM / LOW / INFO**. Lock target:
0 CRITICAL + 0 HIGH + 0 MEDIUM.

Each round writes
`specs/SPEC-017-IMPL-STEP_3-security-rM-audit.md` — fresh file
per round, NEVER append.

---

```
=== BEGIN PROMPT ===

You are auditing the Step 3 IMPL diff for SPEC-017 at branch
`impl/spec-017-step-1` (PR #173) of github.com/Augustas11/macprovider,
from the SECURITY lens.

Output: specs/SPEC-017-IMPL-STEP_3-security-rM-audit.md (round
M; fresh file per round, never append).

Severity model:
- CRITICAL — token leak, timing oracle, partner-key projection
  ACAO `*`, recover middleware logs raw token / token_hash,
  panic stack in public log, secret comparison via `==`,
  rate-limit bypass via spoofed XFF when no trusted proxy, IDOR
  via partner_key.id in URL/header, SQL injection through
  user-controlled query param, role escalation (handler uses
  `stats_rollup` write pool).
- HIGH — would force a v0.2 SECURITY fix-round: prefix or
  label leaked through metric label; CORS allowing
  sibling-subdomain wildcard; preflight grants > 60s with no
  operator-config opt-in; Origin normalization bypass via
  trailing-slash / IDN / case variation; HEAD response body
  non-empty for keyed projection (info leak via length); 503
  envelope leaks `provider_rewards_ledger` schema details.
- MEDIUM — defense-in-depth gap: missing constant-time
  comparison fallback, missing fixture for one §5.7 row, log
  field naming that could leak by future refactor; the
  redaction context middleware does not also strip `Cookie` or
  `X-Api-Key` (defense-in-depth even though SPEC only names
  `Authorization`).
- LOW — polish.
- INFO — positive observations.

Required reading (before findings):
- `specs/SPEC-017-network-stats-api.md` v0.1.8 §5.4, §5.6,
  §5.7, §6.1, §6.4, §6.6, §7.2.
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 3 — full
  redaction invariants list, 7-row decision table, CORS rules,
  middleware stack order, rate-limit reserve-then-refund.
- `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`.
- All SECURITY r1..r(M-1) audit files for Step 3.
- Memory notes (`MEMORY.md`):
  [[provider-auth-unauthenticated-end-to-end]],
  [[c2-gate-gateway-credential-validation-asymmetry]],
  [[c1-control-chars-terminal-sanitizer-bypass]],
  [[audit-loop-catches-billing-ledger-drift]].

Category sweep (EVERY category must produce evidence — empty
no-finding subsection is itself a coverage gap):

A. **Role + pool isolation** — handler stack uses
   `stats_reader` `*sql.DB` ONLY. No imports of
   `internal/stats/migrations`, no admin DSN, no
   `stats_rollup` pool reference. Verify
   `cmd/coordinator/main.go` mux wiring injects only the
   `stats_reader` pool. The grants migration (Step 1) already
   denies `stats_reader` SELECT on `ledger_*` /
   `provider_tokens` / `provider_rewards_ledger` /
   `provider_visibility_audit`; the handler code MUST NOT try
   to SELECT them.

B. **Token handling** — raw token never logged, never
   serialized, never in error message, never in panic stack,
   never in trace span, never in metric label, never echoed
   in response (including `error.code` / `error.detail`).
   Token-hash derivation uses `sha256(token_utf8_bytes)`
   matching `internal/auth/tokens.go`. The redaction context
   middleware sets `Authorization` to `REDACTED` in the
   request's log header view BEFORE any other middleware
   reads. The recover middleware ALSO performs a
   defense-in-depth `Authorization` strip. The auth dispatcher
   reads the bearer from `r.Context().Value(authKey{})`,
   passes it to `sha256`, and discards immediately — no
   long-lived storage.

C. **Timing equivalence** — rows 5, 6, 7 of §5.4.3 share
   `sha256 + SELECT by token_hash` work BEFORE evaluating
   Origin / row presence / revocation. Row 3 (Origin absent +
   allowlist non-empty) also performs the same hash+SELECT
   before rejecting. Test exists at sustained rate ≤270 rpm
   (below auth-failure cap). Any short-circuit, prefix
   mismatch early return, or per-row branch order is a
   CRITICAL.

D. **CORS + Origin** — preflight grants no per-key decision;
   per-key allowlist enforced ONLY on GET; partner-key
   projection NEVER `ACAO: *` (echoed Origin or omitted);
   sibling-subdomain wildcards FORBIDDEN; RFC 6454
   normalization (lowercase scheme/host, IDN→Punycode,
   default-port strip, malformed → absent); Vary on the
   actual response projection; preflight `Max-Age = 60` (cap
   300 only by operator-config opt-in, > 300 requires SPEC
   bump).

E. **Rate-limit security** — auth-failure tier runs BEFORE
   `sha256+SELECT` so invalid-bearer floods cannot drive
   unbounded DB lookups; spoofed `X-Forwarded-For` ignored
   when trusted-proxy allowlist EMPTY; trusted XFF parsed
   correctly; 429 envelope does not leak `partner_keys.id`
   or label.

F. **Recover + redaction invariants (AC-15 Step 3 share)** —
   recover middleware on the ENTIRE `/v1/stats/*` subtree
   including OPTIONS + 405 paths; panic-log redaction sweep
   confirms no raw token / no `token_hash` / no random
   substring; trace-span redaction confirms the same; metric
   labels are NOT in this step's sweep (Step 4.C).

G. **Surface attack tests** — HEAD response body bytes must
   be 0 even on partner-key projection; 304 must not carry
   `X-Stats-Generated-At` or any key-derived header;
   POST/PUT/DELETE/PATCH → 405 (path traversal / SSRF /
   header injection not in scope but verify the mux is
   prefix-match `/v1/stats/` with no `..` collapse oddity);
   error envelopes (4xx, 5xx) MUST NOT leak SQL error,
   stack frame, env var, DSN substring, host name, or
   internal IP.

H. **Step 4 boundary** — Step 3 owns NO partner-key CLI
   surface (Step 4.A), NO nginx config (Step 4.B), NO
   Prometheus metric label authoring (Step 4.C). Any
   cross-step bleed is itself a security finding (defers
   attack surface authoring to a step the security audit
   does not own this round).

Validation (run before findings):
- `git show --name-only --format=fuller HEAD`.
- `git diff --name-only bd68a0a..HEAD`.
- `rg "partner_keys\.token_hash|raw_token|bearer_token"
  phase4-coordinator/internal/stats/` — assert any matches
  are in the auth dispatcher only, never in log/trace/metric.
- `rg "log\.|fmt\.Print|trace\." phase4-coordinator/internal/
  stats/` — sample the logged context shape; verify no
  `Authorization` raw-bytes call site.
- `rg "subtle\.ConstantTimeCompare"
  phase4-coordinator/internal/stats/` — at least one match in
  the auth dispatcher.
- `go test ./internal/stats/... -count=1`.
- `go test -tags=integration -c ./internal/stats -o
  /tmp/stats-integ.test` (compile smoke).
- `gofmt -l phase4-coordinator/internal/stats`.

Output structure (one document per round, fresh file):

```
# SPEC-017 IMPL Step 3 — Security Audit Round M

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `<sha>` (`<subject>`)
Prior round: `specs/SPEC-017-IMPL-STEP_3-security-r(M-1)-audit.md`
Lens: SECURITY — role isolation, token handling, timing
equivalence, CORS, rate-limit security, recover/redaction,
surface attacks, cross-step boundary.

Required reading completed: <list>

## Validation Run
- <commands + outcomes>

## Category Verdicts
A. Role + pool isolation: PASS/FAIL — ...
B. Token handling: PASS/FAIL — ...
C. Timing equivalence: PASS/FAIL — ...
D. CORS + Origin: PASS/FAIL — ...
E. Rate-limit security: PASS/FAIL — ...
F. Recover + redaction: PASS/FAIL — ...
G. Surface attack tests: PASS/FAIL — ...
H. Step 4 boundary: PASS/FAIL — ...

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

## Positive Security Observations
- <evidence of clean isolation, redaction, etc.>

## Final Verdict
CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 0
INFO: 0

READY TO LOCK.

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM.

=== END PROMPT ===
```
