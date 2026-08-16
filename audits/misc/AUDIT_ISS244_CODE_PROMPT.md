## Lane: CODE

## Context

You are auditing a fix for issue [#244](https://github.com/Augustas11/macprovider/issues/244): `deploy-pearl-vps.sh` could leave production nginx in a TLS-broken state when certbot failed on any subdomain. The fix landed as commit `a74ac02` on branch `fix/iss244-deploy-pearl-tls-safety` in worktree `/Users/augstar/macprovider-iss244/`.

The script is a one-shot bash deploy-from-operator-Mac wrapper that SSHes into a remote VPS (Pearl) to install the coordinator binary + nginx config + Let's Encrypt certs.

### The bug being fixed

1. Step 5 (port-80 ACME-stub install) OVERWROTE the existing full TLS vhost at `/etc/nginx/sites-available/<domain>`.
2. Step 6 (certbot loop) used `set -e` so any single subdomain failure exited the script.
3. Step 6b (install-full-TLS-vhost-and-reload) never ran on partial failure → production HTTPS broken.

### The fix (three layered changes)

(a) `dist/nginx-{coordinator,stats}.malibu.tech.conf` ship with `ssl_certificate` lines UNCOMMENTED. The deploy-script sed-surgery `s|# ssl_certificate|...|g` stays as a defensive no-op.

(b) Step 5 no longer touches the per-domain config of any domain that already has a valid cert at `/etc/letsencrypt/live/<domain>/fullchain.pem`. A new step 4b classifies domains into `DOMAINS_HAVE_CERT` vs `DOMAINS_NEED_CERT` via one SSH round-trip.

(c) Step 6 is per-domain fail-soft. Each domain's `certbot certonly` runs in its own `$SSH` invocation; the local `if $SSH ...; then ...; else ...; fi` catches the exit. Failed domains go into `DOMAINS_ISSUED_FAIL`.

Step 6b installs the full TLS vhost ONLY for `DOMAINS_HAVE_CERT ∪ DOMAINS_ISSUED_OK`. Failed-issuance domains keep their ACME stub from step 5.

End-of-script policy: non-zero exit 9 ONLY if the PRIMARY `$DOMAIN` itself failed. Non-primary failures (e.g. stats.malibu.tech NXDOMAIN) are WARN-only because step 8 has already verified `$DOMAIN/healthz`.

## Your job

CODE LANE: focus on bash correctness — quoting, expansion, escaping, loop semantics, array handling, IFS, `set -e` interactions, here-doc edge cases, race conditions between local + remote shell layers, error-path completeness.

Re-read the FILES IN SCOPE below, then produce a finding list in the format:

```
CRITICAL: <one-line title>
  file:line — <one-sentence problem statement>
  why it matters: <one sentence>
  suggested fix: <one to two sentences>

HIGH: <...>
MEDIUM: <...>
LOW: <...>
INFO: <...>
```

A finding should be CRITICAL only if it can cause production outage, data loss, or money-path corruption. HIGH = silently-wrong behavior. MEDIUM = wrong-in-edge-case. LOW = nit / style. INFO = forward-looking observation.

If no findings at a severity, write the severity header followed by "(none)".

## Files in scope

Read and audit:
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/deploy-pearl-vps.sh` (full file)
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-stats.malibu.tech.conf`

Reference the prior state via `git -C /Users/augstar/macprovider-iss244 show HEAD~1:phase4-coordinator/dist/deploy-pearl-vps.sh` if useful.

Diff: `git -C /Users/augstar/macprovider-iss244 show HEAD`.
