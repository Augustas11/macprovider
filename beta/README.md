# Mac Provider — Phase 2 beta

Two-Mac MVP: one M4 contributor serves MLX; one M1 operator fires varied
workloads through a Cloudflare tunnel, logs every request to SQLite, and
renders an HTML daily report.

This README is split into **operator** (you, augstar, on the M1) and
**contributor** (the M4 user) sides. The contributor only needs to read the
first ~30 lines of the contributor section.

---

## Quick path: send them an AI-CLI prompt

If the M4 user has Codex, Claude Code, or any agentic CLI installed (almost
certain for Type B users), skip the manual steps and send them
[`CONTRIBUTOR_PROMPT.md`](./CONTRIBUTOR_PROMPT.md). The block between the
`=== BEGIN/END PROMPT ===` lines is a self-contained instruction set that
detects RAM, picks a model, sets up venv + tmux + cloudflared, smoke-tests
the tunnel, and prints the URL to send back. The manual instructions below
are the fallback.

## Contributor side (M4 user, manual path)

You need: a Mac with Apple Silicon, ~10 GB free disk, and 20 minutes of
attention once. After setup, each session is two terminal commands.

### One-time setup

```bash
# Homebrew prerequisites
brew install python@3.12 cloudflared

# Python env for MLX
python3 -m venv ~/macprovider
source ~/macprovider/bin/activate
pip install --upgrade pip
pip install mlx-lm
```

### Pick a model based on your RAM

| RAM           | Recommended model                                                 | On-disk |
| ------------- | ----------------------------------------------------------------- | ------- |
| 16 GB (base)  | `mlx-community/Qwen2.5-7B-Instruct-4bit`                          | ~4 GB   |
| 24 GB (Pro)   | `mlx-community/Qwen2.5-14B-Instruct-4bit`                         | ~8 GB   |
| 48 GB+ (Max)  | `mlx-community/Llama-3.3-70B-Instruct-4bit` or a 30B-class 4-bit  | ~35 GB  |

If unsure, start with the 7B — it leaves headroom for everything else you do.

### Every session — two terminals

```bash
# Terminal 1: serve MLX on localhost
source ~/macprovider/bin/activate
mlx_lm.server --model mlx-community/Qwen2.5-7B-Instruct-4bit --port 8080
```

```bash
# Terminal 2: expose it via Cloudflare
cloudflared tunnel --url http://localhost:8080
# Look for the line:
#   Your quick Tunnel has been created! Visit it at (it may take some time...):
#   https://<random-words>.trycloudflare.com
# Send that URL to the operator.
```

When you're done for the day, Ctrl-C both terminals. Nothing persists. The
tunnel URL changes every session — send the new one each time.

### What's collected

The harness records, per request: timestamp, workload type, HTTP status,
time-to-first-token, total wall time, prompt+completion token counts,
throughput, and a 300-character preview of the response. No personal data;
the prompts come from a fixed library in `workloads.py`.

### What's safe to expect

- The 7B 4-bit model uses ~4 GB of unified memory while serving.
- A normal workload batch (5 requests) takes ~30 s of compute total.
- The fans may spin up briefly under sustained load — that's normal.
- If the Mac feels slow during a request, that's also normal — MLX uses the
  GPU, which is shared with the display.

---

## Operator side (M1)

### Layout

```
beta/
├── README.md           # this file
├── config.yaml         # tunnel URL, model, batch list, paths
├── harness.py          # buyer-side request firing + SQLite logging
├── workloads.py        # workload library (6 types)
├── report.py           # SQLite -> HTML daily report
├── runs.sqlite         # created on first run
├── reports/            # YYYY-MM-DD.html outputs
└── scripts/
    ├── run-once.sh         # smoke test a single workload
    └── run-scheduled.sh    # cron entrypoint: batch + report
```

### Python environment

The existing `beta/.venv` was created with Python 3.9, which reached end-of-life in October 2025. To rebuild on a supported Python:

```bash
python3.11 -m venv beta/.venv
source beta/.venv/bin/activate
pip install -r beta/requirements.txt
```

Both `harness.py` and `report.py` import `pyyaml` and `requests`; `beta/requirements.txt` pins the minimum versions.

### Configure

Edit `config.yaml`:

- `tunnel_url`: the `https://*.trycloudflare.com` URL the M4 user sent.
- `model`: must match the `--model` argument they passed to `mlx_lm.server`.
- `batch`: comma the workloads you want each scheduled run to fire.

### Smoke test

```bash
cd beta
./scripts/run-once.sh short_chat
```

Expected output line (verbose):

```
  short_chat: status=200 ttft=— total=850ms in=24 out=42 tps=49.4 leak=0
```

If `status != 200` or you see an error, check:
- Is the M4 user's `mlx_lm.server` still running?
- Is the cloudflared tunnel URL still valid? (It rotates per session.)
- Does the `model` in config.yaml match the one they're serving?

### Schedule

Add to your `crontab -e`:

```cron
# Phase 2 — hourly batch during agreed window (UTC offsets depend on M4 user)
0 9-22 * * * /Users/augstar/macprovider-poc/beta/scripts/run-scheduled.sh >>/Users/augstar/macprovider-poc/beta/cron.log 2>&1
```

Each invocation:
1. Activates the project venv.
2. Runs the full batch from `config.yaml`.
3. Regenerates today's HTML report at `reports/<date>.html`.

### Read the data

```bash
# Quick stats
sqlite3 runs.sqlite "SELECT workload, COUNT(*), ROUND(AVG(total_ms)) FROM runs GROUP BY workload;"

# Errors today
sqlite3 runs.sqlite "SELECT ts_utc, workload, http_status, error FROM runs WHERE error IS NOT NULL AND substr(ts_utc,1,10)=date('now');"

# Open the rendered report
open reports/$(date -u +%F).html
```

### Workloads (defined in `workloads.py`)

| Name                  | Shape (approx)     | Purpose                          |
| --------------------- | ------------------ | -------------------------------- |
| `short_chat`          | 50 in, 100 out     | Cheapest signal of life          |
| `medium_with_system`  | 2K in, 200 out     | Typical chat shape               |
| `long_context`        | 8K in, 100 out     | Push prefill; Phase 1 viable     |
| `code_completion`     | 500 in, 100 out    | Coder-style continuation         |
| `agent_style`         | 3K in, 300 out     | System + tool catalog + query    |
| `streaming_check`     | small, stream=true | Time-to-first-token measurement  |

### SSE quirks the harness already handles

Phase 1 (`../docs/legacy/phase1/PHASE1_REPORT.md`) found `mlx_lm.server` isn't strictly
OpenAI-compatible. The harness already handles:

1. `: keepalive N/M` comment lines in the SSE stream — skipped.
2. Stop-token leakage (`<|eot_id|>`, `<|im_end|>`, `<|end|>`, etc.) — stripped
   from the preview, flagged in the `stop_token_leak` column.
3. Extra response fields — ignored via best-effort JSON access.

The fourth Phase 1 finding — context-length pre-flight — is **not**
implemented here because the M4 contributor is cooperative and the harness
won't intentionally OOM their Mac. Track this for Phase 3.

### Pending decisions (from legacy Phase 1 handoff)

Before running for real, agree with the M4 user on:

1. **Their RAM** → which model.
2. **Availability window** → cron hours.
3. **Tunnel URL exchange channel** (Signal / Telegram / email — doesn't matter functionally).
4. **Report visibility** — share the daily HTML, or operator-only?
5. **Beta duration** — minimum 1 week, target 2.
6. **What "stop" means** — checkpoint at end of week 1.

### Phase 2 success criteria

- ≥ 7 continuous days of operation.
- Real perf data across all 5+ workload types.
- Stop-token leakage rate quantified per model.
- Tunnel stability quantified (drops/day, recovery time).
- M4 user qualitative feedback: heat, noise, interference.
- Explicit decision at week 1: continue, iterate, pivot, or proceed to Phase 3.
