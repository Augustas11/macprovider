> **SUPERSEDED — Phase 1 falsifiability script.** This document continues
> `RUNBOOK.md` (also superseded). For current production operations see
> [`OPS.md`](OPS.md). Kept here for historical reference and audit
> traceability.

# Phase 1 Runbook — Continuation Pass

You are a Codex agent picking up an in-progress Mac Provider PoC. The
previous Codex session completed Steps 0–11 of `RUNBOOK.md` and produced
`results/REPORT.md` with verdict **PARTIAL — proceed with caveats**.

Three groups of tests were skipped in that run. They are the most
informative ones for the user's actual production architecture decision.
This continuation runs them.

**Do NOT redo Steps 0–11.** They are already complete. Read the existing
report at `/Users/augstar/macprovider-poc/results/REPORT.md` for context
on what's already known.

## Mission

Run exactly these from the existing `RUNBOOK.md`:
- **Step 6.5** — Alternative tunnel sanity check (localtunnel)
- **Step 6.7** — SSH reverse tunnel to the user's VPS
- **Step 7.5** — Inference stress scenarios (six sub-tests)

The full commands and PASS/FAIL criteria for each are in `RUNBOOK.md`.
This file tells you the *order*, the *state restoration* required before
they can run, and how to report findings.

## Same HARD RULES apply

See `RUNBOOK.md` HARD RULES section. Unchanged. In particular:
- VPS at 165.22.182.207: SSH allowed for Step 6.7 only, port 6890 only,
  loopback only, no file modifications.
- No production antseed paths touched.
- Working directory remains `/Users/augstar/macprovider-poc/`.

## Important context from previous run

- Port 8080 was occupied by a pre-existing `node` listener. The previous
  run used **port 8090** instead. **Continue using 8090 throughout.** Any
  reference to 8080 in RUNBOOK.md should be read as 8090.
- The Llama-3.2-3B model is already cached in `~/.cache/huggingface/`.
- The `.venv` is already set up at `/Users/augstar/macprovider-poc/.venv`.
- `cloudflared` is already installed via Homebrew.
- Previous run was sandbox-sensitive: `mlx_lm.server` and `cloudflared`
  did not survive `nohup` backgrounding in the prior Codex surface. If
  the same issue recurs, run them as **managed foreground processes**
  with periodic polling, exactly as the previous run worked around it.

## Step A — Restore runtime state

The previous run cleaned up. Restart what we need:

```bash
cd /Users/augstar/macprovider-poc
source .venv/bin/activate

# Restart MLX server on port 8090
nohup python3 -m mlx_lm.server \
  --model mlx-community/Llama-3.2-3B-Instruct-4bit \
  --port 8090 \
  --host 127.0.0.1 \
  >> logs/03-mlx-server.log 2>&1 &
echo $! > state/mlx-server.pid

# Wait for listener
for i in $(seq 1 30); do
  if lsof -nP -iTCP:8090 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "MLX up after ${i}s"
    break
  fi
  sleep 1
done

# Restart cloudflared tunnel against port 8090
nohup cloudflared tunnel --url http://127.0.0.1:8090 \
  > logs/06-tunnel-continued.log 2>&1 &
echo $! > state/tunnel.pid

# Capture new tunnel URL
for i in $(seq 1 30); do
  TUNNEL_URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' logs/06-tunnel-continued.log | head -1)
  if [ -n "$TUNNEL_URL" ]; then
    echo "New tunnel URL: $TUNNEL_URL"
    echo "$TUNNEL_URL" > state/tunnel-url.txt
    break
  fi
  sleep 1
done

# Sanity check the restored setup
TUNNEL_URL=$(cat state/tunnel-url.txt)
curl -s -X POST "$TUNNEL_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mlx-community/Llama-3.2-3B-Instruct-4bit",
    "messages": [{"role": "user", "content": "Reply: alive"}],
    "max_tokens": 5,
    "stream": false
  }' | tee logs/A-restore-sanity.json
```

**If the foreground/background launches behave like last time (nohup
doesn't survive), use the managed-foreground workaround from the previous
run — keep them as long-running tasks in your tool surface rather than
detaching.**

**GATE:** Do not proceed until both `state/tunnel-url.txt` exists and the
sanity curl returns valid JSON with non-empty content. If either fails,
write `results/HALT-CONTINUE.md` and stop.

## Step B — Run Step 6.5 (localtunnel)

Execute exactly as written in `RUNBOOK.md` Step 6.5, with one substitution:
**replace `8080` with `8090`** in the localtunnel command.

```bash
# Reference the original spec
grep -A 60 "^## Step 6.5" /Users/augstar/macprovider-poc/RUNBOOK.md | head -70
```

Then run it with port 8090. Capture to `results/06.5-localtunnel-test.json`
and `logs/06.5-localtunnel.log` as specified.

## Step C — Run Step 6.7 (SSH reverse tunnel)

Execute exactly as written in `RUNBOOK.md` Step 6.7. Port 6890 on the VPS
is unchanged. Local port should be **8090** instead of 8080.

```bash
grep -A 80 "^## Step 6.7" /Users/augstar/macprovider-poc/RUNBOOK.md | head -90
```

Constraints from original (still apply):
- Use VPS port 6890 — NOT 6882.
- SSH session: probe + tunnel + curl + GatewayPorts inspect, then close.
- Do not modify any file on VPS.
- Do not touch antseed services.

If SSH key auth fails non-interactively, mark
`state/ssh-status.txt=skipped` and continue — this is informational about
the user's auth setup, not a stop condition.

## Step D — Run Step 7.5 (six stress scenarios)

Execute Test 7.5.1 through 7.5.6 as specified in `RUNBOOK.md` Step 7.5.
Substitute port 8090 for 8080 throughout. Results go to
`results/stress/7.5.N-*.txt` as specified.

Test order matters — do them sequentially:

1. **7.5.1 Concurrent** (3 parallel requests)
2. **7.5.2 Cold start** (kill MLX, restart, measure first request)
3. **7.5.3 Long context** (8K + 16K token prompts)
4. **7.5.4 Sustained load** (5 minutes of continuous inference)
5. **7.5.5 Memory pressure** (~2GB allocated, run request)
6. **7.5.6 Multi-model** (switch to Phi-3.5-mini, test, restore Llama)

After 7.5.6, the runbook instructs restoring the Llama model. Do this.

**Token-budget caution:** The previous run used 212K tokens for Steps 0–11.
Step 7.5 has six sub-tests with substantial output. Be efficient — keep
captured logs concise, summarize only when stating verdicts, and avoid
re-reading large files you've already inspected. If you start approaching
a token budget limit, prioritize completing **7.5.1 (concurrent)**,
**7.5.4 (sustained load)**, and **7.5.6 (multi-model)** — those answer the
most architecturally consequential questions.

## Step E — Cleanup

Same cleanup as `RUNBOOK.md` Step 10. Stop all PoC processes including:
- cloudflared (PID in `state/tunnel.pid`)
- localtunnel (PID in `state/lt.pid` if started)
- ssh tunnel (PID in `state/ssh-tunnel.pid` if started)
- mlx_lm.server (PID in `state/mlx-server.pid`)
- memory_pressure helper (if running)

Verify no listeners on 8090 and no orphan processes.

## Step F — Append to REPORT.md

Do NOT overwrite the existing `results/REPORT.md`. Append a new section.

Read the existing report first to understand its structure, then append a
clearly-delimited continuation section with this format:

```markdown


---
---

# Phase 1 Continuation Report

**Date:** <UTC timestamp>
**Continuation of:** Phase 1 Report from 2026-05-26T00:55:48Z
**Tests added:** Step 6.5 (localtunnel), Step 6.7 (SSH reverse), Step 7.5 (six stress scenarios)

## Headline (continuation)

[Updated verdict given the additional evidence. Possible values:
"FULL PASS — original PARTIAL upgrades to PASS based on new evidence" |
"STILL PARTIAL — new caveats added, listed below" |
"DEGRADED — new evidence reveals issues that lower the original verdict"]

## Additional evidence

### Alternative tunnel sanity check (Step 6.5)
- localtunnel attempted: [YES/SKIPPED/FAILED]
- Same SSE contract observed: [YES/NO/N-A]
- Conclusion: [tunnel-agnostic / cloudflare-specific quirks / inconclusive]

### SSH reverse tunnel to VPS (Step 6.7)
- SSH probe to root@165.22.182.207: [PASS/FAIL/SKIPPED]
- Reverse tunnel established (port 6890): [YES/NO]
- Loopback curl from VPS through tunnel: [PASS/FAIL/SKIPPED]
- VPS sshd GatewayPorts setting: [actual value as observed]
- Production-architecture viability: [validated / blocked by auth /
  blocked by GatewayPorts / needs investigation]
- Latency observation through SSH tunnel: [Xs or N-A]

### Inference stress (Step 7.5)
- **7.5.1 Concurrent (3 parallel):** wall-time = [Xs] vs single = [Ys] →
  parallelism factor = [computed]. Verdict: [PARALLEL / PARTIAL / SERIAL].
  Any failures: [yes/no — details].
- **7.5.2 Cold start:** cold TTFR = [Xs], warm TTFR = [Ys]. Acceptable
  for product? [yes/no/marginal].
- **7.5.3 Long context:** 8K total = [Xs], 16K total = [Ys]. Verdict on
  agentic workload viability: [viable / borderline / not viable].
- **7.5.4 Sustained load (5 min):** [N] requests, [T] total tokens,
  throughput = [tok/s] sustained. Latency drift first vs last minute:
  [stable / degrading / oscillating]. Thermal observations: [notes].
- **7.5.5 Memory pressure:** latency under ~2GB pressure = [Xs] vs
  baseline = [Ys]. Inference outcome: [success / slow / failed / OOM].
- **7.5.6 Multi-model (Phi-3.5-mini):** non-stream = [PASS/FAIL],
  stream = [PASS/FAIL], same SSE shape as Llama: [YES/NO].
  Verdict on cross-architecture path: [generalizes / Phi-specific issues].

## Updated recommendation

[Should the user spend 4–6 weeks on Phase 3 given the *combined* evidence
from Phase 1 + this continuation? Yes/No/conditional. State conditions
explicitly.]

## Updated open questions for Phase 1B (paid live test)

[List anything that still requires actual antseed seller registration with
USDC reserve to resolve. Specifically: does the seller plugin handle the
SSE quirks documented in original report (`<|eot_id|>` leakage, keepalive
comments)? Is concurrent serving cap a hard ceiling? Does sustained-load
thermal behavior degrade buyer UX?]

## Architecture implications for Phase 3 / Phase 4

[Specifically: based on Step 6.7's SSH reverse tunnel evidence, is the
"VPS as relay" pattern (used in Phase 4 of the roadmap) viable as-is,
needs sshd_config changes, needs a different relay design, or is
blocked? This is the most important architectural takeaway from this
continuation.]
```

## Done condition

You are done when:
1. Steps B (6.5), C (6.7), D (7.5 all six) executed — or explicitly
   marked SKIPPED in the appended report with reasoning.
2. Cleanup complete; no PoC processes remain.
3. `results/REPORT.md` has the new continuation section appended.
4. No production antseed system was modified.

Hand the path back to the user. Be specific about which tests skipped
and why, if any.
