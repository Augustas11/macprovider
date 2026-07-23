# Cold/warm TTFT matrix harness (P2)

**P2** from the 2026-07-09 e2e-testing review. P1 (`test/e2e/canary-buyer/`)
measures steady-state serving quality from the buyer vantage. P2 attacks the one
thing P1 doesn't: **cold-start behavior and the latency gates that depend on it.**

## Why this exists (the forcing function)

On 2026-07-09 a cold 30B model load produced a **30,827 ms** canary TTFT in prod.
The W3 canary `max_ttft_ms` gate had been hand-guessed (3500 → padded to 7000)
with **no measured basis**. Tightening it to 3500 — calibrated off the *streaming
buyer* TTFT (~1200 ms warm) — banned a healthy provider three-in-a-row and 503'd
buyers. The fix shipped was to make the latency gates **observe-only**
(`pool.canary_latency_enforcement: observe`, PR #513) — a safety valve, not a
calibration. This harness produces the *real numbers* that let those gates be
tightened back to `enforce` safely, per model class.

### The critical subtlety (this is what bit us)

The pool canary sends `stream:false` (**non-streaming**). Its measured "TTFT" is
the **full non-streaming round-trip** and swings wildly. The **buyer path
streams** and shows the true first-token latency (~1200 ms warm). **These two
numbers are NOT interchangeable.** The `max_ttft_ms` gate is evaluated against
the CANARY's non-streaming regime — so it must be calibrated against *that*.

This harness measures **both regimes side by side**, cold and warm, per model
class:

| Regime | `stream` | What "TTFT" means | Whose number it is |
|--------|----------|-------------------|--------------------|
| `buyer_stream` | `true` | time to first **content token** | what a real buyer feels; the SLO |
| `canary_nonstream` | `false` | **full round-trip** (mirrors coordinator `canaryMetricsFromTiming`: non-streaming → `firstTokenAt` is zero → `ttft = completedAt - start`) | what the `max_ttft_ms` gate sees; the calibration input |

Live confirmation (Pearl, 2026-07-10, observe-mode breach logs over 24h): the
`canary_nonstream` regime breaches even the padded 7000 ms gate on a ~5% tail
with **p95 ≈ 65 s, p99 ≈ 93 s, max ≈ 108 s**, while reporting absurd
`sustained_tps` (17k–33k tok/s). The coordinator logs **only breaches**, so the
warm passing envelope (the `< 7000 ms` probes) is invisible from logs — **this
harness is the instrument that measures it.**

## States (why cold is one-sample-per-cycle)

| State | Meaning | Samples per cycle |
|-------|---------|-------------------|
| `warm` | provider already loaded, steady state | N (batch) |
| `cold` | the **first** request after the model was unloaded / idle-evicted | **1** (the first request warms the model) |
| `post_reboot` | the first request after a full provider process restart | **1** |

Because a cold cycle yields exactly **one** genuinely-cold sample, cold-start
percentiles must be **accumulated over many real cold cycles**. The probe appends
each sample to an append-only NDJSON store; `--build-matrix` aggregates the store
into percentiles. Regimes are **balanced automatically** across cold cycles
(`pickBalancedRegime`) so both fill up, or pin one with `--regime`.

## Safety — read before inducing cold

- **Cold-cycle a LAB provider you own, NEVER the prod `mac` provider.** Churning
  prod caused an **hour-long outage on 2026-07-09**. `cold-cycle.sh` refuses a
  prod `COLDWARM_BASE` unless `COLD_CYCLE_ALLOW_PROD=1` (don't).
- **Do NOT stack coordinator restarts** — rapid coordinator restarts wedge the
  provider CLI's v2 proof-auth (`auth_request proof rejected: type`) and empty
  the pool (issue #519). This harness **never restarts the coordinator**; the
  cold-cycle helper restarts the *provider CLI* at most once per cycle.
- Warm accumulation against **prod read-only is fine** (it's just buyer traffic).
  Only the cold *induction* is lab-only.

## Run it by hand

```bash
export MACPROVIDER_BUYER_TOKEN=mp_...        # or MALIBU_API_KEY; never echoed
cd test/e2e/coldwarm-ttft

# 1. warm baseline — N samples per regime, appended to the store
node coldwarm-probe.mjs --scenario warm --model qwen3-coder-30b-a3b-instruct \
  --samples 20 --store ./matrix.ndjson

# 2. one cold sample (induce cold on a LAB provider first — idle/restart/reboot)
node coldwarm-probe.mjs --scenario cold --state cold \
  --model qwen3-coder-30b-a3b-instruct --store ./matrix.ndjson

# 3. after a provider process restart
node coldwarm-probe.mjs --scenario cold --state post_reboot \
  --model qwen3-coder-30b-a3b-instruct --store ./matrix.ndjson

# 4. aggregate → matrix + advisory calibration + SLO (no token needed)
node coldwarm-probe.mjs --build-matrix --store ./matrix.ndjson \
  --metrics-out /tmp/coldwarm.prom --json-out ./artifacts
```

### Operator cold-cycle helper

`cold-cycle.sh` induces cold out of band then captures the sample:

```bash
# idle lever — wait past the model-unload threshold (no restart)
LAB_MODEL=qwen3-coder-30b-a3b-instruct COLDWARM_BASE=https://<lab-gateway> \
  ./cold-cycle.sh --lever idle --idle-min 12 --state cold

# restart lever — you supply the provider-CLI restart command
PROVIDER_RESTART_CMD='ssh lab-mac launchctl kickstart -k gui/501/tech.malibu.provider' \
COLDWARM_BASE=https://<lab-gateway> \
  ./cold-cycle.sh --lever restart --state post_reboot
```

Loop it: induce cold → capture → repeat. Over many cycles the store accumulates
enough cold samples for a real p99.

## Model id — use the FULL catalog id (not the short rate-card key)

Pass the **full** model id the provider advertises — the one `/v1/status` returns,
e.g. `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` — or leave `--model` /
`COLDWARM_MODEL` unset to auto-derive it from `/v1/status`. Do **not** use the
short rate-card key `qwen3-coder-30b-a3b-instruct`: post-#510 the provider
advertises the full catalog id, and a buyer request for the short id returns
`404 model_not_found` (the coordinator's `ModelKnown` only knows the advertised
full id; there's no `routing.model_classes` alias). This bit the harness on
2026-07-10 — its default was the short id. Same convention as P1's canary-buyer
probe, which derives models from `/v1/status`.

## Schedule it (lab host)

**systemd** (always-on lab Linux host): `coldwarm-warm.{service,timer}` accumulate
the warm baseline every 30 min; `coldwarm-matrix.{service,timer}` rebuild the
matrix every 15 min. See the service headers for install steps. **launchd** (lab
Mac): `com.streamvc.coldwarm-warm.plist` for the warm baseline. Cold cycles stay
operator-driven regardless.

## Output — the matrix

`--build-matrix` emits a Prometheus textfile and a JSON artifact:

```
macprovider_coldwarm_ttft_ms{model,regime,state,quantile}     # p50/p95/p99
macprovider_coldwarm_ttft_samples{model,regime,state}         # accumulated n
macprovider_coldwarm_decode_tps{model,regime,state,quantile}  # p50
macprovider_coldwarm_recommended_max_ttft_ms{model}           # advisory (enforce_ready only)
macprovider_coldwarm_recommended_cold_start_grace_s{model}    # advisory grace sizing
macprovider_coldwarm_cold_start_ttft_p99_ms{model}            # buyer-UX SLO
```

The JSON `recommendations` / `slo` blocks carry the calibration; see
`CALIBRATION.md` for how those numbers become the three P2 deliverables (the
`max_ttft_ms` PR, the prewarm decision, the SLO).

## Configuration

| Var | Default | Meaning |
|-----|---------|---------|
| `MACPROVIDER_BUYER_TOKEN` / `MALIBU_API_KEY` | — | buyer bearer (required to probe) |
| `COLDWARM_BASE` | `https://api.streamvc.live` | gateway base URL |
| `COLDWARM_STORE` | `./coldwarm-samples.ndjson` | append-only NDJSON sample store |
| `COLDWARM_SAMPLES` | `20` | warm samples per regime |
| `COLDWARM_CANARY_MAX_TOKENS` | `16` | non-streaming `max_tokens` — keep == the coordinator's `canary_max_tokens` so the regime matches the gate |
| `COLDWARM_TPS_MAX_TOKENS` | `128` | decode window for the warm TPS sample |
| `COLDWARM_INTERVAL_MS` | `1500` | floor gap between warm samples |
| `COLDWARM_REQ_TIMEOUT_MS` | `90000` | per-request timeout — a cold 30B load was ~30–58 s; must not abort a cold load |
| `COLDWARM_HEADROOM` | `1.5` | calibration headroom multiplier over warm p99 |
| `COLDWARM_MIN_SAMPLES` | `30` | min samples per cell before a gate is recommended (`enforce_ready`) |
| `COLDWARM_ALLOW_INSECURE` | *(unset)* | `1` permits http/localhost/private targets (local mock only) |

The buyer token is redacted from all logs, stdout, and the store even if a
mispointed gateway echoes the `Authorization` header. Same SSRF guards as P1:
`COLDWARM_BASE` must be https + non-private, `redirect: 'manual'` on
token-bearing requests.

## Local smoke test

`mock-gateway.mjs` serves both regimes (and simulates a cold first request) so the
probe logic can be exercised without a live network:

```bash
PORT=8799 node mock-gateway.mjs &
export COLDWARM_ALLOW_INSECURE=1 COLDWARM_BASE=http://127.0.0.1:8799
export MACPROVIDER_BUYER_TOKEN=mp_smoke COLDWARM_STORE=/tmp/cw.ndjson
node coldwarm-probe.mjs --scenario warm --model qwen3-coder-30b-a3b-instruct --samples 5
node coldwarm-probe.mjs --scenario cold --state cold --regime canary_nonstream
node coldwarm-probe.mjs --build-matrix
```

## KVS-01a — KV-survival restart cycle (SPEC-037, FR-KVP13 / §6)

`kvs-01a.sh` is a distinct mode that drives the SPEC-037 restart-survival gate.
Each cycle runs, in order:

1. **persist turn** — a synthetic `conv:kvs-synth:` prefix over the direct-HTTP
   operator path (the FR-KVP11 gate persists it);
2. **persist barrier** — wait for `disk_write_committed` in the provider stderr
   (persist-before-kill);
3. **kill + relaunch** — SIGKILL the provider, relaunch the exact build/model;
4. **template-seed turn** — a warm turn on a **different** throwaway
   `conv:kvs-synth:` key, *before* the measured restored turn, so the
   freshly-restarted adapter learns the live-model geometry template (see the
   residual below); barrier on its `disk_write_committed`;
5. **restored turn** — re-send the *same persisted prefix* + one new suffix token
   within the eligibility window; it must promote from disk (`disk_hit`) and
   report `cached_prompt_tokens` **equal to the persisted prefix's
   `prompt_tokens`** by the unchanged LCP rule.

The probes no longer mask failures: **the harness exits nonzero** if any probe
fails, if no `disk_write_committed` appears, or if the restored arm does not
record `disk_hit` with the exact expected `cached_prompt_tokens`. This is a real
pass/fail gate, not a data-collection dry run.

It is **harness capability, not a CI run** — it launches a real model. Like the
cold-cycle path it refuses a production coordinator (`§6` production fence): the
target must be a **local provider you own**, with the tier enabled
(`kv_disk_cache.enabled=true`).

```bash
export KVS01A_PROVIDER_CMD="macprovider-cli serve --config /path/to/local.yaml"
export KVS01A_BASE=http://127.0.0.1:8080
export KVS01A_PROMPT_TOKENS=2500          # v1 allowlist class under the 256 MiB ceiling; 8k is KVS-01b
./kvs-01a.sh --cycles 20                   # or KVS01A_CYCLES=20
```

`--cycles N` (or `KVS01A_CYCLES=N`) runs N full cycles interleaved and prints a
**nearest-rank** TTFT percentile summary (`p50/p90/p99/min/max`) over the restored
arm — the number that matters for the restart-survival latency story. Nearest-rank
means the p-th percentile is the sample at 1-based rank `ceil(p/100 · n)` of the
sorted samples (no interpolation), so with a handful of cycles the percentiles are
honest picks of real samples rather than smoothed estimates.

Each cycle appends one §6 record (regime `kvs01a_restored`) to `$KVS01A_STORE`
(default `~/.local/state/kvs-01a/samples.ndjson`): `cycle`, `disk_reason`
(hit/miss code), `cached_prompt_tokens`, `prompt_tokens`, `ttft_ms`,
`total_latency_ms`, `restore_bytes`, `restore_ms`, `staging_peak_bytes`,
`commit_serialized_bytes`, and `commit_latency_ms` (write-path overhead).
`prompt_tokens` stays the full incoming length; `cached_prompt_tokens` is the
promoted prefix length. `kvs-01a-probe.mjs` is the request half (one streaming
turn), re-usable stand-alone for the warm/cold/seed arms.

### Residual: load-time geometry capture (HIGH-3)

The disk tier can only promote a restored entry once the process holds a
**live-model geometry template** to validate the persisted manifest against. That
template is currently learned lazily, from the first `captureSnapshot` **commit**
in the process — so the very first turn after a restart has no template and cannot
promote (the KVS-01a-critical case). The clean fix is **load-time geometry
capture**: build the template at model-load time. A *config-derived* template was
deferred because the exact KV tensor geometry the envelope compares byte-for-byte
— the dims order, the sequence axis, and especially the runtime KV **dtype**
(f16/bf16, and whether KV quantization is engaged) — is not reliably reconstructable
from static model config across architectures, and a wrong-but-passing template
would be worse than none. Until load-time capture lands (a persist-and-seed of the
learned template across restarts is the recommended, model-hash-fenced approach),
step 4 above **seeds the template explicitly** with a throwaway warm turn before the
measured restored turn. This is belt-and-braces and is kept even once fix (a) lands.
Model-hash fencing in envelope validation means a stale/foreign template can only
ever cause a *miss*, never an incorrect promotion.
