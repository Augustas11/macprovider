---
role: security-audit
version: 1.0
date: 2026-07-03
target_pr: v1.7.7 Stage1 probe prewarm (Track A3)
lens: SECURITY — trust, exploitation, DoS
audit_bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW/INFO acceptable if documented.
---

# SECURITY audit — v1.7.7 Stage1 probe prewarm

Audit for security-relevant defects on the current diff.

## Context

v1.7.7 adds a prewarm request in
`phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift` at
`Stage1Prober.probe()` after `waitForReady == .ready`. The prewarm
sends one throwaway request to `127.0.0.1:<port>` (the local
MLX subprocess spawned by `runner.start()`) so that the SUBSEQUENT
measurement observes warm-service TTFT instead of cold-start (which
includes model-load + prefill wall-clock).

Prewarm errors are swallowed via `try?` — the prober does not care
if the first request fails; it only cares about the measurement
that follows.

## Security-relevant surfaces to audit

### 1. Local-subprocess trust boundary

The prewarm sends an HTTP request to `127.0.0.1:<port>` — same target
as the real probe. The subprocess is a locally-spawned MLX server
under provider trust. Consider:
- Does prewarm expand DoS surface? (Answer likely no — one extra
  request per candidate, bounded by probeIdleTimeoutSec = 300s.)
- Can the subprocess return anything to the prewarm that leaks state
  or persists into the measurement? The prewarm's SSE response bytes
  are discarded via `_ = try?`. Confirm no side-effects persist.

### 2. Swallowed prewarm error

`_ = try? await probeOnce(...)` — the error is fully discarded.
Consider:
- Could a subprocess exploit the swallowed error to hide misbehavior
  from the operator (e.g., emit an error the operator would want to
  know about, then respond normally to the real probe)?
- Threat model: the subprocess is under the same trust as the CLI
  itself. It is spawned by the CLI. So attacker-manipulated
  subprocess is out-of-scope unless there's a local-machine
  compromise path.

### 3. Prewarm as amplification vector

If the subprocess spawns child processes on receiving `/v1/chat/completions`
POSTs, prewarm doubles that spawn count. Consider whether this creates
a resource-exhaustion concern for legitimate hardware or only
malicious/broken runtimes.

### 4. Interaction with the ProviderPreWarmer

The existing `ProviderPreWarmer` (used by Stage 2 hill-climb) has its
own prewarm semantics. The new v1.7.7 change adds a SEPARATE
`probeOnce`-based prewarm inside `Stage1Prober`. Are the two now
racing on the same runner? Do both fire when Stage 1 → Stage 2
transitions happen? Check callers of Stage1Prober.probe.

### 5. Probe timing side channel

Prewarm's HTTP request is observable to anything monitoring the
loopback interface. Are TTFT values from prewarm ever persisted or
transmitted? Confirm the `_ = try?` discard fully prevents leakage.

## Non-goals

- MLX subprocess internal security (unchanged).
- The full 300s probeIdleTimeoutSec was audited in v1.7.5.
- Notary/signing (unchanged).

## Files to read

- `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`
  (esp. `Stage1Prober.probe()` prewarm block)
- `phase3-binary/Sources/macprovider-cli/ProviderPreWarmer.swift`
  (for interaction analysis)
- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`
  (only if you need caller context)

## Reply format

```
## SECURITY audit — v1.7.7

CRITICAL: <count>
HIGH: <count>
MEDIUM: <count>
LOW: <count>
INFO: <count>

### CRITICAL
[if none: "None."]
### HIGH
### MEDIUM
### LOW
### INFO
### Verdict
```
