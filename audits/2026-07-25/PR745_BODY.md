## Summary

Fixes #745: `serve --model <A>` with `config.yaml` naming model B (and `model_artifact_path` for B) no longer silently loads B.

**Root cause:** `applyCLI` set only `config.model`; `ModelRuntime` loads `modelLoadPath ?? modelID` where `modelLoadPath` is the untouched config artifact. Autotune's candidate runner passes `--model <candidate>` without `--config`, so every post-install probe measured the incumbent under the candidate's name.

**Fix:** when CLI `--model` disagrees with the configured artifact binding, clear `model_artifact_path` + `model_artifact_sha256` so load falls through to the CLI model. Same-path CLI keeps the SHA binding. Fresh installs (no artifact) unchanged.

## AC evidence

| AC | Evidence |
|----|----------|
| AC-1 load A or fail closed | `testCLIModelPathClearsMismatchedConfigArtifactBinding` — artifact cleared; load path = `--model` |
| AC-2 candidate bench while other config | same path; candidate serve no longer inherits incumbent artifact |
| AC-3 A/B config states identical for same `--model` | config artifact cleared whenever CLI model disagrees |
| AC-4 resolved path on records | existing `CandidateBenchmark.modelArtifactPath` from artifact resolver; load path now matches |
| AC-5 regression | tests above + `testCLIModelWithoutConfigArtifactLeavesPathNilForFallback` |

## Out of scope

- Catalog gate re-derivation (#744) — blocked until this lands and real benches re-run
- Live production re-tune (ops)

## Test plan

- [x] ConfigApplier #745 unit tests (5)
- [ ] Three-lane codex audit to 0 C/H/M
- [ ] CI `ci-required` green
- [ ] Approving review

---

SPEC-GOVERNANCE-DECLARATION-BEGIN
{
  "schema_version": "spec-pr-governance-v1",
  "behavior_change": "yes",
  "contract_change": "none",
  "specs": ["SPEC-023"],
  "requirements": ["SPEC-023-R001"],
  "authority_domains": ["installer-autotune-policy"],
  "arbitration": ["CODE_BUG"],
  "tests": ["phase3-binary/Tests/macprovider-cliTests/ConfigApplierTests.swift"],
  "journeys": ["not-required"],
  "issue": "https://github.com/Augustas11/macprovider/issues/745"
}
SPEC-GOVERNANCE-DECLARATION-END
