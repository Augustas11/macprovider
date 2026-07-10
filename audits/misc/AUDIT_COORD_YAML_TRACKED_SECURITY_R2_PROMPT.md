# Track dist/coordinator.yaml in-tree — SECURITY-lane audit (R2)

R1 found one MEDIUM (`.example` `catalog_public_key` was a placeholder,
not the real pubkey, so a trust-anchor rotation would be invisible to
reviewers diffing tree vs `.example`).

## R2 fix

`phase4-coordinator/dist/coordinator.yaml.example` line 192 was
changed to embed the actual public key value:

```
  #   catalog_public_key: "IVH2aAlTudARJSK3e7XGmcGjxAqwm6lReGiS-0U9aFQ"
```

matching `phase4-coordinator/dist/coordinator.yaml` line 151. A
byte-for-byte diff between the two files now catches any rotation.

Header comment on `.example` also rewritten to reflect the new
tracked-yaml model + reinforce the "NEVER inline a secret" convention.

## R2 scope

Verify ONLY:

1. Does the R1 MEDIUM close? Diff the R2 tree state
   (`git diff origin/main -- phase4-coordinator/dist/coordinator.yaml.example`)
   and confirm the placeholder is replaced with the actual value and
   they match `dist/coordinator.yaml:151`.
2. Did the fix introduce any NEW security issue?
   - Any new inline secret exposure in `.example`?
   - Any header text that misleads about the new secret-handling
     convention?
3. Are there any residual HIGH or CRITICAL findings the R1 pass
   missed given the R2 diff shape?

## Output format

```
CRITICAL (N): ...
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
```

Write to `specs/COORD_YAML_TRACKED_R2_SECURITY_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM, end with:
`VERDICT: security lane READY TO MERGE (R2)`
