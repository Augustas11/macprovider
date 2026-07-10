CRITICAL (0):
HIGH (0):
MEDIUM (1):
  M1. Production example still teaches the obsolete local-secret source-of-truth model
      Evidence: phase4-coordinator/dist/coordinator.yaml.example:2
      Fix:     Update the dist example header before merge so it says tracked dist/coordinator.yaml is Pearl's live source of truth, secrets must be env-indirected, and the example is documentation/reference only.

LOW (4):
  L1. Emergency structural-config posture needs an explicit backfill convention
      Evidence: phase4-coordinator/dist/deploy-pearl-vps.sh:402
      Fix:     Add a short OPS/CLAUDE playbook for emergency Pearl edits: make the live edit, restart, immediately backfill the same structural change in a PR, and require the next deploy reviewer to confirm Pearl has no unlanded hotfix drift before allowing ALLOW_CONFIG_DRIFT=1.

  L2. Inline-secret convention is useful in .gitignore but should not live only there
      Evidence: .gitignore:44
      Fix:     Keep the .gitignore warning, but mirror the convention in OPS.md or AGENTS.md where operators and future agents look for production-config rules.

  L3. Add CI for the no-inline-secret invariant
      Evidence: .gitignore:50
      Fix:     Add a lightweight check that parses phase4-coordinator/dist/coordinator.yaml and fails when keys matching *_key, *_secret, *_token, *_password, or *_dsn have non-env: values, with explicit allowlist handling for public fields such as tier2.catalog_public_key and URL/base-url fields.

  L4. Two-file model should be named as an intentional reference-doc split
      Evidence: phase4-coordinator/dist/coordinator.yaml.example:220
      Fix:     In this PR or a follow-up, rename coordinator.yaml.example to coordinator.yaml.annotated or add a top comment saying it is an annotated reference, not an operator bootstrap template that must structurally match live on every PR.

QUESTIONS (1):
  Q1. The prompt references an existing admin bypass_mode=always ruleset note for coordinator.yaml, but I only found the general "money-path and security-sensitive changes go through PRs" rule.
      Evidence: CLAUDE.md:69
      Fix:     Confirm whether the GitHub ruleset/admin-bypass convention exists outside the repo; if it is real operating policy, document it next to the emergency config playbook.
