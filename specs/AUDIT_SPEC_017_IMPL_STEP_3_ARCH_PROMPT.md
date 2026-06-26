# AUDIT_SPEC_017_IMPL_STEP_3 — Architecture lane

Operator-paste prompt to audit the **Step 3 IMPL code** (handlers
+ middleware + store) under PR `Augustas11/macprovider#173` from
the architecture lens.

Audit target is the **Step 3 implementation diff** layered on top
of the converged Step 2 (HEAD `bd68a0a` or later). SPEC-017
v0.1.8 is LOCKED; `BUILD_SPEC_017_IMPL_PROMPT.md` is the
controlling kickoff; `specs/SPEC-017-IMPL-STEP_2-r10-convergence.md`
is the Step 2 convergence record.

Severity: **CRITICAL / HIGH / MEDIUM / LOW / INFO**. Lock target:
0 CRITICAL + 0 HIGH + 0 MEDIUM. LOW + INFO MAY be deferred and
acknowledged in the convergence file.

Each round writes
`specs/SPEC-017-IMPL-STEP_3-arch-rM-audit.md` — new file per
round, NEVER append.

---

```
=== BEGIN PROMPT ===

You are auditing the Step 3 IMPL diff for SPEC-017 at branch
`impl/spec-017-step-1` (PR #173) of github.com/Augustas11/macprovider,
from the ARCHITECTURE lens.

Output: specs/SPEC-017-IMPL-STEP_3-arch-rM-audit.md (round M;
fresh file per round, never append).

Severity model:
- CRITICAL — handler/middleware breaks a locked SPEC invariant
  (e.g. 7-row §5.4.3 decision table off-by-one, partner-key
  projection emits ACAO `*`, rate-limit absent-Authorization
  debit, recover middleware logs raw token, error envelope
  introduces a new code outside §5.9's closed vocabulary, 503
  stale debits success bucket, ETag computed off-snapshot,
  middleware order reverses redaction-vs-recover).
- HIGH — would force a v0.2 fix-round within the first month,
  structurally misaligns Step 3 with Step 2 storage or Step 4
  CLI/nginx surface (e.g. handler computes `rewards_populated`
  synchronously against `provider_rewards_ledger` violating the
  §7.2.1 deny list, leaderboard query bypasses
  `stats_leaderboard_*` for ad-hoc OLTP sums, partner-key
  projection branches off `provider_visibility_audit` instead
  of `provider_visibility`, mux uses `net/http.DefaultServeMux`
  instead of an explicit `Handler` with HEAD allowlist).
- MEDIUM — two conforming Step 3 sessions could resolve a Step
  3 decision differently; missing structural guidance bleeds
  into Step 4's audit.
- LOW — polish / quality / non-blocking.
- INFO — positive observations or evidence captured during
  verification.

Required reading (before writing findings):
- `specs/SPEC-017-network-stats-api.md` v0.1.8 sections
  1.5, 4.3, 5.1, 5.2, 5.3, 5.4, 5.6, 5.7, 5.8, 5.9, 7.1, 7.2,
  9.1, 9.5, 9.7.
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md` section 2 Step 3
  (the entire "Step 3 — HTTP handlers + error envelope + CORS
  + auth + redaction" block), plus the AC-to-step matrix.
- `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`.
- `specs/SPEC-017-IMPL-STEP_2-r10-convergence.md` (storage
  shape Step 3 inherits).
- `phase4-coordinator/internal/stats/migrations/`
  (the locked schema Step 3 reads from + the `partner_keys`
  table shape).
- All ARCH r1..r(M-1) audit files for Step 3 (close-out checks
  in §"Round-(M-1) Closure Checks").
- Step 3 implementation diff: `git diff bd68a0a..HEAD --
  phase4-coordinator/`. Focus on
  `phase4-coordinator/internal/stats/handlers*.go`,
  `internal/stats/store/`, `internal/stats/middleware*.go`,
  `internal/stats/mux*.go`, `cmd/coordinator/main.go` mux
  wiring delta.

Audit categories (sweep ALL — empty findings still record
evidence):

A. **Endpoint + projection scope vs Step 4 boundary** — Step 3
   owns the three handlers, the §5.9 error envelope, CORS, the
   §5.4.3 7-row decision table, in-process rate limiting (all
   three tiers per §5.6), 503 staleness, HEAD, redaction
   middleware, recover. Step 3 does NOT own: the partner-key
   CLI (Step 4.A), nginx config (Step 4.B), Prometheus metric
   labels (Step 4.C), CI lint, AC-9/AC-10/AC-16/AC-17/AC-20
   (other steps per §2.4 matrix). Flag any cross-step bleed.

B. **Middleware stack ordering** — exactly 7 layers in the
   pinned order (redaction-context → recover → access-log/trace
   → auth-failure tier limiter → auth dispatcher → post-auth
   success bucket → handler). Recover MUST also strip
   `Authorization` defensively. Auth-failure limiter MUST skip
   absent-Authorization requests AND reserve-then-refund slots
   on 200 partner projection. Per-IP derivation uses
   trusted-proxy allowlist; untrusted `X-Forwarded-For` ignored.

C. **§5.4.3 partner-key authn flow** — 7-row decision table,
   row 5 origin-rejection MUST do `sha256 + SELECT` first,
   `subtle.ConstantTimeCompare` for any secret-derived byte
   comparison, `last_used_at` NOT touched in v0.1, no token-
   prefix early return, RFC 6454 ASCII Origin normalization
   (lowercase scheme/host, IDN→Punycode, strip default ports,
   trailing-slash/path/query treated as absent).

D. **CORS per §5.7** — preflight is key-agnostic, GET enforces
   per-key allowlist; preflight returns EXACTLY 204 with
   `Access-Control-Max-Age: 60`; partner-key projection
   responses NEVER emit `ACAO: *` (split into echoed-Origin
   browser case vs server-to-server omit case);
   public-leaderboard no-key still emits `ACAO: *` (locked
   §5.7 row 2); sibling-subdomain wildcards FORBIDDEN.

E. **Header surface** — Cache-Control table (overview / leader
   public / leader partner / health), Vary table (public vs
   partner projection differs; auth-failed 401 takes
   public Vary), `X-Stats-Generated-At` on every non-304
   response, ETag = `sha256(body)` with 304 round-trip per
   §5.9 (304 carries only RFC 7232 headers, no
   X-Stats-Generated-At).

F. **Endpoint contract** — overview 14 fields + 30-point
   timeseries with `null` (NOT zero) for missing minutes;
   leaderboard public projection carries ONLY `tokens` / `jobs`
   / `active_accounts` in totals (no `earnings_*` totals on
   public), single `earnings_bucket` + single `exact_earnings`
   field per row (no per-axis variants); partner projection
   ADDS `earnings_usd` / `earnings_work_usd` /
   `earnings_rewards_usd` + `first_seen_at` / `last_seen_at`
   + totals.earnings_*; meta.rewards_populated REQUIRED from
   `stats_rewards_populated` (NOT computed synchronously
   against `provider_rewards_ledger`); `partial_history_since`
   exposed iff config non-empty AND window is `30d` or `all`
   AND now()-since < window length; 24h/7d never include it;
   health JSON derived from `stats_components_health` + §9.5
   thresholds (no `status` column read); 7-component map
   (overview, timeseries_rpm, timeseries_tpm, leaderboard_24h,
   leaderboard_7d, leaderboard_30d, leaderboard_all) — NO
   v0.1.6 single `timeseries` key.

G. **503 + rate-limit semantics** — 503 stale path runs AFTER
   cheap auth/CORS validation but BEFORE post-auth success
   bucket debit (rollup outage MUST NOT exhaust client quotas);
   429 emits `Retry-After`; envelope §5.9 vocabulary closed;
   auth-failure tier 300 rpm pre-SELECT cap; partner tier 600
   rpm default keyed on `(partner_keys.id, endpoint)`; public
   tier 60 rpm keyed on `(client_ip, endpoint)`.

H. **Failure modes + main.go integration** — store reads
   through `stats_reader` `*sql.DB` only (no admin DSN, no
   `stats_rollup` write pool); mux mounts on both
   `coordinator.streamvc.live` and `stats.streamvc.live` via
   the same binary; HEAD added to explicit method allowlist
   (Go's `http.ServeMux` doesn't auto-handle HEAD); 405 path
   with `Allow: GET, HEAD, OPTIONS` + §5.9 envelope;
   Config.Stats.Rollup.PartialHistorySince + .BackfillMode
   injected via shared `*config.Stats` struct (NOT per-handler
   global, NOT DB read on hot path).

Validation steps (run before writing findings):
- `git diff --name-only bd68a0a..HEAD -- phase4-coordinator/`
  to scope the Step 3 delta.
- `go build ./...` from `phase4-coordinator/`.
- `go test ./internal/stats/...` (unit only).
- `go test -tags=integration -c ./internal/stats` (compile
  smoke for the integration suite even if rootless Docker
  blocks execution).
- `go list -f '{{.ImportPath}} {{join .Imports "\n"}}'
  ./internal/stats` to verify the handler package imports
  stay within an explicit allowlist: standard library,
  `internal/auth` (for shared hash helpers only),
  `internal/config`, `internal/stats/store`, `internal/pool`
  (only if handler needs Registry for snapshot — should not),
  `github.com/rs/zerolog`, `golang.org/x/net/idna` (approved
  Step 3 dep — required for RFC 6454 §5.7 Origin
  normalization IDN → Punycode; see `.golangci.yml` preamble
  for the lint-config record of this approval). No imports of
  `internal/ws`, `internal/explorer`, `internal/billing`,
  `internal/buyer`, `internal/session`.
- `gofmt -l ./internal/stats` (clean expected).
- `git diff --check origin/main...HEAD` (no whitespace errors
  in inspected files).

Output structure (one document per round, fresh file):

```
# SPEC-017 IMPL Step 3 — Architecture Audit Round M

Branch: `impl/spec-017-step-1`
HEAD audited: `<sha>` (`<commit subject>`)
Diff base: Step 2 converged tip `bd68a0a`
Auditor lane: ARCHITECTURE
Prior rounds checked:
- specs/SPEC-017-IMPL-STEP_3-arch-r1-audit.md  (... etc.)

Verdict: <READY TO LOCK | NOT READY TO LOCK> —
0 CRITICAL + N HIGH + M MEDIUM + L LOW + I INFO

## Validation evidence
- <list of commands run + outcomes>

## Category Verdicts
A. ...: PASS / FAIL — <one-sentence summary>
B. ...
...
H. ...

## Findings
### CRITICAL
1. <file:line>
   - Evidence: <code or diff snippet>
   - Why: <which locked invariant / SPEC § / BUILD § is violated
     and the failure mode>
   - Fix: <minimal SPEC-conforming patch shape>

### HIGH
...

### MEDIUM
...

### LOW
...

### INFO
- ...

## Round-(M-1) Closure Checks
- <each prior finding's status: closed (with new file:line
  evidence) or still open (re-raise as the SAME severity)>

## Final Verdict
READY TO LOCK: YES/NO
Blocking count: CRITICAL/HIGH/MEDIUM/LOW/INFO
```

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM.

=== END PROMPT ===
```
