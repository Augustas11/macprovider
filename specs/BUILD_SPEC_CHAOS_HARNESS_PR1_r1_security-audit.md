# BUILD_SPEC_CHAOS_HARNESS_PR1 — round 1 SECURITY-lane audit

Scope: PR 1 security audit for `test/network-harness/scenarios/15_provider_reconnect_storm.yaml`, the README chaos-lane addendum, and the referenced existing harness secret/artifact/chaos execution paths.
Verdict: PASS 0/0/0

## Findings

### INFO-1 — Chaos command stdout/stderr can persist future secret-bearing output
File: `test/network-harness/README.md:149`
Evidence: The README correctly documents that chaos entries run through `/bin/sh -c` and that stdout, stderr, exit code, and fire times are captured into `chaos_events.json` (`test/network-harness/README.md:149`). The runner stores command, stdout, and stderr directly in the event artifact (`test/network-harness/internal/chaos/runner.go:16`). Scenario 12's five committed commands are only `launchctl kickstart` against `gui/$(id -u)/live.streamvc.macprovider` (`test/network-harness/scenarios/15_provider_reconnect_storm.yaml:103`), and normal `launchctl kickstart` output is not token-shaped, bearer-shaped, or PII-shaped. However, because future chaos commands are arbitrary trusted shell, any command that prints a URL, `Authorization` header, token, or credential on stdout/stderr would persist in the artifact bundle.
Fix: No shipping blocker for PR 1. Add an INFO-level README callout near the chaos-events trust boundary before broader chaos-lane expansion: do not author chaos commands that echo secrets, URLs with credentials, or auth headers because stdout/stderr are copied into `chaos_events.json`.

