# Serial tool-turn stop lab e2e — 2026-09-21

Campaign PR **#1662**. Sanitized: timings, finish reasons, tool names,
token counts, PIDs. No buyer keys, no `settings.json` edits, no live
8080 traffic.

## Header

- **Date:** 2026-09-21
- **Operator:** augstar
- **Hardware:** Mac Studio M3 Ultra, 256 GB, macOS 26.4.1
- **Topology:** isolated `127.0.0.1:18081`, `--no-join`,
  `credential_store: protected_file`, `continuous_batching: off`,
  `max_concurrency_override: 1`, `max_context_override: 16384`.
  SSH tunnel `localhost:18081` → Studio `127.0.0.1:18081` for Pi.
- **Live processes left running:** 8080 PID **80741**
  (`live.malibu.provider`, Qwen 30B); 18080 PID **93055**
  (`macprovider-cb-serve-prefill`, CB canary, Qwen 30B).
- **Model:** `qwen3-8b` /
  `mlx-community/Qwen3-8B-4bit` sha256
  `1f591f9c4fb38d05ea2d879d89a6eeab485c23a04eb75e3e0a289db9d95ec877`.
  8B because two 30B weights were already resident; a third 30B load
  is forbidden for this campaign.
- **Pi:** `PI_CODING_AGENT_DIR=/tmp/pi-loopback-1662` (copy of
  `~/.pi/agent/{settings,models}.json`, `baseUrl` rewritten to
  `http://127.0.0.1:18081/v1`). Original
  `~/.pi/agent/settings.json` mtime unchanged (`2026-09-07 08:44`).

## Binaries

| Role | Path | SHA-256 | Identity |
| --- | --- | --- | --- |
| Isolated lab CLI | `/Users/a1/macprovider-serial-tool-stop/phase3-binary/.build/release/macprovider-cli` | `39a0b6fef0509c0641eb0fc3da618fc9ab308fda172bd6f8ab10aae2b651397a` | `swift build -c release` of `feat/serial-tool-turn-stop` `@88874f27`; `--version` still `1.8.123` |
| Isolated serve | PID **99111** after 16k context restart (first serve was PID 98803 at 8k) | same SHA | `--port 18081 --no-join --no-idle-prewarm` |
| Live 8080 | `/Users/a1/macprovider/macprovider-cli` | not used | PID 80741 throughout |
| CB canary 18080 | worktree `macprovider-cb-serve-prefill` | not used | PID 93055 throughout |

## Curl stream (serial tool, omitted `parallel_tool_calls`)

- **Wall:** 1.47 s (`generation_ms=965`, `completion_tokens=115`,
  `prompt_tokens=177`)
- **Wire:** native `tool_calls` deltas for `read` with
  `arguments` `{"path":"Makefile"}`, then
  `finish_reason=tool_calls`, then `[DONE]`
- **Log:** `malformed tool-call output … missingEndDelimiter` **and**
  `kv_cache_request_completed` `finish_reason=tool_calls`. Leftover
  close-tag did not hang and did not drop the stream.

## Pi json bakeoff (tool must execute)

Prompt class: read `Makefile` `test-dist` first command, then `bash`
`gh pr view 1638 --repo Augustas11/macprovider --json state,mergedAt,title`.

| | Result |
| --- | --- |
| Wall | 30.76 s (`real 30.76`) |
| Tool 1 | `read` `Makefile` executed (`isError` unset / success) |
| Tool 2 | `bash` `gh pr view 1638 …` executed; stdout `state=MERGED` `mergedAt=2026-09-20T08:05:28Z` |
| Final | stopReason `stop`; quoted `bash scripts/test-openai-wire-compat.sh`; PR 1638 merged |
| Serve | two `missingEndDelimiter` warnings with `finish_reason=tool_calls` (314 then 77 completion tokens), then final `finish_reason=stop` (261 completion tokens). No 150 s hang. |

First Pi attempt at `max_context_override: 8192` hit
`context_length_exceeded` (8582 > 8192) after the Makefile tool result.
That is an 8B lab-config bound, not the leftover hang. Restarted **only**
18081 at 16384; 8080/18080 PIDs unchanged.

## Verdict

**PASS** for the campaign defect: leftover markup after a complete
serial tool no longer hangs the generator; Pi executes the tool and
continues. Not a Coder-30B bakeoff vs OpenRouter (8B isolated). Not an
enable, fleet promote, or signed-CLI cut.

## Not done here

- Freeze three-lane `omc ask codex` (next, on this freeze diff)
- Squash-merge / signed CLI cut (Loop B)
- Sticky / CB / fleet flags
