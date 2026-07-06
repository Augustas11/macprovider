# BUILD_SPEC_CHAOS_HARNESS_PR1 — round 1 CODE-lane audit

Scope: CODE lane audit of `feat/chaos-scenario-12-reconnect-storm` against `origin/main...HEAD`: scenario 15 YAML, README chaos-lane docs, and non-runtime audit prompt artifacts.
Verdict: PASS 0/0/0

## Findings

### LOW-1 — README still marks `PROVIDER_SSH` as required for local chaos scenarios
File: test/network-harness/README.md:82
Evidence: The new chaos-lane section says "No `PROVIDER_SSH` needed for scenarios 05, 06, 12" at `test/network-harness/README.md:182`, and scenario 15 uses only local `launchctl` commands at `test/network-harness/scenarios/15_provider_reconnect_storm.yaml:100`. The existing setup block still says `PROVIDER_SSH` is required for chaos scenarios 05 and 06, and the committed-scenarios table still lists `PROVIDER_SSH` for both local-launchctl scenarios at `test/network-harness/README.md:311` and `test/network-harness/README.md:312`.
Fix: Update the setup block and rows for scenarios 05 and 06 to reflect the current local-launchctl contract, or explicitly mark `PROVIDER_SSH` as legacy/example-only if remote chaos is intentionally still documented.

### LOW-2 — Hybrid-rig isolation note names the wrong current model set
File: test/network-harness/README.md:176
Evidence: The README says "The MLX models the chaos scenarios target (Qwen3-32B-4bit today) must be served ONLY by this Mac", but scenario 15 targets `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` at `test/network-harness/scenarios/15_provider_reconnect_storm.yaml:94`. An operator following only the README could isolate Qwen3-32B while leaving the Qwen3-Coder lane multi-provider, making scenario 15 reroute/noise more likely.
Fix: Reword the bullet to say each chaos scenario's `prompts[].model` must be served only by this Mac during the run, and list both current examples if useful.

### LOW-3 — Cost-discipline paragraph is stale for the new chaos scenario
File: test/network-harness/README.md:223
Evidence: The README says committed scenarios use `max_tokens` 16-32 and small fleets, but scenario 15 adds 3 buyers x 2 requests with `max_tokens: 384` at `test/network-harness/scenarios/15_provider_reconnect_storm.yaml:83` and `test/network-harness/scenarios/15_provider_reconnect_storm.yaml:98`. This is still operationally reasonable, but the cost guidance no longer describes the committed suite accurately.
Fix: Update the paragraph to carve out chaos scenarios with long streaming prompts, or give a rough per-scenario cost note for scenario 15.

### INFO-1 — Scenario 12 validates against the current schema
File: test/network-harness/scenarios/15_provider_reconnect_storm.yaml:48
Evidence: `BUYER_TOKEN=dummy go run ./cmd/harness run scenarios/15_provider_reconnect_storm.yaml --out /tmp/macprovider-chaos-pr1-dryrun --dry-run` returned `scenario "provider_reconnect_storm" valid`. Cross-checking `Scenario.Validate()` shows the set fields satisfy the buyer-fleet schema: required target token and paired `_ssh` DB fields are present, `buyers.pattern: constant` is accepted, `requests_per_buyer: 2` has no extra constraint for constant mode, prompt model/user are present, and every chaos event has a non-empty command with non-negative `at`.
Fix: None.

### INFO-2 — Runtime and invariant plumbing are compatible with repeated kicks
File: test/network-harness/scenarios/15_provider_reconnect_storm.yaml:89
Evidence: `duration: 90s` admits second requests before the buyer deadline, while in-flight requests are awaited by `buyer.Run()`; `request_timeout: 60s` bounds each stream; and the final 85s `kickstart` fires before the runner proceeds to the 90s settlement quiesce pad. The chaos runner executes commands through `/bin/sh -c`, captures exit code/stdout/stderr, and local `man launchctl` confirms `kickstart` without `-k` starts the service without killing an already running instance, while `-k` kills before restart. The launchd plist template has `KeepAlive` and `ThrottleInterval` 10s, so the 20s kick cadence is plausible for repeated churn, though actual restart timing remains phase-B evidence.
Fix: None.

### INFO-3 — Diff includes audit prompt artifacts but no runtime source changes
File: specs/AUDIT_BUILD_SPEC_CHAOS_HARNESS_PR1_IMPL_CODE_PROMPT.md:1
Evidence: `git diff --name-status origin/main...HEAD` shows three new `specs/AUDIT_BUILD_SPEC_CHAOS_HARNESS_PR1_IMPL_*_PROMPT.md` files in addition to `test/network-harness/README.md` and `test/network-harness/scenarios/15_provider_reconnect_storm.yaml`. No Go, Swift, coordinator, gateway, provider, chaos-runner, or invariant source files are changed; `go test ./internal/scenario ./internal/chaos ./internal/invariants ./internal/reconcile` passed.
Fix: None for runtime code. Optionally update the audit prompt's "Files changed" summary to mention the audit prompt artifacts so future reviewers do not treat the name-status output as scope drift.
