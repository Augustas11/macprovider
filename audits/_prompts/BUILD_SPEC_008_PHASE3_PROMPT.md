# BUILD SPEC-008 Phase 3 — Pillar D: Behavioral Safety Controls

## Context

You are working on **macprovider-poc** — a P2P Mac inference marketplace.
The coordinator is a Go service (`phase4-coordinator/`) that proxies buyer
chat-completion requests to Mac provider machines over WebSocket.

SPEC-008 Phases 1 and 2 are complete. **This session implements Phase 3:
Pillar D behavioral safety controls in the coordinator relay loop.**

Pillar D is coordinator-internal. No SPEC-001 wire change is required. No
changes to the provider binary (`phase3-binary/`) are needed.

Normative spec: `specs/SPEC-008-tier2.md` §8 (Pillar D), §11.1 (config keys),
§12.5 (T2.D audit events), §13 (disclosure update). Read those sections before
implementing.

---

## What to build

### Overview

Add three enforcement controls that the coordinator applies to every provider
response **before writing bytes to the buyer**:

1. **Response size cap** (§8.3) — truncate provider output at
   `tier2.output_size_cap_bytes` bytes when positive.
2. **Completion encoding validation** (§8.4) — reject responses containing
   non-UTF-8 bytes, forbidden control codepoints, or invalid SSE/JSON framing.
3. **Response-time anomaly logging** (§8.5) — log a WARN when provider
   time-to-first-token significantly exceeds the declared baseline. Logging
   only; never reject solely for TTFT.

All three controls are gated by `tier2.behavioral_safety_enabled: false`
(default). **When false, Tier-1 buyer-visible behavior MUST be byte-for-byte
identical to today.** No latency, no change in output.

---

### 1. Config keys

Add to `phase4-coordinator/internal/config/config.go` under `Tier2Config`:

```go
BehavioralSafetyEnabled        bool    `yaml:"behavioral_safety_enabled"`
OutputSizeCapBytes              int64   `yaml:"output_size_cap_bytes"`
OutputBytesPerTokenCeiling      int     `yaml:"output_bytes_per_token_ceiling"`
DefaultOutputSizeCapBytes       int64   `yaml:"default_output_size_cap_bytes"`
EncodingValidationEnabled       bool    `yaml:"encoding_validation_enabled"`
ResponseTimeAnomalyEnabled      bool    `yaml:"response_time_anomaly_enabled"`
ResponseTimeAnomalyFactor       float64 `yaml:"response_time_anomaly_factor"`
ResponseTimeAnomalyMinMs        int64   `yaml:"response_time_anomaly_min_ms"`
```

Default values (all preserve Tier-1 behavior):
- `behavioral_safety_enabled: false`
- `output_size_cap_bytes: 0`
- `output_bytes_per_token_ceiling: 16`
- `default_output_size_cap_bytes: 1048576`
- `encoding_validation_enabled: false`
- `response_time_anomaly_enabled: false`
- `response_time_anomaly_factor: 5.0`
- `response_time_anomaly_min_ms: 10000`

Startup validation (§11.2) — fail startup when:
- `response_time_anomaly_factor <= 1.0`
- `response_time_anomaly_min_ms < 0`
- `output_bytes_per_token_ceiling <= 0`
- `default_output_size_cap_bytes <= 0`
- `behavioral_safety_enabled: true` AND `encoding_validation_enabled: true`
  AND `output_size_cap_bytes < 0`

These are Pillar D config fields. Per existing reload policy, mark them
`tier2HotReloadable` in `tier2ReloadFieldClasses`
(`cmd/coordinator/main.go`) — they apply to the next response chunk after
reload, no restart required.

---

### 2. Pillar D guard

Add `internal/tier2/pillarD.go` (new file):

```go
package tier2

import "github.com/augstar/macprovider/phase4-coordinator/internal/config"

// PillarDGuard holds evaluated state for one response.
// Construct once per forwardWS* call when behavioral_safety_enabled.
type PillarDGuard struct {
    cfg             config.Tier2Config
    bytesWritten    int64
    capExceeded     bool
    encodingFailed  bool
    ttftLogged      bool
    requestID       string
    providerID      string
    log             zerolog.Logger
}

func NewPillarDGuard(cfg config.Tier2Config, requestID, providerID string, log zerolog.Logger) *PillarDGuard
func (g *PillarDGuard) Active() bool  // true iff behavioral_safety_enabled

// CheckChunk validates one SSE data chunk (the raw SSE line, e.g. "data: {...}\n\n").
// Returns (forward bool, truncated bool, err error).
// - forward=false means drop this chunk and abort the stream.
// - truncated=true means the chunk was shortened to fit the cap.
func (g *PillarDGuard) CheckChunk(chunk string) (forward bool, truncated bool, err error)

// CheckNonStreamingBody validates the complete non-streaming JSON response body.
// Returns err != nil if the body fails encoding validation.
func (g *PillarDGuard) CheckNonStreamingBody(body []byte) error

// LogTTFT records time-to-first-token and emits WARN audit event if anomalous.
func (g *PillarDGuard) LogTTFT(ttftMs int64, providerBaselineMs int64)
```

Implement the controls per spec:

**Size cap (§8.3):**
- Count bytes in the completion payload (after SSE `data:` prefix strip,
  before writing to buyer).
- For streaming: once cumulative bytes reach `output_size_cap_bytes`, finish
  the stream with a well-formed `data: [DONE]\n\n` terminal event and log
  `T2.D oversized_completion_truncated`. Do not write further payload chunks.
- For non-streaming: truncate response body JSON at UTF-8 boundary before
  returning it; log `T2.D oversized_completion_truncated`. Return valid JSON
  even if truncated (truncate the content string, not the JSON envelope).
- If preserving UTF-8 validity requires emitting fewer bytes than the cap,
  prefer valid UTF-8; log both configured cap and actual emitted byte count.
- `output_size_cap_bytes == 0` means disabled even if
  `behavioral_safety_enabled: true`.

**Encoding validation (§8.4):**
- After stripping the `data:` SSE prefix, extract the completion `content`
  string from the JSON payload (if present).
- Reject if the decoded content contains bytes in forbidden codepoint ranges:
  - C0 range U+0000–U+001F **except** U+0009 (TAB), U+000A (LF), U+000D (CR)
  - U+007F (DEL)
  - C1 range U+0080–U+009F
- JSON string escapes (e.g. `\0`) are decoded before the check; the
  escaped value is subject to the forbidden-range rule.
- Reject if the SSE payload is not valid JSON.
- Reject if the response body (non-streaming) is not valid JSON.
- SSE framing newlines and colons are NOT rejected — only the completion text.
- Pre-commit failure (no bytes written yet): return
  `tier2_output_encoding_invalid` (HTTP 502) to buyer.
- Post-commit failure (streaming, bytes already sent): emit SSE error event
  and close stream; log `T2.D output_encoding_rejected`.

**TTFT anomaly (§8.5):**
- Record timestamp when `forwardWS*` is entered; record timestamp of first
  `chunk` received from `relay.Chunks`.
- `ttft_ms = first_chunk_time - dispatch_time`
- Threshold: `ttft_ms > max(response_time_anomaly_min_ms, provider_baseline_ms * response_time_anomaly_factor)`
- `provider_baseline_ms` comes from `pool.Provider.ModelLoadTimeMs` if
  present, else 0 (baseline missing = skip anomaly check per §8.5).
- Anomaly is log-only WARN: `T2.D response_time_anomaly`. Never reject.

---

### 3. Wire the guard into the relay loops

Edit `phase4-coordinator/internal/buyer/server.go`:

**`forwardWSStreaming`** — insert Pillar D guard:

```go
// At top of function, after relay is obtained:
cfg := s.tier2Config()
guard := tier2.NewPillarDGuard(cfg, requestID, provider.ProviderID, s.log)

// Replace the existing w.Write([]byte(chunk.Data)) block:
if guard.Active() {
    forward, truncated, err := guard.CheckChunk(chunk.Data)
    if err != nil {
        // encoding failure
        if !committed {
            writeError(w, http.StatusBadGateway, "server_error",
                "tier2_output_encoding_invalid", "Provider response encoding validation failed.")
            relay.Cancel("tier2_encoding_invalid")
            return wsForwardFailed
        }
        // post-commit: emit error SSE and close
        commit()
        writeSSEError(w, "Provider response encoding validation failed.", "tier2_output_encoding_invalid")
        relay.Cancel("tier2_encoding_invalid")
        return wsForwardFailed
    }
    if !forward {
        // cap reached: stream closed with DONE already appended by guard
        relay.Cancel("tier2_cap_exceeded")
        return wsForwardComplete
    }
    if truncated {
        // guard already wrote the truncated chunk + DONE via the writer passed to it
        relay.Cancel("tier2_cap_truncated")
        return wsForwardComplete
    }
}
commit()
if _, err := w.Write([]byte(chunk.Data)); err != nil { ... }
```

> Design note: pass `w` into `CheckChunk` or handle writes inside the caller
> — pick whichever keeps the guard stateless about `http.ResponseWriter`.
> The above pseudocode shows intent; adapt to the actual implementation shape.

**`forwardWSNonStreaming`** — insert guard on accumulated body:

```go
// Before the final w.Write(body.Bytes()):
if guard.Active() {
    if err := guard.CheckNonStreamingBody(body.Bytes()); err != nil {
        writeError(w, http.StatusBadGateway, "server_error",
            "tier2_output_encoding_invalid", "Provider response encoding validation failed.")
        return wsForwardFailed
    }
    // size cap for non-streaming: truncate body if needed
    body = guard.TruncateNonStreamingBody(body)
}
```

**TTFT:** record `dispatchAt := time.Now()` before `s.relay(...)` is called.
Pass `dispatchAt` to the guard; call `guard.LogTTFT(ttftMs, provider.ModelLoadTimeMs)`
when the first chunk arrives in either path.

---

### 4. Audit events (T2.D)

Add to `phase4-coordinator/internal/tier2/` (or audit package):

| Event type string | Severity | When |
|---|---|---|
| `T2.D oversized_completion_truncated` | WARN | size cap triggered |
| `T2.D output_encoding_rejected` | WARN | encoding validation failed |
| `T2.D response_time_anomaly` | WARN | TTFT threshold exceeded |

Fields on every T2.D event: `request_id`, `provider_id`, `assigned_id`,
`model_id`.

Additional fields:
- `oversized_completion_truncated`: `configured_cap_bytes`, `emitted_bytes`
- `output_encoding_rejected`: `reason` (forbidden_codepoint / invalid_json / invalid_sse)
- `response_time_anomaly`: `ttft_ms`, `baseline_ms`, `threshold_ms`, `factor`

---

### 5. Disclosure update (§13)

In `phase5-gateway/internal/router/server.go`, the `/v1/models` handler reads
coordinator routing metadata. Add `untrusted_provider_safety` to the Tier-2
disclosure fields:

Value is computed from the coordinator's Pillar D flag matrix (§8.6):

| behavioral_safety_enabled | output_size_cap_bytes | encoding_validation | anomaly | Value |
|---|---|---|---|---|
| false | any | any | any | `"none"` |
| true | 0 | false | false | `"none"` |
| true | >0 AND true AND true | — | — | `"enforced"` |
| true | anything else | — | — | `"partial"` |

The coordinator MUST include these fields in the routing metadata it returns to
the gateway (the existing `/internal/routing-metadata` or equivalent endpoint).

---

### 6. Tests

Add to `phase4-coordinator/internal/buyer/server_test.go` and a new
`phase4-coordinator/internal/tier2/pillar_d_test.go`:

Cover all five acceptance criteria from SPEC-008 §8.7:

- **AC-D-1**: streaming 64-byte ASCII, cap=32 → exactly 32 bytes forwarded,
  `T2.D oversized_completion_truncated` logged.
- **AC-D-2**: cap falls inside a multi-byte UTF-8 codepoint → only complete
  codepoints emitted, both configured and actual byte counts logged.
- **AC-D-3**: chunk with invalid UTF-8 bytes → `tier2_output_encoding_invalid`
  before buyer commit.
- **AC-D-4**: decoded completion text contains C0/C1 forbidden codepoints →
  rejected and logged.
- **AC-D-5**: TTFT 5001ms, baseline 1000ms, factor 5 → WARN logged, response
  NOT rejected.

Also test: `behavioral_safety_enabled: false` → zero change to Tier-1 behavior
(no extra latency, byte-identical output).

---

### 7. Build and verify

```bash
cd phase4-coordinator
go build ./...
go test ./... -count=1
go test -race ./... -count=1 -run TestPillarD
```

Coordinator must pass all existing tests unchanged. No gateway or
phase3-binary changes needed for Phase 3.

---

## Key files

```
phase4-coordinator/internal/config/config.go          # add Pillar D config keys
phase4-coordinator/internal/tier2/pillar_d.go         # new — PillarDGuard
phase4-coordinator/internal/tier2/pillar_d_test.go    # new — AC-D-1 through AC-D-5
phase4-coordinator/internal/buyer/server.go           # wire guard into relay loops
phase4-coordinator/internal/buyer/server_test.go      # integration tests
phase4-coordinator/cmd/coordinator/main.go            # mark Pillar D keys hot-reloadable
phase5-gateway/internal/router/server.go              # untrusted_provider_safety disclosure
specs/SPEC-008-tier2.md                               # normative — §8, §11.1, §12.5, §13
```

## Out of scope for this session

- Shadow/log-only mode (optional per spec, explicitly deferred in v0.3)
- Phase 1 or Phase 2 changes
- provider binary changes
- Config activation (C3) — that is an operator step after deploy
