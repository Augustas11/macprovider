# Long agent-session gate

A model or runtime is **not agent-ready** until it passes this matrix on the
lab build. Short tool/turn tests (one session, under 32k tokens, asserting
correctness) do not count: they missed both defects this gate exists for.

- The gateway cut a stream after 10 s without tokens (`decode_idle`, settled
  as `provider_timeout`). Another session's long prefill had stalled decode.
  The client's retry then got `429 no_provider_available`.
- Past about 100k context, the provider conversation cache stopped capturing
  (`capture_skipped reason=exceeds_promotion_ceiling`,
  `conv_cache_entries=0`). Only the static prefix hit, so every turn
  re-prefilled about 76k tokens.

## Tools

- `scripts/agent_session_replay.py` rebuilds the exact request sequence of a
  Codex rollout (`CODEX_HOME/sessions/**/rollout-*.jsonl`). It replays the
  same growing input, tools and reasoning effort, over streaming
  `/v1/responses` (default) or `--api chat`. It writes `turns.jsonl` and
  `summary.json`, and exits 1 on any SLO breach.
- `scripts/prod_failure_signatures.py` counts the same failures in gateway
  and provider logs. Run it over the window's logs as a cross-check, and over
  production logs when a buyer reports a stalled agent.

Rollouts contain prompts, file contents and command output. Keep them and the
replay output out of this repository. Store window evidence in the private
`macprovider-internal` repo.

## Preconditions

1. Use the campaign's lab build: provider CLI and gateway at the campaign
   commit. Do not use the installed release.
2. Run in a paused Studio window, with the buyer runner stopped first, as
   described in [studio-lab-window.md](studio-lab-window.md). No live buyer
   traffic may share the provider during the matrix.
3. Use a source rollout from a real agent session whose context reaches past
   128k. Check it with `--plan`:

   ```bash
   python3 scripts/agent_session_replay.py --plan <rollout.jsonl>
   ```

   The plan lists every request with its context size. `tools_source` shows
   whether the tool schemas came from the rollout or were synthesized. Pass
   `--tools-file` with a captured tools array when byte-exact prefixes
   matter.
4. Set `--idle-limit-seconds` to the gateway's `streaming_idle_ms` under
   test.

## Matrix

There are 12 cells: four context steps, each run in three shapes. Each cell is
one run with its own `--out-dir`. Every run tags its sessions with a fresh
nonce, so a cell never reuses cache from an earlier cell.

| Context (`--max-context`) | 1 session | 4 sessions | 1 session + aggressor |
|---|---|---|---|
| `32k` | pass required | pass required | pass required |
| `64k` | pass required | pass required | pass required |
| `100k` | pass required | pass required | pass required |
| `128k` | pass required | pass required | pass required |

```bash
B=http://127.0.0.1:<lab-gateway-port>/v1
K=<path to lab buyer key file>
R=<rollout.jsonl>
for ctx in 32k 64k 100k 128k; do
  python3 scripts/agent_session_replay.py "$R" --base-url "$B" --api-key-file "$K" \
    --max-context "$ctx" --sessions 1 --out-dir "out/$ctx-s1"
  python3 scripts/agent_session_replay.py "$R" --base-url "$B" --api-key-file "$K" \
    --max-context "$ctx" --sessions 4 --stagger-seconds 15 --out-dir "out/$ctx-s4"
  python3 scripts/agent_session_replay.py "$R" --base-url "$B" --api-key-file "$K" \
    --max-context "$ctx" --sessions 1 --aggressor-prefill-tokens 64k --out-dir "out/$ctx-aggr"
done
python3 scripts/prod_failure_signatures.py --fail-on-any <gateway.log> <provider.log>
```

The aggressor sends one uncached prompt of about K tokens per turn. It starts
when that turn's first token arrives, so its prefill lands on the turn's
decode. Aggressor requests are recorded but not held to the SLOs.

Keep the API key in a file. The harness never prints it.

## SLOs

Every replayed request is checked. A failed attempt breaches even if a retry
then succeeds.

| SLO | Default | Flag |
|---|---|---|
| Cache ratio (cached / prompt tokens) on every request except the first and the first after a compaction | ≥ 0.90 | `--min-cache-ratio` |
| Largest gap between streamed tokens | < gateway idle limit | `--idle-limit-seconds` |
| Cut streams, 5xx, 429 | 0 | none |
| TTFT | ≤ base + uncached tokens / prefill rate | `--ttft-base-seconds`, `--prefill-tokens-per-second` |

Set the prefill rate to the model's measured single-request prefill rate on
the box. Do not loosen it to make a cell pass.

`summary.json` reports `breach_counts`, the first 100 breaches, and per
context bucket (32k/64k/100k/128k) the minimum cache ratio, largest gap, TTFT
p50/max and decode tok/s p50. `turns.jsonl` holds every attempt, including
the source session's own prompt and cached token counts for comparison.

## Verdict

- All 12 cells exit 0, and the signature scan of the window's logs is clean:
  the model or runtime is agent-ready on that build. Record the summaries
  with the campaign evidence.
- Any cell fails: the model or runtime is not agent-ready. Fix the code in
  the campaign PR, rebuild, and rerun the failed cells and every cell at a
  larger context.
- A new CLI cut of a build that passed only rebinds identity. It does not
  rerun the matrix. A change to decode, scheduling, prefill, cache capture or
  the gateway streaming path reruns the matrix.
