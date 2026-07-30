## Lane: ARCHITECT

## Context

Auditing fix for issue [#244](https://github.com/Augustas11/macprovider/issues/244). Fix landed as commit `a74ac02` on branch `fix/iss244-deploy-pearl-tls-safety` in worktree `/Users/augstar/macprovider-iss244/`.

### Bug

Step 5 of `deploy-pearl-vps.sh` overwrote the per-domain nginx vhost with a port-80 ACME-stub. Step 6 (certbot) used `set -e`. Step 6b (full TLS vhost reinstall) never ran on certbot failure. Production HTTPS broken until manual recovery.

### Fix design (what shipped)

1. Classify domains upfront (new step 4b) into `DOMAINS_HAVE_CERT` vs `DOMAINS_NEED_CERT` via one SSH probe.
2. Step 5 ACME-stub only installed for `DOMAINS_NEED_CERT`. Domains with existing certs are untouched.
3. Step 6 certbot per-domain fail-soft via local-side `if $SSH ...; then; else; fi`.
4. Step 6b installs full TLS vhost only for `DOMAINS_HAVE_CERT ∪ DOMAINS_ISSUED_OK`. Failed domains keep ACME stub.
5. End-of-script exits non-zero (9) ONLY if PRIMARY `$DOMAIN` failed; non-primary failures are WARN-only.
6. `dist/nginx-*.conf` ship with `ssl_certificate` uncommented. sed surgery kept as defensive no-op.

### Your job

ARCHITECT LANE: focus on whether the fix design is well-bounded, whether invariants are preserved, whether responsibility is correctly placed at the right layer, whether the abstraction (ACME-stub-only-for-NEED, full-TLS-only-after-cert-confirmed) is the right one, whether the failure surface is well-modeled, whether there is hidden coupling that will rot, whether the fix conflicts with prior comments/specs in the script (SPEC-017 Step 4.B references, M1-6 / DEVE-4 / DEVE-5 callouts), and whether the WARN-only-for-non-primary policy is right for the operator audience.

Specifically consider:
- The classification at step 4b creates state that flows through 3 distinct script phases — is the state model clear or brittle?
- The defensive-sed no-op leaves two "sources of truth" for cert directives (the conf file + the script's expectation) — does that create future drift?
- The end-of-script exit policy treats `$DOMAIN` as money-path and `$STATS_DOMAIN` as non-money-path. SPEC-017 names stats.streamvc.live as a "first-class public hostname" — is the asymmetry justified?
- The fix does not add a test for the failure-mode (script can't be unit-tested without a remote VPS). Should there be a `--dry-run` flag or a unit-testable helper extraction?
- Idempotency: re-running the script after a partial-failure recovery — does the state model handle that cleanly?
- Comments around SPEC-017 v0.1.8 Step 4.B + round-4 ARCH r2 H1 / CODE r2 C1 still reference the old "uncomment via sed" approach — are they now misleading?

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
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-stats.streamvc.live.conf`

Diff: `git -C /Users/augstar/macprovider-iss244 show HEAD`.
