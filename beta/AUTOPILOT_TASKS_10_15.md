# Autopilot prompt — tasks #10–#15

Paste everything between the `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
lines into a fresh Claude Code or Codex CLI session at the repo root
(`/Users/augstar/macprovider-poc`). The receiving agent has no memory of the
prior session — the prompt is self-contained.

The agent will read existing files, follow the established patterns, ship
six new pieces of code, smoke-test each one, and update HANDOFF.md when done.
Expected duration: ~3 hours of autonomous work.

---

```
=== BEGIN PROMPT ===

You are continuing work on the Mac Provider Phase 2 buyer harness at
/Users/augstar/macprovider-poc. Phase 1 PoC and the first slice of Phase 2
are complete. Your job is tasks #10–#15 from the upgraded plan
(beta/PHASE2_UPGRADED_PLAN.md). Read that file and beta/README.md first to
ground yourself, then proceed.

## Required reading before any code

1. beta/PHASE2_UPGRADED_PLAN.md            — the spec you are implementing
2. beta/harness.py                          — main harness; understand run_one
                                              and run_one_adversarial
3. beta/workloads.py                        — cooperative workload contract
4. beta/workloads_adversarial.py            — adversarial workload contract
                                              (your new ones must match it)
5. beta/config.yaml                         — config keys to extend
6. beta/report.py                           — keep working; don't break it
7. results/REPORT.md (skim Step 7.5 only)   — Phase 1 quirks already known

## Environment

- macOS Apple Silicon, Python 3.9 in /Users/augstar/macprovider-poc/.venv
- Already installed in venv: mlx-lm, requests, PyYAML
- You may pip-install: psutil, huggingface-hub (small), datasets (heavier; ok
  if you need it, but prefer cached samples committed to repo). Document any
  new dependency in HANDOFF.md.
- Python 3.9 quirk: f-strings cannot contain backslash escapes inside the
  expression part. Use a local variable, not "{...\"x\"...}".
- The urllib3 LibreSSL warning on every Python invocation is harmless —
  ignore.

## Hard rules

1. **Additive only.** Do not rewrite or restructure existing files. New
   features land as new files or appended functions. The current harness.py,
   workloads.py, workloads_adversarial.py, report.py, config.yaml, and both
   shell wrappers MUST keep working unchanged from the user's perspective.
2. **Backwards compatible config.** If a user has the current config.yaml
   (single `model:` string, `batch:` + `batch_adversarial:` lists), it must
   keep working. New keys are optional with sensible defaults.
3. **Smoke-test every task before marking it done.** Smoke tests don't
   require a live mlx server — fire against http://127.0.0.1:1 (unreachable)
   and assert that error paths populate the right SQLite columns. Real-server
   testing is the operator's job.
4. **Use TaskCreate/TaskUpdate** to track each subtask so the operator sees
   progress. Read the existing task list with TaskList first; tasks #10–#15
   already exist as pending.
5. **No secrets, no money moves, no production touch.** All work is in
   /Users/augstar/macprovider-poc/beta/. Do not modify ~/.ssh, do not
   touch any other project, do not start any service the user didn't ask for.

## Tasks, in order

### Task #10 — 4 more adversarial workloads (in workloads_adversarial.py)

Add to workloads_adversarial.REGISTRY. Each function follows the existing
contract:  def fn(url, model, timeout) -> dict  returning the same metric
keys as retry_storm. Then add each name to config.yaml batch_adversarial
(but commented out for the heaviest — see notes below).

a) **long_context_oom_probe**
   - Build a single ~30,000-token prompt (use the FILLER_SENTENCES pattern
     from scripts/long_context_test.py if useful — it's the same colony
     prose).
   - Fire once. Capture HTTP status + total ms + whether response arrived.
   - Phase 1 found Llama-3.2-3B OOMs at ~26K on M1 8GB. Expected outcomes:
     success (M4 has more RAM), HTTP 500 (server caught it), or
     ConnectionError (server crashed). All three are valid data; record
     which happened in `notes`.
   - Set n_requests=1; n_ok=1 if HTTP 200; else 0.
   - Leave commented out in config.yaml — operator opts in deliberately.

b) **concurrent_burst_8way**
   - 8 concurrent medium-sized requests (~500 input, ~200 output tokens),
     ThreadPoolExecutor pattern like retry_storm.
   - Differs from retry_storm: bigger requests, tests inference contention
     (not connection contention).
   - Active by default in config.yaml.

c) **midstream_disconnect**
   - Fire 10 sequential streaming requests, close the response after
     receiving the first SSE chunk each time.
   - Use requests.post(..., stream=True) and break out of iter_lines after
     one chunk. Use a context manager so the connection cleanly drops.
   - Goal: verify the server doesn't leak request slots / stay stuck.
   - Record: did all 10 successfully start streaming? Any sequel failures?
   - Active by default in config.yaml.

d) **malformed_tool_call**
   - Send a request with deliberately broken tool-call JSON in the messages
     payload (e.g. unterminated string in a "tool_calls" field, or invalid
     function arguments). Try ~5 variants of malformation.
   - Record HTTP status distribution. Want to know whether the server
     gracefully rejects (4xx) or crashes (5xx / ConnectionError).
   - Active by default in config.yaml.

For each, smoke-test against http://127.0.0.1:1 by patching a temp config
(use /tmp/adv-test.yaml pattern from the original session — see the
sequence used in the recent transcript). Assert the adversarial_runs row
lands with n_ok=0 and a sensible error_summary.

### Task #11 — Public-corpus prompt sampler (corpus.py + workloads.py wiring)

Create beta/corpus.py with one public function:

    def sample(category: str, seed: int | None = None) -> dict
        returns {"system": str | None, "user": str, "source": str}

Categories: short, medium, code, long, agent.

Approach:
- Maintain pre-curated JSONL files under beta/corpus/:
  - short.jsonl, medium.jsonl, code.jsonl, long.jsonl, agent.jsonl
  - Each file: ~100–500 entries, one JSON object per line with the same
    shape sample() returns.
- Populate them by downloading from huggingface_hub at first use, OR commit
  curated samples. Recommended: download once with `huggingface_hub`
  snapshot_download on these datasets:
    * lmsys/lmsys-chat-1m (requires HF login — try it but FALL BACK to:)
    * anon8231489123/ShareGPT_Vicuna_unfiltered  (public, no auth)
    * THUDM/LongBench  (public)
  If HF auth fails, use a smaller free dataset. Document the source in
  each entry's "source" field.
- corpus.sample() is deterministic given a seed.
- Wire into workloads.py: each of the 6 cooperative workloads picks a fresh
  prompt from the matching category per batch. Seed by date+workload so
  the same workload at the same hour gets the same prompt (reproducible
  daily diffs, varied across the day).
- Backwards compat: if beta/corpus/ is empty or sampling fails, fall back
  to the hardcoded prompts already in workloads.py. Log the fallback.

Add corpus/ to beta/.gitignore if the JSONLs are large; commit them if
under ~5 MB total.

Smoke test: `python -c "from corpus import sample; print(sample('short', 42))"`
should print a dict. Then run the existing run-scheduled.sh against the
unreachable port and confirm cooperative workloads still execute (they will
error on HTTP but should successfully build a request body from a sampled
prompt — verify by inspecting the row's `error` column shape, not by
needing a live server).

### Task #12 — Model rotation in config.yaml

Change config.yaml shape:

    model: "..."                              # legacy single-model (still supported)
    models:                                   # new — preferred
      - {id: "mlx-community/Qwen2.5-7B-Instruct-4bit", tier: "16gb"}
      - {id: "mlx-community/Qwen2.5-14B-Instruct-4bit", tier: "24gb"}
    model_select: "rotate"                    # "rotate" | "first" | "day_of_week"

Implement in harness.py:
- If `models:` list is present, pick one per batch run based on `model_select`:
  - "first" — always models[0]
  - "rotate" — round-robin, persisted index in beta/.cache/model_index
  - "day_of_week" — index = datetime.utcnow().weekday() % len(models)
- Echo chosen model in --verbose output: "harness: selected model=<id> (tier=<tier>)"
- If `models:` is absent or empty, fall back to legacy `model:` string.

Smoke test: switch /tmp config to a 3-model list, run --batch --dry-run
three times in rotate mode, confirm each picks a different model in order.

### Task #13 — Tokenizer-config-derived stop tokens

Currently LEAKED_STOP_TOKENS in harness.py is a hardcoded list. Replace with
per-model derivation:

- Add beta/.cache/tokenizer_configs/ directory.
- For each model id used, fetch
  https://huggingface.co/{model_id}/resolve/main/tokenizer_config.json
  using urllib (no auth needed for public models). Cache to
  .cache/tokenizer_configs/<sanitized-model-id>.json
- Extract:
  - eos_token (string or {"content": ...})
  - bos_token (same)
  - any entries in added_tokens_decoder where "special" is true
  - any chat template stop strings if discoverable
- Build a per-model leak regex. Store cache in memory keyed by model id.
- On fetch failure (network down, model not on HF), fall back to the
  existing LEAKED_STOP_TOKENS hardcoded list and log a one-line warning.
- run_one() should use the per-model regex, not the global one.

Smoke test: call the fetch function for Llama-3.2-3B-Instruct-4bit and
confirm the cache file appears + contains "<|eot_id|>" in the assembled
regex.

### Task #14 — Full-response ring buffer

Add new table to harness.py SCHEMA:

    CREATE TABLE IF NOT EXISTS full_responses (
        run_id INTEGER PRIMARY KEY,
        full_content TEXT
    )

After every cooperative run_one() insert that produced a non-empty
response, insert the FULL (untruncated) assistant content keyed by the
runs.id. Then prune to last 500:

    DELETE FROM full_responses
    WHERE run_id <= (SELECT MAX(run_id) FROM full_responses) - 500

Do NOT capture full responses for adversarial workloads (they fire many
sub-requests and would explode storage).

Smoke test: run the cooperative batch against unreachable port (will produce
runs rows with errors — full_responses table should stay empty since no
content was received). Then write a tiny unit test that injects a fake
metrics dict with content="x"*5000 and confirms a row lands.

### Task #15 — Companion host-telemetry script

Create beta/companion.py — this is shipped to the contributor's Mac and
runs in their third tmux session.

Spec (~50 lines, including arg parsing):
- Polls every 60 seconds (configurable via --interval)
- Logs to ~/.macprovider/host.sqlite (creates dir + db if missing)
- Schema:
    CREATE TABLE host_metrics (
      ts_utc TEXT PRIMARY KEY,
      cpu_pct REAL,
      ram_pct REAL,
      foreground_app TEXT
    )
- CPU via psutil.cpu_percent(interval=1)
- RAM via psutil.virtual_memory().percent
- Foreground app via osascript:
    osascript -e 'tell application "System Events" to get name of first process whose frontmost is true'
  Run via subprocess.run with timeout=2.
- --no-app flag suppresses foreground-app capture (privacy opt-out).
  When set, foreground_app is stored as NULL.
- Graceful SIGTERM handling (cron / tmux kill should exit cleanly).
- Prints one line to stdout per insert, so tmux capture-pane shows progress.

Document in HANDOFF.md and update beta/CONTRIBUTOR_PROMPT.md (or note that
v2 prompt is the next deliverable, not part of this autopilot) — but the
companion.py file itself must exist and be runnable.

Smoke test: run `python companion.py --interval 1` for ~3 seconds with a
keyboard interrupt; confirm at least 1 row lands in ~/.macprovider/host.sqlite
with non-null cpu_pct and ram_pct.

## Final acceptance gate

When all 6 tasks are marked completed, do this end-to-end check:

1. `python harness.py --list` shows 6 cooperative + 5 adversarial workloads.
2. `python harness.py --once retry_storm` against unreachable port → row in
   adversarial_runs.
3. `python harness.py --batch cooperative` against unreachable port → 5
   rows in runs (errored), full_responses still empty.
4. `python harness.py --batch adversarial` against unreachable port → 4
   rows in adversarial_runs (long_context_oom_probe stays commented out).
5. `python companion.py --interval 1` runs and writes to ~/.macprovider/host.sqlite.
6. `python report.py` regenerates today's HTML without crashing on the new tables.
7. Clean up any temp /tmp test configs.
8. Update HANDOFF.md with a "## Tasks #10–#15 completed" section listing
   each new file and what changed in existing files. Append to the existing
   doc; don't rewrite.

After acceptance, mark all 6 tasks completed via TaskUpdate, summarize what
landed in under 200 words, then stop. Do not start task #16 — that's the
operator's writing job.

## When to stop and ask vs proceed

Proceed without asking when:
- You can satisfy a spec exactly as written.
- A trivial design choice has an obvious cheap default (use it, note it).

Stop and ask the operator when:
- A spec conflicts with the existing codebase in a way that requires deleting
  >50 lines of working code.
- A new dependency is needed beyond psutil + huggingface_hub.
- A smoke test surfaces a regression in existing cooperative workloads.
- You hit ambiguity that materially changes Phase 3 spec (rare — most
  ambiguity here is local).

That's the whole job. Begin by reading the files in the "Required reading"
section, then create your own TaskList breakdown for the subtasks, then go.

=== END PROMPT ===
```

---

## How to use it

```bash
cd /Users/augstar/macprovider-poc

# Option A: Claude Code CLI
claude < beta/AUTOPILOT_TASKS_10_15.md

# Option B: paste manually after launching `claude` interactively
# (copy everything between BEGIN/END PROMPT lines)

# Option C: Codex CLI — same idea, different binary
codex < beta/AUTOPILOT_TASKS_10_15.md
```

Expect ~3 hours of autonomous work. The session will use TaskCreate/TaskUpdate
to track its own subtasks (visible to you in real time) and stop at the
acceptance gate.

## What to do while it's running

The four parallel tracks that aren't gated on code:

1. Conversation with the M4 user (RAM, availability, agreement, stable-tunnel preference)
2. Conversation with the M1 collaborator (same)
3. Write `beta/DECISION_CRITERIA.md` yourself (task #16)
4. Decide which stable-tunnel mechanism you'll standardize on (named cloudflared vs ngrok reserved domain)
