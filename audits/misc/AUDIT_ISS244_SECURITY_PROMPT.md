## Lane: SECURITY

## Context

Auditing fix for issue [#244](https://github.com/Augustas11/macprovider/issues/244): `deploy-pearl-vps.sh` could leave production nginx in TLS-broken state when certbot failed on any subdomain. Fix landed as commit `a74ac02` on branch `fix/iss244-deploy-pearl-tls-safety` in worktree `/Users/augstar/macprovider-iss244/`.

This is a money-path-adjacent deploy script — a broken `coordinator.malibu.tech` means buyers can't authenticate or fetch receipt-keys.

### What changed

1. `dist/nginx-{coordinator,stats}.malibu.tech.conf` now ship with `ssl_certificate` lines UNCOMMENTED.
2. New step 4b classifies domains by cert presence on the remote (one SSH probe, HAVE/NEED lines parsed locally).
3. Step 5 installs the port-80 ACME-stub ONLY for `DOMAINS_NEED_CERT` (so domains with existing certs keep their full TLS vhost untouched).
4. Step 6 is per-domain fail-soft (local `if $SSH …; then; else; fi` per domain).
5. Step 6b installs the full TLS vhost ONLY for domains with a valid cert at this point.
6. End-of-script exits non-zero (9) only if the PRIMARY `$DOMAIN` itself failed cert issuance.

### Your job

SECURITY LANE: focus on attack surface, authn/authz, secret handling, TLS posture, command-injection in SSH-piped here-docs, shell-quoting hazards that allow argument injection if a domain name is operator-controlled, downgrade attacks from leftover ACME stub, race windows where HTTPS could silently degrade, redirect chain hijacks, certbot misuse, and any new way an operator could be tricked into a "successful" deploy that left a vulnerable production state.

Specifically consider:
- The `for d in ${DOMAINS_NEED_CERT[*]}` expansion inside an `$SSH "..."` double-quoted string: are domain names interpolated safely?
- The HAVE/NEED parsing trusts remote stdout — what if the remote returns junk?
- End-of-script exit policy: is "non-primary failure is WARN-only" the right default for money-path adjacency? What if `stats.malibu.tech` is later used by auth or receipt keys?
- ACME stub on port 80 + redirect to HTTPS — if HTTPS is unavailable post-failure, is there a downgrade path?
- Defensive sed no-op (`s|# ssl_certificate|ssl_certificate|g`) — can a malicious edit slip past?

Produce findings in this format:

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

If no findings at a severity, write the severity header followed by "(none)".

## Files in scope

- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-stats.malibu.tech.conf`

Diff: `git -C /Users/augstar/macprovider-iss244 show HEAD`.
