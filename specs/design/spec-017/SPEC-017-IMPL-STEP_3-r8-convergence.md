# SPEC-017 IMPL Step 3 — Convergence Record (round 8)

Branch: `impl/spec-017-step-1` / PR #173
HEAD at convergence: `2b27256` (round-7 closure commit).
Step 2 base: `bd68a0a` (per
`specs/SPEC-017-IMPL-STEP_2-r10-convergence.md`).
Step 3 scope: `/v1/stats/{overview,leaderboard,health}` HTTP
handlers + 7-layer middleware stack + read-only store DAO,
mounted from `cmd/coordinator/main.go` at `/v1/stats/`.

## Lock targets

Per BUILD §2.1: each of three independent codex lanes (ARCH /
CODE / SECURITY) must return **0 CRITICAL + 0 HIGH + 0 MEDIUM**
before the step is considered converged. LOW + INFO MAY be
deferred and are acknowledged here.

## Final round counts

| Lane     | Round | Verdict       | Counts                          |
|----------|-------|---------------|---------------------------------|
| ARCH     | r5    | READY TO LOCK | 0C / 0H / 0M / 1L / 13 INFO     |
| CODE     | r8    | READY TO LOCK | 0C / 0H / 0M / 0L / 13 INFO     |
| SECURITY | r8    | READY TO LOCK | 0C / 0H / 0M / 0L / 8 INFO      |

All three lanes hit lock criteria. ARCH r5 LOW is deferred (the
LOW asks for a real-panic injection seam; closed in round 5 via
the `RecoverForTest` test seam).

## Per-round trajectory

### ARCH

| Round | Tip       | Findings                                                | Closures |
|-------|-----------|---------------------------------------------------------|----------|
| r1    | initial   | 3 CRIT + 6 HIGH + 3 MED — envelope/JSON/freshness/auth  | r2       |
| r2    | r1 fixes  | 1 CRIT (ETag snapshot anchor) + 1 H + 1 M               | r3       |
| r3    | r2 fixes  | 1 CRIT (auth scoping) + 1 H + 1 M                       | r4       |
| r4    | r3 fixes  | 0 / 0 / 1 M (idna recurring)                            | r5       |
| **r5**| **r4 fixes** | **0 / 0 / 0 / 1 L — LOCKED (idna allowlist amendment)** | —     |

### CODE

| Round | Tip       | Findings                                                | Closures |
|-------|-----------|---------------------------------------------------------|----------|
| r1    | initial   | 1 CRIT (HEAD body leak) + 8 H + 3 M + 1 L               | r2       |
| r2    | r1 fixes  | 0 / 5 H (header/refund/snapshot/ETag/BackfillMode) / 1 M | r3       |
| r3    | r2 fixes  | 0 / 2 H (limiter refund, partner err headers) / 1 M     | r4       |
| r4    | r3 fixes  | 0 / 0 / 1 M (test coverage)                             | r5       |
| r5    | r4 fixes  | 0 / 0 / 1 M (still test coverage)                       | r6       |
| r6    | r5 fixes  | 0 / 0 / 1 M (still test coverage)                       | r7       |
| r7    | r6 fixes  | 0 / 0 / 1 M (test seam asks)                            | r8       |
| **r8**| **r7 fixes** | **0 / 0 / 0 — LOCKED**                                | —        |

### SECURITY

| Round | Tip       | Findings                                                | Closures |
|-------|-----------|---------------------------------------------------------|----------|
| r1    | initial   | 0 / 0 / 1 M + 2 L                                       | r2       |
| r2    | r1 fixes  | 0 / 0 / 1 M (test coverage)                             | r3       |
| r3    | r2 fixes  | 0 / 0 / 1 M (test coverage)                             | r4       |
| r4    | r3 fixes  | 0 / 0 / 2 M (panic refund + tests)                      | r5       |
| r5    | r4 fixes  | 0 / 0 / 1 M (test coverage)                             | r6       |
| r6    | r5 fixes  | 0 / 0 / 1 M (test coverage)                             | r7       |
| r7    | r6 fixes  | 0 / 0 / 1 M (s2s row + token_hash leak)                 | r8       |
| **r8**| **r7 fixes** | **0 / 0 / 0 — LOCKED**                                | —        |

## Lock commits

| Lane         | Lock tip   | HEAD recording the lock                                 |
|--------------|------------|---------------------------------------------------------|
| ARCH r5      | `220181a`  | round-4 fixes (panic refund + idna allowlist amendment) |
| CODE r8      | `2b27256`  | round-7 fixes (test seam additions + 3 final asks)      |
| SECURITY r8  | `2b27256`  | same — round-7 closure also satisfied SECURITY lane     |

## Step 3 deliverables (cumulative on `2b27256`)

### Endpoints (§5.1, §5.2, §5.3)
- `GET /v1/stats/overview` — 14 network fields + nested
  `rpm_30m.points[]` / `tpm_30m.points[]` with `t` RFC3339
  timestamps; JSON null for missing minutes. `Auth: None`.
- `GET /v1/stats/leaderboard` — public + partner projections;
  `?window=` ∈ {24h, 7d, 30d, all}, `?sort=` ∈ {earnings,
  tokens, jobs}, `?limit=` ∈ [1, 100]. Public projection
  emits single `earnings_bucket` + single `exact_earnings`
  per row (null unless `provider_visibility.mode='exact'`)
  AND `totals.tokens/jobs/active_accounts`. Partner adds
  per-row `earnings_usd/work/rewards` + `first_seen_at /
  last_seen_at` AND `totals.earnings_*`.
  `meta.rewards_populated` REQUIRED on every response from
  the rollup-side `stats_rewards_populated` table.
  `partial_history_since` exposed iff `BackfillMode ==
  "partial"` AND window ∈ {30d, all} AND `now - since <
  window length`.
- `GET /v1/stats/health` — `status` derived at request time
  from `stats_components_health` + §9.5 thresholds; 7-
  component map; `rollup_lag_seconds` field; returns 200
  even when degraded. `Auth: None`.

### Middleware stack (pinned)
1. **redaction-context** (outermost) — replaces Authorization
   / Cookie / X-Api-Key with REDACTED in the request-header
   logging view; stashes parsed Bearer in r.Context under
   the unexported `authKey{}` struct value; flags
   `authPresent` separately.
2. **recover** — wraps the whole `/v1/stats/*` subtree
   including 405/OPTIONS paths; defensive re-strip of
   Authorization/Cookie/X-Api-Key; type-name-only panic log
   at ERROR; raw stack to DEBUG sink; emits §5.9 `internal`
   envelope at 500.
3. **access-log** — reads only the redacted view.
4. **auth-failure tier** (scoped to `/leaderboard` only —
   §4.3 fix) — 300 rpm per `(client_ip, endpoint)`,
   Authorization-PRESENT requests only; reserve-then-refund
   pattern (refund immediately after dispatcher success so
   valid keys aren't double-counted; refund also on dispatch
   error / 500). Client-IP derivation honors trusted-proxy
   allowlist.
5. **auth dispatcher** (`/leaderboard` only) — §5.4.3 7-row
   decision table; sha256 + SELECT BEFORE Origin / row
   presence / revocation evaluation; malformed Authorization
   → 401.
6. **post-auth success bucket** — public 60 rpm per
   `(client_ip, endpoint)`; partner per-key rpm per
   `(partner_keys.id, endpoint)`. Reserve-then-refund on
   non-2xx (including the `rec.status == 0` panic path).
7. **handler** — overview / leaderboard / health.

### CORS (§5.7)
- OPTIONS returns EXACTLY 204 with `Max-Age=60` (operator
  clamp ≤300; >300 SPEC bump).
- Global preflight allowlist = static config UNION active
  `partner_keys.allowed_origins` (from
  `Store.ActivePartnerOrigins`).
- Partner projection NEVER `ACAO: *` — echoed Origin
  (browser context) or omitted (server-to-server).
- Public projection `ACAO: *`.
- 401 partner-reject omits ACAO entirely.
- Sibling-subdomain wildcards FORBIDDEN.

### Header surface
- Cache-Control row per endpoint × projection (overview /
  leader public / leader partner / health).
- Vary row per endpoint × projection (partner adds
  Authorization).
- ETag = full `W/"<sha256-of-body>"` (64 hex). Computed
  once per snapshot; overview timeseries grid anchored to
  `ov.GeneratedAt.Truncate(minute)` (NOT request time) so
  ETag stays stable across snapshot.
- `X-Stats-Generated-At` on every non-304 response,
  including 4xx/5xx errors.
- 304 carries ONLY ETag + Cache-Control + Vary, empty body.

### §5.9 envelope (closed code vocabulary)
`{code, message, retry_after_seconds?}` — `bad_request`,
`unauthorized`, `method_not_allowed`, `rate_limited`,
`stats_stale`, `internal`. `retry_after_seconds` only on
`rate_limited` + `stats_stale`. HEAD drops the body bytes
on every error path.

### 503 staleness
- Overview: `> 120s` since `stats_overview_current.generated_at`
  → 503 + `Retry-After: 30`. Probe runs BEFORE post-auth
  success bucket debit.
- Leaderboard per-window: 24h→300s, 7d→1800s, 30d→14400s,
  all→86400s. Empty leaderboard reads snapshot timestamp
  from `stats_components_health.leaderboard_<window>`.

### RFC 6454 Origin normalization
- Lowercase scheme + host, IDN→Punycode via
  `golang.org/x/net/idna` (explicitly approved Step 3 dep),
  strip default ports (80 for http, 443 for https), treat
  trailing slash / path / query / fragment / non-http(s) as
  absent.

### Store DAO (read-only via stats_reader)
- `Overview`, `RpmTimeseries`, `TpmTimeseries`,
  `Leaderboard(window, sort, limit) LEFT JOIN provider_visibility`,
  `LeaderboardTotals`, `RewardsPopulated(window)` —
  reads `stats_rewards_populated.rewards_populated`,
  `ComponentsHealth`, `ComponentGeneratedAt`,
  `LookupPartnerKeyByHash`, `ActivePartnerOrigins`.
- No INSERT/UPDATE/DELETE.
- No import of `internal/billing`, `internal/explorer`,
  `internal/ws`, `internal/auth` (depguard-enforced).

### Test coverage (final)
- **Unit**: envelope shape, origin normalization, ETag weak
  comparison, health status derivation, HEAD body guard.
- **Integration** (testcontainers-go, ~30 named tests):
  AC-1 (overview JSON shape + 14 fields),
  AC-2 (window validation + 400),
  AC-3 (invalid Bearer → 401),
  AC-4 (bucketed → exact_earnings null),
  AC-5 (exact → exact_earnings populated),
  AC-6 (partner projection earnings_*),
  AC-7 (health 200 even degraded),
  AC-11 real panic via `RecoverForTest` seam +
    9-element redaction sweep (Bearer / panic substring /
    random suffix / Cookie / Cookie substring / X-Api-Key /
    X-Api-Key substring / token_hash literal value /
    token_hash field name),
  AC-12 (304 round-trip),
  AC-13 (OPTIONS 204 + Max-Age=60),
  AC-14 (overview stale 503 + Retry-After=30),
  AC-15 (header redaction),
  AC-18 (rows 5/6/7 timing equivalence, 100 samples/row
    at ~265 rpm, pairwise ±20%),
  AC-21 (POST → 405 + Allow),
  AC-22 (auth-failure 300 rpm cap + SQL counter ≤300),
  §5.7 full 7-row CORS matrix (table-driven),
  §5.7 row 4 server-to-server explicit omit case,
  Public-omits-earnings-totals,
  Public + partner HEAD parity,
  Method 405 matrix (PUT/DELETE/PATCH),
  Malformed Auth → 401,
  Trusted/untrusted XFF split,
  Active-key origin preflight union,
  Sibling-subdomain reject,
  Valid-partner 500-req refund proof + bucket counter == 0,
  Stale-503-not-debited (100 stale + 60 fresh),
  partial_history_since Path A vs Path B all-windows,
  No-trace-span invariant (defends Step 4.C boundary).

### Wire-up
- `cmd/coordinator/main.go` mounts the stats mux at
  `/v1/stats/` iff `cfg.Stats.Enabled`. Injects
  `statsstore.New(statsPools.Reader)` only (no admin DSN,
  no rollup pool). Same binary serves both
  `coordinator.streamvc.live/v1/stats/*` and
  `stats.streamvc.live/v1/stats/*` per BUILD §2 Step 3
  (nginx vhost routing is Step 4.B).

## Audit cycle observations

8 rounds — high but consistent with the "audit-cycles-as-
design-discovery" pattern observed in Steps 1+2. Round 1
surfaced 12+ findings (every JSON shape, every envelope
shape, every error path, the freshness ordering); rounds
2-3 closed structural gaps (auth scoping, snapshot anchor,
partner CORS); rounds 4-8 were progressively narrower test-
coverage MEDIUMs. The pattern of "auditor keeps asking for
more tests" is itself useful — each addition (panic seam,
SQL counter, bucket counter, no-trace invariant) is a
real regression lock against future Step 4 or v0.2 work.

Notable late-round catches:
- **Round 3 ARCH C1 — auth scoping**: SPEC §4.3 makes
  `/overview` and `/health` `Auth: None`. Initial code
  ran the §5.4.3 dispatcher on all three endpoints, which
  meant invalid bearers got 401 instead of public-200 on
  /overview, and valid keys leaked partner CORS to
  endpoints whose locked Vary excludes Authorization.
- **Round 3 CODE H1 — limiter refund-on-allowed**: the
  `defer m.X.refund()` ran even after the cap-rejected
  429 path, decrementing the existing count from N to N-1
  and letting request N+2 through. Fix: only schedule the
  refund AFTER `allow` returned true.
- **Round 4 SECURITY M1 — panic refund**: the
  success-bucket defer treated `rec.status == 0` as
  success. A panic before the inner handler wrote any
  status would leak the count, pushing later requests
  toward 429 during a panic-triggering regression.

## Step 4 starting state

Step 4 (split into 4.A CLI / 4.B nginx / 4.C observability)
inherits a stable handler contract at `2b27256`:
- HTTP surface: `/v1/stats/{overview,leaderboard,health}`
  with locked headers, envelope, and 304/HEAD semantics.
- DB surface: read via `stats_reader`; key writes via
  Step 4.A CLI (partner_keys + `partner_keys_writer` pool).
- Observability surface (Step 4.C): metric labels MUST
  exclude prefix, label, token_hash, raw token, origin,
  per the locked redaction matrix and the
  `TestNoTraceImports` invariant we shipped this round.
