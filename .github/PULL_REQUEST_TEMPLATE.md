## Summary

<!-- What changes and why. Write "Related: #N" for issues this PR does not fully complete. -->

## Tests

<!-- Exact commands and results. An interrupted, skipped, or timed-out run is not a pass. -->

- [ ] `make vet`
- [ ] Tests for the changed surface (list the commands)
- [ ] `python3 scripts/gen_spec_index.py --check` and `python3 scripts/check_spec_governance.py --base-ref origin/main` (when `specs/` changes)

## Deploy

<!-- If this changes catalog, continuous-batching, or native-MTP state, name the scripts/ops/ deploy step. Otherwise write "none". -->

## SPEC governance declaration

<!--
Fill in the JSON below; CI validates it with scripts/check_spec_pr_declaration.py.
- behavior_change / contract_change: "none" or "yes". contract_change is "yes" when
  a canonical specs/SPEC-NNN-*.md, specs/AUTHORITY.json, or specs/CONFORMANCE.json changes.
- behavior_change "none" is valid only when every changed path is governance-only.
- behavior_change "yes" needs specs, requirements, authority_domains, arbitration
  (CODE_BUG, SPEC_BUG, DECISION_REQUIRED, DUPLICATE_AUTHORITY, UNKNOWN), tests, and
  journeys (or ["not-required"]).
- "issue" is optional: https://github.com/Augustas11/macprovider/issues/<N>
-->

SPEC-GOVERNANCE-DECLARATION-BEGIN
{
  "schema_version": "spec-pr-governance-v1",
  "behavior_change": "none",
  "contract_change": "none",
  "specs": [],
  "requirements": [],
  "authority_domains": [],
  "arbitration": [],
  "tests": [],
  "journeys": []
}
SPEC-GOVERNANCE-DECLARATION-END
