# AUDIT PROMPT — Issue #585 v1.8.40 diff — CODE lane (R1)

You are an independent code auditor. Audit the complete uncommitted-release diff
for v1.8.40 in THIS worktree:

```
git -C /Users/augstar/macprovider-malibu-bootstrap-bridge diff 71eb927a..HEAD
```

Base `71eb927a` is origin/main (= immutable v1.8.39 source). The diff comprises
two commits (checkpoint `2dcfc90b`, widening `12941d2b`).

## Context

- Issue #585: provider lifecycle must work as one signed system (Option 2:
  launchd+CLI own process/credentials/updates/lifecycle; Malibu is read-only).
- The immutable v1.8.39 release failed physically on the real provider: the
  autotune candidate exited on `invalid lifecycle transition from loading_model
  to degraded_serving`, and its rollback stranded a `rollback_in_progress`
  lifecycle file that the restored legacy v1.8.30 CLI cannot clear.
- Decision log: `beta/DECISION_CRITERIA.md` entries 152–161 (155–161 are in the
  diff or adjacent history and are normative for this audit).
- Evidence already collected: the opt-in real-model integration test
  `testIntegrationRealServeLifecycleWhenEnabled` PASSED against the real
  `serve --no-join --autotune-candidate` path with a real model on this Mac.

## Audit scope (rate every finding CRITICAL / HIGH / MEDIUM / LOW)

1. **Lifecycle graph edits** (`ProviderLifecycleState.swift`,
   `MacProviderCLI.swift`, `CoordinatorClient.swift`): are the two new edges
   (`loading_model -> degraded_serving`, `loading_model -> paused_by_operator`)
   exactly as narrow as Entry 158 requires — correct writer authority
   (`serve` / `operator_command`), no broadened predecessors elsewhere, fencing
   and sequence semantics intact? Test adequacy in
   `ProviderLifecycleStateTests.swift`.
2. **Installer transaction correctness** (`dist/install.sh`,
   `dist/test/install_upgrade_evidence_rollback.test.sh`): the lifecycle state
   file (`lifecycle/state-v1.json`) is now the tenth transaction member —
   snapshot at `begin_install_transaction`, restore of exact prior
   contents-or-prior-absence as the LAST swap in the generated `recover.sh`.
   Verify: correct staging/prove-copy, correct absence semantics, interrupted
   rollback rerun convergence, orphan-scan and observe.sh paths, failure
   behavior when the snapshot cannot be staged or verified, no ordering bug
   that could clobber the restored state with a later transactional write,
   bash quoting/set -e pitfalls, and the regression matrix actually asserting
   what it claims (byte-exact hash compare, absence, interruption, forward
   success).
3. **Version-bump coherence**: CLI/app/coordinator/release-ledger all at
   1.8.40 (`project.yml`, `release-builds.tsv`, coordinator yaml files,
   `CoordinatorClient.swift`). Anything still asserting or advertising 1.8.39
   where it must not?
4. **Malibu bridge pin** (`CLIUpdateRunner.swift` + tests): correctness only in
   this lane (authority questions belong to the security lane) — logic,
   version comparison edge cases, test coverage of arm/disarm/downgrade.
5. **Observable-surface back-compat**: the lifecycle file schema, field names,
   writer strings, and reason codes are consumed by Malibu 1.8.39's projection
   (`AgentSnapshot.swift`) and by operators' journals. Confirm the diff
   preserves every existing field/shape and adds no incompatible emission.

Attribute every finding as NEW-to-this-diff vs PRE-EXISTING on the v1.8.39
baseline; pre-existing-not-worsened issues are reported but not blocking.

## Output format

Markdown. For each finding: severity, file:line, what breaks, minimal
reproduction or reasoning, suggested fix. End with a summary table and an
explicit verdict line: `VERDICT: X CRITICAL / Y HIGH / Z MEDIUM / W LOW`.
