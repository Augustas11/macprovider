# AUDIT — BUILD_SPEC_CHAOS_HARNESS_KICKSTART PR 1 (IMPL) — SECURITY lane

## What to audit

Branch `feat/chaos-scenario-12-reconnect-storm` (worktree at
`/Users/augstar/macprovider-chaos-pr1`). Diff:

```
git -C /Users/augstar/macprovider-chaos-pr1 diff origin/main...HEAD
```

Files changed:

- `test/network-harness/scenarios/15_provider_reconnect_storm.yaml` — new
- `test/network-harness/README.md` — new "Chaos lane" subsection + row in scenarios table

Zero Go changes; zero harness runtime changes.

## Intent (security-relevant summary)

The scenario runs a buyer fleet against Pearl coord+gateway (SUT) while
issuing `launchctl kickstart -k` against the LOCAL provider process 4×
in 60s. Chaos is scoped to the local process — no faults injected into
Pearl. Buyer traffic uses `${BUYER_TOKEN}` env-expanded at scenario
load time.

## Audit focus (SECURITY lane)

Please assess and write findings to
`specs/BUILD_SPEC_CHAOS_HARNESS_PR1_r1_security-audit.md`. Rate
CRITICAL / HIGH / MEDIUM / LOW / INFO with file:line, evidence, fix.

Bar for shipping: **0 CRITICAL, 0 HIGH, 0 MEDIUM**.

### 1. No production fault injection

- Confirm every `chaos_events[*].command` in
  `15_provider_reconnect_storm.yaml` targets ONLY the local
  `live.streamvc.macprovider` launchd label. No `ssh`, no `systemctl`,
  no direct network calls at Pearl coord/gateway.
- Confirm the scenario cannot be silently repurposed to fault-inject at
  Pearl by env-var substitution — commands contain no `${VAR}`
  references. If it did, `scenario.expandEnv()` would substitute at
  load time.
- Read `test/network-harness/README.md` "Chaos lane (money-path
  resilience) → Chaos-lane anti-scope" — does it correctly document
  the "Pearl is SUT, never fault-injected" rule for future scenario
  authors?

### 2. Command-injection surface

- The chaos runner (`internal/chaos/runner.go`) executes each `command`
  via `/bin/sh -c`. Anything a scenario author writes in a chaos_events
  command IS shell-executed. Assess:
  - Is the committed 12 YAML's command string free of anything a
    reviewer could accidentally hand-edit into an unsafe shell (backtick,
    unbalanced quote, `rm -rf`-adjacent)?
  - `$(id -u)` expansion at runner time — this expands to the harness's
    process UID. Confirm that is the SAME UID launchd's GUI domain uses
    to register `live.streamvc.macprovider` (typically the console user
    501). If the harness is run under a different UID (sudo, launchd
    daemon, ci), `$(id -u)` returns that UID and the kickstart targets
    the wrong (or nonexistent) domain — kick is a no-op.
- Are chaos_events restricted to a documented vocabulary anywhere?
  (Answer: no, per README "chaos commands are committed YAML and trust
  the operator".) Is this documented explicitly enough that a phase-B
  reviewer knows scenario YAMLs are code-equivalent to shell scripts?
- The README addendum should surface that trust boundary. Assess
  whether the wording in the new "Chaos lane" section makes this
  clear enough, or whether it needs a callout.

### 3. Secret handling

- `${BUYER_TOKEN}` is env-expanded at scenario load time
  (`scenario.expandEnv()`). The RUNTIME scenario carries the plaintext
  bearer. The ARTIFACT bundle copies the PRE-expansion snapshot (per
  `run-scenario.sh`), so the artifact `scenario.yaml` retains the
  `${BUYER_TOKEN}` placeholder. Verify this is still true — an artifact
  bundle attached to a PR must not leak the bearer.
- Chaos runner captures `Stdout` and `Stderr` from each shell command
  into `chaos_events.json`. Do any of the 5 committed launchctl
  commands emit anything token-shaped, bearer-shaped, or PII-shaped on
  stdout/stderr in the normal case? (`launchctl kickstart -k <label>`
  is silent on success; it might print an error if the label is
  missing.)
- If a chaos command errored and printed a URL or auth header, would
  that land in the committed artifact? Argue for an INFO-level note in
  the README if so.

### 4. Local rig / port exposure

- Scenario 12 does not spin up a local coord/gateway (per spec and
  README, the local rig is deferred). Confirm no port bind, no
  listener, no `0.0.0.0` in any code path this PR touches.

### 5. SPEC-002 / SPEC-022 alignment

- Nothing in this PR softens I1–I4 or introduces a
  `charged_delivered_tolerance_tokens > 0`. Verify.
- Confirm the scenario doesn't add a bypass or auth-relaxation that
  would let a mid-stream reconnect silently upgrade to a
  privileged-path. (It shouldn't — scenario is passive observation
  plus provider-side chaos — but a security-lane audit should say so
  explicitly.)

### 6. Audit-prompt integrity

- The audit prompt files under `specs/` are added as part of this PR.
  Confirm they contain no committed tokens, no credentials, no
  environment secrets. `${VAR}` references in prose are fine.

## Deliverable

Write findings to
`specs/BUILD_SPEC_CHAOS_HARNESS_PR1_r1_security-audit.md` with the
same structure as the CODE lane: verdict header + `## Findings`
section with `### <SEVERITY>-N — <title>` entries listing file:line,
evidence, fix.

If zero C/H/M — write the file anyway to record convergence.
