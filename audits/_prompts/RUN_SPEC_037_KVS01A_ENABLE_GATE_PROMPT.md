# RUN: SPEC-037 KVS-01a enable gate on the Mac Studio 256 GB

You are a senior provider-runtime engineer on `Augustas11/macprovider`. This
session has **one job**: run the already-shipped SPEC-037 KV-survival disk tier
through its **real-hardware enable gate** (KVS-01a) on the operator's Mac Studio
(M3 Ultra, 256 GB), record the evidence, and stop.

Work autonomously. Do not ask "want me to run it?". Do not reopen Approach A vs
C. Do not start SPEC-038, thermal-soak, cold-TTFT, catalog benches, or KVS-01b.

Read `AGENTS.md` first. Then this prompt. Then the cited files. Do not inspect
`d-inference` source.

---

## 0. What "done" is

**PASS (enable residual closed for v0.1 synthetic-key experiments on this
tuple):**

- Packaged (not worktree) `macprovider-cli` on the Studio, isolated local
  HTTP serve, **no coordinator join**, **not** the live Pearl-connected
  `8080` provider.
- `test/e2e/coldwarm-ttft/kvs-01a.sh --cycles 30` exits 0.
- Every restored arm: `disk_hit`, `correctness=ok`,
  `cached_prompt_tokens == persist.prompt_tokens + persist.completion_tokens`.
- Append-only NDJSON + sanitized evidence bundle committed under
  `docs/runbooks/` (same shape as the 2026-09-20 continuous-batching evidence
  files: counts, TTFT, hit/miss codes, RSS, binary identity; **no tokens, no
  keys, no bearer headers**).
- Purge primitive exercised on the same install (`kv-cache status`,
  `kv-cache purge` of a synth key, then a miss).
- Decision-log entry in `beta/DECISION_CRITERIA.md` stating the exact binary,
  model, hardware, cycle count, and the enable consequence below.
- PR for the evidence + decision entry (docs/runbook + decision log; no
  runtime default flip).

**FAIL:** harness exit 5 (correctness) or a stop-condition trip. Record numbers,
do **not** enable anything, do **not** "fix the kernel / invent paged restore"
in this session. Follow §6 stop condition (write the DECISION_CRITERIA entry
naming the failed gate). A `--perf-gate` exit 6 is **not** a KVS-01a fail
unless you opted into it; for this session leave perf **advisory**.

**Enable consequence if PASS (narrow — read twice):**

- Operator **may** leave `kv_disk_cache.enabled=true` on **this Studio isolated
  lab serve** for `conv:kvs-synth:` direct-HTTP traffic.
- Fleet default stays **off**. Do not flip `enabled` default in code or in the
  live Pearl-connected Studio/32 GB providers.
- `allow_buyer_keys` stays **false / rejected**. Buyer-key persistence is
  unenableable in v0.1 (no coordinator purge channel).
- Do **not** mark `SPEC-037-R013` conformant. FR-KVP13 graduation past
  synthetic-key experiments still requires KVS-01b (8k / Q6-Q7) + KVS-02/03.
  KVS-01a PASS is the Entry-199 **before-ENABLE** residual, not LOCK / not
  fleet-on.

---

## 1. Why this session exists (do not rediscover)

SPEC-037 IMPL merged **#771** (`d53e8650`, 2026-07-27) as a dormant,
default-off, synthetic-key-only, residency-only encrypted disk tier behind
`ConversationCache`. Audits, CI, and unit tests all passed **while the feature
was a silent no-op** on real serve (`RotatingKVCache` vs `KVCacheSimple`
allowlist). That is **Entry 199** in `beta/DECISION_CRITERIA.md`. The lesson is
load-bearing: **green CI is not the enable gate. A packaged-binary persist →
SIGKILL → relaunch → disk_hit run on a real Mac is.**

That run has never happened. It was blocked on a controllable >32 GB Mac. The
Studio is that Mac.

Normative contract: `specs/SPEC-037-kv-survival-restart.md` FR-KVP11, FR-KVP13,
§6, AC-10. Harness: `test/e2e/coldwarm-ttft/README.md` (KVS-01a section) +
`kvs-01a.sh` + `kvs-01a-probe.mjs`. Do not build a parallel harness.

---

## 2. Hard fences (violating any of these is a session fail)

1. **Production fence (SPEC-037 §6).** Kill-and-relaunch only a **local
   provider you start**. `kvs-01a.sh` already refuses `*malibu.tech*` /
   `*coordinator.*` / `*api.*` bases. Do **not** set `KVS01A_ALLOW_REMOTE=1`.
2. **Do not touch the live Pearl-connected Studio serve.** Live 8080 / launchd
   `live.malibu.provider` / the buyer-pool coder-30b process is out of bounds.
   If something is already listening on 8080 and joined to
   `coordinator.malibu.tech`, **leave it**. Isolated gate serve binds a **free
   port** (recommended `127.0.0.1:18080`).
3. **Do not steal the box from SPEC-038.** Session
   `5987135e-f612-423b-aade-480f1d9d66ab` / PR **#1623** and the 2026-09-20
   `msb-throughput` evidence runs own Studio Metal/RAM when they are active.
   Before any SIGKILL or model load:
   - `gh pr view 1623 --repo Augustas11/macprovider`
   - `pgrep -lf 'macprovider-cli|msb-throughput|swift build'` on the Studio
   - If 038 is mid-measurement, **stop and report**. Do not queue behind it
     silently for hours; surface the blocker.
4. **Packaged binary only.** Entry 199: a worktree/`swift build` `serve`
   self-re-execs into the **installed** binary (PATH-repair) and a plain Swift
   build has no `mlx.metallib`. Use a signed candidate tree that contains
   `macprovider-cli` **and** `mlx.metallib` (Studio already has
   `/Users/a1/candidate-v1.8.170/`). Prefer a candidate cut from **current
   `origin/main`** if one exists after #1634 (conversation-keyed serial
   `KVCacheSimple`); v1.8.170 is acceptable for **smoke** if it is the only
   packaged tree on disk, but the 30-cycle enable bundle must name the exact
   `compatibility_set_id` / commit. Do not promote any CLI. Read
   `docs/releases/cli-release-train.md` before choosing the binary.
5. **Continuous batching stays off.** `continuous_batching: off`. SPEC-037
   serializes contiguous `KVCacheSimple`. Paged/038 layout is a different codec
   (SPEC-037 §8). Do not enable paged-KV for this gate.
6. **Model must be a v1 allowlist family.** AC-10: Llama / Qwen3 default
   `newCache` → `KVCacheSimple`. **Use**
   `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` (the production MoE SKU
   already resident on this Studio; 48× `KVCacheSimple`, no `kv_bits`). Do
   **not** use gpt-oss / gemma-4 / nemotron (those `disk_write_skipped
   (unsupported_cache_class)` by design).
7. **Synthetic keys only.** `conv:kvs-synth:` over **direct HTTP** to the
   isolated serve. No relay, no Pearl, no buyer `conv:` keys, no
   `--kv-disk-cache-allow-buyer-keys`.
8. **No secrets in git, chat, or evidence.** Redact `mp_`, `Bearer`, raw
   conversation keys, prompts, completions. The probe already hashes keys;
   keep it that way.
9. **Git:** fresh sibling worktree off `origin/main` for any commit
   (`git worktree add ../macprovider-037-kvs01a -b docs/037-kvs01a-enable-gate origin/main`).
   Do not edit canonical `/Users/augstar/macprovider-poc` except to read.
   Evidence + decision-log PR from Augustas11; antfleet-ops approves; squash
   merge as Augustas11. No `--admin`. No default-on code change in that PR.

---

## 3. Studio facts (verify on box; do not assume)

- Host: Mac Studio, Apple M3 Ultra, 256 GB unified memory, macOS 26.4.1,
  user `a1`. AC power.
- Staged canary: `/Users/a1/candidate-v1.8.170/` (serve **not** swapped into
  the live launchd path as of `docs/releases/cli-release-train.md`).
- Live buyer serve may still be on 8080. Treat 8080 as hostile-to-kill until
  proven otherwise (`lsof -iTCP:8080 -sTCP:LISTEN` + the process command line).
- Node must be on PATH for `kvs-01a.sh` (`KVS01A_NODE_BIN` if needed).
- Direct-HTTP token: a **local** operator/buyer token that the isolated serve
  accepts. Do not use the production OpenRouter/Pearl `mp_` key against this
  isolated process, and do not paste it into the repo. File default:
  `~/.config/macprovider/buyer-api-key` (harness reads it). If the isolated
  serve is config-auth local-only, follow existing local-serve test patterns;
  do not weaken serve auth.

---

## 4. Procedure

### Phase 0 — freeze check (15 min, hard gate)

On the Studio:

```bash
lsof -nP -iTCP:8080 -sTCP:LISTEN
lsof -nP -iTCP:18080 -sTCP:LISTEN
pgrep -lf 'macprovider-cli|msb-throughput|swift-package|mlx'
launchctl print gui/$(id -u)/live.malibu.provider 2>/dev/null | head
```

In this repo: `gh pr view 1623 --repo Augustas11/macprovider --json state,title,updatedAt`.

If 038 / msb-throughput / a live measurement owns GPU/RAM, stop. Write one
paragraph: what is running, PID, since when, and that KVS-01a is blocked.

### Phase 1 — isolated serve configs

Two YAML files, **not** the live provider config. Distinct `provider_id`,
distinct `--kv-disk-cache-dir` under a lab path (e.g.
`/tmp/kvs01a-kv-cache`), `0700`. Bind `127.0.0.1:18080`. No coordinator URL /
empty or local-only. `continuous_batching` off. `paged_kv` off / default.

Enabled (`KVS01A_PROVIDER_CMD`):

- `kv_disk_cache.enabled: true`
- `allow_buyer_keys: false` (must remain false; `true` disables the tier)
- `--model mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` (or the already
  cached snapshot `6e302ea604ad9ab206367e2c501d1571023e7b6d`)
- stderr must contain `event=kv_disk_cache` lines (harness greps
  `disk_write_committed` / `disk_hit`)

Disabled (`KVS01A_PROVIDER_CMD_NODISK`): same binary, port, model; 
`kv_disk_cache.enabled: false` (arm D).

Launch via the **packaged** CLI path, e.g.
`/Users/a1/candidate-v1.8.170/bin/macprovider-cli serve --config ...`
(adjust to the real tree). Confirm `mlx.metallib` is next to that binary.
Foreground: the harness `kill -9`s the PID it started.

Smoke-start once **without** the harness: curl `http://127.0.0.1:18080/v1/status`,
confirm model id, confirm log line `event=kv_disk_cache action=enabled`, then
kill that process yourself. If you see `disk_write_skipped` /
`unsupported_cache_class` / `dormant reason=` on a Qwen3-Coder request, stop
and diagnose — that is the Entry-199 silent-no-op class. Do not grind 30 cycles
on a skip.

### Phase 2 — smoke (1–2 cycles)

From a checkout of the same commit as the packaged binary (or current
`origin/main` harness; the scripts are stable):

```bash
export KVS01A_PROVIDER_CMD='…serve --config /path/enabled.yaml'
export KVS01A_PROVIDER_CMD_NODISK='…serve --config /path/disabled.yaml'
export KVS01A_BASE=http://127.0.0.1:18080
export KVS01A_PROMPT_TOKENS=2500
export KVS01A_STORE="$HOME/.local/state/kvs-01a/samples.ndjson"
export KVS01A_READY_TIMEOUT=600   # 30B load on first start
# MACPROVIDER_BUYER_TOKEN from the local key file; do not echo it
./test/e2e/coldwarm-ttft/kvs-01a.sh --smoke
```

Expect: persist → SIGKILL → relaunch → geometry-seed (throwaway synth key;
documented residual, keep it) → restored `disk_hit` with exact cached tokens.

If smoke fails: capture sanitized stderr (`event=kv_disk_cache` lines only),
fix config/binary/port/model, retry smoke. Do not jump to 30 cycles.

### Phase 3 — gate (30 cycles)

```bash
./test/e2e/coldwarm-ttft/kvs-01a.sh --cycles 30
```

Do **not** pass `--perf-gate`. Record the printed advisory warm-relative
percentiles anyway (restored p95 vs warm / miss / disabled). They do not fail
KVS-01a.

This will take a long time (each cycle reloads the 30B model twice: enabled
relaunch + disabled relaunch). Stay on AC power. Do not start competing MLX
jobs. If a cycle fails correctness, the script exits 5 — that is the answer.

### Phase 4 — purge primitive (same install, after a PASS or after a
partial store exists)

On the enabled serve (restart it if the harness tore it down):

```text
macprovider-cli kv-cache status   # counts/bytes only
macprovider-cli kv-cache purge --key conv:kvs-synth:<one-key-from-the-run>
```

Then one restored-shaped request on that purged key → expect miss / no
promotion (`disk_miss_tombstoned` or `disk_miss_absent`, not `disk_hit`).
Sanitized status + reason code into the evidence bundle.

Do **not** `--forget` the live provider's cache directory. Point purge at the
**lab** `--kv-disk-cache-dir` / lab `provider_id` only.

### Phase 5 — evidence + PR

Write `docs/runbooks/kv-survival-kvs01a-enable-gate-evidence-YYYY-MM-DD.md`:

- Date, operator, hardware tuple, binary path + `compatibility_set_id` /
  sha256 of the CLI, model id + revision + `model_sha256`
- Isolated port, `continuous_batching=off`, `kv_disk_cache.enabled=true`,
  `allow_buyer_keys=false`
- Cycle count, exit code
- Per-arm: n, disk_hit/miss counts, cached_prompt_tokens equality, TTFT p50/p95
  (nearest-rank), restore_ms p50/p95, commit_latency_ms p50/p95, peak RSS
- Purge check result
- Explicit statement: buyer keys not enabled; fleet default unchanged
- Pointer to sanitized NDJSON path **outside** the repo if the raw store is
  large; commit a redacted summary (cycle, arm, disk_reason, token counts,
  ttft_ms, restore_ms, commit_latency_ms). No prompts.

Append one `beta/DECISION_CRITERIA.md` entry: KVS-01a ran on Studio; PASS or
FAIL; enable consequence as in §0.

Open the PR (Augustas11). Governance block if the checker requires it
(docs + decision log: declare honestly). Three-lane `omc ask codex` only if
the PR grows code; a docs/evidence PR does not need a fake audit theater, but
do not sneak a default-on flag change into it.

---

## 5. Stop conditions (copy of SPEC-037 §6, operationalized)

Pause Approach A (no more persistence engineering this session) if KVS-01
cannot meet the **correctness** gate without replacing contiguous
per-conversation KV with a shared paged allocator, or if:

- restored arm never `disk_hit` on Qwen3-Coder (silent skip / wrong cache class)
- promotion reconstructs tensors so slowly that the process OOMs or the
  256 MiB staging ceiling is hit at 2.5k (log `disk_miss_budget`)
- Keychain/DEK path leaves the tier `dormant` on this host
- a disk_hit yields **wrong** `cached_prompt_tokens` or corrupt output
  (`correctness!=ok`)

Then write the decision entry and stop. Do not "just enable paged restore".
That is SPEC-038/039 + a new codec ID (SPEC-037 §8).

---

## 6. Out of scope (do not do)

- KVS-01b (8k) — blocked on Q6/Q7 quantized-KV / ceiling-raise
- KVS-02/03 harness (none exists; do not invent one here)
- KVS-04/05 soaks
- RESEARCH_234 cold idle-evict / RESEARCH_235 thermal soak
- SPEC-038 canary, `continuous_batching: on`, paged-KV attach
- Fleet CLI promote, Pearl join, OpenRouter soak
- `allow_buyer_keys=true`
- CONFORMANCE row flips to `conformant`
- Changing serve cache allocation / `newCache` / ModelRuntime except a
  **blocker fix** that smoke proves is still the Entry-199 no-op on this
  packaged binary. If you must fix code: stay on **one** campaign PR
  (`docs/runbooks/lab-campaign-loop.md`). Iterate with a local
  `swift build -c release` on isolated 18080. Flag stays default-off. Do
  not merge-cut-retest per blocker. When local smoke + 30-cycle PASS, one
  freeze audit, one merge, one packaged candidate — then re-run the
  packaged confirmation. That packaged run is the KVS-01a evidence; a
  worktree binary is not. Prefer reporting the blocker over calling
  KVS-01a green on an unpackaged fix.

---

## 7. House git (short)

```bash
git fetch origin
git worktree add ../macprovider-037-kvs01a -b docs/037-kvs01a-enable-gate origin/main
cd ../macprovider-037-kvs01a
# ... evidence + decision log ...
gh auth switch -u Augustas11
git push -u origin HEAD
gh pr create ...
```

Approve from `antfleet-ops` only after Augustas11 opened it. Merge squash as
Augustas11 when required checks are green. Then sync canonical `main` and
`git worktree remove --force` this sibling.

---

## 8. First message back to the operator

Before loading the 30B model: freeze-check result, chosen binary identity,
chosen port, confirmation that live 8080 was not targeted. Then run smoke.
Then 30 cycles. Then the evidence PR URL + PASS/FAIL in one paragraph.
