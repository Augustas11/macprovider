# Track dist/coordinator.yaml in-tree — SECURITY-lane audit (R1)

You are the **security** lane of a three-lane audit of a PR that
brings the previously-gitignored production coordinator.yaml into
git history. This is the most security-sensitive audit in the set:
once committed, secrets in git history are unrecoverable via edit.

## Branch / commit
- Branch: `feat/coord-yaml-sync-spec026`
- Worktree root: `/Users/augstar/macprovider-coord-yaml-sync`
- Base: `origin/main` @ `dabf188`
- Files in scope:
  - `.gitignore` (removes phase4-coordinator/dist/coordinator.yaml
    exclusion; adds a "NEVER commit inline secrets" comment).
  - `phase4-coordinator/dist/coordinator.yaml` (NEW; content equals
    what is currently deployed on Pearl VPS).

## What the pre-commit secret scan found (transparency)

Field-shaped scan (`grep -nE "(_key|_secret|_token|_password):"`)
returned exactly three fields:

| Line | Field | Value class |
|------|-------|-------------|
| 50 | `auth.operator_key` | `env:OPERATOR_KEY` (env-indirected) |
| 53 | `auth.gateway_service_token` | `env:GATEWAY_SERVICE_TOKEN` |
| 151 | `signed_catalog.catalog_public_key` | 43-char base64 ed25519 pubkey (public trust anchor; matches the value already in `.example`) |

Field-shaped scan for `(dsn|url|host|endpoint):`:

| Line | Field | Value class |
|------|-------|-------------|
| 68 | `pool.gateway_base_url` | literal public URL, no embedded auth |
| 86 | `onboarding.postgres_dsn` | `env:ONBOARDING_POSTGRES_DSN` |
| 157 | `signed_catalog.public_catalog_base_url` | literal public URL |

Additional new `env:` indirections introduced by SPEC-026 that
this PR ships as tracked config:
- `env:OPERATOR_AUTH_POLICY_A`, `env:OPERATOR_AUTH_POLICY_B`
- `env:APPLE_TEAM_ID`

## Security-lane scope (apply each; stay in lane)

### SEC-1. Independent inline-secret verification

Re-run the scan independently. Do NOT trust the pre-commit table.
Enumerate every value that is NOT `env:`-indirected AND is either
- >20 chars long, OR
- looks like a hex / base64 / JWT / PEM blob.

For each hit, verify it's either:
- The documented catalog_public_key (which IS safe to publish; it's
  the public trust anchor)
- A public URL (no `user:pass@` component)
- A public constant (bundle ID, domain name, version string)

If you find ANY value that doesn't fit these categories, ESCALATE
to CRITICAL — a real secret going into git history is unrecoverable.

### SEC-2. Env-name enumeration

List every `env:NAME` referenced by the file. Each NAME must be
resolved at runtime from `/etc/macprovider/*.env` (see deploy
script). The names themselves are not secrets, but audit for:
- Any NAME that looks like it could be a typo (e.g. accidentally
  reusing a different service's env var name → cross-tenant secret
  leak on startup)
- Any NAME that suggests a compound value (e.g.
  `env:DATABASE_URL_INCLUDING_PASSWORD`) — env: is one-shot, not
  a fragment substitution

### SEC-3. Historical exposure

- Confirm this file was ONLY previously present in gitignored form,
  i.e. never accidentally committed in an earlier PR that was later
  reverted. Check `git log --all --full-history -- phase4-coordinator/dist/coordinator.yaml`.
  If it's ever been in history, that history version may have had
  inline secrets that are already public — a separate incident
  independent of this PR's decision.

### SEC-4. Attack surface via `bundle_id` / `apple_team_id`

- `onboarding.bundle_id = "tech.malibu.app"` — public constant used
  to validate iOS App Attestation claims. Trivially discoverable
  from the App Store. Not a secret.
- `onboarding.apple_team_id = env:APPLE_TEAM_ID` — Team IDs are
  semi-public (they appear in App Store listings) but keeping them
  env-indirected reduces enumeration convenience. Safe posture.

### SEC-5. Attack surface via `catalog_public_key` value

- The 43-char value on line 151 is an ed25519 PUBLIC key. It is the
  trust anchor buyers use to verify the signed model catalog. It IS
  meant to be public.
- Confirm the value MATCHES the corresponding entry in
  `dist/coordinator.yaml.example` (a value that is already tracked
  and thus already in git history). If it differs, a rotation
  happened without a matching `.example` update — flag as MEDIUM,
  not because of secrecy but because reviewers of past PRs may not
  have caught the rotation.

### SEC-6. Convention risk (future PRs)

The `.gitignore` note prohibits inline secrets. Is that prohibition
enforceable? Consider:
- A future contributor could easily commit `operator_key: some-hex`
  by mistake if they don't know the convention. Is a pre-commit hook
  or CI check warranted? Note as a follow-up if so; not a merge
  blocker.
- The deploy script's step 1b diff will surface drift, but WILL NOT
  block a bad-secret commit from reaching origin. That's a code-
  path gap.

### SEC-7. Public URL disclosure

- `pool.gateway_base_url` and `signed_catalog.public_catalog_base_url`
  reveal infrastructure hostnames. If any of these hostnames were
  previously private (only known to insiders), publishing them
  adds an attack-recon signal.
- The primary hostnames (coordinator.streamvc.live,
  gateway.streamvc.live, stats.streamvc.live) are DNS-resolvable
  and already public via nginx TLS certs (transparency logs). No
  new disclosure.
- Confirm no admin/backdoor hostname (e.g.
  admin.internal.example) is in the file.

### SEC-8. Ratchet analysis

Once tracked, EVERY future coordinator.yaml change must go through
a PR. That's an audit win but a velocity cost. Confirm:
- Emergency ops (rotate operator_key, patch a runtime env value)
  don't require a PR — they're env-indirected, so `/etc/macprovider/*.env`
  edits + coordinator restart handle it without touching git.
- Structural config changes (add a rate limit, tune a threshold,
  add a section) now require PR + review. That's the intended
  outcome.

## Output format

```
CRITICAL (N):
  C1. <one-line title>
      Evidence: <file:line>
      Attack:  <one-sentence adversary scenario>
      Fix:     <one-sentence fix>
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Write to `specs/COORD_YAML_TRACKED_R1_SECURITY_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM, end with:
`VERDICT: security lane READY TO MERGE`

If ANY CRITICAL, additionally output at the very top:
`STOP: DO NOT MERGE — CRITICAL SECRET IN GIT HISTORY UNRECOVERABLE`
