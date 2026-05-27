# Phase 3 binary swap — M4 partner instructions

Hey — we're ready to swap your `mlx_lm.server` for the new Phase 3 binary
we've built. Same hostname (`m4.streamvc.live`), same port (8080), same
model (Qwen2.5-7B-Instruct-4bit). The Cloudflare tunnel is untouched.

**Total time: ~5 minutes of your attention.** Rollback in 30 seconds if
anything feels off.

---

## What I'll send you

Three files (via Signal/Telegram/whatever channel we've been using):

1. `phase3-binary-m4-<tag>.tar.gz` — the binary + Metal shaders (~35 MB)
2. `install-m4.sh` — installer script
3. `rollback-m4.sh` — revert script (KEEP THIS HANDY)

## Install

```bash
# Drop the three files into ~/Downloads or wherever convenient
chmod +x install-m4.sh rollback-m4.sh
./install-m4.sh ~/Downloads/phase3-binary-m4-<tag>.tar.gz
```

The installer:
1. Stops your current `mlx_lm.server` tmux session
2. Unpacks the binary to `~/phase3-binary-m4/`
3. Clears macOS Gatekeeper quarantine (so it can execute)
4. Starts the binary in the same `mlx` tmux session
5. Waits up to 2 minutes for the model to load
6. Verifies `/v1/models` responds

If step 6 succeeds, you're done. The Cloudflare tunnel keeps relaying
traffic; our buyer harness hits the new binary instead of `mlx_lm.server`.

## What's different about the new binary

From outside: identical OpenAI-compatible API.
From inside:
- Single-language implementation (Swift instead of Python wrapping mlx)
- Stricter request validation (malformed JSON returns 400, not 404)
- Synthesized `usage` chunks on streaming responses (more spec-compliant)
- ~3 GB resident memory once model is loaded (similar to mlx_lm.server)

## Monitoring

```bash
# Live binary logs:
tmux attach -t mlx       # Ctrl-B then D to detach
# OR
tail -f /tmp/phase3-binary-m4.log

# Quick health check:
curl -sS http://127.0.0.1:8080/v1/models
```

## Rollback (run this ANY time)

```bash
./rollback-m4.sh
```

Reverts to `mlx_lm.server` in ~30 seconds. Cloudflare tunnel unaffected.

When to rollback (any of):
- Mac fans spin permanently (binary stuck)
- `curl /v1/models` returns 500 / hangs > 30s
- You see crash logs in Console.app for `macprovider-cli`
- Anything feels off — there's no penalty for rolling back

## Validation window

The operator will watch the Phase 2 cron metrics for ~60 minutes after
your swap. If throughput stays within 10% of baseline and no crashes,
the binary stays. If anything looks bad, the operator will message
you to run `rollback-m4.sh`.

## What you can do while it's running

Nothing. The binary runs in tmux the same way `mlx_lm.server` did. Your
normal workflow on the Mac is unaffected (a few hundred MB more RAM
used, brief GPU activity on each inference request).

## Cleanup later (after the test)

If we end up keeping the binary, no cleanup needed.
If we revert, you can delete `~/phase3-binary-m4/` whenever convenient.

---

## Acceptance criteria for the operator (FYI)

The operator will compare these metrics for the first hour after the swap:

| Metric | Pre-swap (mlx_lm.server) | Post-swap target |
|---|---|---|
| short_chat throughput | 19.8 tps | 17.8–21.8 tps |
| medium_with_system | 17.3 tps | 15.6–19.0 tps |
| code_completion | 19.8 tps | 17.8–21.8 tps |
| TTFT (streaming) | 708 ms | <850 ms |
| HTTP 200 rate | ~89% | ≥85% |
| Stop-token leaks | 0% | 0% |

If 4 of 5 cron cycles fall in range: swap accepted, binary stays.
If not: rollback.

---

Thanks for helping validate Phase 3. This swap is the last big
acceptance test before SPEC-002 coordinator build starts.
