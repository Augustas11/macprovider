---
role: security-audit
version: 1.0
date: 2026-07-02
target_pr: v1.7.5 Stage1 probe timeout + infeasible-reason persistence
lens: SECURITY — trust boundaries, data leakage, tampering, DoS
audit_bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW/INFO acceptable if documented.
---

# SECURITY audit — SPEC-023 v1.7.5 probe timeout + diagnostics

You are a security-review specialist. Independently audit this change
for **security-relevant defects**: trust-boundary crossings, data
leakage, tampering opportunities, DoS surface expansion. Do NOT report
generic hardening suggestions unless a concrete attack scenario exists.

## Context

macprovider-cli v1.7.5 fixes SPEC-023 install regression on M-Base +
30B MoE (probe URLRequest timeout was 64s → prefill exceeded it → no
paid model was ever admitted). Fix A extends the URL request idle
timeout to 300s (configurable). Fix B persists per-candidate
`.infeasible(reason:)` strings into `last-recommendation.json` and
emits them to stderr as `[warn]` lines so users can diagnose "no
eligible paid model" states.

## Security-relevant surfaces to audit

### 1. Diagnostic string source / injection

`.infeasible(reason:nErr:)` strings originate from:
- Local `Stage1Prober` — sources: probe HTTP status codes, "TTFT
  exceeded gate", "provider readiness timeout: <lastError>", stop-token
  leak messages. `<lastError>` is a Swift `Error.localizedDescription`
  from the local mlx subprocess.
- Local subprocess stderr tail on `.processExited` cases.
- Local benchmarker's own gate rejections (RAM / tier / runtime-status).

These strings are:
- Written to stderr as `[warn] spec-023 probe: <modelKey>: <reason>`.
- Written to `~/.config/macprovider/last-recommendation.json` inside
  `probe_diagnostics` map.

**Threat model to consider**:
- Can a malicious model or CDN cause the probe to embed attacker-
  controlled strings into these diagnostics? E.g. subprocess stderr tail
  → does the coordinator later parse this file for anything?
- If `last-recommendation.json` is ingested by another tool
  (coordinator, portal, autotune-status), can a crafted reason string
  cause parser trouble (JSON escaping bugs)?
- Are terminal control sequences ever escaped when writing to stderr,
  or does an ANSI-escape in a subprocess stderr tail get echoed to a
  human terminal? See historical incident:
  `c1-control-chars-terminal-sanitizer-bypass`.

### 2. Model-key origin

`benchmarks[modelKey]` and `probeDiagnostics[modelKey]` keys are drawn
from `request.candidateCatalog.rows.keys`. The catalog is Ed25519-signed
by streamvc autotune keys (SPEC-023 v0.3). Keys are attacker-controlled
only if the signing key is compromised. Confirm audit assumes that.

### 3. URLRequest timeout DoS surface

New 300s idle timeout on `POST /v1/chat/completions` sent to
`http://127.0.0.1:<port>`. Provider spawns a **local** mlx subprocess
on that port (SPEC-023 v0.3 §Stage1Probe). Third parties cannot bind
to that port during a probe (loopback only). Concerns:
- Could a rogue subprocess be replaced during the 300s window (e.g.
  via provider trust-of-local-tools compromise) to keep the connection
  open, tying up the URLSession?
- If yes, this only harms the calling user. Consider whether that's
  in-scope.
- Is 300s an acceptable ceiling given that `runner.stop(graceSeconds:
  10)` is used in `defer`? What happens if the subprocess ignores
  SIGTERM and the URLRequest is still pending?

### 4. Configurability of `probeIdleTimeoutSec`

Now injectable via `init` but no CLI flag or config file surface — so
production always uses the 300s default. Consider whether this is
correct posture (a malicious config could not override it).

### 5. `probe_diagnostics` file persistence

`last-recommendation.json` is written via `RecommendationStateStore.write`
using `Data.write(to:options:.atomic)`. Consider:
- Any file permissions concern?
- Is this file readable by other users on multi-user Macs and would
  the diagnostics leak information a threat model would care about
  (installed model IDs and hardware constraints — probably not
  sensitive, but confirm)?

### 6. Non-goals to explicitly ignore

- Cryptographic signing of `probe_diagnostics` — this is diagnostic
  data, not authorization state. Not in scope.
- Rate-limiting stderr emissions — same argument.

## Files to read

- `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`
- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`
  (esp. `benchmarks()`, `storedStateJSON()`, `LastRecommendationState`)
- `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift`
  (esp. `runAutotuneRecommend()` stderr emission loop)

## Reply format

```
## SECURITY audit — v1.7.5

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

Reject speculative "harden by also doing X" if there is no concrete
attack. Report each finding with the attack scenario and the specific
line(s) making it possible.
