# AUDIT_SPEC_017_IMPL_STEP_4B — Security lane

Operator-paste prompt to audit the **Step 4.B IMPL config** (nginx
edge) under PR `Augustas11/macprovider#173` from the security
(isolation / leak / privilege) lens.

Severity: **CRITICAL / HIGH / MEDIUM / LOW / INFO**. Lock target:
0 CRITICAL + 0 HIGH + 0 MEDIUM.

Each round writes
`specs/SPEC-017-IMPL-STEP_4B-security-rM-audit.md`.

---

```
=== BEGIN PROMPT ===

You are auditing the Step 4.B IMPL diff for SPEC-017 at branch
`impl/spec-017-step-1` (PR #173) of github.com/Augustas11/macprovider,
from the SECURITY (edge-side isolation / cache / log-leak) lens.

Step 4.B scope: see ARCH-lane prompt.

Output: specs/SPEC-017-IMPL-STEP_4B-security-rM-audit.md.

Severity model:
- CRITICAL — partner-key projection (exact $) gets cached at
  the edge and served to an anonymous client OR a different
  partner key; raw token, body, or `token_hash` lands in
  `access.log` or any nginx log file; access-log includes
  Authorization header verbatim; the public limiter throttles
  Authorization-bearing requests at the edge (which would
  exhaust partner-key quotas via bystander IP collision).
- HIGH — `proxy_no_cache` is missing while `proxy_cache_bypass`
  is set (read-only protection — the response gets WRITTEN to
  cache even though it's not READ back); subdomain CORS
  echoed at the edge (would override Step 3's reject); error_log
  contains DEBUG entries that include Authorization values;
  HEAD method is rate-limited differently from GET allowing a
  cheap-probe bypass.
- MEDIUM — log-rotation / disk-fill operational gap; missing
  TLS hardening directive (e.g. session-ticket reuse beyond
  what the existing Pearl vhost ships).
- LOW — polish / quality / non-blocking.
- INFO — positive observations.

Required reading (same as ARCH/CODE lanes), with added
emphasis on:
- SPEC §6.6.2 (partner exact-$ exposure invariants).
- BUILD §2 Step 4.B SECURITY r5 C1 paragraph (the
  `proxy_no_cache` requirement).
- §7.4 (access-log strip directive).
- The existing Pearl vhosts' security-header snippets:
  `frontdoor/console/dist/nginx-snippets/console-security-headers.conf`
  and the inheritance trap from
  [[nginx-add-header-inheritance-trap]] — any location-level
  `add_header` shadows ALL server-level headers; Step 4.B
  MUST use the snippet+include pattern or NO `add_header`
  blocks at all in the stats vhost.

Audit categories (sweep ALL — empty findings still record
evidence):

A. **Partner-projection cache hygiene** — `proxy_cache_bypass`
   AND `proxy_no_cache` BOTH reference `$http_authorization`
   (read-bypass + write-suppression). A test seed proves that
   after a keyed request, NO entry exists for that URL on
   disk. Inspect `proxy_cache_path` directory shape (BUILD §2
   Step 4.B SECURITY r5 C1).

B. **Public-tier rate-limit bypass for Authorization** — the
   map-based keying MUST emit an empty key on Authorization
   present. A 100-request keyed test against one IP MUST hit
   none of the edge 429s (BUILD test for §5.6 keyed-through-
   nginx bypass).

C. **Access-log redaction** — Authorization NEVER appears in
   the access-log format. Either:
   - The `log_format` literal omits `$http_authorization`, OR
   - A `set $authorization_redacted "REDACTED"` is used and the
     access-log references THAT variable.
   The error_log MUST NOT include Authorization in any DEBUG
   directive (verify `error_log` posture).

D. **add_header inheritance trap** — the new vhost MUST NOT
   declare `add_header` at the location level UNLESS it also
   re-declares every server-level security header
   (X-Content-Type-Options, X-Frame-Options, etc.). The
   safe-default is to add NO `add_header` at the stats vhost;
   the response-header surface for /v1/stats/* is owned by
   the Step 3 handler (Cache-Control, Vary, ETag, X-Stats-
   Generated-At all emit from the coordinator process).

E. **Method allowlist** — only GET / HEAD / OPTIONS reach
   the coordinator; nginx forwards methods, but if a
   `limit_except GET HEAD OPTIONS { deny all; }` block is
   present it MUST be syntactically correct and match the
   Step 3 405 envelope path (NOT replace the application
   layer 405). Either pattern is acceptable; the audit
   captures evidence.

F. **TLS posture parity** — TLSv1.2/1.3 only; no SSLv3,
   TLS 1.0, TLS 1.1; certbot pipeline aligns with Pearl's
   existing automation; `ssl_session_tickets off` if Pearl
   global posture; HSTS preload behavior considered.

G. **Cloudflare / external-CDN compatibility** — IF a
   Cloudflare layer is used in front of nginx, partner-key
   projections MUST set `Cache-Control: private` (Step 3
   handler) AND the Cloudflare rule-set MUST NOT cache
   `Cache-Control: private`. If no Cloudflare is in front,
   record that.

H. **Subdomain-trust boundary** — `Origin: https://evil.
   malibu.tech` requests are FORWARDED to the coordinator
   (NOT short-circuited at the edge). The Step 3 CORS test
   verifies the application-layer reject; the edge-layer
   forwarding posture is what the SECURITY lane verifies
   here. The audit author confirms `nginx -t` does NOT add
   any Origin-based `if` block that would silently 444 or
   200 such requests.

I. **AC-15 nginx access-log redaction** — produce a keyed
   request through nginx using a valid `mpk_*` token; wait
   for log flush; scan `/var/log/nginx/<vhost>-access.log`
   (or whatever path the IMPL declared) for:
   - the raw token string,
   - any 43-char base64url substring,
   - `mpk_<...>` beyond what `prefix` legitimately carries
     in operator-permitted log lines,
   - the literal `token_hash`.
   ALL counts MUST be 0.

J. **error_log posture** — `error_log` set to `warn` or
   above; NOT `debug` in the committed config (operator
   may flip locally for troubleshooting, but the
   committed default MUST NOT log Authorization-bearing
   request lines).

Validation steps (same as ARCH/CODE lanes).

Output structure (one document per round, fresh file).

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM.

=== END PROMPT ===
```
