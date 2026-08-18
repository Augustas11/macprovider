# provider-portal/dist — operator deploy artifacts

Reproducibility source-of-truth for the live `https://portal.malibu.tech/`
deploy (decision-log Entry 86, 2026-06-24). The files on Pearl are
byte-identical copies of these.

This `dist/` is OUT-OF-SCOPE for the SPEC-014 spec contract — the parent
`README.md` documents the portal as a single-file web bundle; this
directory adds an operator deploy reference without polluting the
spec-owned doc.

## Files

- `nginx-portal.malibu.tech.conf` — full nginx site (port 80 → 301
  redirect; port 443 TLS + static portal serve + two SPEC-014 §3 / Open Q9
  reverse-proxy locations).
- `nginx-snippets/portal-security-headers.conf` — HSTS, CSP,
  X-Content-Type-Options, Referrer-Policy, Permissions-Policy. MUST be
  `include`d in EVERY `location` block because nginx `add_header` is
  all-or-nothing per level — any location-level `add_header` shadows ALL
  inherited add_headers (silent security-header regression if you forget).
- `nginx-snippets/portal-shared.conf` — http-context `limit_req_zone`
  declarations used by the portal vhost. Stage under `/etc/nginx/conf.d/`
  before running `nginx -t`; nginx rejects `limit_req_zone` inside a
  `server` block.

## Two deploy gotchas worth remembering

1. **Coordinator backend runs on TWO localhost ports.** `/v1/pool/check`
   and `/v1/provider/malibu-accrual` are on buyer-mux **port 8443** (per
   `phase4-coordinator/internal/buyer/server.go:397`).
   `/providers/{id}/earnings` is on ws-mux **port 8444** (billing
   endpoints registered on the ws-side http handler). The site config
   splits the two proxy locations accordingly; collapsing them to one
   upstream silently 404s `/v1/pool/check`. Verify by running
   `ss -tlnp | grep coordinator` on Pearl before assuming a single
   backend.

2. **Nginx `add_header` is all-or-nothing per level.** Any location-level
   `add_header Cache-Control` shadows ALL server-level `add_header`
   directives (HSTS, CSP, etc.), even when `always` is set. The snippet
   pattern (extracted security headers + `include` in every location) is
   the workaround. Latent in `console.malibu.tech` too — currently
   works only because that site has no location-level add_header
   overrides; the moment someone adds one, all security headers vanish.

## One-time deploy (operator action; run from the macprovider-poc repo root)

```bash
# Set PEARL to your Pearl IP (current production: 159.223.165.194)
PEARL=159.223.165.194

# 1. Stage portal files
ssh root@$PEARL 'install -d -o www-data -g www-data -m 0755 /var/www/portal'
scp frontdoor/provider-portal/index.html root@$PEARL:/var/www/portal/
# Generate portal-config.json from portal-config.json.example with your
# deployment values, then:
scp portal-config.json root@$PEARL:/var/www/portal/
ssh root@$PEARL 'chown www-data:www-data /var/www/portal/*; chmod 0644 /var/www/portal/*'

# 2. Stage nginx config + snippets
scp frontdoor/provider-portal/dist/nginx-snippets/portal-shared.conf \
  root@$PEARL:/etc/nginx/conf.d/portal-shared.conf
scp frontdoor/provider-portal/dist/nginx-snippets/portal-security-headers.conf \
  root@$PEARL:/etc/nginx/snippets/portal-security-headers.conf
scp frontdoor/provider-portal/dist/nginx-portal.malibu.tech.conf \
  root@$PEARL:/etc/nginx/sites-available/portal.malibu.tech

# 3. Issue Let's Encrypt cert via webroot. The default-server
# acme-challenge location does NOT match arbitrary Host headers, so
# certbot will 404 unless a port-80 server block exists for the target
# Host. Stage a temporary HTTP-only stub, certbot, then swap to the
# full HTTPS-enabled config.
ssh root@$PEARL bash <<'STUB'
cat > /etc/nginx/sites-available/portal.malibu.tech.cert-stub <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name portal.malibu.tech;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 404; }
}
EOF
ln -sf /etc/nginx/sites-available/portal.malibu.tech.cert-stub \
  /etc/nginx/sites-enabled/portal.malibu.tech.cert-stub
nginx -t && systemctl reload nginx
certbot certonly --webroot --webroot-path /var/www/html \
  -d portal.malibu.tech \
  --non-interactive --agree-tos --email ops@example.com --no-eff-email
rm -f /etc/nginx/sites-enabled/portal.malibu.tech.cert-stub
ln -sf /etc/nginx/sites-available/portal.malibu.tech \
  /etc/nginx/sites-enabled/portal.malibu.tech
nginx -t && systemctl reload nginx
STUB
```

## Smoke test

Run from anywhere with public DNS; if the A record was added very
recently, your local resolver may have NXDOMAIN cached (macOS:
`sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`).

```bash
curl -sI https://portal.malibu.tech/
# Expect: HTTP/2 200 + Strict-Transport-Security + Content-Security-Policy
#         + X-Content-Type-Options + Referrer-Policy + Permissions-Policy

curl -s https://portal.malibu.tech/portal-config.json
# Expect: production portal-config values

curl -s -o /dev/null -w "%{http_code}\n" \
  https://portal.malibu.tech/providers/x/earnings
# Expect: 401 (auth required; proves /providers/*/earnings proxy works)

curl -s "https://portal.malibu.tech/v1/pool/check?provider_id=<id>"
# Expect: real coordinator response (provider_not_found if id not in pool;
# JSON pool-state if id is healthy)
```
