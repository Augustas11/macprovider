# Contributor onboarding prompt

This is a single self-contained prompt to paste into the M4 user's AI CLI
(Codex, Claude Code, etc.). The agent does the setup, starts the server +
tunnel in background tmux sessions, and reports the public URL.

**To send to the contributor:** copy everything between the `===` lines below
into whatever channel you both agreed on (Signal, Telegram, email). They
paste it as the very first message into `codex`, `claude`, or whichever CLI
they prefer.

---

```
=== BEGIN PROMPT ===

You are helping me join a small Mac-inference beta. I'm contributing idle
GPU time on this Mac; a friend on a separate Mac will fire test workloads at
me over an encrypted Cloudflare tunnel. The prompts come from a fixed
library — no personal data leaves this machine. Everything is local and
revocable; closing two terminal sessions ends it instantly.

Please do the following, in this order, asking me only when you genuinely
need a decision from me:

1. **Verify environment.** Confirm this is an Apple Silicon Mac (`uname -m`
   should return `arm64`). If not, stop and tell me — the beta only works on
   M-series chips.

2. **Report my RAM** by reading it from `sysctl hw.memsize`. Convert to GB.

3. **Install prerequisites** if missing. Use Homebrew. I want:
   - `python@3.12` (or any python ≥ 3.10 already on PATH is fine)
   - `cloudflared`
   - `tmux` (for running the two long-lived processes without me babysitting
     two terminal windows)
   Skip whatever I already have. Tell me what you installed.

4. **Create a Python venv** at `~/macprovider` and `pip install mlx-lm` into
   it. Skip the venv creation if it already exists; just upgrade `mlx-lm`.

5. **Pick a model based on the RAM you reported in step 2:**
   - 16 GB → `mlx-community/Qwen2.5-7B-Instruct-4bit`
   - 24 GB → `mlx-community/Qwen2.5-14B-Instruct-4bit`
   - 36 GB or more → ask me whether I'd rather run a 14B (faster, ~8 GB) or
     a 30B-class 4-bit (slower but more capable, ~20 GB). Don't pick a 70B
     unless I explicitly say so.
   Print the exact model id you're about to use.

6. **Start MLX server in a detached tmux session** named `mlx`:
   ```
   tmux new-session -d -s mlx \
     "source ~/macprovider/bin/activate && mlx_lm.server --model <MODEL_ID> --port 8080"
   ```
   Wait ~30 seconds for the model to download (first run only) and the
   server to bind. Then confirm it's up by curling
   `http://localhost:8080/v1/models` and showing me the response. If the
   first run, this can take a few minutes — be patient and recheck.

7. **Start the Cloudflare tunnel in a detached tmux session** named
   `tunnel`:
   ```
   tmux new-session -d -s tunnel "cloudflared tunnel --url http://localhost:8080"
   ```
   Then poll `tmux capture-pane -p -t tunnel` every ~3 seconds until you see
   a line containing `https://` and `trycloudflare.com`. Extract that URL.

8. **Smoke-test the public URL** by curling
   `<URL>/v1/chat/completions` with a one-line prompt. Show me the response
   so I can see it round-trips.

9. **Present the tunnel URL** to me clearly, like this:

   ```
   ============================================================
   Public tunnel URL (send this to your friend):

     https://<random>.trycloudflare.com

   Model serving:
     <model id>

   To stop everything later:
     tmux kill-session -t mlx
     tmux kill-session -t tunnel

   To peek at logs:
     tmux attach -t mlx        # ctrl-b then d to detach
     tmux attach -t tunnel
   ============================================================
   ```

10. **Stop there.** Do not modify any other files on this Mac. Do not start
    or stop any other services. If anything in steps 1–8 fails, stop and
    explain — don't try to "fix" things outside this beta's scope.

A few rules:

- **Never** run anything as root or with `sudo` unless brew explicitly asks
  for it during an install.
- Tunnel URLs from `cloudflared tunnel --url` are ephemeral — they rotate
  whenever the tunnel session restarts. That's expected; I'll resend it.
- If `mlx_lm.server` exits or crashes, tell me but don't auto-restart it.

That's the whole job. Ready when you are.

=== END PROMPT ===
```

---

## Why this works for Type B users

- They live in their AI CLI already; pasting a prompt is the natural action.
- The agent inspects RAM rather than asking — one less question.
- `tmux` is the right primitive for two long-lived processes driven by an
  agent: no extra terminal windows, easy detach/reattach, single command
  to kill.
- The smoke curl at step 8 catches setup mistakes before the URL ever gets
  sent to the operator, saving a round-trip.
- Step 10 explicitly fences scope — the agent won't reorganize their dotfiles.

## If they want the manual path instead

Point them at `README.md` (this directory). It's the same flow without
agent assistance.

## Operator follow-up

When they send the URL:

1. Paste it into `config.yaml` (no trailing slash; harness appends
   `/v1/chat/completions`).
2. Set `model:` in `config.yaml` to whatever model id they reported.
3. `cd beta && ./scripts/run-once.sh short_chat` — should print
   `status=200`.
4. Enable the cron line from `README.md` for the agreed window.
