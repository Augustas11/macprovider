# AUDIT_PROVIDER_IDLE_PREWARM_SECURITY — SECURITY lane

You are auditing the diff that implements the provider idle-prewarm
described in `specs/BUILD_PROVIDER_IDLE_PREWARM_IMPL_PROMPT.md`.

## Your lane: SECURITY

Focus exclusively on security-class defects. Not correctness, not
architecture.

### Look for

1. **Coordinator-visibility hygiene**
   - The prewarm inference MUST NOT change any WSS heartbeat field
     (slots_free, slots_total, requests_total, in_flight_count, any
     new field). A hostile provider operator MUST NOT be able to use
     prewarm activity to lie to the coordinator about capacity or
     to exclude themselves from routing during warm periods.
   - No new WSS message type introduced. No new
     `CoordinatorClient.swift` request-dispatch surface added.

2. **Receipt / billing path leakage**
   - `runInternalWarmup` cannot invoke `ReceiptAudit.emit*`,
     `ReceiptBuilder`, `CachedReceiptKeyStore`, or
     `InMemoryReceiptKeyStore`. A prewarm that accidentally emitted a
     receipt would inflate provider earnings.
   - No path where a prewarm result gets tagged with a buyer
     `request_id` or `conversation_key` and forwarded upstream.

3. **Amplification vectors**
   - Config bounds enforced at load time:
     - `tick_seconds >= 1` (prevents CPU-spin loop).
     - `max_tokens <= 8` (bounded per-tick GPU cost).
     - `prompt` length <= 64 UTF-8 bytes (bounded prefill cost).
     - `idle_threshold_seconds >= 5` (prevents "prewarm every second").
   - A malicious yaml with all knobs at their extremes still
     produces bounded resource consumption per unit time.

4. **KV-cache / SPEC-024 poisoning**
   - The prewarm inference MUST NOT write to the SPEC-024
     conversation-cache in a way that a subsequent buyer request
     with a colliding hash would see. If the prewarm hits the same
     cache key as a real buyer's future request, it could bias
     billing or leak into non-intended conversation contexts.
   - Prewarm bypasses cache-write OR uses a well-known reserved
     key namespace.

5. **Battery-drain amplification**
   - `run_on_battery: false` (default) is enforced BEFORE the
     inference dispatch, not after. An attacker with yaml-write
     access flipping `run_on_battery: true` and setting
     `tick_seconds: 1` + `max_tokens: 8` is bounded by the load-time
     validation.
   - Even at `run_on_battery: true`, thermal gating (R1 point 4)
     provides a floor — prewarm stops on `.serious`.

6. **IOKit resource handling**
   - `IOPSCopyPowerSourcesInfo` return value is `CFRelease`d before
     returning from the check.
   - `IOPSCopyPowerSourcesList` return value is `CFRelease`d.
   - Individual `CFDictionaryRef` items obtained via
     `IOPSGetPowerSourceDescription` are NOT `CFRelease`d (they're
     borrowed references per Apple docs). Verify the code does not
     over-release.
   - No unbounded allocation / retention cycle.

7. **Signal / SIGINT hygiene**
   - Shutdown handler cancels the prewarmer BEFORE draining the
     runtime, so no prewarm inference outlasts a graceful shutdown
     window and holds MLX resources.
   - Force-kill (SIGKILL) is out of scope.

8. **Log injection**
   - `prompt` field (operator-configurable) is NOT logged verbatim
     in structured events. If the operator sets `prompt: "\"attack\"
     newline injection"` the log line must remain well-formed JSON.
   - `thermal_state` and `on_battery` are enum values, no injection
     risk.

9. **Config knob as attack surface**
   - Validation prevents `tick_seconds: 0.001`, `max_tokens:
     100000`, `prompt: "<128k characters>"`.
   - Yaml unmarshal defaults for missing fields do NOT produce a
     less-safe state than the documented defaults.

10. **No secret exfiltration**
    - Prewarm event logs do NOT include buyer keys, provider tokens,
      keychain secrets, or any material from
      `~/.config/macprovider/keys/`.
    - Prewarm output text is NOT logged at all (only
      `tokens_generated` count).

### Do NOT flag

- Non-security correctness bugs (CODE lane).
- Naming / placement (ARCHITECT).
- Findings from unchanged pre-diff code.

### Output format

Report findings ranked C / H / M / L / I. Each finding lists:
file:line, threat model (who benefits), concrete scenario, proposed
mitigation.

```
STATUS: SECURITY lane — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>
```

## Diff to audit

`git diff` in the worktree.
