# Phase 1 Runbook — Mac Provider PoC

You are a Codex agent executing Phase 1 of the Mac Provider project. You have
no context from prior conversations. This runbook is self-contained. Execute
sequentially. Stop and report on first FAIL.

## Mission

Validate one specific question:

> **Does a local Mac running MLX inference, exposed via a public tunnel,
> behave correctly as an OpenAI-compatible backend?**

If yes, the user can confidently spend 4–6 weeks building a proper Swift CLI
to replace the tunnel hack. If no, the architecture needs rethinking before
any heavy investment.

This is a *falsifiability test*, not a feature build. Your job is to gather
evidence and report it honestly. Do not paper over failures.

---

## HARD RULES — silo constraints

This PoC must not touch any production system. Specifically:

| Path / system | Rule |
|---|---|
| `/Users/augstar/.antseed/` | READ-ONLY. Do not modify any file under this path. |
| `/Users/augstar/.antseed-buyer/` | READ-ONLY. Do not modify. |
| `/Users/augstar/antseed-seller/` | READ-ONLY. Do not modify. |
| `/Users/augstar/antseed-*/` repos | READ-ONLY. Do not modify. |
| VPS at `165.22.182.207` | RESTRICTED. SSH connection ALLOWED for Step 6.7 only, with constraints below. Otherwise no contact. |
| Any `systemctl` / `launchctl` commands targeting antseed services | FORBIDDEN. |
| VPS port `6882` (antseed seller public port) | DO NOT BIND TO. Use a non-conflicting port for tests. |
| Any antseed config files on the VPS | READ-ONLY. Do not modify. |
| `/Users/augstar/.darkbloom/` | READ-ONLY. Do not modify. |
| `/usr/local/bin/darkbloom` | DO NOT INVOKE. Reference only. |

Your working directory is **only** `/Users/augstar/macprovider-poc/`. All
files, configs, processes, and logs live here.

If at any point you observe unexpected behavior in production (e.g. existing
antseed seller crashes, a port conflict with running services), STOP
immediately and write `results/HALT.md` with what you observed.

---

## Hardware context

Target hardware: Apple M1 MacBook Air, 8GB unified memory, 7 GPU cores,
68 GB/s bandwidth. macOS available memory: ~4GB at idle.

Model choice for this PoC: `mlx-community/Llama-3.2-3B-Instruct-4bit`
(~2GB on disk, fits in available memory with headroom).

---

## Step 0 — Pre-flight checks

Capture environment state. Write all output to `logs/00-preflight.txt`.

```bash
mkdir -p /Users/augstar/macprovider-poc/logs
cd /Users/augstar/macprovider-poc

{
  echo "=== Date ==="
  date -u
  echo
  echo "=== Hardware ==="
  sysctl -n machdep.cpu.brand_string
  sysctl -n hw.memsize | awk '{print $1/1024/1024/1024 " GB total"}'
  vm_stat | head -5
  echo
  echo "=== Python ==="
  which python3 && python3 --version
  echo
  echo "=== Existing port 8080 listener (if any) ==="
  lsof -nP -iTCP:8080 -sTCP:LISTEN 2>/dev/null || echo "8080 free"
  echo
  echo "=== Existing port 8443 listener (if any) ==="
  lsof -nP -iTCP:8443 -sTCP:LISTEN 2>/dev/null || echo "8443 free"
  echo
  echo "=== Homebrew ==="
  which brew && brew --version | head -1
  echo
  echo "=== cloudflared ==="
  which cloudflared && cloudflared --version 2>/dev/null || echo "cloudflared NOT installed"
} > logs/00-preflight.txt 2>&1

cat logs/00-preflight.txt
```

**Decision point:**
- If port 8080 is in use → switch to 8090 throughout this runbook.
- If port 8443 is in use → switch to 8444 throughout this runbook.
- If Python 3 missing → write `results/HALT.md`, stop.
- If Homebrew missing → install via `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`, then re-check.

---

## Step 1 — Install `mlx-lm` in an isolated venv

Do NOT install into system Python or user site-packages. Use a venv inside
the PoC directory only.

```bash
cd /Users/augstar/macprovider-poc
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install "mlx-lm>=0.20"
pip show mlx-lm | tee logs/01-mlx-install.txt
```

**PASS:** `pip show` reports an installed version.
**FAIL:** any pip error. Write to `results/HALT.md`, stop.

---

## Step 2 — Download the model

The model will cache to `~/.cache/huggingface/`. This is OK — it's not a
production path and the agent should not delete it on cleanup (user may
want to reuse the weights).

```bash
cd /Users/augstar/macprovider-poc
source .venv/bin/activate

# Trigger model download by loading once
python3 -c "
from mlx_lm import load
print('Downloading mlx-community/Llama-3.2-3B-Instruct-4bit...')
model, tokenizer = load('mlx-community/Llama-3.2-3B-Instruct-4bit')
print('Model loaded successfully.')
print(f'Tokenizer vocab size: {tokenizer.vocab_size if hasattr(tokenizer, \"vocab_size\") else \"unknown\"}')
" 2>&1 | tee logs/02-model-download.txt
```

**PASS:** "Model loaded successfully" appears.
**FAIL:** any exception. Write to `results/HALT.md`, stop.

Approximate download time on a fast connection: 1–3 minutes for ~2GB.

---

## Step 3 — Start the MLX inference server

Background process. Log to file.

```bash
cd /Users/augstar/macprovider-poc
source .venv/bin/activate

nohup python3 -m mlx_lm.server \
  --model mlx-community/Llama-3.2-3B-Instruct-4bit \
  --port 8080 \
  --host 127.0.0.1 \
  > logs/03-mlx-server.log 2>&1 &

echo $! > state/mlx-server.pid
sleep 8

# Verify it's listening
if lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "PASS: mlx_lm.server listening on 127.0.0.1:8080 (PID $(cat state/mlx-server.pid))"
else
  echo "FAIL: mlx_lm.server not listening"
  tail -20 logs/03-mlx-server.log
fi
```

**PASS:** server listening on 8080.
**FAIL:** not listening after 8s. Check log tail, write to `results/HALT.md`, stop.

---

## Step 4 — Local smoke test (no tunnel yet)

Before exposing publicly, verify the local endpoint speaks OpenAI-compatible
HTTP correctly.

```bash
cd /Users/augstar/macprovider-poc

# 4a — non-streaming request
curl -s -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mlx-community/Llama-3.2-3B-Instruct-4bit",
    "messages": [{"role": "user", "content": "Say only the word: ready"}],
    "max_tokens": 10,
    "stream": false
  }' | tee results/04a-local-nonstream.json

echo

# 4b — streaming request
curl -s -N -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mlx-community/Llama-3.2-3B-Instruct-4bit",
    "messages": [{"role": "user", "content": "Count from 1 to 5"}],
    "max_tokens": 30,
    "stream": true
  }' | tee results/04b-local-stream.txt
```

**PASS criteria:**
- 4a response is valid JSON, contains `choices[0].message.content` with a string.
- 4b response is a sequence of `data: {...}` SSE chunks ending with `data: [DONE]`.
- Each streamed chunk contains `choices[0].delta.content` field.

**FAIL:** missing fields, malformed JSON, or HTTP error. Write to
`results/HALT.md`, stop.

Note: mlx_lm.server's exact SSE format may differ slightly from OpenAI's spec
(e.g. missing some optional fields). Record what it actually emits — the
report at the end will note any deviations.

---

## Step 5 — Install `cloudflared`

```bash
if ! command -v cloudflared >/dev/null 2>&1; then
  brew install cloudflared 2>&1 | tee logs/05-cloudflared-install.txt
fi
cloudflared --version | tee -a logs/05-cloudflared-install.txt
```

**PASS:** `cloudflared --version` reports a version.

---

## Step 6 — Start the tunnel

Use the quick-tunnel mode (no Cloudflare account needed). The tunnel URL is
randomly assigned per session.

```bash
cd /Users/augstar/macprovider-poc

nohup cloudflared tunnel --url http://127.0.0.1:8080 \
  > logs/06-tunnel.log 2>&1 &
echo $! > state/tunnel.pid

# cloudflared takes 5-15s to register and emit the tunnel URL
echo "Waiting for tunnel URL..."
for i in $(seq 1 30); do
  TUNNEL_URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' logs/06-tunnel.log | head -1)
  if [ -n "$TUNNEL_URL" ]; then
    echo "Tunnel URL: $TUNNEL_URL"
    echo "$TUNNEL_URL" > state/tunnel-url.txt
    break
  fi
  sleep 1
done

if [ -z "$TUNNEL_URL" ]; then
  echo "FAIL: no tunnel URL after 30s"
  tail -30 logs/06-tunnel.log
fi
```

**PASS:** tunnel URL written to `state/tunnel-url.txt`.
**FAIL:** no URL after 30s. Write to `results/HALT.md`, stop.

---

## Step 6.5 — Alternative tunnel sanity check (localtunnel)

**Goal:** Confirm the OpenAI-compatibility contract isn't tunnel-specific.
If the same MLX server works through a different tunnel implementation, we
know the local endpoint is genuinely standards-compliant rather than just
"works with Cloudflare's edge."

We use `localtunnel` (loca.lt) because it requires no account and runs via
`npx`. This is a parallel test — cloudflared keeps running.

```bash
cd /Users/augstar/macprovider-poc

# Check Node.js availability
if ! command -v npx >/dev/null 2>&1; then
  echo "SKIP: npx not available. localtunnel test skipped." | tee logs/06.5-localtunnel.log
  echo "skipped" > state/lt-status.txt
else
  # Start localtunnel on a different port to avoid conflict (port 8081 inbound)
  # We need an inbound listener to expose, so use mlx server's same port 8080.
  # localtunnel will create its own public hostname.
  nohup npx --yes localtunnel --port 8080 \
    > logs/06.5-localtunnel.log 2>&1 &
  echo $! > state/lt.pid

  echo "Waiting for localtunnel URL..."
  for i in $(seq 1 30); do
    LT_URL=$(grep -oE 'https://[a-z0-9-]+\.loca\.lt' logs/06.5-localtunnel.log | head -1)
    if [ -n "$LT_URL" ]; then
      echo "Localtunnel URL: $LT_URL"
      echo "$LT_URL" > state/lt-url.txt
      echo "ok" > state/lt-status.txt
      break
    fi
    sleep 1
  done

  if [ -z "$LT_URL" ]; then
    echo "FAIL: no localtunnel URL after 30s — skipping this step, not stopping run"
    tail -30 logs/06.5-localtunnel.log
    echo "failed" > state/lt-status.txt
  fi
fi
```

**Test through localtunnel** (only if status is `ok`):

```bash
if [ "$(cat state/lt-status.txt 2>/dev/null)" = "ok" ]; then
  LT_URL=$(cat state/lt-url.txt)
  echo "Testing through localtunnel: $LT_URL"

  # Note: localtunnel may show a browser interstitial for first request.
  # bypass-tunnel-reminder header skips it.
  curl -s -X POST "$LT_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "bypass-tunnel-reminder: true" \
    -d '{
      "model": "mlx-community/Llama-3.2-3B-Instruct-4bit",
      "messages": [{"role": "user", "content": "Reply with one word: yes"}],
      "max_tokens": 5,
      "stream": false
    }' | tee results/06.5-localtunnel-test.json
fi
```

**PASS:** response JSON has same shape as cloudflared test (Step 4a).
**SOFT FAIL:** localtunnel returns error or interstitial — note as quirk
in report but do not halt run. The cloudflared path is the authoritative one.

This step is informational. It is OK to skip entirely if npx isn't available
or localtunnel is flaky — record the outcome and continue.

---

## Step 6.7 — SSH reverse tunnel to the user's VPS

**Why this test matters:** Cloudflare and localtunnel are throwaway PoC tools.
The actual production architecture has contributor Macs connecting to a
relay on a VPS the user controls. An SSH reverse tunnel to the user's
existing VPS (165.22.182.207) tests *that* deployment pattern — same
infrastructure, no third-party dependency, lower latency.

**Constraints (read carefully):**
- Use port **6890** on the VPS (NOT 6882 — that's the antseed seller's
  public port and is in production use).
- Do NOT modify any file on the VPS.
- Do NOT touch any antseed service.
- Do NOT run any command that writes to `/root/.antseed/`, `/root/antfeed-*/`,
  or any antseed-related path.
- The only allowed VPS operations are: open an SSH session, run an outbound
  curl against `localhost:6890` to verify the tunnel, then disconnect.

```bash
cd /Users/augstar/macprovider-poc

# Probe whether SSH to the VPS works with default key auth (non-interactive)
ssh -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=accept-new \
    root@165.22.182.207 'echo ssh_ok' \
    > logs/06.7-ssh-probe.log 2>&1

if [ $? -ne 0 ]; then
  echo "SKIP: SSH to root@165.22.182.207 failed (auth or network). Output:"
  cat logs/06.7-ssh-probe.log
  echo "skipped" > state/ssh-status.txt
else
  echo "SSH probe ok."

  # Establish reverse tunnel in background.
  # -R 6890:127.0.0.1:8080 → on VPS, anything hitting 127.0.0.1:6890 reaches
  # this Mac's 127.0.0.1:8080.
  # -N → no remote command. -f → background. -o ExitOnForward... → die fast
  # if the forward fails.
  ssh -N -f \
      -o ExitOnForwardFailure=yes \
      -o ServerAliveInterval=30 \
      -R 6890:127.0.0.1:8080 \
      root@165.22.182.207 \
      > logs/06.7-ssh-tunnel.log 2>&1

  # Capture the ssh PID (best effort — -f forks)
  sleep 2
  SSH_PID=$(pgrep -f "ssh.*-R 6890:127.0.0.1:8080" | head -1)
  if [ -n "$SSH_PID" ]; then
    echo "$SSH_PID" > state/ssh-tunnel.pid
    echo "ssh tunnel pid: $SSH_PID"
  fi

  # Verify the tunnel works by running curl FROM the VPS against its own
  # localhost:6890, which should reach this Mac's mlx server.
  echo "--- Curl from VPS through reverse tunnel ---"
  ssh -o BatchMode=yes -o ConnectTimeout=5 \
      root@165.22.182.207 \
      "curl -s -m 30 -X POST http://127.0.0.1:6890/v1/chat/completions \
        -H 'Content-Type: application/json' \
        -d '{\"model\":\"mlx-community/Llama-3.2-3B-Instruct-4bit\",\"messages\":[{\"role\":\"user\",\"content\":\"Say only: tunneled\"}],\"max_tokens\":5,\"stream\":false}'" \
      | tee results/06.7-ssh-loopback.json

  echo

  # Optional: detect whether GatewayPorts is enabled on the VPS, which would
  # let us bind 0.0.0.0:6890 and reach the Mac from any external client.
  # We do NOT change sshd_config — only inspect.
  GW=$(ssh -o BatchMode=yes -o ConnectTimeout=5 root@165.22.182.207 \
       "grep -i '^GatewayPorts' /etc/ssh/sshd_config 2>/dev/null || echo 'GatewayPorts no (default)'")
  echo "VPS sshd GatewayPorts: $GW" | tee -a results/06.7-ssh-loopback.json
  echo "$GW" > state/ssh-gatewayports.txt

  echo "ok" > state/ssh-status.txt
fi
```

**PASS criteria:**
- SSH probe succeeds (`ssh_ok` echoed).
- Reverse tunnel established (ssh process running).
- Curl from VPS through `127.0.0.1:6890` returns valid OpenAI-shaped JSON
  with non-empty `choices[0].message.content`.

**SOFT FAIL:** SSH auth fails (no key configured for non-interactive SSH).
This is a real-world signal: the agent records it as `state/ssh-status.txt=skipped`
and continues. The user may need to set up SSH key auth before Phase 3
deployment work.

**HARD FAIL:** SSH connects but tunnel curl returns error. Document precisely
— this is more informative than success because it reveals where the
production pattern would break.

**What this test deliberately does NOT do:**
- Does not flip `GatewayPorts` to `yes` (would modify sshd_config — silo violation).
- Does not bind to `0.0.0.0:6890` on VPS (only `127.0.0.1:6890` — loopback only).
- Does not test external client → VPS public IP → Mac (that requires
  GatewayPorts + firewall change, both production-touching).
- Does not register anything with antseed.

The test answers one question: *does the SSH-reverse pattern work as a
relay mechanism between this Mac and the existing VPS?* That's enough
to validate the architecture for Phase 4 (where you'd build a proper
coordinator on the same VPS instead of antseed-style port forwarding).

---

## Step 7 — End-to-end test through tunnel

This is the actual PoC. Validate that the public tunnel URL serves
OpenAI-compatible inference correctly.

```bash
cd /Users/augstar/macprovider-poc
TUNNEL_URL=$(cat state/tunnel-url.txt)
echo "Testing through: $TUNNEL_URL"

# 7a — non-streaming through tunnel
echo "--- 7a: non-streaming ---"
time curl -s -X POST "$TUNNEL_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mlx-community/Llama-3.2-3B-Instruct-4bit",
    "messages": [{"role": "user", "content": "What is 2+2? Answer in one word."}],
    "max_tokens": 10,
    "stream": false
  }' | tee results/07a-tunnel-nonstream.json

echo
echo "--- 7b: streaming ---"
time curl -s -N -X POST "$TUNNEL_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mlx-community/Llama-3.2-3B-Instruct-4bit",
    "messages": [{"role": "user", "content": "Tell me a 3-sentence story about an ant."}],
    "max_tokens": 100,
    "stream": true
  }' | tee results/07b-tunnel-stream.txt

echo
echo "--- 7c: latency measurement (5 requests) ---"
for i in 1 2 3 4 5; do
  START=$(python3 -c "import time; print(time.time())")
  curl -s -X POST "$TUNNEL_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "mlx-community/Llama-3.2-3B-Instruct-4bit",
      "messages": [{"role": "user", "content": "Hello"}],
      "max_tokens": 5,
      "stream": false
    }' > /dev/null
  END=$(python3 -c "import time; print(time.time())")
  echo "Request $i: $(python3 -c "print(f'{$END - $START:.2f}s')")"
done | tee results/07c-latency.txt
```

**PASS criteria:**
- 7a returns valid JSON with non-empty content.
- 7b returns SSE stream with multiple chunks ending in `[DONE]`.
- 7c: median latency for 5-token request < 5s (M1 baseline; first request may be slower due to warm-up).

**FAIL:** errors, timeouts, malformed responses. Capture and continue to
Step 8 (we still want diagnostic data).

---

## Step 7.5 — Inference stress scenarios

**Goal:** Validate that an M1 Mac behaves like a sane inference backend
under realistic conditions, not just the happy path. Each test answers a
specific question that would otherwise become an unknown in Phase 3.

All tests run through the cloudflared tunnel URL (`state/tunnel-url.txt`)
to keep parity with the rest of the runbook.

### Test 7.5.1 — Concurrent requests

**Question:** Does `mlx_lm.server` handle 3 parallel buyers, or does it
queue/crash? Critical because Antseed will route multiple buyers
simultaneously.

```bash
cd /Users/augstar/macprovider-poc
TUNNEL_URL=$(cat state/tunnel-url.txt)

mkdir -p results/stress

# Fire 3 simultaneous requests, capture per-request timing
{
  echo "=== Concurrent (3 parallel) ==="
  for i in 1 2 3; do
    (
      START=$(python3 -c "import time; print(time.time())")
      RESPONSE=$(curl -s -X POST "$TUNNEL_URL/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{
          \"model\": \"mlx-community/Llama-3.2-3B-Instruct-4bit\",
          \"messages\": [{\"role\": \"user\", \"content\": \"Reply with the number $i\"}],
          \"max_tokens\": 5,
          \"stream\": false
        }")
      END=$(python3 -c "import time; print(time.time())")
      echo "Req $i: $(python3 -c "print(f'{$END - $START:.2f}s')") | $(echo "$RESPONSE" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('choices',[{}])[0].get('message',{}).get('content','ERR'))" 2>/dev/null)"
    ) &
  done
  wait
  echo "=== All 3 completed ==="
} 2>&1 | tee results/stress/7.5.1-concurrent.txt
```

**PASS criteria:**
- All 3 requests return valid responses (no 5xx, no truncation).
- Total wall-clock time for all 3 < 3× the single-request time
  (i.e. server is doing *some* parallelism, not strict serial queueing).

**SOFT FAIL:** Requests serialize completely (total time = 3× single).
Record as known limitation — Phase 3 binary may need its own batch scheduler.

**HARD FAIL:** Any request returns 5xx, crash, or empty body. Document and
continue — we want all stress data, not early exit.

### Test 7.5.2 — Cold start latency

**Question:** What does the first request after a cold MLX server look like?
Real contributors won't keep model loaded 24/7; first-impression latency is
load-bearing for retention.

```bash
cd /Users/augstar/macprovider-poc
TUNNEL_URL=$(cat state/tunnel-url.txt)

{
  echo "=== Cold start ==="
  # Kill current MLX server
  if [ -f state/mlx-server.pid ]; then
    kill $(cat state/mlx-server.pid) 2>/dev/null
    rm state/mlx-server.pid
  fi
  pkill -f "mlx_lm.server" 2>/dev/null
  sleep 3

  # Restart it
  source .venv/bin/activate
  nohup python3 -m mlx_lm.server \
    --model mlx-community/Llama-3.2-3B-Instruct-4bit \
    --port 8080 \
    --host 127.0.0.1 \
    >> logs/03-mlx-server.log 2>&1 &
  echo $! > state/mlx-server.pid

  # Wait for listener
  for i in $(seq 1 30); do
    if lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1; then
      echo "Server up after ${i}s"
      break
    fi
    sleep 1
  done

  # First request after cold start (model still loading on first inference call)
  echo "--- First request (cold) ---"
  START=$(python3 -c "import time; print(time.time())")
  curl -s -X POST "$TUNNEL_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "mlx-community/Llama-3.2-3B-Instruct-4bit",
      "messages": [{"role": "user", "content": "Hello"}],
      "max_tokens": 5,
      "stream": false
    }' > /tmp/cold-response.json
  END=$(python3 -c "import time; print(time.time())")
  echo "Cold TTFR: $(python3 -c "print(f'{$END - $START:.2f}s')")"
  cat /tmp/cold-response.json | head -c 200; echo

  # Second request (warm)
  echo "--- Second request (warm) ---"
  START=$(python3 -c "import time; print(time.time())")
  curl -s -X POST "$TUNNEL_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "mlx-community/Llama-3.2-3B-Instruct-4bit",
      "messages": [{"role": "user", "content": "Hello"}],
      "max_tokens": 5,
      "stream": false
    }' > /tmp/warm-response.json
  END=$(python3 -c "import time; print(time.time())")
  echo "Warm TTFR: $(python3 -c "print(f'{$END - $START:.2f}s')")"
} 2>&1 | tee results/stress/7.5.2-coldstart.txt
```

**Capture:** cold TTFR, warm TTFR, ratio. Note in the report.
**No PASS/FAIL — informational.** A 30s cold start may be acceptable; a 5min
cold start kills the product.

### Test 7.5.3 — Long context

**Question:** Can the M1 handle long prompts (8K, 16K tokens) that agentic
buyers send? Prefill is bandwidth-bound; on 68 GB/s M1 this could be slow.

```bash
cd /Users/augstar/macprovider-poc
TUNNEL_URL=$(cat state/tunnel-url.txt)

# Generate a ~8K token prompt by repeating filler text
python3 -c "
import json
# Approximate token count: ~1.3 chars/token for English, so 8K tokens ≈ 10400 chars
filler = ('The ant colony observes carefully and reports back to the queen. ' * 200).strip()
# Verify approximate token count via word count (rough proxy)
print(f'Filler word count: {len(filler.split())}', file=__import__('sys').stderr)
body = {
    'model': 'mlx-community/Llama-3.2-3B-Instruct-4bit',
    'messages': [
        {'role': 'system', 'content': filler},
        {'role': 'user', 'content': 'In one sentence, summarize what the system message is about.'}
    ],
    'max_tokens': 30,
    'stream': False
}
with open('/tmp/long-context-8k.json', 'w') as f:
    json.dump(body, f)
print('8K prompt body written to /tmp/long-context-8k.json')
"

# Same idea, ~16K
python3 -c "
import json
filler = ('The ant colony observes carefully and reports back to the queen. ' * 400).strip()
print(f'Filler word count: {len(filler.split())}', file=__import__('sys').stderr)
body = {
    'model': 'mlx-community/Llama-3.2-3B-Instruct-4bit',
    'messages': [
        {'role': 'system', 'content': filler},
        {'role': 'user', 'content': 'In one sentence, summarize what the system message is about.'}
    ],
    'max_tokens': 30,
    'stream': False
}
with open('/tmp/long-context-16k.json', 'w') as f:
    json.dump(body, f)
"

{
  echo "=== Long context — ~8K tokens ==="
  START=$(python3 -c "import time; print(time.time())")
  curl -s -X POST "$TUNNEL_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d @/tmp/long-context-8k.json | tee /tmp/8k-out.json
  END=$(python3 -c "import time; print(time.time())")
  echo
  echo "8K total time: $(python3 -c "print(f'{$END - $START:.2f}s')")"
  echo

  echo "=== Long context — ~16K tokens ==="
  START=$(python3 -c "import time; print(time.time())")
  curl -s -X POST "$TUNNEL_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d @/tmp/long-context-16k.json | tee /tmp/16k-out.json
  END=$(python3 -c "import time; print(time.time())")
  echo
  echo "16K total time: $(python3 -c "print(f'{$END - $START:.2f}s')")"
} 2>&1 | tee results/stress/7.5.3-longcontext.txt
```

**Capture:** total time for 8K and 16K. **No PASS/FAIL** — informational.
A 30s 16K prefill is acceptable; a 5min 16K prefill rules out agentic
workloads on M1 8GB.

**HARD FAIL only if:** 16K returns an OOM error or context-too-long error
suggesting the model can't handle it at all. Document and move on.

### Test 7.5.4 — Sustained load

**Question:** Does the M1 thermal-throttle, slow down, or get loud after
5 minutes of continuous inference? Retention killer if yes.

```bash
cd /Users/augstar/macprovider-poc
TUNNEL_URL=$(cat state/tunnel-url.txt)

{
  echo "=== Sustained load — 5 minutes ==="
  START=$(python3 -c "import time; print(time.time())")
  END_TARGET=$(python3 -c "import time; print(time.time() + 300)")
  REQ_COUNT=0
  TOTAL_TOKENS=0

  while [ "$(python3 -c "import time; print(time.time())")" \< "$END_TARGET" ]; do
    REQ_START=$(python3 -c "import time; print(time.time())")
    RESPONSE=$(curl -s -X POST "$TUNNEL_URL/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d '{
        "model": "mlx-community/Llama-3.2-3B-Instruct-4bit",
        "messages": [{"role": "user", "content": "Write one short sentence about ants."}],
        "max_tokens": 30,
        "stream": false
      }')
    REQ_END=$(python3 -c "import time; print(time.time())")
    TOK=$(echo "$RESPONSE" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('usage',{}).get('completion_tokens', 0))" 2>/dev/null || echo 0)
    REQ_COUNT=$((REQ_COUNT + 1))
    TOTAL_TOKENS=$((TOTAL_TOKENS + TOK))
    ELAPSED=$(python3 -c "print(f'{$REQ_END - $START:.0f}')")
    LATENCY=$(python3 -c "print(f'{$REQ_END - $REQ_START:.2f}')")
    echo "t=${ELAPSED}s req=$REQ_COUNT lat=${LATENCY}s tok=$TOK"
  done

  TOTAL_TIME=$(python3 -c "print(f'{$END_TARGET - $START - 300 + 300:.0f}')")
  echo
  echo "=== Summary ==="
  echo "Requests completed: $REQ_COUNT"
  echo "Total output tokens: $TOTAL_TOKENS"
  echo "Throughput: $(python3 -c "print(f'{$TOTAL_TOKENS / 300:.1f}')") tok/s sustained"
} 2>&1 | tee results/stress/7.5.4-sustained.txt

# Capture thermal state at end
echo "=== Thermal/CPU state after sustained load ===" >> results/stress/7.5.4-sustained.txt
pmset -g thermlog 2>/dev/null | tail -5 >> results/stress/7.5.4-sustained.txt
sysctl -a 2>/dev/null | grep -i "thermal\|cpu_freq" | head -20 >> results/stress/7.5.4-sustained.txt
top -l 1 -n 0 -s 0 | head -10 >> results/stress/7.5.4-sustained.txt
```

**Look for:**
- Per-request latency increasing over time (thermal throttling)
- Throughput dropping in later requests vs earlier
- Any errors mid-loop

**Capture in report:** throughput trend (first minute vs last minute),
total requests served, any thermal indicators.

### Test 7.5.5 — Memory pressure

**Question:** Does inference fail gracefully when the system is under
memory pressure (real Macs do other things)? Or does it OOM-kill?

```bash
cd /Users/augstar/macprovider-poc
TUNNEL_URL=$(cat state/tunnel-url.txt)

{
  echo "=== Memory pressure ==="

  # Baseline memory state
  echo "--- Before pressure ---"
  vm_stat | head -8

  # Apply ~2GB memory pressure via macOS memory_pressure utility (if available),
  # else allocate via Python.
  echo "--- Applying ~2GB pressure for 60s ---"
  if command -v memory_pressure >/dev/null 2>&1; then
    nohup memory_pressure -l warn -s 60 > logs/7.5.5-pressure.log 2>&1 &
    PRESSURE_PID=$!
  else
    # Fallback: Python-based memory hog
    nohup python3 -c "
import time, sys
# Allocate ~2GB
big = bytearray(2 * 1024 * 1024 * 1024)
time.sleep(60)
" > logs/7.5.5-pressure.log 2>&1 &
    PRESSURE_PID=$!
  fi

  sleep 2
  echo "--- During pressure ---"
  vm_stat | head -8

  # Run an inference request while under pressure
  echo "--- Inference request during pressure ---"
  START=$(python3 -c "import time; print(time.time())")
  RESPONSE=$(curl -s -X POST "$TUNNEL_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "mlx-community/Llama-3.2-3B-Instruct-4bit",
      "messages": [{"role": "user", "content": "Reply with one short word."}],
      "max_tokens": 10,
      "stream": false
    }')
  END=$(python3 -c "import time; print(time.time())")
  echo "Latency under pressure: $(python3 -c "print(f'{$END - $START:.2f}s')")"
  echo "Response: $RESPONSE"

  # Clean up pressure
  kill $PRESSURE_PID 2>/dev/null
  wait 2>/dev/null

  sleep 2
  echo "--- After pressure released ---"
  vm_stat | head -8
} 2>&1 | tee results/stress/7.5.5-mempressure.txt
```

**PASS:** request completes successfully (even if slower).
**SOFT FAIL:** request is dramatically slower (>3× normal) but still works.
**HARD FAIL:** request errors, server crashes, or OOM kill occurs.

### Test 7.5.6 — Different model architecture

**Question:** Does the path generalize beyond Llama 3B? A second model
with different architecture validates that we're not pattern-matching on
one model's quirks.

We use Phi-3.5-mini-instruct-4bit (~2.5GB): different vendor (Microsoft),
different architecture, different tokenizer, similar size to fit on M1 8GB.

```bash
cd /Users/augstar/macprovider-poc

{
  echo "=== Multi-model — switching to Phi-3.5-mini ==="

  # Stop current MLX server
  if [ -f state/mlx-server.pid ]; then
    kill $(cat state/mlx-server.pid) 2>/dev/null
    rm state/mlx-server.pid
  fi
  pkill -f "mlx_lm.server" 2>/dev/null
  sleep 3

  # Download (if not cached) and start with Phi-3.5
  source .venv/bin/activate
  python3 -c "
from mlx_lm import load
print('Downloading mlx-community/Phi-3.5-mini-instruct-4bit if needed...')
model, tok = load('mlx-community/Phi-3.5-mini-instruct-4bit')
print('Loaded.')
" 2>&1 | tail -3

  nohup python3 -m mlx_lm.server \
    --model mlx-community/Phi-3.5-mini-instruct-4bit \
    --port 8080 \
    --host 127.0.0.1 \
    >> logs/03-mlx-server.log 2>&1 &
  echo $! > state/mlx-server.pid

  # Wait for listener
  for i in $(seq 1 30); do
    if lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1; then
      echo "Phi server up after ${i}s"
      break
    fi
    sleep 1
  done

  TUNNEL_URL=$(cat state/tunnel-url.txt)

  echo "--- Phi-3.5-mini through tunnel ---"
  START=$(python3 -c "import time; print(time.time())")
  curl -s -X POST "$TUNNEL_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "mlx-community/Phi-3.5-mini-instruct-4bit",
      "messages": [{"role": "user", "content": "Reply with one short sentence about the color blue."}],
      "max_tokens": 30,
      "stream": false
    }' | tee results/stress/7.5.6-phi-nonstream.json
  END=$(python3 -c "import time; print(time.time())")
  echo
  echo "Phi non-stream latency: $(python3 -c "print(f'{$END - $START:.2f}s')")"

  echo
  echo "--- Phi-3.5-mini streaming ---"
  curl -s -N -X POST "$TUNNEL_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "mlx-community/Phi-3.5-mini-instruct-4bit",
      "messages": [{"role": "user", "content": "Count to 3."}],
      "max_tokens": 20,
      "stream": true
    }' | head -20 | tee results/stress/7.5.6-phi-stream.txt
} 2>&1 | tee -a results/stress/7.5.6-multimodel.txt
```

**PASS:** Phi responds correctly through tunnel with same SSE format as
Llama did.
**FAIL:** Phi-specific errors (tokenizer issues, model loading failure).
Document — informs whether Phase 3 needs per-model handling.

### Step 7.5 summary

After all six stress tests, the agent should know:

| Question | Answered by |
|---|---|
| Can M1 serve concurrent buyers? | 7.5.1 |
| What's cold-start latency? | 7.5.2 |
| Can M1 handle agentic long-context? | 7.5.3 |
| Does M1 thermal-throttle under sustained load? | 7.5.4 |
| Does inference survive memory pressure? | 7.5.5 |
| Does the path generalize across models? | 7.5.6 |

Before Step 8, restart the MLX server with the original Llama model
(Phi was a probe — Llama is the primary target):

```bash
cd /Users/augstar/macprovider-poc
if [ -f state/mlx-server.pid ]; then
  kill $(cat state/mlx-server.pid) 2>/dev/null
  rm state/mlx-server.pid
fi
pkill -f "mlx_lm.server" 2>/dev/null
sleep 3

source .venv/bin/activate
nohup python3 -m mlx_lm.server \
  --model mlx-community/Llama-3.2-3B-Instruct-4bit \
  --port 8080 \
  --host 127.0.0.1 \
  >> logs/03-mlx-server.log 2>&1 &
echo $! > state/mlx-server.pid
sleep 8
```

---

## Step 8 — Cancellation behavior

Critical for the smart-router design. Verify that closing the client mid-stream
stops generation on the server (i.e. server doesn't keep generating after
disconnect).

```bash
cd /Users/augstar/macprovider-poc
TUNNEL_URL=$(cat state/tunnel-url.txt)

# Start a long generation, kill after 2s, observe server behavior
{
  timeout 2 curl -s -N -X POST "$TUNNEL_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "mlx-community/Llama-3.2-3B-Instruct-4bit",
      "messages": [{"role": "user", "content": "Write a long detailed essay about ants, at least 500 words."}],
      "max_tokens": 1000,
      "stream": true
    }' 2>&1
  echo "--- client killed at 2s ---"
} | tee results/08-cancellation-client.txt

# Wait, then check whether server is still generating (look at log activity)
sleep 5
echo "--- server log tail (5s after kill) ---" >> results/08-cancellation-client.txt
tail -10 logs/03-mlx-server.log >> results/08-cancellation-client.txt
```

**PASS:** server log stops producing generation activity within ~3s of
client disconnect.
**SOFT FAIL:** server keeps generating to completion. Record this — it's a
real limitation but doesn't block Phase 1.

---

## Step 9 — Streaming chunk format inspection

Capture exactly what the SSE stream looks like, so we know whether it's
strictly OpenAI-compatible or has quirks the Antseed plugin would need to
handle.

```bash
cd /Users/augstar/macprovider-poc
TUNNEL_URL=$(cat state/tunnel-url.txt)

curl -s -N -X POST "$TUNNEL_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mlx-community/Llama-3.2-3B-Instruct-4bit",
    "messages": [{"role": "user", "content": "Reply with one word."}],
    "max_tokens": 5,
    "stream": true
  }' | head -20 | tee results/09-sse-format.txt
```

In the report, note:
- Does each chunk start with `data: ` prefix? (Required for OpenAI compat)
- Does the stream end with `data: [DONE]`? (Required)
- Does `choices[0].delta.role` appear in the first chunk? (Expected)
- Does `choices[0].finish_reason` appear in the final chunk? (Expected)
- Are there extra fields (`logprobs`, `system_fingerprint`, etc.) or missing fields?

---

## Step 10 — Cleanup (run after verifying all results)

Leave the workspace in a known clean state. Do NOT delete:
- Captured logs (`logs/`)
- Results (`results/`)
- The HuggingFace model cache (user may want to reuse)

```bash
cd /Users/augstar/macprovider-poc

# Stop cloudflared tunnel
if [ -f state/tunnel.pid ]; then
  kill $(cat state/tunnel.pid) 2>/dev/null
  rm state/tunnel.pid
fi

# Stop localtunnel if it was running
if [ -f state/lt.pid ]; then
  kill $(cat state/lt.pid) 2>/dev/null
  rm state/lt.pid
fi
pkill -f "localtunnel" 2>/dev/null

# Stop SSH reverse tunnel if it was running
if [ -f state/ssh-tunnel.pid ]; then
  kill $(cat state/ssh-tunnel.pid) 2>/dev/null
  rm state/ssh-tunnel.pid
fi
pkill -f "ssh.*-R 6890:127.0.0.1:8080" 2>/dev/null

# Stop mlx server
if [ -f state/mlx-server.pid ]; then
  kill $(cat state/mlx-server.pid) 2>/dev/null
  rm state/mlx-server.pid
fi
pkill -f "mlx_lm.server" 2>/dev/null

# Stop any lingering memory pressure helper
pkill -f "memory_pressure" 2>/dev/null

# Final state check
echo "=== Final state ==="
echo "Cloudflared processes: $(pgrep -f cloudflared | wc -l | tr -d ' ')"
echo "Localtunnel processes: $(pgrep -f localtunnel | wc -l | tr -d ' ')"
echo "MLX processes: $(pgrep -f mlx_lm.server | wc -l | tr -d ' ')"
echo "Port 8080: $(lsof -nP -iTCP:8080 -sTCP:LISTEN 2>/dev/null | wc -l | tr -d ' ') listeners"
```

---

## Step 11 — Write the report

Write `results/REPORT.md` with the following structure. Be honest. Include
failures and quirks.

```markdown
# Phase 1 Report — Mac Provider PoC

**Date:** <UTC timestamp>
**Hardware:** Apple M1, 8GB
**Model:** mlx-community/Llama-3.2-3B-Instruct-4bit

## Headline result

[ONE OF: "PASS — proceed to Phase 3", "PARTIAL — proceed with caveats",
"FAIL — architecture needs rethinking"]

## Evidence

### Local endpoint (Step 4)
- Non-streaming: [PASS/FAIL] — [details]
- Streaming: [PASS/FAIL] — [details]

### Tunnel end-to-end (Step 7)
- Non-streaming: [PASS/FAIL] — [details]
- Streaming: [PASS/FAIL] — [details]
- Latency (5-request median): [Xs]
- TTFT (time to first token) for streaming: [Xs]

### Alternative tunnel sanity check (Step 6.5)
- localtunnel attempted: [YES/SKIPPED/FAILED]
- Same SSE contract observed: [YES/NO/N-A]
- Conclusion: [tunnel-agnostic / cloudflare-specific quirks / inconclusive]

### SSH reverse tunnel to VPS (Step 6.7)
- SSH probe to root@165.22.182.207: [PASS/FAIL/SKIPPED]
- Reverse tunnel established (port 6890): [YES/NO]
- Loopback curl from VPS through tunnel: [PASS/FAIL]
- VPS sshd GatewayPorts setting: [value as found]
- Production-architecture viability: [validated / blocked by auth /
  blocked by GatewayPorts / needs investigation]
- Latency through SSH tunnel vs cloudflared: [comparison if both
  successful, else N-A]

### Inference stress (Step 7.5)
- **7.5.1 Concurrent (3 parallel):** wall-time = [Xs] vs single = [Ys] →
  parallelism factor = [X / 3Y]. Verdict: [PARALLEL / PARTIAL / SERIAL].
  Any failures: [yes/no].
- **7.5.2 Cold start:** cold TTFR = [Xs], warm TTFR = [Ys]. Acceptable
  for product? [yes/no/marginal].
- **7.5.3 Long context:** 8K total = [Xs], 16K total = [Ys]. Verdict on
  agentic workload viability: [viable / borderline / not viable].
- **7.5.4 Sustained load (5 min):** [N] requests, [T] total tokens,
  throughput = [tok/s] sustained. Latency drift across the window:
  [stable / degrading / oscillating]. Thermal observations: [notes].
- **7.5.5 Memory pressure:** latency under ~2GB pressure = [Xs] vs
  baseline = [Ys]. Inference outcome: [success / slow / failed / OOM].
- **7.5.6 Multi-model (Phi-3.5-mini):** non-stream = [PASS/FAIL],
  stream = [PASS/FAIL], same SSE shape as Llama: [YES/NO].
  Verdict on cross-architecture path: [generalizes / Phi-specific issues].

### Cancellation behavior (Step 8)
- Server stops on client disconnect: [YES/NO/UNCLEAR]
- Implications for smart router: [note]

### SSE format conformance (Step 9)
- OpenAI-strict: [YES/NO]
- Deviations observed: [list]
- Impact on Antseed seller plugin compatibility: [assessment]

## Quirks / surprises

[Anything that didn't go as expected. Be specific.]

## Confidence assessment

[Author's confidence that the Antseed seller plugin (which proxies OpenAI-
compatible backends to OpenRouter today) would work transparently with this
endpoint. Rate 1–5, justify.]

## Recommendation

[Should the user spend 4–6 weeks on Phase 3 (Swift CLI build) based on this
evidence? Yes/No, with reasoning.]

## Open questions for Phase 1B (optional)

[Anything that would require a paid test — running an actual Antseed seller
instance with USDC reserve — to resolve. List these so the user can decide
whether to commit ~$15–20 for an end-to-end live test.]
```

---

## Failure modes & what to do

| Symptom | Action |
|---|---|
| MLX server OOMs at model load | Mac is too memory-pressured. Close other apps. Retry. If persists, write to HALT and stop. |
| Cloudflared tunnel returns 502 | Check that mlx server is still running. Restart from Step 3. |
| Tunnel URL works once then 5xx | Cloudflare rate-limit on free quick-tunnels. Wait 60s, retry. |
| `mlx_lm.server` SSE format differs from OpenAI | Document precisely in Step 9 output. Do NOT mark as full FAIL — note as deviation for downstream compatibility assessment. |
| Latency > 30s for simple request | Likely tunnel issue or M1 under thermal throttle. Check `pmset -g thermlog`. |
| Production antseed seller behaves oddly during PoC | STOP immediately. Write `results/HALT.md`. The silo was broken somewhere. |

---

## Out of scope for Phase 1

Do NOT attempt any of the following in this PoC:
- Running an Antseed seller instance.
- Registering a provider on Antseed.
- Sending real buyer sessions / spending USDC.
- Modifying any antseed config file.
- Testing on hardware other than this M1.
- Testing model sizes beyond 3B.
- Implementing PT_DENY_ATTACH or any Darkbloom security primitives.
- Building any Swift, Rust, or Go code.

These are explicitly Phase 1B / Phase 3+ concerns. Do not pre-emptively
expand scope.

---

## Done condition

You are done when:
1. All steps 0–10 executed.
2. `results/REPORT.md` exists with a headline result.
3. No production system was modified.
4. All PoC processes are stopped.

Hand the report path back to the user. Do not summarize or hedge — they
will read the report directly.
