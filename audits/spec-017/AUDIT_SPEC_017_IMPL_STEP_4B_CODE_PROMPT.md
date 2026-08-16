# AUDIT_SPEC_017_IMPL_STEP_4B — Code lane

Operator-paste prompt to audit the **Step 4.B IMPL config** (nginx
edge + rate-limit + cache + access-log redaction) under PR
`Augustas11/macprovider#173` from the implementation-correctness
lens.

Severity: **CRITICAL / HIGH / MEDIUM / LOW / INFO**. Lock target:
0 CRITICAL + 0 HIGH + 0 MEDIUM.

Each round writes `specs/SPEC-017-IMPL-STEP_4B-code-rM-audit.md`.

---

```
=== BEGIN PROMPT ===

You are auditing the Step 4.B IMPL diff for SPEC-017 at branch
`impl/spec-017-step-1` (PR #173) of github.com/Augustas11/macprovider,
from the CODE (nginx directive correctness) lens.

Step 4.B scope: see ARCH-lane prompt.

Output: specs/SPEC-017-IMPL-STEP_4B-code-rM-audit.md.

Severity model:
- CRITICAL — the config fails `nginx -t`; a directive name is
  misspelled or wrong-context; `limit_req_zone` is declared at
  the `server` context (not `http`); `map` is referenced
  before declaration; `proxy_cache_path` syntax breaks (e.g.
  missing `keys_zone=name:size`); a `location` block has
  unbalanced braces.
- HIGH — directive semantics drift from SPEC: `burst=` left in
  by accident (v0.1.8 removed it); `rate=60r/m` typo (e.g.
  `60r/s` would be 3600x the intended cap); `proxy_pass`
  missing the trailing slash that affects path rewrites;
  `proxy_set_header Authorization` overrides instead of
  forwards; `limit_req_status` value other than 429; `client_
  max_body_size` set too low for the JSON response envelope
  (overview is small but Vary fragments multiply edge cache
  entries — keep above 8K to match the coordinator vhost).
- MEDIUM — non-essential directive ergonomics gap.
- LOW — polish / quality / non-blocking.
- INFO — positive observations.

Required reading (same as ARCH lane).

Audit categories (sweep ALL — empty findings still record
evidence):

A. **`nginx -t` compatibility** — every directive used here
   is documented in the nginx core or http_limit_req_module
   docs; no Cloudflare-only directives that would error on
   stock nginx. The shape (b) `error_page 418 = @keyed_pass`
   trick (if used) is the documented dispatch pattern; if
   shape (a) is used, no `if ($http_authorization)` ladders.

B. **map directive correctness** — `map $http_authorization
   $public_rl_key { "" $binary_remote_addr; default ""; }`
   precedes its first reference; the variable is referenced
   in `limit_req_zone` decls.

C. **limit_req_zone declarations** — each at http context
   (typically at the top of the vhost file outside any
   server block, OR via a `dist/nginx-snippets/...` include).
   Names match the references in `limit_req`. Shared memory
   size sufficient (`:10m` is a default-safe).

D. **location block ordering** — `/v1/stats/leaderboard`,
   `/v1/stats/overview`, `/v1/stats/health` are declared
   BEFORE any wildcard `location /v1/ { return 404; }` so
   the longest-match wins. On the `coordinator.malibu.tech`
   vhost specifically: the existing `location /v1/ { return
   404; }` at line ~204 MUST be preceded by the new
   `/v1/stats/` exception block.

E. **proxy_pass posture** — points at `127.0.0.1:<port>`
   where `<port>` is the coordinator's HTTP listener (the
   one Step 3 wires the mux to). NO trailing slash unless
   the location prefix is being rewritten; both shapes
   pass `nginx -t` but differ semantically.

F. **proxy_cache_path** — declared at http context with a
   valid disk path (Pearl convention is `/var/cache/nginx/
   stats/`). `keys_zone=stats_public:10m`. `inactive=300s`.
   Subdirectory `levels=1:2`. The location block references
   the zone via `proxy_cache stats_public`.

G. **proxy_cache_bypass + proxy_no_cache** — both reference
   `$http_authorization`. The expected behavior is: any
   request carrying ANY Authorization header (including
   garbage) bypasses cache read AND cache write. This pairs
   with the Step 3 §5.4.3 row 6 hash+SELECT 401 path.

H. **access-log format** — `log_format` defined or replaced
   to OMIT `$http_authorization`. The default `combined`
   format would include Authorization; the SPEC posture is
   that no log line carries any token-derived material.
   Acceptable patterns: explicit `log_format stats '... $remote_
   addr "$request" ...'` without `$http_authorization`; OR
   `set $authorization_redacted "REDACTED"` and reference the
   redacted variable.

I. **Header forwarding** — `proxy_set_header Host $host;
   X-Real-IP $remote_addr; X-Forwarded-For $proxy_add_x_
   forwarded_for; X-Forwarded-Proto $scheme; Authorization
   $http_authorization`. The Authorization header is
   intentionally forwarded so the coordinator dispatcher can
   read it.

J. **HEAD method behavior** — nginx serves HEAD via the
   GET location implicitly. No special block needed; the
   audit lane records evidence that HEAD reaches Step 3's
   mux unchanged.

K. **TLS posture** — TLSv1.2/1.3 only, certbot-compatible
   paths; matches the existing `coordinator.malibu.tech`
   vhost. No HSTS misconfigurations.

L. **Test harness** — the IMPL author MUST ship either a
   `dist/test/` script or testcontainers-go nginx fixture
   that runs `nginx -t` against the config + drives the AC-8
   / AC-3 / AC-15 / per-endpoint isolation / keyed-bypass
   tests. The audit author records test-execution path even
   if the harness is shell + curl rather than Go.

Validation steps (same as ARCH lane).

Output structure (one document per round, fresh file).

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM.

=== END PROMPT ===
```
