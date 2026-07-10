# Session direct-push audit R2 — SECURITY lane

You are the **security** lane of a three-lane audit (code / security /
architect) verifying that the R1 → R2 fix for SEC-M-1 actually closes
the threat surface, and that ARCH-M-1's new signal-cascade + subprocess
teardown does not open new surface.

Convergence bar: **0 CRITICAL, 0 HIGH, 0 MEDIUM findings** across all
three lanes.

## Scope — what changed since R1

Worktree: `/Users/augstar/macprovider-poc-r1fix/` on branch
`fix/session-r1-orphan-and-ws-url` (base = `origin/main` at `2b7021b`).

- **`f7d44f9` — SEC-M-1 fix**: `RegisterClient.validateCoordinatorWSURL`
  now runs after decoding `/v1/providers/register` response; rejects
  any coordinator_ws_url that isn't same-origin with the registrar
  base URL (scheme, host, port, no userinfo, non-empty path).
- **`cfc0efe` — ARCH-M-1 fix**: CLI `--recommend` path becomes pgid
  leader + installs cascading SIGINT/SIGTERM handler that re-emits
  via `killpg(0, SIGTERM)`. App tears down subtree via
  `terminateAutotuneSubtree` (SIGTERM → grace → killpg SIGKILL +
  kill SIGKILL fallback).

## Security-lane scope (apply each; stay in lane)

### SEC-R2.1 — Does SEC-M-1 fix actually close the threat?

Original threat (R1 SEC-M-1): a network attacker who tampers with the
HTTPS `/v1/providers/register` response can return an attacker-
controlled `coordinator_ws_url`; the App persists it; the CLI later
sends `Authorization: Bearer <provider_token>` to that origin.

R2 fix: `validateCoordinatorWSURL(_:expectedBase:)` rejects mismatch
on scheme / host / port / userinfo / empty-path.

Verify:

- Same-origin definition matches the industry norm (scheme + host +
  port). Confirm.
- Case sensitivity: DNS is case-insensitive on host; `lowercased()`
  applied to both. `scheme` also lowercased. Confirm the attacker
  can't defeat validation via `WSS://COORDINATOR.STREAMVC.LIVE` case
  differences or Unicode homoglyphs. What about IDN? URL.host on an
  attacker-controlled ASCII-punycode host (`xn--…`) — would the
  comparison match against a non-punycode expected host?
- Path validation is "non-empty". An attacker who successfully
  compromised the registrar could still steer the CLI to
  `wss://coordinator.streamvc.live/attacker-controlled-path`. Is the
  path attacker-influenceable in a way that matters to the WebSocket
  handshake (e.g. does the coordinator route path-based to different
  handler chains)? If yes, path should be pinned to `/v2/provider`
  or the exact expected path.
- Port validation defaults 443/80. An attacker who controls DNS or
  MITM could redirect a same-hostname client to a different port at
  the network level, but this validator only sees the URL string
  from the response — the actual TCP destination is chosen at connect
  time. Confirm the validator scope is correctly "the URL we persist",
  not "the network destination we reach".
- What if the register response returns the CORRECT URL but the
  attacker MITMs the WebSocket connect after? That's a TLS trust
  issue, out of scope for this validator. Confirm the coordinator WS
  connect uses standard TLS trust with system CA — no pinning
  currently, so any compromised CA still wins that fight. Note as
  INFO if relevant.
- Any `postRegister` callsite that persists ANYTHING (not just the WS
  URL) before the validator returns? Read
  `phase3-binary/app/Sources/Malibu/Onboarding/LaunchProviderController.swift`
  to confirm the register response is opaque until postRegister
  returns without throw.

### SEC-R2.2 — Does ARCH-M-1 fix open new surface?

The CLI now sets itself as pgid leader and installs a signal handler
that fans out `killpg(0, SIGTERM)` to its process group. New surface:

- **Signal-injection from same-UID processes**: any process with same
  EUID can send SIGTERM to the CLI. Before ARCH-M-1, this killed the
  CLI. After, it cascades to all children (which now includes the
  serve --no-join grandchild). Result: same-UID attacker can shut
  down the CLI's autotune subtree. Blast radius is availability,
  not confidentiality. Was the same shutdown already possible via
  `kill(childPid)` directly? If yes, ARCH-M-1 does not expand the
  surface — it just makes graceful shutdown reliable. Confirm.
- **Signal loop concern**: cascade calls `killpg(0, SIGTERM)`. If
  the CLI's SIG_IGN somehow didn't take effect BEFORE the dispatch
  source was set up (race between `signal(SIGTERM, SIG_IGN)` and
  the first SIGTERM arrival), could the CLI kill itself in a loop?
  Trace the init order in `AutotuneSignalSources.init`. Note the
  SIG_IGN happens BEFORE `.resume()`, so the source is armed after
  ignore is in place.
- **Process-group pollution**: The CLI's setpgid runs BEFORE the
  benchmarker spawns its first child, so children inherit the new
  pgid. But the CLI itself was originally in the App's process group.
  After setpgid, the CLI is in its own group; does that break any
  App-side assumption (e.g. App using killpg with a group id it
  captured pre-fork)? Read the App-side code to confirm no such
  assumption exists.
- **posix_spawn signal defaults**: Foundation.Process on macOS uses
  `posix_spawn` which by default resets signal dispositions to
  `SIG_DFL` in the child. Confirm this — if the child inherits the
  parent's `SIG_IGN` for SIGTERM, cascade delivery becomes a no-op
  and orphan-children persist.
- **App-side SIGKILL escalation**: `killpg(cliPid, SIGKILL)` +
  `kill(cliPid, SIGKILL)` in `terminateAutotuneSubtree`. Can either
  reach a wrong process (PID reuse race)? PID reuse after the CLI
  exits is a real macOS concern, but `Process` maintains a wait4
  reference so PID is not recycled until reap. Confirm.

### SEC-R2.3 — Debug-print discipline

The R1 SEC-I-2 audit confirmed no `[idsig]` prints in release paths.
Re-verify for THIS round: the new signal-cascade / URL-validation
paths must NOT log secrets. Grep the two commit diffs for:
- `stderr` writes containing bearer tokens, coordinator URLs,
  provider IDs, transcript hashes, ECDH keys, signature bytes.
- The one new stderr write is
  `"autotune --recommend interrupted; exiting after subtree cleanup\n"`
  — no secrets. Confirm.

### SEC-R2.4 — Config write path integrity (regression check)

SEC-M-1 fix rejects bad URLs BEFORE persistence. But separately, does
`ProviderConfig.saveProviderIdentity` still perform its own safety
checks (YAML escaping, atomic write, 0600 perms)? R1 SEC scope did
NOT deeply audit this. Do a spot-check now — the validator is a
belt-and-suspenders layer on top of the persistence layer, not a
replacement.

### SEC-R2.5 — Test coverage of security-relevant paths

The new RegisterClientTests cover the accept path and each reject
path individually. What's MISSING that would strengthen the security
posture?

- Test that `postRegister(...)` DOES NOT return a `RegisterResponse`
  object when the validator throws (i.e. no partial persistence
  path). Currently only the validator itself is tested in isolation.
- Test for IDN / punycode host mismatch.
- Test for scheme comparison being case-insensitive (both
  `wss://coordinator.streamvc.live` and `WSS://coordinator.streamvc.live`
  accepted, but a comparison bug that makes the URL scheme parse fail
  for uppercase would show up here).

## Response format

Write findings to
`audits/2026-07-05/session-direct-r1/session-direct-r2-security-findings.md`
using this template:

```
# Session direct-push R2 — SECURITY lane findings

## Verdict
PASS / FAIL

## Findings
### SEC-R2-C-1 (CRITICAL) <title>
- File: <path:line>
- Threat model: ...
- Evidence: ...
- Recommendation: ...
### SEC-R2-H-1 (HIGH) <...>
### SEC-R2-M-1 (MEDIUM) <...>
### SEC-R2-L-1 (LOW) <...>
### SEC-R2-I-1 (INFO) <...>
```

Stay in your lane. If verdict is PASS, write a one-paragraph "what
threats I checked" narrative.
