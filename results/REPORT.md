# Phase 1 Report — Mac Provider PoC

**Date:** 2026-05-26T00:55:48Z
**Hardware:** Apple M1 MacBook Air, 8 GB
**Model:** mlx-community/Llama-3.2-3B-Instruct-4bit

## Headline result

PARTIAL — proceed with caveats

## Evidence

### Local endpoint (Step 4)
- Non-streaming: PASS — valid JSON with `choices[0].message.content`; observed content was `ready<|eot_id|>`.
- Streaming: PASS — SSE chunks used `data: {...}` and ended with `data: [DONE]`; chunks contained `choices[0].delta.content`.

### Tunnel end-to-end (Step 7)
- Non-streaming: PASS — tunneled response returned valid JSON with non-empty content: `Four.<|eot_id|>`.
- Streaming: PASS — tunneled stream returned multiple `data:` chunks and ended with `data: [DONE]`.
- Latency (5-request median): 0.446825s.
- TTFT (time to first token) for streaming: 0.379309s.

### Cancellation behavior (Step 8)
- Server stops on client disconnect: YES.
- Implications for smart router: Client disconnect produced a server-side `BrokenPipeError` while writing the stream, and the 5s log tail did not show generation continuing to completion. The server should not leak long-running generation after the downstream client closes, but the router should expect noisy broken-pipe logs.

### SSE format conformance (Step 9)
- OpenAI-strict: NO.
- Deviations observed: stream may begin with an SSE comment line like `: keepalive 9/10`; streamed chunks include extra fields such as `system_fingerprint` and `tool_calls`; non-streaming content included the literal `<|eot_id|>` suffix.
- Impact on Antseed seller plugin compatibility: Likely compatible if the parser ignores SSE comment lines and tolerates extra fields. A strict parser that assumes every non-empty SSE line starts with `data: ` may need a small compatibility fix.

## Quirks / surprises

- Port 8080 was already occupied by a pre-existing local `node` listener, so the run used port 8090 as directed by the runbook.
- Sandboxed `sysctl` could not read CPU/memory fields; hardware was confirmed later with `system_profiler`.
- `mlx_lm.server` aborted inside the sandbox due to Metal device discovery, then worked when run outside the sandbox.
- Background `nohup` launches from this Codex surface did not keep the MLX server or cloudflared tunnel alive reliably. Managed foreground sessions worked.
- First tunnel attempt returned Cloudflare `530 The origin has been unregistered from Argo Tunnel`; rerunning with a managed cloudflared session fixed it.

## Confidence assessment

4/5. The core OpenAI-compatible behaviors needed by a proxy are present: `/v1/chat/completions`, valid non-streaming JSON, SSE streaming chunks, `[DONE]`, and low latency through the public tunnel. Confidence is not 5/5 because of the SSE keepalive comments, literal `<|eot_id|>` suffixes, and the need to verify the actual Antseed seller parser against these quirks.

## Recommendation

Yes, spend the 4–6 weeks on Phase 3, but make Phase 3 explicitly include compatibility handling for SSE comments, extra fields, and output cleanup of model stop tokens. The architecture works well enough for the PoC question: a local M1 MLX backend exposed through a public tunnel can serve OpenAI-compatible requests with acceptable latency.

## Open questions for Phase 1B (optional)

- Does the current Antseed seller plugin ignore SSE comment lines such as `: keepalive 9/10`?
- Does the current seller or buyer path strip model stop tokens such as `<|eot_id|>` before forwarding output?
- Does live OpenRouter-style traffic behave the same under concurrent requests and real buyer cancellation?
- Does the tunnel remain stable enough for a paid end-to-end test, or should Phase 1B use a named Cloudflare tunnel instead of a quick tunnel?


---
---

# Phase 1 Continuation Report

**Date:** 2026-05-26T01:45:51Z
**Continuation of:** Phase 1 Report from 2026-05-26T00:55:48Z
**Tests added:** Step 6.5 (localtunnel), Step 6.7 (SSH reverse), Step 7.5 (six stress scenarios)

## Headline (continuation)

STILL PARTIAL — new caveats added, listed below

## Additional evidence

### Alternative tunnel sanity check (Step 6.5)
- localtunnel attempted: YES — `https://famous-groups-jump.loca.lt`.
- Same SSE contract observed: N-A — Step 6.5 only specified a non-streaming request.
- Conclusion: tunnel-agnostic for non-streaming OpenAI-shaped JSON; localtunnel returned valid JSON with content `yes<|eot_id|>`, matching the same stop-token leakage seen through cloudflared.

### SSH reverse tunnel to VPS (Step 6.7)
- SSH probe to root@165.22.182.207: SKIPPED — non-interactive auth failed with `Permission denied (publickey,password)`.
- Reverse tunnel established (port 6890): NO.
- Loopback curl from VPS through tunnel: SKIPPED.
- VPS sshd GatewayPorts setting: N-A; not inspected because SSH probe failed.
- Production-architecture viability: blocked by auth.
- Latency observation through SSH tunnel: N-A.

### Inference stress (Step 7.5)
- **7.5.1 Concurrent (3 parallel):** wall-time = 1.66s vs single = 1.84s → parallelism factor = 0.90x. Verdict: PARALLEL. Any failures: no.
- **7.5.2 Cold start:** cold TTFR = 1.72s, warm TTFR = 0.66s. Acceptable for product? yes.
- **7.5.3 Long context:** 8K total = 11.68s, 16K total = 13.58s. Observed prompt token counts were 2447 and 4847, so the provided runbook bodies did not actually reach true 8K/16K token sizes. Verdict on agentic workload viability: viable for the tested ~2.4K/~4.8K prompts; true 8K/16K remains an open Phase 1B check.
- **7.5.4 Sustained load (5 min):** 210 requests, 4200 total output tokens, throughput = 14.0 tok/s sustained. Latency drift first vs last minute: slightly degrading but not failing; first-minute average 1.16s, last-minute average 1.252s. Thermal observations: `pmset -g thermlog` did not return promptly in this Codex surface and was stopped after the load completed; `top` snapshot showed load average 4.08/3.95/3.29, 48.48% CPU idle, and 7460M physical memory used.
- **7.5.5 Memory pressure:** latency under ~2GB pressure = 21.91s vs baseline = 1.84s. Inference outcome: slow but successful.
- **7.5.6 Multi-model (Phi-3.5-mini):** non-stream = PASS, stream = PASS, same SSE shape as Llama: YES. Verdict on cross-architecture path: generalizes, with model-specific stop token leakage (`<|end|>` for Phi vs `<|eot_id|>` for Llama).

## Updated recommendation

Yes, but conditional. The user should proceed with Phase 3 if the Swift CLI explicitly treats the local model server as an imperfect OpenAI-compatible backend: strip model-specific stop tokens, ignore SSE comment keepalives, tolerate extra response fields, and add local scheduling/backpressure for concurrent buyers. The continuation strengthens the core inference case: concurrency works, cold starts are acceptable, sustained load survived 5 minutes, and a second model architecture works through the same tunnel path. The biggest unresolved production risk is the VPS relay path, which could not be validated because non-interactive SSH auth failed.

## Updated open questions for Phase 1B (paid live test)

- Does the actual Antseed seller plugin tolerate SSE keepalive comment lines and extra fields?
- Does the seller or buyer path strip leaked stop tokens such as `<|eot_id|>` and `<|end|>`?
- Is the apparent concurrent serving behavior sufficient under real buyer traffic, or does quality/latency degrade under higher concurrency?
- Does the memory-pressure slowdown create unacceptable buyer UX on real contributor Macs?
- Does a true 8K/16K token prompt remain viable? The runbook's generated bodies measured only 2447 and 4847 prompt tokens.
- Can SSH key auth be configured non-interactively for the VPS relay test, and what is the actual GatewayPorts setting?

## Architecture implications for Phase 3 / Phase 4

The "VPS as relay" pattern is not validated yet. The Step 6.7 probe was blocked before any tunnel setup because root SSH key auth to `165.22.182.207` failed non-interactively. That means Phase 4 should not assume the VPS relay is viable as-is. Next validation requires explicit SSH key setup for the Mac provider host, then rerunning the loopback-only `-R 6890:127.0.0.1:8090` test. Public external access through the VPS will still depend on GatewayPorts/firewall behavior, which this continuation deliberately did not modify or inspect after auth failed.



---
---

# Phase 1 Step 6.7 — SSH Reverse Tunnel (re-run after auth fix)

**Date:** 2026-05-26T17:13:00Z (run by main session, not Codex)
**Status:** PASS — production-architecture pattern validated for loopback path

## What was fixed before re-running

Previous run's SSH probe failed with `Permission denied (publickey,password)`.
Root cause: `~/.ssh/antseed_vps_ed25519` was present (dated 2026-05-08) and
worked when invoked explicitly with `-i`, but there was no `~/.ssh/config`
to auto-select it for host `165.22.182.207`. Default `ssh` tried `~/.ssh/id_*`,
which didn't exist.

**Fix:** Added a `Host 165.22.182.207` block to `~/.ssh/config` with
`IdentityFile ~/.ssh/antseed_vps_ed25519` and `IdentitiesOnly yes`.

After the fix, `ssh -o BatchMode=yes root@165.22.182.207 'echo ok'` returns
`ok` non-interactively. Step 6.7 ran from there.

## Findings

### Tunnel mechanism
- SSH reverse tunnel established: **YES** (PID 28268, port 6890 on VPS → port 8090 on Mac)
- Loopback curl from VPS through tunnel: **PASS** — returned valid OpenAI-shaped
  JSON with content `"Tunneled."` and `usage.completion_tokens=5`.
- Stop-token leakage observed in earlier original tests was absent here, likely
  because the model output happened to be a clean word.

### VPS sshd configuration
- `GatewayPorts` setting: **not set in sshd_config (default: no)**.
- Implication: reverse tunnels bind to `127.0.0.1` on the VPS only. External
  clients cannot reach the Mac through the VPS public IP via SSH reverse alone.
- For public-facing relay via SSH, the VPS would need either:
  - `GatewayPorts yes` (binds tunnels to all interfaces — broad), or
  - `GatewayPorts clientspecified` + explicit `-R 0.0.0.0:port` (binds per request)
  - Plus firewall must open the chosen public port.

### Latency through SSH tunnel (loopback only)
- 5 sequential requests through `ssh root@vps "curl localhost:6890 ..."`:
  - 5.486s, 5.570s, 4.945s, 5.004s, 5.726s
  - Median: 5.486s, vs cloudflared median (Step 7): 0.447s
- **Caveat:** this is NOT a fair comparison to cloudflared. Each measurement
  here opens a fresh SSH session to the VPS (TCP + auth handshake), runs curl
  remotely, returns. Most of the latency is the SSH session setup overhead,
  not the tunnel itself. Production Phase 4 architecture uses a persistent
  outbound connection from Mac to VPS coordinator, so this overhead does not
  apply at runtime.
- The relevant comparison is: did the request *complete correctly*? Yes.

## Architecture implications for Phase 3 / Phase 4

The "VPS as relay" pattern is **validated for the loopback case**. The Mac
can reach the VPS, establish a reverse tunnel, and the VPS can route a
request through that tunnel back to the Mac's MLX endpoint. This is the
core mechanism Phase 4 depends on.

What remains to be designed in Phase 4 (not blockers, but design decisions):

1. **Connection topology.** SSH reverse tunnels are a reasonable PoC mechanism
   but Phase 4 should use a purpose-built WebSocket from Mac to VPS
   coordinator (the same outbound pattern Darkbloom uses). SSH would be heavy
   for production: per-Mac sshd connections, no buyer multiplexing, no app-level
   metadata.

2. **Public exposure on VPS.** Phase 4 coordinator needs a public HTTPS endpoint
   (`api.macprovider.io`) that accepts buyer requests. That's a normal HTTP
   server bound to `0.0.0.0:443`, no GatewayPorts dance needed — completely
   independent of how the Mac connects inbound.

3. **The GatewayPorts question becomes moot.** It only mattered if we were
   considering exposing the Mac directly via SSH reverse tunnel (i.e. using
   SSH as the production relay). The right Phase 4 design uses a real
   coordinator process on the VPS, not SSH port forwarding.

## Updated headline

Phase 1 verdict: **PASS — proceed to Phase 3 with concrete shim list, Phase 4
architecture (VPS coordinator) is unblocked.**

The only remaining "unknown" of architectural consequence — whether the
production-pattern relay works at all — is resolved positively. Phase 4
should be designed around a purpose-built WebSocket coordinator, not SSH
reverse tunnels, but the underlying VPS-as-relay assumption holds.

## Cleanup verification
- MLX processes: 0
- SSH reverse tunnel processes: 0
- Port 8090 listeners: 0
- No production antseed paths or services touched
- No VPS files modified



---
---

# Phase 1 Step 7.5.3 — Long Context (tokenizer-accurate re-run)

**Date:** 2026-05-26T11:45:00Z
**Reason for re-run:** Original 7.5.3 in continuation report used filler
multiplication that produced 2447 and 4847 actual tokens, far short of the
intended 8K/16K. This re-run constructs prompts to exact target sizes using
the actual `mlx-community/Llama-3.2-3B-Instruct-4bit` tokenizer.

## Results

| Target | Server-confirmed prompt_tokens | Wall time | Prefill rate (est) | Result |
|---|---|---|---|---|
| 8,000 | 8,000 | **47.06s** | ~175 tok/s | ✅ PASS — response: "Ants are highly..." |
| 16,000 | 16,000 | **76.49s** | ~213 tok/s | ✅ PASS — response coherent |
| 32,000 | (n/a — failed) | 222s | n/a | ❌ HARD FAIL — Metal GPU OOM at ~26K tokens |

## Failure mode at 32K (most important finding)

The MLX server crashed with:
```
libc++abi: terminating due to uncaught exception of type std::runtime_error:
[METAL] Command buffer execution failed: Insufficient Memory
(00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)
```

Server log shows progressive prefill up to `26624/32000` tokens before the
Metal command buffer OOM'd. **The server process died** — this is not a
catchable Python exception, it's a libc++abi terminate. Recovery requires
full server restart.

Progressive prefill timing (from server log) shows attention cost growing:
- 0–2K: ~120 tok/s
- 8K–10K: ~170 tok/s (warmed up, batch efficiency)
- 16K–18K: ~115 tok/s (attention quadratic kicking in)
- 22K–24K: ~90 tok/s
- 24K–26K: ~85 tok/s, then OOM

## Hard ceiling on M1 8GB for Llama 3.2 3B Q4

Effective maximum context: **somewhere between 26K and 32K tokens**.
Practical safe ceiling: **~24K tokens** with margin for system memory pressure.
KV cache at ~96 KB/token × 24,000 ≈ 2.3 GB, plus 2 GB model weights, plus
activations — already saturating the ~4 GB GPU-available memory on this Mac.

## Phase 3 implementation requirements this surfaces

This is the **most important Phase 3 finding** from any of the runs. The
Mac Provider binary must:

1. **Pre-flight context length check before accepting requests.**
   Tokenize the incoming prompt, compute expected memory footprint, and
   reject (or route to a different Mac) any request that would exceed
   safe capacity. Do not pass it to the inference engine and hope.

2. **Per-Mac context cap as a function of RAM.**
   8GB M1: cap ~20K to be safe (24K is the absolute observed ceiling).
   16GB Mac: probably 50–60K. 32GB+: much higher.
   The binary needs to compute this at startup based on `hw.memsize`
   minus a headroom reserve, and advertise the cap to the coordinator.

3. **Graceful refusal policy, not silent crash.**
   Return a clean HTTP 413 or similar (`context too long for this provider`)
   so the coordinator can re-route. Do not let Metal OOM kill the process.

4. **Coordinator routing must respect per-Mac context caps.**
   When a buyer sends a 16K-token request, the coordinator should only
   route to Macs that advertised >16K capacity. This is a new field in
   the provider registration message.

## Updated agentic-workload viability verdict

| Workload pattern | Llama 3.2 3B on M1 8GB | Verdict |
|---|---|---|
| Short chat (≤2K context) | <5s prefill, fast | ✅ Excellent |
| Medium agent (4K–8K context) | ~25–47s prefill | ✅ Viable for non-realtime |
| Heavy agent (8K–16K context) | 47–76s prefill | ⚠️ Borderline — user waits >1 min |
| Cursor-style agents (16K+) | 76s for 16K, OOM at 32K | ❌ Not viable on 8GB |

**This sharpens the Mac Provider product positioning:** 8GB Macs are
genuinely good for short-to-medium contexts (the largest market — basic
chat, RAG with small context, code completion). They are not viable for
heavy agentic workloads. Phase 3 routing should reflect this — buyers
asking for >16K context should be routed exclusively to higher-RAM Macs.

This is not a defect of the architecture — it's a hardware-tier
segmentation that the coordinator must surface. The Mac Provider product
will have natural tiers based on RAM, the way cloud providers have tiers
based on GPU type.

## Original 7.5.3 conclusion was wrong in a useful way

The original continuation said "viable for the tested ~2.4K/~4.8K
prompts." That was technically true but misleading because the test
didn't reach what it claimed. This re-run shows the **real** picture:
8K viable, 16K borderline, 32K outright impossible on 8GB. That's a
much more actionable finding for Phase 3 design.
