# Audit Prompt: SPEC-015 v0.2 Implementation Step 7

Audit the Step 7 CLI implementation on branch `impl/spec-015-v0-2-step-07`.
Scope the audit to `phase7-verify/internal/cli`,
`phase7-verify/cmd/macprovider-verify`, and the explicit hash bypass added to
`phase7-verify/internal/verify/verify.go`.

Required checks:

- Confirm every §10.4.4 flag-interaction matrix row is mapped to a CLI test.
- Confirm §10.4.3 exit codes `0`, `1`, `2`, `64`, and `65` are each reachable
  by a concrete test.
- Check the `64` vs `65` boundary: `bundle_version=99` is `65`; malformed
  bundle JSON and unknown bundle keys are `65`; unknown flags, missing
  required flags, mutual exclusion, and malformed `--pubkey` are `64`.
- Confirm bundle strict mode uses `DisallowUnknownFields()` and rejects unknown
  top-level keys.
- Confirm provider-id resolution order follows CF7 strictly: `--provider-id`,
  bundle `provider_id`, exact single-match cache fallback, then `64` when no
  provider id and no explicit `--pubkey`.
- Confirm missing provider id without `--pubkey` is never downgraded to
  `inconclusive`.
- Confirm `--bundle` plus `--receipt` is a mutual-exclusion usage error.
- Confirm `--quiet` suppresses stderr while preserving JSON `warnings[]`.
- Confirm `--explain` prints the trust-boundary text after a valid result and
  is suppressed by `--quiet`.
- Confirm the explicit hash bypass is limited to header+hashes mode and does
  not alter bundle canonicalization behavior.
- Confirm the full Steps 1-6 suite still passes with `go test ./... -race`.
- Confirm there is no Step 8 scope creep: human output remains minimal and JSON
  formatting is limited to Step 7 necessities.

Report CRITICAL/MAJOR/MINOR findings first with file and line references.
If no issues are found, state that explicitly and cite the validation commands.
