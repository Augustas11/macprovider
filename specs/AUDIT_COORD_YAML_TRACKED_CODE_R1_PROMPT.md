# Track dist/coordinator.yaml in-tree — CODE-lane audit (R1)

You are the **code** lane of a three-lane audit (code / security /
architect) of a PR that removes `phase4-coordinator/dist/coordinator.yaml`
from `.gitignore` and commits its current contents as the tracked
authoritative production config. Stay narrowly in your lane.

## Branch / commit
- Branch: `feat/coord-yaml-sync-spec026`
- Worktree root: `/Users/augstar/macprovider-coord-yaml-sync`
- Base: `origin/main` @ `dabf188`
- Files in scope:
  - `.gitignore` — line 44-46 replaced with an explanatory block that
    permits `phase4-coordinator/dist/coordinator.yaml` to be tracked
    and prohibits inline secrets.
  - `phase4-coordinator/dist/coordinator.yaml` (NEW to tracking) —
    contents equal what is currently running on Pearl VPS
    (`159.223.165.194:/opt/macprovider/coordinator.yaml`); pulled via
    scp then structurally verified secret-free before commit.

## What this change does (operator summary — NOT the audit answer)

Previously the file was per-operator-local (gitignored). This broke
the deploy loop: `dist/deploy-pearl-vps.sh` step 1b diffs local vs
live, and there was no repo-side source of truth so a fresh operator
had no way to know what live actually looked like. All secret-shaped
fields are now `env:NAME` indirected (resolved at runtime from
`/etc/macprovider/*.env`), so the file itself carries no secrets.
Tracking it closes the tree↔live drift loop.

## Code-lane scope (apply each; stay in lane)

### CODE-1. YAML validity

- Parse the file: `python3 -c "import yaml, sys; yaml.safe_load(open('phase4-coordinator/dist/coordinator.yaml'))"` should succeed.
- All top-level keys resolvable against the coordinator config
  schema (`phase4-coordinator/internal/config/config.go`):
  - `listen`, `pool`, `routing`, `provider_http`, `limits`, `auth`,
    `storage`, `logging`, `billing`, `providers`,
    `coordinator_advertised_version`, `onboarding`, and any others
    the live file contains.
- Confirm each new (drift) section maps to a Go struct field:
  - `auth.operator_keys.spec026_a`, `spec026_b` — is
    `auth.operator_keys` a defined field (map[string]string)?
  - `onboarding.app_track_register_enabled`,
    `onboarding.postgres_dsn`, `onboarding.bundle_id`,
    `onboarding.apple_team_id`, `onboarding.coordinator_domain`,
    `onboarding.asn_prefixes` — cross-check
    `phase4-coordinator/internal/onboarding/*.go` and the
    `OnboardingConfig` struct.
  - `coordinator_advertised_version.latest_binary_version` —
    cross-check where this is consumed (likely
    `phase4-coordinator/internal/config/config.go` or the
    provider-ws handshake).

### CODE-2. Deploy-script drift check compatibility

- `dist/deploy-pearl-vps.sh` step 1b runs `normalize_yaml` on both
  local and live before diffing. Verify the tracked file, after
  normalization (mask `_key/_secret/_token`, strip comments/blanks),
  matches the live file's normalized form exactly.
- Trace the deploy contract now: tree yaml == live yaml (audited).
  Any commit that touches the yaml must be followed by a deploy or
  the drift check re-fires. Is that documented in the PR body
  or `.gitignore` explanatory comment?

### CODE-3. `.example` file relationship

- `phase4-coordinator/dist/coordinator.yaml.example` is now
  significantly stale vs the tracked `coordinator.yaml` (235 vs
  166 lines; different comment style; different tuning values;
  missing SPEC-026 sections).
- Options: (a) leave `.example` alone as an out-of-date template
  (documentation debt), (b) delete `.example` (tracked yaml IS the
  template), (c) sync `.example` to match `coordinator.yaml`
  structure. This PR ships (a). Is that the right scope for this
  change or a follow-up bug?

### CODE-4. No inline secrets — verify the pre-commit scan

Confirm the scan performed before commit:
- Every field name ending in `_key`, `_secret`, `_token`,
  `_password` has a value that starts with `env:` OR is the
  documented catalog ed25519 public key on line 151.
- Line 151 `catalog_public_key` is 43 chars = base64-encoded 32-
  byte ed25519 pubkey. Compare against the value in
  `dist/coordinator.yaml.example` (line ~138); they must match
  bit-for-bit. If they don't, either the audit target has an
  unaudited rotation, OR the `.example` template is stale.
- Every field name matching `dsn|url|host|endpoint` has a value
  that starts with `env:` OR is a public URL with no embedded
  `user:pass@` auth pair.

### CODE-5. Diff hygiene

- The `.gitignore` diff replaces 3 lines with a 10-line
  explanatory block. Confirm no unrelated `.gitignore` lines were
  touched.
- No other files should change in this PR — this is a scope-tight
  yaml-tracking change. Confirm.

## Output format

```
CRITICAL (N):
  C1. <one-line title>
      Evidence: <file:line>
      Fix:     <one-sentence fix>
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Write to `specs/COORD_YAML_TRACKED_R1_CODE_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM, end with:
`VERDICT: code lane READY TO MERGE`
