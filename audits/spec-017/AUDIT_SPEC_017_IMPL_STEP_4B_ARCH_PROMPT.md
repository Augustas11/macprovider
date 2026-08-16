# AUDIT_SPEC_017_IMPL_STEP_4B — Architecture lane

Operator-paste prompt to audit the **Step 4.B IMPL config** (nginx
edge + rate-limit + cache + access-log redaction) under PR
`Augustas11/macprovider#173` from the architecture lens.

Audit target is the **Step 4.B implementation diff** layered on top of
Step 4.A. SPEC-017 v0.1.8 is LOCKED; `BUILD_SPEC_017_IMPL_PROMPT.md`
is the controlling kickoff.

Severity: **CRITICAL / HIGH / MEDIUM / LOW / INFO**. Lock target:
0 CRITICAL + 0 HIGH + 0 MEDIUM.

Each round writes
`specs/SPEC-017-IMPL-STEP_4B-arch-rM-audit.md` — new file per
round, NEVER append.

---

```
=== BEGIN PROMPT ===

You are auditing the Step 4.B IMPL diff for SPEC-017 at branch
`impl/spec-017-step-1` (PR #173) of github.com/Augustas11/macprovider,
from the ARCHITECTURE lens.

Step 4.B scope:
- Nginx server-block on Pearl for `stats.malibu.tech`
  (new vhost file: `phase4-coordinator/dist/nginx-stats.malibu.tech.conf`).
- Path-prefix allow-through for `/v1/stats/*` on the existing
  `coordinator.malibu.tech` vhost (existing vhost currently
  returns 404 on `/v1/`).
- Authorization-aware public-tier rate limiting via shape (a)
  preferred: `map $http_authorization $public_rl_key` + per-
  endpoint `limit_req_zone` declarations + `limit_req zone=...
  nodelay` (no `burst=`). Shape (b) acceptable if author chose it.
- `proxy_cache_path` for the public projection with a tight
  `proxy_cache_bypass $http_authorization` + `proxy_no_cache
  $http_authorization` pair (SECURITY r5 C1).
- `Authorization` header stripped from access logs.

Output: specs/SPEC-017-IMPL-STEP_4B-arch-rM-audit.md.

Severity model:
- CRITICAL — a locked SPEC §5.6 / §5.7 / §6.6.2 invariant is
  violated by the edge config: nginx caches the partner-key
  projection (proxy_no_cache absent on Authorization); public
  rate-limit zone shared across endpoints (60-rpm /overview
  exhausts /leaderboard quota); Authorization-bearing requests
  hit the public limiter (partner traffic 429s at the edge);
  `Vary: Authorization` appears on the public projection
  (response-fragmentation per locked v0.1.7 H2); access-log
  format INCLUDES `$http_authorization` so raw tokens land
  in /var/log/nginx/access.log; subdomain CORS is enforced at
  the edge (which would override the application-layer
  sibling-subdomain reject and mask Step 3 CORS bugs).
- HIGH — would force a v0.2 nginx re-config within the first
  month: `limit_req_status` missing per location; the new
  vhost's TLS posture doesn't match the rest of Pearl's certs;
  the `coordinator.malibu.tech` path-prefix allow is missing
  (one of the two surfaces stays 404'd); `proxy_cache_path`
  directory wired into a tmpfs / no-disk path that the operator
  rotation playbook doesn't cover; `proxy_read_timeout` too
  tight for the rollup-tick-aligned overview snapshot path.
- MEDIUM — structural ambiguity: two conforming Step 4.B
  authors could resolve a directive differently.
- LOW — polish / quality / non-blocking.
- INFO — positive observations or evidence captured.

Required reading (before writing findings):
- `specs/SPEC-017-network-stats-api.md` v0.1.8 sections
  5.6 (rate limiting), 5.7 (CORS), 6.6.2 (partner exact-$),
  7.1 (mount points), 7.4 (edge config), 8.5 (changelog).
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md` section 2 Step 4.B
  (entire "4.B Edge / nginx / rate-limit / cache" block) plus
  the AC-to-step matrix.
- Step 3 convergence record (`SPEC-017-IMPL-STEP_3-r8-
  convergence.md`) — Step 3's in-process limiter is the
  fallback; understand which limiter does what.
- Existing `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf`
  (the file Step 4.B may need to amend to add /v1/stats/*
  allow-through).
- The new `phase4-coordinator/dist/nginx-stats.malibu.tech.conf`
  file (if Step 4.B added one).
- All ARCH r1..r(M-1) audit files for Step 4.B.

Audit categories (sweep ALL — empty findings still record
evidence):

A. **Vhost surface** — `stats.malibu.tech` server-block
   created with port 80→443 redirect + 443 TLS + certbot-
   compatible cert paths (match the existing `coordinator.
   malibu.tech` pattern). The `coordinator.malibu.tech`
   vhost amended to allow-through `/v1/stats/*` BEFORE the
   `location /v1/ { return 404; }` catch-all (longest-match
   ordering).

B. **Per-endpoint rate-limit zones** — `limit_req_zone` for
   each of `stats_overview`, `stats_leaderboard`, `stats_health`
   declared at `http` context (e.g. via a `dist/nginx-snippets/
   stats-limit-zones.conf` included at the http level, OR
   declared at the top of the new vhost which nginx hoists).
   Each zone uses `rate=60r/m`. The location blocks reference
   their own zone with `nodelay` and NO `burst=` parameter.
   Per-endpoint isolation is structural (separate zone names),
   not a runtime check.

C. **Authorization-aware keying** — shape (a) map-based bypass:
   `map $http_authorization $public_rl_key { "" $binary_remote_addr;
   default ""; }`. With Authorization present, the limiter
   key is empty and nginx does not count the request. Shape (b)
   is also acceptable (named-location dispatch via `error_page
   418 = @keyed_pass`). Mark either as PASS; the author's
   choice MUST be reflected.

D. **Cache hygiene** — `proxy_cache_path` declared (only for
   public projections); each /v1/stats/<endpoint> location
   has BOTH `proxy_cache_bypass $http_authorization` AND
   `proxy_no_cache $http_authorization`. SPEC-014 v0.9
   provider portal cache directives are NOT crosspollinating
   into this vhost.

E. **Header hygiene** — `proxy_set_header X-Forwarded-For
   $proxy_add_x_forwarded_for` so the trusted-proxy CIDR
   allowlist in Step 3's `clientIP()` derivation lines up
   with what nginx forwards. `proxy_set_header Authorization
   $http_authorization` so the in-process partner-key
   dispatcher can read it. Access-log `log_format` does NOT
   include `$http_authorization` (or uses an explicit
   redaction variable). The `Server` header is not advertising
   nginx version unnecessarily (`server_tokens off` if Pearl's
   global posture).

F. **Method allowlist + 405** — only GET / HEAD / OPTIONS
   accepted; nginx forwards methods to the coordinator, which
   emits the §5.9 405 envelope on the rest. Step 3 owns 405;
   nginx MUST NOT short-circuit POST with a 200 cache HIT.

G. **CORS — application-layer** — nginx does NOT echo `Access-
   Control-Allow-Origin` or any preflight header. The Step 3
   handler owns CORS. If nginx adds an `add_header
   Access-Control-Allow-Origin *` line, that's a CRITICAL
   because it would (a) override the partner-projection
   NEVER-* rule and (b) cause partner cache leaks.

H. **Cloudflare / Pearl posture** — the BUILD optional-
   Cloudflare paragraph doesn't apply if the operator runs
   stats.malibu.tech behind Pearl's nginx directly. The
   audit lane MUST verify NO Cloudflare-specific directives
   live in this PR that would silently break Pearl's pipeline
   (e.g. a `Cache-Control` add_header that would shadow the
   coordinator's `private`/`public` selection).

Validation steps (run before writing findings):
- `nginx -t -c <new vhost path>` (simulated; the audit author
  notes the testing posture — the actual `nginx -t` is the
  AC-8 test infrastructure).
- `grep -E 'limit_req_zone|limit_req |proxy_cache|proxy_no_cache
  |\$http_authorization' phase4-coordinator/dist/nginx-*.conf`.
- `git diff 51b9736..HEAD -- phase4-coordinator/dist/`.

Output structure (one document per round, fresh file). Same
shape as Step 4.A ARCH lane.

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM.

=== END PROMPT ===
```
