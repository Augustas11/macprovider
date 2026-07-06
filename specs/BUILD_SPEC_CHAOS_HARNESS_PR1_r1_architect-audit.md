# BUILD_SPEC_CHAOS_HARNESS_PR1 — round 1 ARCHITECT-lane audit

Scope: PR 1 chaos-harness architecture audit for `test/network-harness/scenarios/15_provider_reconnect_storm.yaml`, the README chaos-lane addendum, and the referenced existing harness contracts.
Verdict: PASS 0/0/0

## Findings

### INFO-1 — Chaos event artifacts prove command execution, not post-event service recovery
File: `test/network-harness/internal/chaos/runner.go:16`
Evidence: `EventResult` records `index`, `description`, `command`, `scheduled_at`, `fired_at`, `skipped`, `exit_code`, `stdout`, `stderr`, and `err` only. That schema is unchanged by this PR and is sufficient to correlate the five scenario-12 kicks with buyer outcomes, but it cannot distinguish "launchctl command exited successfully and launchd restarted a usable provider" from "launchctl exited successfully but the provider never reconnected or reloaded the model." Scenario 12's final `launchctl kickstart` at `test/network-harness/scenarios/15_provider_reconnect_storm.yaml:113` mitigates cleanup risk, but it still records only the shell result.
Fix: Keep this PR scenario-only. Before expanding the chaos lane substantially, consider adding an optional post-event probe field, for example `post_check_command`, `post_check_exit_code`, `post_check_stdout`, and `post_check_stderr`, or a higher-level `recovered` boolean derived from a provider visibility probe. That should be a separate harness-schema PR because it changes `chaos_events.json` consumers.

### INFO-2 — Scenario 12 is committed as a live-Pearl target instance, not a target-profile-neutral fixture
File: `test/network-harness/scenarios/15_provider_reconnect_storm.yaml:75`
Evidence: The scenario hardcodes live Pearl URLs plus `pearl:/var/lib/macprovider/coordinator.db` and `pearl:/var/lib/macprovider/gateway.db`. The existing schema already supports a future local rig through `target.coordinator_db_path` / `target.gateway_db_path`, and validation enforces mutual exclusion with the `_ssh` fields at `test/network-harness/internal/scenario/schema.go:376`. Therefore the schema is flexible enough for PR 2's local-rig decision, but this committed YAML would still need an edited target block, a copied local variant, or a future target-profile overlay to run unchanged against local coord+gateway.
Fix: No change needed in PR 1. If PR 2 adopts a local coord+gateway rig, decide whether chaos scenarios should stay live-target YAMLs with documented edits or gain a small target overlay/profile mechanism so scenario behavior and target selection do not fork.
