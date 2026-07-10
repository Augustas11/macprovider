# SPEC-017 v0.1.8 — Final whole-implementation SECURITY audit (adversarial)

You are the security lane on the final pre-merge adversarial
audit of the SPEC-017 v0.1.8 implementation. This is the LAST
audit pass before PR #173 ships. Your job is to REFUTE the
"secure and ready to ship" claim. Default to finding bypasses.

## Scope

ALL of SPEC-017 v0.1.8 on branch `impl/spec-017-step-1` at HEAD
`9ef3d92`. 189 files changed.

Diff base: `git diff --name-only $(git merge-base HEAD main)..HEAD`.

## Adversarial posture

Approach this as a red-team engineer who has access to:

- The compiled binary + nginx config.
- The OPS.md runbook with all documented procedures.
- A non-admin shell on the Pearl VPS (read-only on
  config + binary; cannot escalate without an existing flaw).
- The public stats API surface.
- An honest partner key (a real `mpk_*` token) — NOT a stolen
  one. You're trying to find what this honest partner key
  gives you beyond what SPEC §6.6.2 promised.

Probe:

A. **Token redaction surface.** A real `mpk_*` token is 47
   chars (`mpk_` + 43 base64url). It enters the system via
   `Authorization: Bearer mpk_*`. List EVERY sink the request
   could touch: nginx access log, nginx error log, Go zerolog
   sink, structured event lines, Prometheus metric labels,
   `stats_components_health.last_error_message`, CLI stdout
   on partner-keys list, `partner_keys.token_hash` (which is
   sha256, not the raw token — but still), the panic stack
   line. For each sink, is the redaction explicit + tested?
   Find one sink missing a guard.

B. **Origin allowlist bypass.** SPEC §5.4.3 + §5.4.5 normalize
   Origin per RFC 6454. The §5.4.3 row 5 expects 401 on
   Origin-not-in-allowlist. Are there normalization edge cases
   that defeat the check? `Origin: HTTPS://Acme.Example/.`
   (with trailing dot)? `Origin: https://acme.example:443/`?
   `Origin: https://acme.example//path`? IPv6 brackets?
   Punycode? Mixed unicode normalization forms?

C. **Timing equivalence for rows 5, 6, 7.** AC-18 verifies
   timing equivalence with a 100-sample t-test. Is the
   statistical bar enough? Could a determined attacker
   distinguish rows by running 10,000 samples? Trace the code
   path: does the DB SELECT actually dominate branch cost on
   every row?

D. **Partner-key issuance secret discipline.** Step 4.A's
   `coordinator partner-keys issue` generates the token via
   `generatePartnerToken()` (CSPRNG). The token is delivered
   via stdout (interactive) or `--token-out FILE` (mode 0600,
   O_EXCL). Examine the file-write path: could a symlink
   attack on the operator's chosen --token-out path cause
   the token to land at an attacker-controlled location?
   O_EXCL refuses to follow symlinks for the final component;
   what about parent directories?

E. **JOURNAL_STREAM env-detection bypass.** The CLI refuses
   stdout token print when `JOURNAL_STREAM` is set. Could an
   attacker arrange for the env not to be set during issuance
   (e.g. via `env -i coordinator partner-keys issue ...`),
   capture the stdout via a parent process, and persist the
   token? The CLI's job here is to protect against systemd-
   journal *accidental* capture; what's the boundary of the
   threat model?

F. **partner_keys schema integrity.** Step 4.A INSERT uses
   `pqStringArrayLiteral(canonicalOrigins)` for the
   `allowed_origins` column. Is the literal-builder
   injection-safe? Try `'); DROP TABLE partner_keys; --` and
   other classic payloads. SPEC normalizes Origin to schema
   + lowercased host + port-or-empty; does the normalizer
   reject hostile inputs?

G. **CLI subcommand argv injection.** `coordinator partner-keys
   issue --label X --created-by Y --allowed-origin Z` —
   what's the validation on each free-form input?
   `--label "\nFAKE EVENT\n"` could inject newlines into the
   structured event line. `--reason` on revoke similarly.
   Find one such injection.

H. **proxy_cache hostility.** Step 4.B's `proxy_no_cache
   $http_authorization` is paired with `proxy_cache_bypass
   $http_authorization`. Imagine an attacker that sends BOTH
   anonymous and keyed requests interleaved at high rate. Can
   they coerce nginx into serving a partner projection from
   cache to an anonymous request? Read the nginx semantics
   carefully — the contract is "anonymous warm-up caches,
   keyed request bypasses AND doesn't write" — but is there
   a race condition between the bypass-read and the
   no-cache-write?

I. **CORS reflection on auth-failed paths.** SPEC §5.4.3 rows
   3/5/6/7 return 401. Does the 401 response carry CORS
   headers reflecting the attacker's Origin? If yes, can the
   attacker mount a CSRF-equivalent against the partner key
   surface? (The partner projection isn't credentials-gated
   in the same way as a cookie API, but information leakage
   matters.)

J. **CLI principal default.** `--created-by` defaults to
   `resolvePrincipal("")`. What value does that produce on
   different host OSes (linux, darwin, root, non-root,
   detached process)? Could a non-root operator issue a key
   that appears to be created by `postgres` or another
   security-sensitive principal?

K. **Coordinator binary's surface area increase.** Step 4
   added the `/metrics` endpoint on the provider port 8444
   (loopback-only per Pearl posture). What enforces the
   "loopback-only"? If a misconfigured deploy exposes 8444 on
   a public interface, `/metrics` becomes a partner-key-id
   enumeration oracle (the `partner_key_id` label is a
   monotonic primary key).

L. **Anything else.** Find your own attack surface.

## Verdict format

Write your output to
`specs/SPEC-017-FINAL-security-audit.md`. Required structure:

1. `## Verdict` — `REQUEST CHANGES` or `READY TO LOCK`.
2. `Blocking count: NC CRITICAL / NH HIGH / NM MEDIUM / NL LOW / N INFO`.
3. `## Validation evidence` — commands run, paths inspected.
4. `## Findings` categorized.
5. `## Category sweep` (A–L).
6. `## Final recommendation`. If no blockers, name 3 attacks
   you tried that the implementation defeats.

Severity bar:

- **CRITICAL**: production secret leak, money-path bypass,
  authentication bypass, or §6.6.2 sign-off circumvent.
- **HIGH**: token-in-log leak class, CORS reflection that
  enables data leakage, timing-attack practical on small
  sample counts.
- **MEDIUM**: argv injection that lands in a structured event,
  threat-model-edge weakness that requires unusual operator
  posture but is real.
- **LOW**: defense-in-depth weakness with no concrete attack
  path.
- **INFO**: noteworthy but not actionable.

Lock requires 0 CRITICAL + 0 HIGH + 0 MEDIUM.
