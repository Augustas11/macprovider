# Launch package — M1 collaborator

Everything needed to bring the second provider online. Three things to send,
in this order, over a 1:1 channel (Signal / Telegram / encrypted email — not
a group chat, because Message 3 contains a credential).

After they finish, you do the verification block at the bottom.

---

## Pre-send checklist (operator, before opening the conversation)

- [ ] M1 partner has agreed verbally to participate in a 14-day beta
- [ ] You've explained that adversarial workloads (30K-token prompts,
      50-concurrent bursts, mid-stream disconnects) will hit their Mac
      twice a week
- [ ] You've agreed a weekly 15-min check-in slot
- [ ] You've agreed an "out clause" — what makes either side stop early
- [ ] You know their Mac model + rough RAM (helpful but not required;
      the prompt detects)

---

## Message 1 — context + agreement (safe to share)

Copy everything between the `=== BEGIN ===` / `=== END ===` lines.

```
=== BEGIN MESSAGE 1 ===

Hey — confirming the Mac Provider beta details before we kick off.

What I'm asking from you:
• Run an MLX inference server on your M1 for 14 days starting [DATE].
• Available during your normal workday (whenever your Mac is on
  anyway — no need to keep it running off-hours).
• Weekly 15-min check-in to compare notes ([SLOT]).

What I'll be doing:
• Firing test workloads at your Mac from my M1 over a Cloudflare tunnel.
• Prompts come from a fixed library + public AI conversation datasets
  (LMSYS / ShareGPT / LongBench). No personal data.
• Twice a week, I'll fire adversarial workloads designed to stress your
  hardware: a 30K-token RAG prompt, 50 concurrent requests in 5 seconds,
  mid-stream client disconnects, and malformed tool calls. These are
  meant to find failure modes, so:
  - Your Mac WILL get hot during the bursts (~30s each).
  - The 30K-token prompt MIGHT crash the mlx server process (Phase 1
    showed this happens on 8GB Macs above 26K tokens). I don't think it
    will on your machine but I can't promise.
  - If anything weird happens, I'll be the first to know — we'll
    diagnose together.

What you'll get back:
• Daily HTML reports showing how your Mac performed (TTFT, throughput,
  error rates, comparison vs my M1).
• Co-credit on whatever I publish from this work.
• [REWARD if any — token allocation, equity, cash, recognition].

Either side can stop at any point with no hard feelings. The "out clauses"
we agreed on:
  - You don't enjoy it / find it disruptive → tell me, we stop same day.
  - Your Mac crashes more than once from beta workloads → I stop.
  - Anything legal / compliance unexpected on either side → stop.
  - You're silent for 48h without explanation → I stop and reach out.

If you're still in: reply "in" and I'll send the setup instructions.

=== END MESSAGE 1 ===
```

---

## Message 2 — AI-CLI setup prompt (safe to share)

Send this after they say "in." They paste it into Claude Code, Codex, or any
agentic CLI. Self-contained.

```
=== BEGIN MESSAGE 2 ===

You're helping me join a 2-Mac inference beta. The operator runs a buyer
harness from their M1; this Mac (mine) is the second provider. A Cloudflare
tunnel has been pre-provisioned by the operator — my job is to set up MLX
locally and connect the tunnel.

Please do the following in order. Ask me only when you genuinely need a
decision.

1. Verify Apple Silicon: `uname -m` should return `arm64`. If not, stop.

2. Report my RAM (`sysctl hw.memsize`, convert to GB). Print it.

3. Install via Homebrew if missing (skip what I already have):
   - python@3.12 (any python ≥ 3.10 already on PATH is fine)
   - cloudflared
   - tmux

4. Create a Python venv at `~/macprovider` and `pip install mlx-lm psutil`.
   If the venv already exists, just upgrade mlx-lm. Print versions installed.

5. Pick a model based on the RAM you reported:
   • 8 GB  → mlx-community/Llama-3.2-3B-Instruct-4bit
            (operator already validated this on an 8GB M1 in Phase 1;
             Qwen 7B 4-bit would technically load but thrash under
             swap pressure — don't pick it.)
   • 16 GB → mlx-community/Qwen2.5-7B-Instruct-4bit
   • 24 GB → mlx-community/Qwen2.5-14B-Instruct-4bit
   • 32 GB → mlx-community/Qwen2.5-14B-Instruct-4bit (default) OR ask me
     whether to go to a 30B-class 4-bit (~20 GB, slower but more capable)
   • 48 GB+ → ask me before picking; don't auto-default to anything 70B
   Print the exact model id you're about to use.

6. Start MLX server in a detached tmux session named `mlx`:
   tmux new-session -d -s mlx \
     "source ~/macprovider/bin/activate && mlx_lm.server --model <MODEL_ID> --port 8080"
   Wait up to 5 minutes for first-run model download. Then confirm by
   curling `http://localhost:8080/v1/models` and show me the response.

7. Install cloudflared as a system service using the install command the
   operator gave me. The exact command is in their next message — don't
   ask me for it yet, just stop after step 6 and tell me you're ready for
   the install token.

DO NOT proceed past step 7 until I paste the operator's install command.
Once I paste it, you'll need sudo (macOS will prompt me for my password)
to run it. After installation:

8. Verify the tunnel is up:
   • `cloudflared tunnel info` should list the tunnel as connected
   • From my Mac: `curl http://localhost:8080/v1/models` should work
     (same as step 6)
   • The operator will independently verify the public hostname from
     their side — they'll confirm or tell me what's wrong.

9. Save the operator's companion telemetry script when they send it later
   (Message 4, optional). Don't proceed to that step now.

10. Print a final status line:
   ============================================================
   M1 provider ready
     Model:          <model id>
     tmux sessions:  mlx (server), <other sessions>
     Tunnel:         installed as launchd service
   To stop everything later:
     sudo cloudflared service uninstall
     tmux kill-session -t mlx
   ============================================================

Hard rules:
• Never run anything as root or with sudo unless brew / cloudflared
  explicitly asks for it.
• Don't modify any other files, services, or daemons on this Mac.
• If mlx_lm.server crashes, tell me — don't auto-restart.
• If anything fails in steps 1–8, stop and explain. Don't improvise.

Begin.

=== END MESSAGE 2 ===
```

---

## Message 3 — the install token (CREDENTIAL, send last)

**1:1 ONLY.** Anyone with this token can run a tunnel under your Cloudflare
account. Do not post in groups, do not put in screenshots, do not commit
anywhere.

The current token for the M1 collaborator is in:

```
beta/CONTRIBUTOR_TUNNEL_TOKENS.txt
```

(That file is gitignored, mode 600, and contains both M4 and M1 tokens —
copy only the M1 block.)

The message to send is exactly the second block of that file:

```
=== BEGIN MESSAGE 3 ===

Paste this and follow the agent's lead:

sudo cloudflared service install <PASTE M1 TOKEN HERE>

After installation, your hostname m1.streamvc.live will go live within
about 60 seconds. Tell the agent to verify and run step 8.

=== END MESSAGE 3 ===
```

---

## Operator verification (you, after they finish)

When the M1 partner confirms "done," run these from your M1:

```bash
# DNS resolves to Cloudflare edge — should be quick
dig +short A m1.streamvc.live @1.1.1.1

# Public hostname round-trip — should return mlx models JSON, NOT HTTP 530
curl -sS https://m1.streamvc.live/v1/models | python3 -m json.tool | head -20

# Harness smoke test — point a temp config at their hostname
cd /Users/augstar/macprovider-poc/beta
TMP=$(mktemp)
sed -E 's|^tunnel_url:.*|tunnel_url: "https://m1.streamvc.live"|; s|^model:.*|model: "<MODEL_ID_THEY_REPORTED>"|' config.yaml > "$TMP"
python harness.py --config "$TMP" --once short_chat --verbose
rm "$TMP"
```

If `short_chat` returns `status=200`, you're live with the M1 partner.
Record the model id they're running and their tmux session start time;
that becomes their day-0 entry in your decision log.

---

## After both providers are live

1. **Update `config.yaml` for the operator-facing harness:**
   - Decide which provider's hostname goes into the main `tunnel_url`,
     OR set up two harness configs and run two separate crontab lines
     (one per provider). Recommended: two configs (`config-m4.yaml`,
     `config-m1.yaml`), two crontab lines.

2. **Update `model:` per provider** based on what each actually serves.

3. **Stamp `DECISION_CRITERIA.md` header** — kickoff date = today.

4. **Enable cron** for cooperative + adversarial schedules.

5. **First report** lands at `reports/<today>.html` an hour later.
