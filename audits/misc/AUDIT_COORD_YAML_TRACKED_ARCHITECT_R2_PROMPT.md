# Track dist/coordinator.yaml in-tree — ARCHITECT-lane audit (R2)

R1 found one MEDIUM (`.example` header still said "gitignored because
it contains a secret" — that instruction became wrong when this PR
started tracking `dist/coordinator.yaml`).

## R2 fix

`phase4-coordinator/dist/coordinator.yaml.example` header (lines 1-5)
was rewritten to:
- Name `phase4-coordinator/dist/coordinator.yaml` as the tracked
  authoritative production config
- Reposition `.example` as an annotated reference for operators + audits
- Reinforce the "NEVER commit inline secrets, use env: indirection"
  convention
- Explain `catalog_public_key` is the ed25519 PUBLIC trust anchor
  and IS safe to commit verbatim

## R2 scope

Verify ONLY:

1. Does the R1 MEDIUM close? The header now correctly documents the
   new source-of-truth model. Confirm no residual "gitignored" claim.
2. Does the header framing invite a NEW class of confusion?
   - Does it still make sense as a bootstrap doc for a fresh operator?
   - Does it correctly describe the two-file model (tracked yaml vs
     annotated reference)?
3. Any residual HIGH / CRITICAL that the R1 pass missed given the
   R2 diff shape?

## Output format

```
CRITICAL (N): ...
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
```

Write to `specs/COORD_YAML_TRACKED_R2_ARCHITECT_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM, end with:
`VERDICT: architect lane READY TO MERGE (R2)`
