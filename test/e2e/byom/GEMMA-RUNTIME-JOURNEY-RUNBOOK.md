# JOURNEY-OLLAMA-LOOPBACK-RUNTIME physical run (issue #1569)

**Issue:** #1569. **Runner:** `test/e2e/byom/gemma_runtime_journey.py`.
**Sibling lane:** the slice-7 `admission_journey.py` / `ADMISSION-JOURNEY-RUNBOOK.md`.

This lane proves the #1569 end-to-end contract: a **single**
`macprovider-cli serve` process serving `ollama:gemma3:270m` through the
`ollama_loopback` adapter, the coordinator's synthetic probe reaching **that**
live session over the provider wire, real tokens coming back, and the candidate
staying **non-earning**. It is a separate run from the twelve-step admission
journey and reuses that journey's vetted rig plumbing and the shared
`byom_journey_evidence` redaction contract; it does not modify or weaken any
admission-journey assertion.

## What the run proves, and what it deliberately does not

- One serve process, one model. The runner starts it, records its PID, and
  tears down **only that PID**. It never signals `macprovider-cli` by name.
- The serve hello is `runtime_source = ollama_loopback` serving
  `ollama:gemma3:270m`, bound by a `macprovider.gguf-file.v1` file digest (never
  an Ollama manifest/layer digest). A Llama hello fails the run.
- `models offer ollama:gemma3:270m --yes` is coordinator-backed and the
  candidate stays uncatalogued (`catalog_model_key` null).
- The coordinator synthetic probe reaches this session over the authenticated
  provider wire (no dereferenceable locator held coordinator-side), **passes**
  (`synthetic_probe_passed` → `network_admitted_unsettled`), and the coordinator
  records `synthetic_probe_completion_tokens > 0`.
- This is the flip versus admission-journey **step 10**, whose Llama-session
  case legitimately fails the probe (`synthetic_probe_failed`). That step is
  unchanged; this is a distinct lane for the Gemma-runtime case.
- Still non-earning: never `catalog_priced`/`settlement_capable`, null
  economics, the request log does not advance (not buyer-routable), and all ten
  money-path ledgers are zero.

The run does **not** move money and involves no gateway or buyer traffic.

## Gate-off posture (decided; do not change)

The rig coordinator runs with `require_autotune_hello_gate = false` (the config
default). In that posture the uncatalogued `ollama:gemma3:270m` hello is admitted
as a live session and stays **non-buyer-serving** — but note *why*, because the
mechanism differs from the gate-ON path:

- **Gate-ON (production):** the hello gate hard-closes an uncatalogued model, or
  (where it admits) marks the session `HashStatusUncatalogued` /
  `AdmissionCeilingExcluded`, which removes it from `RoutingEligible` /
  `ServingCapable`. Production is unchanged by this lane.
- **Gate-OFF (this rig):** those ceiling flags are *cleared*, so the pool-level
  session is routable. The buyer-exclusion instead holds one layer up, at the
  money-path admission gate: an uncatalogued candidate keeps a null
  `catalog_model_key`, can never reach a settlement / `catalog_priced` state, and
  is therefore not `ModelAdmissionDefaultPaidRoutingEligible`
  (`byomDefaultPaidRoutingEligible` → `ReasonBYOMNonSettlement`). Buyer
  `/v1/models` is catalog-gated, so no buyer request maps to the session, and
  receipts are disabled on the loopback path — nothing can settle or earn.

**Production stays gate-ON** and still hard-closes uncatalogued models. This
lane is a non-earning proof of the loopback runtime path, so it runs gate-OFF on
purpose; do not weaken the gate-ON path, and do not treat this posture as a
SPEC-032 change.

## Preconditions

| Need | Why |
|---|---|
| A Mac that is not a live earner | The run starts a provider and mutates rig coordinator state |
| A **running loopback Ollama** with `gemma3:270m` pulled (`ollama pull gemma3:270m`) | serve proxies the synthetic probe to the loopback origin; discovery resolves the served GGUF and computes its `macprovider.gguf-file.v1` digest |
| One `macprovider-cli` binary (the candidate build) | The run serves and offers from a single binary |
| Rig coordinator with the ten money-path ledgers and `require_autotune_hello_gate=false` | Admission store + the zero-ledger measurement |
| One operator actor under `auth.operator_keys` | The single bearer that reads the offer listing |
| `psql` (or a SQLite ledger path) reachable for the ledgers | `money_path_zero_rows` is measured, not declared |
| The rig coordinator log, as a file | Step 7 (redaction) reviews what it appends during the run |

The provider serve log is **created by the runner** (`--provider-log`); it is not
a pre-existing file the operator must provision.

## Secrets

The operator secret and ledger DSN are read from environment variables named on
the command line; their values never appear in argv, logs, captures, or the
manifest, and the redaction review fails the run if they do. Every subprocess
the runner starts (serve, the CLI, `psql`) gets a scrubbed environment: the
operator secret variable, the DSN variable and every `PG*` variable are dropped.
`MACPROVIDER_OLLAMA_ORIGIN` is **not** a secret and is preserved so serve and
discovery honour the operator's loopback origin; its value is also treated as a
redaction needle.

```bash
export MACPROVIDER_JOURNEY_OPERATOR_A=...      # the operator actor's bearer key
export MACPROVIDER_JOURNEY_LEDGER_DSN=postgres://...   # read access to the ten tables
# Optional: override the loopback Ollama origin (default http://127.0.0.1:11434).
# It must be a loopback origin; serve fails closed on anything else.
export MACPROVIDER_OLLAMA_ORIGIN=http://127.0.0.1:11434
```

## Run

```bash
test/e2e/byom/gemma_runtime_journey.py \
  --out ~/gemma-runtime-run \
  --cli-binary <candidate macprovider-cli> \
  --provider-config ~/.config/macprovider/config.yaml \
  --coordinator-admin-origin http://127.0.0.1:18444 \
  --operator-actor rig_a \
  --served-ref ollama:gemma3:270m \
  --provider-log ~/gemma-runtime-run/serve.log \
  --coordinator-log <rig coordinator log file> \
  --serve-log-level warning \
  --discovery-arg --skip-lmstudio --discovery-arg --skip-llamacpp \
  --discovery-arg --skip-openai-compatible
```

`--out` must be new or empty. A failing run publishes no manifest. The runner
creates `--provider-log`, starts exactly one serve process there, and always
tears that PID down (SIGTERM then SIGKILL) in a `finally` block, pass or fail.

### The serve command the runner starts, exactly

```
macprovider-cli serve --model ollama:gemma3:270m \
  --config <provider-config> --log-level <serve-log-level> [--serve-arg ...]
```

One process, one model. The runner records this command (paths redacted) in its
own transcript, tracks the child PID, and never starts or signals a second
serve. **Do not run `pkill macprovider-cli` (by binary name) to clean up** — a
production serve may run on this same Mac; the runner targets only the exact PID
it started, and so must you if you intervene.

## Keep the serve log quiet

Step 7 reviews the bytes the serve log gains **after startup settles** (the
runner draws the review baseline once the loopback candidate is discoverable, so
serve's startup lines — which may name the coordinator URL — are excluded, while
the probe-time bytes are included). serve must not append a URL, filesystem path
or IP literal during the probe, or the redaction review fails. Run serve at a
quiet level (`--serve-log-level warning`, the default; `notice` is also fine) and
keep debug/request logging off for the duration of the run. Point
`--coordinator-log` at the rig coordinator log at its default level for the same
reason (the admission operator surface logs `remote_addr` only on the
ambiguous-bearer warning path).

## Assertions (each fails the run)

1. **One serve, Gemma-loopback identity.** Exactly one runner-owned serve
   process; discovery shows the `ollama:gemma3:270m` candidate as
   `runtime_source = ollama_loopback` with `identity_state` in
   `{catalog_matched, artifact_hash_available}` — the proxy that the served bytes
   are bound by the CLI's own `macprovider.gguf-file.v1` file digest, not a
   runtime-reported Ollama digest. Read from `models discover --json` plus the
   coordinator offer-listing **session block** (`session.runtime_source`,
   `session.served_model_ref`). A Llama served ref anywhere fails.
2. **Coordinator-backed offer, uncatalogued.** `models offer ... --yes` returns
   a coordinator-backed `model_admission_status.v1` with a coordinator event id
   and `catalog_model_key` null.
3. **Probe over the provider wire.** The coordinator offer item exposes no
   dereferenceable locator (`endpoint`, `origin`, `socket`, `url`, `*_path`,
   …), so the probe reached the session only over the authenticated wire.
4. **Probe passed.** The offer item reaches `synthetic_probe_passed`
   (coordinator-origin) and state `network_admitted_unsettled`;
   `catalog_priced`/`settlement_capable` never appear. `synthetic_probe_failed`,
   `revoked`, timeout, or a Llama hello fail the run.
5. **Token proof.** `synthetic_probe_completion_tokens` on that item is a
   positive integer.
6. **Still non-earning.** Status stays uncatalogued with
   `earning_path_class = no_earning_path_in_v0_1`; `models catalog-economics`
   shows the row `blocked` / `rate_source none` / `settlement_capable false`
   with null rates; the request log does not advance (not buyer-routable); and
   the ten money-path ledgers are all zero.
7. **Redaction.** The runner log, the CLI/operator transcript, every captured
   document, the coordinator offer listing, and the provider and coordinator
   logs are reviewed; no operator secret, ledger credential, Ollama origin, URL,
   filesystem path, IP literal, raw prompt (`Reply with ok.` or a chat request
   shape) or raw completion (a chat response shape) is persisted in any of them.

Where each readback field comes from:

| Assertion | Field | Surface |
|---|---|---|
| 1 | `runtime_source`, `served_model_ref`, `identity_state` | `models discover --json` candidate |
| 1 | `session.runtime_source`, `session.served_model_ref` | `GET /admin/model-admission/offers` item |
| 2 | `admission_state_source`, `coordinator_event_id`, `catalog_model_key` | `models offer --yes` status |
| 3 | absence of locator keys | `GET /admin/model-admission/offers` item |
| 4 | `admission_state`, `reason_code`, `last_event_actor` | `GET /admin/model-admission/offers` item |
| 5 | `synthetic_probe_completion_tokens` | `GET /admin/model-admission/offers` item |
| 6 | `earning_path_class`, economics row, `request_log`, ledger counts | `models admission status`, `models catalog-economics`, ledger read |

## After the run

The run emits `~/gemma-runtime-run/run-manifest.json`
(`schema_version: macprovider.gemma-runtime-journey.v1`) plus distilled,
redaction-clean capture documents under `captures/`. Attach the manifest and
captures to the #1569 evidence trail. A live run additionally needs, from the
operator: a running loopback Ollama with `gemma3:270m` pulled, the rig
coordinator running gate-off with the ten ledgers reachable, and the operator
bearer for `--operator-actor`.
