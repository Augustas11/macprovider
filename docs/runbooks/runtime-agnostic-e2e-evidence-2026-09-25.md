# #1690 real-engine e2e: delivered-only billing and signed settlement finality (2026-09-25)

**Issue:** #1690, epic PR #1719. **Code under test:** `bench/1690-loopback-vs-native`
at `d5dd3334` (includes `551fd876`, the finality-lookup change). Every lab
binary (coordinator, coordinator-cli, gateway, labtool, lab CLI, lab native
CLI) was built on the Mac Studio from one export of the harness branch
`e2e/1690-harness`, whose only diff from `d5dd3334` is `scripts/lab/**` and
this doc. Mixed pairings used `origin/main` `d967bc6d` coordinator and gateway
binaries built from a detached `origin/main` worktree.
**Host:** Mac Studio (M3 Ultra, 256 GB), isolated 127.0.0.1:191xx, lab dirs
`/Users/a1/lab-1690-m6/e2e`, `.../e2e-mixA`, `.../e2e-mixB`.
**Harness:** `scripts/lab/1690-e2e/` (new) plus `scripts/lab/1690-m6/`
(`rig.sh`, `serve.sh`, `write_configs.py` extended). Model: Qwen2.5-0.5B
(MLX 4-bit for native and mlx_lm.server, Q4_K_M GGUF for llama.cpp, Ollama
`qwen2.5:0.5b`).

## Result

The new #1690 mechanisms held in every run. Gateway negotiation, delivered-only
recording, signed finality trailers on non-streaming and streaming responses,
the signed `legacy` tuple, the gateway pin, and engine selection all behaved as
specified. With the pin on, normal traffic produced **0**
`missing_settlement_finality_trailer` holds in every engine run. Every tampered
or stripped trailer held and then settled at the coordinator's finality, with
two exceptions:

- F7: a stripped declaration with the pin off, a designed downgrade.
- F5: stuck holds from an unrelated cause.

External engines earned only inside the Trusted Pool. A global-route loopback
never reached dispatch.

The matrix also found **ten defects**. Four are HIGH, and they are money-path.

- **F2:** every stream past about 280 tokens is cut off by the gateway, on every
  engine, and the delivered part is free.
- **F4:** a buyer that disconnects on a fast engine is billed the full generation.
- **F5:** a verified receipt on a quarantined credit makes the coordinator
  finality lookup return 500 forever, leaving a stuck hold.
- **F9:** after a receipt-key rotation, the CLI omits every receipt until restart.

F1, F2 and F6 also reproduce with the origin/main coordinator, so they predate
#1690. The findings are listed below with repros.

Every case that ran is in the tables; nothing skipped is counted as passed.

## Matrix

Per label: requests sent, HTTP statuses, invariant checks passed, and every failed check
tagged with the finding it matches (`summarize.py`; 0 unclassified failures in
R1, R2, MIXA native, MIXB). Evidence per request (buyer view, gateway
reservation and usage row, coordinator request_log, ledger rows with
payability, receipt verdicts, route snapshots, attempt outputs, and the
coordinator finality) is in `LAB/e2e/results/<label>.json`; the tables are
`LAB/e2e/summary-{R1,R2,MIXA,MIXB}.md`.

Invariants checked per request (`matrix.py`): `no_hold`, `debit_eq_settled`,
`credit_has_evidence`, `credit_implies_debit`, `no_undelivered_bill`,
`delivered_not_free`, `buyer_usage_eq_debit`, `stream_complete`.

Shapes: `plain` (32 tok), `tool` (tools + `get_weather`), `long` (700 tok),
`cap` (max_tokens 8), each streaming and non-streaming. Behaviours: `normal`,
`disconnect` (stream, close after 4 content events), `slow` (small receive
buffer, 50 ms per line), `early_close` (non-stream, close after headers),
`abort` (close 0.5 s after sending, before headers).

### Run 1 and Run 2 (enforce coordinator, pin off and on)

| Engine x route | R1 pin0 | R1 pin1 | R2 pin0 | R2 pin1 | Failures (both runs) | Post-fix (`97b22eb3`) |
|---|---|---|---|---|---|---|
| native, pool A + global (32 req) | 202/236 | 207/227 | 199/234 | 202/236 | F1, F2, F3, F4, F5 (stuck holds 2/1/2/2), F6 | R1 213/240, 217/231; R2 217/240, 213/231. 0 stuck holds; F2, F4, F5 fixed. Left: F1, F3, F6 (expected), **F13 new** |
| llama.cpp, pool A + global refusals (21 req) | 133/146 | 133/146 | 133/146 | 133/146 | F1, F2, F3 | pin1 139/148: F2 fixed; left F1, F3 |
| mlx_lm.server, pool M + global refusals (21 req) | 130/140 | 129/138 | 130/140 | 131/142 | F1, F2, F3 | pin1 137/144: F2 fixed; left F1, F3 |
| Ollama, pool O + global refusals (21 req) | 133/146 | 133/146 | 133/146 | 133/146 | F1, F2, F3 | pin1 139/148: F2 fixed; left F1, F3 |
| Engine selection, 9 selectors x (global, A, M, O), per engine (36 req) | all PASS except F1 on served 200s | same | same | same | F1 only | not re-run |

What passed everywhere:

- **External engines on the pool route:** normal-read plain, tool (JSON→SSE)
  and cap requests, streaming and non-streaming, are `verified`,
  `pool_operator_attested` and credited. The buyer is debited exactly the
  finality tokens. No hold remains.
- **Global route for external engines, with or without the selector:** 503
  (`byom_non_settlement_unavailable` / `engine_unavailable`) before
  reservation or dispatch, with no ledger credit.
- **Engine selection:**
  - Each value selects its own class.
  - An unavailable engine gets 503 `engine_unavailable`.
  - `LLAMACPP`, `vllm` and two conflicting headers get 400
    `invalid_engine_selection`.
  - An empty header behaves as absent.
  - `X-MacProvider-Engine` discloses the served class.
- **Aborts and closes:**
  - `abort` bills nothing and credits nothing.
  - `early_close` (non-stream, headers already received) settles the full body
    as delivered, consistently on both sides.
- **Capped output:** `cap` bills exactly 8 completion tokens.

### Faults (llama.cpp member on pool A; rotation on native)

| Case | R1 | R2 | Notes |
|---|---|---|---|
| proxy `pass`, pin 0/1 | PASS (F1 only) | PASS (F1 only) | 0 holds |
| proxy `strip_capability`, pin 0 | PASS (F1 only) | PASS | coordinator falls back to record-before-write, unsigned headers; settles |
| proxy `strip_capability`, pin 1 | PASS | PASS | 2 `missing_settlement_finality_trailer` holds, reconciled to coordinator finality |
| proxy `strip_trailers`, pin 0/1 | PASS | PASS | non-stream holds (1), reconciled |
| proxy `strip_decl`, pin 0 | **FAIL F7** | **FAIL F7** | downgraded to local `provider_reported` settlement, debit 44 vs settled 37 |
| proxy `strip_decl`, pin 1 | PASS | PASS | 2 holds, reconciled |
| proxy `strip_mac`, pin 0/1 | PASS | PASS | 1 / 2 holds, reconciled |
| proxy `tamper_mac`, pin 0/1 | PASS | PASS | 2 holds each, reconciled; never debited from the tampered tuple |
| proxy `tamper_outcome` ("refunded"), pin 0/1 | PASS | PASS | 2 holds each (MAC mismatch), reconciled to `verified`; never refunded from the forged tuple |
| engine killed mid-stream (llama-server stopped) | PASS | PASS | R1b: stream cut by F2 first; R1 (non-stream attempt) 502 + null_error, no credit, refund |
| receipt-key rotation mid-stream (native) | not staged (harness, see below) | **FAIL F9** | rotation accepted; every later request `receipt_omitted construction_failed` → quarantined, refunded. **Post-fix `PF-rotate`: PASS** (53/56, F1 only): the in-flight stream and all 6 later requests verified, 0 `receipt_omitted` |

R1 `rotate`, R1b `rotate` and R1c `rotate` did not rotate. The harness looked
for the control socket at the wrong path. An `--isolate-lifecycle` serve binds
`/private/tmp/macprovider-autotune-<uuid>/control.sock`, and R1/R1b also ran
it on llama.cpp, which exposes no control surface. Those labels only cover
plain native/llama traffic. R2 is the only real rotation run.

A previous-key receipt can't be forged from the rig (the CLI signs with its
current key), so "a previous-key receipt is rejected" was **not staged**. The
nearest real case, rotation with a stream in flight, is F9.

### Observe mode (coordinator `verified_model_settlement_mode: observe`)

| Case | R1 | R2 | Notes |
|---|---|---|---|
| llama.cpp on enforce pool A | PASS | PASS | 12/12 503 `pool_settlement_mode_unsatisfied`, no dispatch |
| native, pool NO (native-only, observe) + global (32 req) | 204/236, 203/228 | 204/236, 202/230 | F2, F5, F6, **F8**. Post-fix R1: 216/240, 214/232; F2 gone; left F8 (documented), F6, one F4-by-design gap |
| native on enforce pool A | 60/62 | 60/62 | 503 on pool A (correct); global F8 |

An observe pool for an external engine can't be created: a v2 core with a
non-empty `runtime_allowlist` must be `enforce`
(`poolmanifest/manifest.go:279`, `errRuntimeAllowlistObserve`). This is by
design. My first attempt, pool AO, returned `invalid_event` because of this
(a harness error), and the coordinator logged no reason (LOW).

### Mixed versions

| Pairing | Case | Result |
|---|---|---|
| A: new coordinator + origin/main gateway | native global + pool A (24 req) | 155/184, same F1/F2/F5/F6 pattern as the new gateway: **baseline holds** |
| A | llama.cpp pool A (17 req) | 60/120: **all 12 pool 200s held forever**; the old gateway rejects `pool_operator_attested` finality ("not settlement-capable") while the provider credit is payable (**F10**). **Post-fix: PASS 85/85**: all 13 pool requests 503 before dispatch, 0 route snapshots, 0 ledger rows, 0 upstream calls, every reservation refunded, 0 held |
| A | global refusals | old gateway ignores `X-MacProvider-Engine-Select` (503 `byom_non_settlement_unavailable`), expected |
| B: origin/main coordinator + new gateway | coordinator start on the #1690 feed | **fails to start** (**F11**): `unknown field "file_path"`, then `runtime source "mlxlm_loopback"`. Post-fix (unstripped feed): still exits (expected; the fix is operational); step 4a flags it on a YAML config, see **F12** |
| B | native global, feed stripped of #1690 fields and re-signed (11 req) | 74/84, F1/F2/F6 only: **baseline holds**; new gateway reads old coordinator's header finality |
| B | any pool | not run: the old coordinator rejects the v2 policy core (`invalid_event`), by design |
| B | llama.cpp | not run: the old coordinator cannot price a loopback candidate; fail closed, by design |

The Pin column doesn't apply to pairing A (the old gateway has no pin). Pairing
B ran pin off only.

## Resolution (2026-09-25, on top of `39b51ce1`)

Attribution was checked against `origin/main` (`696dfc72`). Each code fix
has a regression test that fails with the fix reverted and passes with it.

| Finding | Sev | Attribution | Resolution |
|---|---|---|---|
| F1 prompt bound | MEDIUM | Pre-existing: `hotpath.go` `boundProviderReportedPromptTokens` and `estimateTokens(req.raw)` are on origin/main; MIXB reproduces it. | CARRIED. The bound counts request bytes, not rendered template or tool-schema tokens. Raising it changes what every buyer pays for prompts (SPEC-005 pricing), so it needs a SPEC-005 decision on a template-aware bound; it is not a settlement defect. Its money-path consequence, F5, is fixed. |
| F2 metadata ceiling | HIGH | Pre-existing: `maxStreamingFallbackMetadataBytes` dates from #354 (`dabf188b`); #1690's per-token loopback relay made it reachable on every engine. | FIXED `de721874`: `chat_proxy.go:1586` uses `streamingFallbackMetadataCeiling` (`chat_proxy.go:3320`), 64 KiB plus 512 bytes per requested completion token, still a hard bound set by max_tokens (which the gateway caps at its configured limit); the fallback estimate stays capped at max_tokens. Tests `TestStreamingMetadataCeilingScalesWithCompletionBudget`, `TestStreamingMetadataCeilingStillStopsPadding`. Why the lab hits it and production rarely does: the rule trips on the count of frames in one stream (64 KiB / about 230 bytes per per-token frame, about 280 frames) whatever the usage path; the lab's `long` shape asks for 700 tokens on every engine, and production logged 5 in 3 days, so few production streams run past about 280 frames. Pearl was not queried in this pass. |
| F3 loopback disconnect free | MEDIUM | New path (#1690 loopback relay). | CARRIED to the Swift agent; no coordinator change needed. The coordinator already bills a loopback `buyer_cancel` partial when the provider end carries one: `withProviderCancelTerminal` (`buyer/server.go:10284-10313`) adopts the end's usage for a loopback runtime when the receipt's `delivered_output_bytes` equals the coordinator-observed delivered prefix. The loopback relay (`OpenAICompatibleLoopbackRuntime.swift`) must, on a buyer cancel, end with status `cancelled`, a pool-authorized v0.4 `buyer_cancel` receipt binding the delivered prefix bytes (as `InferenceRelay.swift:1098-1119` does for native), and a usage object with prompt and completion tokens for that prefix. Until then the partial stays free, which SPEC-022 R-5.6 / AC-022-14 allow (no binding, quarantined, refunded). |
| F4 disconnect billed in full | HIGH | Pre-existing: origin/main holds a `client_disconnect` local terminal and the reconciler debits the coordinator finality in full the same way; #1690's delivered-only claim did not cover the gateway-to-buyer hop. | FIXED `550dc3c7`: the reconciler debits a verified `client_disconnect` hold for the smaller of the coordinator completion and the completion the gateway delivered (`buyerDeliveredCompletionBound`, `settlement_reconcile.go:522`, `:720`), prompt from the coordinator. The provider stays credited for the prefix delivered to the gateway, which its receipt binds (SPEC-022 v0.2.2 R-5.6 addendum); the gap is billed to neither party. Signed finality is unaffected: a gateway-ended stream never reads its trailers and always reconciles. Test `TestSettlementReconcileBoundsVerifiedCompletionByBuyerDelivery`. |
| F5 finality 500 forever | HIGH | Pre-existing lookup: origin/main `requestSettlementUsage` has the same `lrc.quarantined = 0` join and error; the trigger is the F1 bound followed by the cached-token quarantine, both on origin/main. | FIXED `065dbe2c`: a verified attempt whose credits are all quarantined closes `zero_settled` / `valid`, reason `verified_receipt_credit_quarantined` (`settlement_finality.go:278`, `:680`, `:717`); the gateway refunds, the quarantine stands, neither side is paid (SPEC-022 R-8.4 addendum). All seven stuck lab holds in `LAB/db/gateway.db` are this shape (verified verdict, credit quarantined `invalid_cached_prompt_tokens`); the fixed lookup, run against a copy of `LAB/db/coordinator.db`, returns closed `zero_settled` / `valid` for each of the seven. Test `TestVerifiedReceiptOnQuarantinedCreditClosesZeroSettled`. |
| F6 native tool stream | MEDIUM | Pre-existing (MIXB, origin/main coordinator). | CARRIED. Root cause is the native CLI ending a tool-call stream with `finish_reason: "stop"` (Swift agent: emit `tool_calls` whenever tool-call deltas were sent). The coordinator fails closed (refund, no credit); moving its error frame before `[DONE]` means holding `[DONE]` back on every streaming path, not a small change. |
| F7 strip_decl, pin off | LOW | By design (runbook step 2a). | No change. |
| F8 observe divergence | MEDIUM | Pre-existing observe semantics (SPEC-022 R-7.7 keeps the local fallback rules in observe mode). | DOCUMENTED in SPEC-022 v0.2.2. Its parts: non-streaming 44 vs 37 is F1; truncated streams billed 0 are F2 (fixed); disconnects follow the F4 rule (buyer pays what reached the buyer, provider credited for what reached the gateway). |
| F9 rotation omits receipts | HIGH | CLI (Swift). | Handled by the Swift agent in its own worktree. |
| F10 old gateway holds pool traffic | MEDIUM | New in #1690 (external-runtime pool routing, M4b). | FIXED `12bc0ed2`: the coordinator withholds a pool's runtime allowlist unless the request negotiated signed settlement finality (`buyer/server.go:7089`, `:7112`, `:7340`); the request fails closed before dispatch with 503 `byom_non_settlement_unavailable` (or `engine_unavailable` for an explicit engine) naming the negotiation. SPEC-022 R-12.8 bullet; runbook section 9 step 4. Test `TestSPEC042ExternalRuntimeRefusedWithoutSettlementTrailerNegotiation`. |
| F11 rollback on #1690 feed | HIGH | New in #1690 (M4a `file_path`, M8 `mlxlm_loopback`). | FIXED in the docs commit: runbook section 9 step 4a (feed check, then a signed catalog release that withdraws both tuples before the coordinator rollback) and a SPEC-022 R-12.8 rollback bullet. Making the feed backward compatible is not cheap: the older binary strict-decodes and cannot be changed retroactively, so any published `file_path` or `mlxlm_loopback` breaks it. |
| Hardcoded production URL | LOW | CLI (Swift). | For the Swift agent: `AutotuneRecommend.swift:1954,1968` GETs `https://coordinator.malibu.tech/v1/<name>` on every serve preflight; a lab build should take the coordinator URL from its config. |

Lab re-run needed to confirm on real engines (same harness, a fresh `LAB`):
`R1-native-pin0`, `R1-native-pin1`, `R2-native-pin0`, `R2-native-pin1` (F4, F5, F2);
`R1-llamacpp-pin1`, `R1-mlxlm-pin1`, `R1-ollama-pin1` (F2 `long/s/*`);
`R1-observe-native-pin0`, `R1-observe-native-pin1` (F8 after F2 and F4);
`MIXA-llamacpp-pin0` (F10: expect 503 before dispatch, no holds, no credit);
`MIXB-native-pin0` with the unstripped #1690 feed, only to confirm the step 4a
check flags it (the fix is operational).

## Post-fix re-run (bench `97b22eb3`, 2026-09-25)

**Code:** `bench/1690-loopback-vs-native` at `97b22eb3` (F5 `065dbe2c`, F10
`12bc0ed2`, F4 `550dc3c7`, F2 `de721874`, F11 docs `5c4a7c94`, F9
`97b22eb3`, harness `39b51ce1`). **Harness:** `e2e/1690-postfix` on top of
it. Every lab binary was rebuilt from that tree into a fresh
`LAB=/Users/a1/lab-1690-m6/e2e-post`: coordinator, coordinator-cli, gateway,
labtool, the lab CLI, and the lab native CLI with the `static_swift` patch
(confirmed in both exported trees). Mixed pairings: fresh
`e2e-post-mixA` / `e2e-post-mixB` with the same origin/main `d967bc6d`
binaries. Driver: `LAB/postfix.sh`; log `LAB/postfix.out`.

**Memory guard:** another agent's lab (`/Users/a1/lab-1690-f9`, F3 work) runs
on the Studio. Before every engine start, the driver waited while any
`lab-1690-f9` serve or engine process existed. It waited once, 06:31:27 →
06:32:27Z. Memory stayed ≥ 98% free.

That lab uses the same 127.0.0.1:191xx ports as this rig. Its stack started at
06:57:05Z, 13 s after this re-run finished (06:56:52Z), so there was no overlap.
Two such rigs can't run at once, and a stack bound on a port makes the other
rig's `rig.sh up` fail instead of mixing traffic.

**Live provider:** `:8080` (now PID 84503, rolled back to 1.8.192 by another
session) was up before and after, and was never signalled.

### Per invariant (post-fix, pass/total)

| Label | no_hold | debit_eq_settled | credit_has_evidence | credit_implies_debit | no_undelivered_bill | delivered_not_free | buyer_usage_eq_debit | stream_complete |
|---|---|---|---|---|---|---|---|---|
| R1-native-pin0 | 32/32 | 31/32 | 32/32 | 32/32 | 32/32 | 21/28 | 10/26 | 23/26 |
| R1-native-pin1 | 32/32 | 31/32 | 32/32 | 32/32 | 32/32 | 23/25 | 12/23 | 23/23 |
| R2-native-pin0 | 32/32 | 32/32 | 32/32 | 32/32 | 32/32 | 22/28 | 12/26 | 23/26 |
| R2-native-pin1 | 32/32 | 30/32 | 32/32 | 32/32 | 32/32 | 22/25 | 10/23 | 23/23 |
| R1-llamacpp-pin1 | 21/21 | 21/21 | 21/21 | 21/21 | 21/21 | 14/15 | 6/14 | 14/14 |
| R1-mlxlm-pin1 | 21/21 | 21/21 | 21/21 | 21/21 | 21/21 | 12/13 | 6/12 | 14/14 |
| R1-ollama-pin1 | 21/21 | 21/21 | 21/21 | 21/21 | 21/21 | 14/15 | 6/14 | 14/14 |
| R1-observe-native-pin0 | 32/32 | 14/32 | 32/32 | 32/32 | 32/32 | 28/28 | 23/26 | 23/26 |
| R1-observe-native-pin1 | 32/32 | 14/32 | 32/32 | 32/32 | 32/32 | 25/25 | 23/23 | 24/24 |
| PF-rotate (native) | 7/7 | 7/7 | 7/7 | 7/7 | 7/7 | 7/7 | 4/7 | 7/7 |
| MIXA-llamacpp-pin0 | 17/17 | 17/17 | 17/17 | 17/17 | 17/17 | - | - | - |

`no_hold`, `credit_has_evidence`, `credit_implies_debit` and
`no_undelivered_bill` pass on every request of every post-fix label (0 stuck
holds; pre-fix native left 1-2 per label). Every failed check is classified
(`summarize.py --lab .../e2e-post`, 0 unclassified):

| Label | Failed checks by finding |
|---|---|
| R1-native-pin0 | F1 x10, F6 x11, F3 x1, F5-fixed x2, F4-fixed x1, **F13 x2** |
| R1-native-pin1 | F1 x10, F5-fixed x2, F4-fixed x1, **F13 x1** |
| R2-native-pin0 | F1 x10, F6 x9, F3 x1, F5-fixed x2, **F13 x1** |
| R2-native-pin1 | F1 x10, F6 x2, F5-fixed x2, F4-fixed x2, **F13 x2** |
| R1-llamacpp-pin1 / R1-mlxlm-pin1 / R1-ollama-pin1 | F1 x8 / x6 / x8, F3 x1 each |
| R1-observe-native-pin0 / pin1 | F8 x18 / x17, F6 x6 / 0, F4-fixed 0 / x1 |
| PF-rotate | F1 x3 |
| MIXA-llamacpp-pin0 | none |

`F4-fixed` and `F5-fixed` are the fixes' designed outcomes, which the pre-fix
invariants still count as failures:

- **F4-fixed:** a disconnected buyer is debited only what reached it (13-16
  completion tokens), while finality and the provider credit keep the
  gateway-delivered count (411-700). That is the designed gap, "billed to
  neither party", so `debit_eq_settled` reports it.
- **F5-fixed:** closes `zero_settled` / `verified_receipt_credit_quarantined`;
  the buyer is refunded and the credit stays quarantined, so
  `delivered_not_free` reports it.

### Per finding

| Finding | Post-fix result |
|---|---|
| F1 | Unchanged (carried): every served 200 with a templated or tool prompt |
| F2 | **Fixed.** Every `long/s/normal` and `long/s/slow` on llama.cpp, mlx_lm, Ollama and native ran to its finish (up to 700 content events), no `stream_output_exceeded` in any label |
| F3 | Unchanged (Swift fix pending): loopback `disconnect` → `missing_receipt_deadline_elapsed`, refunded. Also seen on native pool A disconnects (R1/R2 pin0, pool NO in observe): same receipt-less cancel shape |
| F4 | **Fixed.** 5 native disconnects settled `verified`: buyer debited 13-16 completion tokens (what it received), provider credited the gateway-delivered prefix. 0 `no_undelivered_bill` failures |
| F5 | **Fixed.** Native non-streaming tool calls with the quarantined credit close `zero_settled` / `verified_receipt_credit_quarantined`, refunded, 0 holds (was: finality 500, held forever) |
| F6 | Unchanged (carried): native streaming tool calls `stream_malformed` / `output_hash_mismatch`; the breaker still trips (502x3 in pin1 labels) |
| F8 | Unchanged semantics (documented); its F2 component is gone: truncated observe streams billed 0 no longer occur |
| F9 | **Fixed** (`PF-rotate`): `rotate-key` accepted with a slow stream in flight; that stream and 6 later global and pool-A requests all `verified` with valid receipts; 0 `receipt_omitted` in the serve log |
| F10 | **Fixed** (`MIXA-llamacpp-pin0`, 85/85): new coordinator + origin/main gateway refuses all 13 pool requests with 503 before dispatch (0 snapshots, 0 ledger rows, 0 upstream calls, 0 holds) |
| F11 | Operational fix confirmed: origin/main coordinator on the unstripped feed still exits (`unknown field "file_path"`), and step 4a flags the feed on a YAML config. But see F12 |

### New findings from the post-fix run

#### E2E-F12 (LOW, runbook): the step 4a feed check fails open on some config forms

Runbook §9 step 4a extracts the feed path with
`awk '/catalog_artifacts_path:/ {print $2}'`:

- **Plain YAML** (`catalog_artifacts_path: /path`, Pearl's form): prints the
  path and a count of 1 for the lab #1690 feed. Correct.
- **JSON config** (the lab's): the key is followed by `":`, so nothing
  matches, and the check prints `feed: none`. The runbook reads that as "go
  to the coordinator rollback", which is the failure F11 describes.
- **Quoted YAML value** (`catalog_artifacts_path: "/path"`): awk keeps the
  quotes, grep fails with `No such file or directory` and prints no count
  (exit 2).

Repro: `LAB/check4a.sh LAB` (renders the lab config both ways; quoted form by
hand). Suggested fix: strip quotes, treat a missing key as an error (not
`none`), and compare against the path the coordinator logs at startup.

#### E2E-F13 (MEDIUM, code, native CLI; newly visible now that F2 no longer cuts long streams): a token boundary inside a multi-byte UTF-8 character → `output_hash_mismatch`, delivered output free

- **Repro:** native, `long` stream (`max_tokens` 700) whose output runs into
  non-Latin text.
  - **Control probe:** `scripts/lab/1690-e2e/probe_hash.py 12` sends 12 long
    streams on the global route, no tool calls and no downgrade, recording
    only flags about the delivered text. Log: `LAB/probe.out`.
  - 2 of 12 settled `quarantined` / `output_hash_mismatch`: the only 2 whose
    delivered text contained U+FFFD (1 each; 207 and 433 non-ASCII
    characters).
  - All 10 streams without U+FFFD verified.
  - In the matrix: 6 of 18 native global long streams (6 labels x normal,
    disconnect, slow) plus 3 pre-fix, where F2 had cut the streams first.
- **Effect:**
  - The buyer receives a complete 200 stream with `finish_reason: length`,
    containing a replacement character.
  - The verdict quarantines the credit and the buyer is refunded, so the
    output is free and the provider unpaid.
  - The coordinator's `delivered_output_bytes` equals the bytes the buyer
    got (661 / 1363), so the coordinator hashed what it delivered. The
    provider's receipt signed a different output hash.
- **Suspected root cause** (not traced to the byte): the native streaming path
  emits per-token text segments through
  `MLXLMCommon.NaiveStreamingDetokenizer` (`ModelRuntime.swift:4981`). A
  token that ends inside a multi-byte UTF-8 character yields a segment with
  U+FFFD, which is what reaches the buyer. The receipt's output hash is built
  from a different rendering of the text (e.g. the full decode, where the
  character completes).
- **Fix direction:** hold back an incomplete UTF-8 tail in the streaming
  detokenizer, and have the receipt hash the exact delivered frames.
- **Not the cause:** the buffered-downgrade path. F6's `recordMalformed`
  (`streaming_downgrade.go:66-77`) still downgrades native for 10 minutes
  after 3 malformed tool streams, but the probe reproduces the mismatch
  without it.

### Not re-run

Engine-selection labels (no fix touched engine selection), R1 `*-pin0` for
the external engines, and the proxy tamper/strip faults (F7 unchanged by
design; no finality-MAC code changed) were not re-run. Their pre-fix results
stand.

## Findings

Severity is the money-path impact. Each finding says whether it is **new** in
#1690 or **pre-existing** (reproduced on origin/main components).

### E2E-F1 (MEDIUM, code, pre-existing): buyer-visible usage ≠ debit; prompt bound under-counts templated prompts

- **Repro:** any request whose engine prompt count exceeds the coordinator's
  byte-estimate bound. With llama-server `--jinja`, a plain prompt reports 44
  and 37 is charged. A tool prompt reports 192 and 105 (non-stream) or 120
  (stream) is charged. The same happens on native (175 → 105) and on the
  origin/main coordinator (MIXB).
- **Effect:**
  - The buyer's `usage` shows 192 and the buyer is debited 105.
  - The provider is credited on 105.
  - The attempt output and the signed receipt say `billable_input_tokens`
    192, yet the verdict is `verified`.
- **Root cause:** `phase4-coordinator/internal/billing/hotpath.go:346`
  `boundProviderReportedPromptTokens`. The bound is `estimateTokens(req.raw)`,
  set at `buyer/server.go:2576-2577` (`setPromptTokenUpperBound`). It counts
  request bytes, not rendered template or tool-schema tokens, so it is
  systematically low for tool calls and chat templates.
- **Evidence:** every `buyer_usage_eq_debit[F1-prompt-bound]` in the results,
  e.g. `R1-llamacpp-pin0.json`.

### E2E-F2 (HIGH, code, pre-existing, now reachable on every engine): streams over about 280 tokens are truncated and the delivered part is free

- **Repro:** any streaming request with `max_tokens` 700 that generates more
  than about 280 tokens, on llama.cpp, mlx_lm, Ollama and native. The buyer gets
  283 content events, a `stream_output_exceeded` error event and `[DONE]`.
- **Effect:**
  - The gateway cancels the coordinator.
  - The attempt ends `buyer_cancel` with no receipt, and the verdict is
    `missing_receipt_deadline_elapsed`.
  - The credit is quarantined and the buyer refunded, so about 280 delivered
    tokens are free and the provider is unpaid.
  - In observe mode (F8) the provider is credited for the full generation
    while the buyer pays 0 completion tokens.
- **Root cause:** `phase5-gateway/internal/router/chat_proxy.go:1579-1590`
  (`maxStreamingFallbackMetadataBytes = 64<<10`, line 101). The fallback guard
  truncates once serialized SSE bytes minus content bytes pass 64 KiB. Each
  one-token chunk is about 232 bytes (`stream_interval: 1`, per-token chunks
  on every engine), so about 280 tokens reach the ceiling. It dates from #354
  (`dabf188b`); #1690's per-token loopback relay puts every engine on it.
- **Evidence:** gateway log `streaming gateway estimate exceeded serialized
  metadata ceiling; truncating stream serialized_bytes=66943
  content_bytes=1364`; `long/s/normal` and `long/s/slow` in every engine label.

### E2E-F3 (MEDIUM, code/spec, new path): a loopback partial stream after buyer disconnect is free

- **Repro:** pool route, llama.cpp/mlx_lm/Ollama (and native on pool A, R1
  pin0), `disconnect` after 4 content events.
- **Effect:** the CLI sends no `buyer_cancel` receipt, so the verdict is
  `missing_receipt_deadline_elapsed`, the credit is quarantined
  (`loopback_runtime_not_settlement_eligible`) and the buyer refunded. The
  delivered prefix is never billed.
- **Assessment:** this conforms to SPEC-022 R-5.6 / AC-022-14 (no binding,
  so pending, then quarantined). It contradicts the delivered-only goal
  (AC-022-15/50c) for loopback runtimes. Suspected cause (not traced): the
  `buyer_cancel` receipt built in `InferenceRelay.swift:1098-1119` is not
  emitted on the loopback relay path (`OpenAICompatibleLoopbackRuntime.swift`).
  Native on the same disconnect either completed first (F4) or also went
  receipt-less (R1 pin0 pool A).

### E2E-F4 (HIGH, code, new with delivered-only): a buyer that disconnects on a fast engine is billed the full generation

- **Repro:** native global or pool A, `disconnect` after 4 content events,
  `max_tokens` 700.
  - Buyer received 4 events. Buyer debited 700 completion tokens
    (`R1-native-pin1`, `R2-native-pin1`, `R1-native-pin0 global`).
  - Provider credited 657, payable. Finality `verified`, `normal_done`,
    `delivered_output_bytes` 3346.
- **Root cause:** delivered-only is measured at the coordinator→gateway hop.
  The engine finishes before the gateway notices the buyer is gone. The gateway
  then writes a `client_disconnect` local-terminal hold
  (`chat_proxy.go:1348-1377` `settleObservedContent` / `settleCancelled`), and
  the reconciler settles it from the coordinator's verified finality, which
  counts bytes delivered to the gateway, not to the buyer.
- **Evidence:** gateway log for `db80a208-…` (`settlement_outcome=client_disconnect`,
  then `nudge completed result=verified`).

### E2E-F5 (HIGH, code, new finality path): a verified verdict on a quarantined credit returns finality 500 forever

- **Repro:** native, non-streaming tool call. F1 bounds the prompt to 105, the
  native CLI reports cached prompt tokens above that, and the ledger
  quarantines `invalid_cached_prompt_tokens`. The receipt verdict closes
  `verified`.
- **Effect:**
  - `/internal/settlement/finality` returns 500: `verified charged ledger
    usage missing for request … attempt 0`.
  - The gateway reconciler retries every 5 s ("coordinator finality
    status=500"). The reservation stays `active`, `settlement_hold=1`, more
    than 90 min past `expires_at` (2 per native label, still held at the end).
  - Output was delivered and never billed.
- **Root cause:** `phase4-coordinator/internal/billing/settlement_finality.go:640-657`
  (`requestSettlementUsage`) joins only `lrc.quarantined = 0`, and treats "no
  unquarantined credit behind a verified verdict" as an error rather than a
  closed, zero-settled or quarantined outcome. `551fd876` (in the tested build)
  did not cover this path. The trigger is `hotpath.go` cached-token validation
  (`invalid_cached_prompt_tokens`) running after the F1 bound.
- **Evidence:** reservations `02cef955-…`, `3e0fac38-…`, `978b3bdb-…` in
  `LAB/db/gateway.db`; coordinator log `internal settlement finality lookup failed`.

### E2E-F6 (MEDIUM, code, pre-existing): native streaming tool calls end malformed and trip the breaker

- **Repro:** native, streaming tool call (12 of 26 native streaming tool
  requests; also reproduced on the origin/main coordinator in MIXB).
- **Effect:**
  - The native CLI finishes with `"finish_reason": "stop"`, not `tool_calls`.
  - The coordinator's `streamToolCallFinalValidator.finalCloseOK`
    (`buyer/server.go:5963`) fails. After `[DONE]` the coordinator appends
    `{"error":{"code":"tool_call_final_close_failed"}}` and a second `[DONE]`
    (`server.go:4222-4235`).
  - The gateway truncates as `stream_malformed`, and the receipt verdict is
    `output_hash_mismatch`. So the output is quarantined and refunded, and the
    buyer got it free.
  - The attempt is also a `FaultBreakerQualifying` fault: after 3-4 tool
    streams the lab breaker (2 in 120 s) opens, and every request returns 502
    `provider_error` (`R1-native-pin1` 502x3; the direct probe went 4 OK, then
    4x 502).
- **Evidence:** `LAB/probe_f6.out` (raw frames, content redacted).

### E2E-F7 (LOW, runbook, by design): pin off plus a stripped trailer declaration downgrades settlement

With `require_settlement_trailers: false`, a hop that strips both the
`Trailer:` declaration and the trailers makes a negotiated non-streaming 200
settle locally as `provider_reported`: buyer debited (44,32), coordinator
settled (37,32). This is the downgrade runbook §9 step 2a exists for. With the
pin on it held and reconciled correctly in R1 and R2. Evidence:
`R*-proxy-pin0-strip_decl.json`, `LAB/logs/proxy.jsonl`.

### E2E-F8 (MEDIUM, code/spec, pre-existing semantics): observe mode debits locally and credits separately, and the two diverge

In observe mode the buyer gets the signed `legacy` tuple and is debited by
local gateway accounting, while the coordinator credits the provider its own
figure.

- **Non-streaming:** buyer debited 44 prompt tokens, provider credited on 37
  (F1).
- **Truncated streams (F2):** buyer debited 0 completion tokens, provider
  credited for 395-700.
- **Disconnects:** buyer debited 8-13 completion tokens, provider credited for
  700.

So the platform pays for tokens the buyer is never billed. SPEC-022 describes
observe-mode local debit as intended. The divergence isn't bounded anywhere.
Evidence: `R*-observe-native-pin*.json`.

### E2E-F9 (HIGH, code): after receipt-key rotation, the CLI omits every receipt until restart

- **Repro:** native serve, `cli.sh rotate-key --ctl-socket-path <serve socket>`
  with a stream in flight (R2). The CLI reports `receipt key rotation
  accepted`, and the coordinator logs `coordinator rotated receipt key
  accepted`.
- **Effect:** the in-flight stream and all 6 later requests (global and pool A,
  stream and non-stream) log `receipt_omitted reason=construction_failed`.
  Each settles `missing_receipt_deadline_elapsed`, quarantined, buyer refunded.
  The provider keeps serving but earns nothing, and the buyer is served free.
  Not checked: whether a serve restart recovers.
- **Suspected root cause:** receipt construction after
  `RotateKeyCommand.rotateActiveProvider`
  (`phase3-binary/Sources/macprovider-cli/RotateKeyCommand.swift:90-110`,
  `swapToCurrent`) versus the v0.4 settlement-receipt branch
  (`HTTPServer.swift:1550-1557`: settlement metadata with no captured snapshot
  hash fails as `construction_failed`). The log doesn't say which field
  failed; needs a CLI-side trace. The hot path, ingestion and verifier stayed
  consistent (no credit was ever payable without a verified receipt), which is
  the current-key-only behaviour working.
- **Evidence:** `R2-rotate.json`, `LAB/logs/serve.log` (`receipt_omitted`), `chain.out`.

### E2E-F10 (MEDIUM, runbook/code): an old gateway with loopback pool traffic holds forever while the provider credit is payable

- **Repro:** new coordinator + origin/main gateway, llama.cpp member on a v2
  pool.
- **Effect:** every 200 settles `verified` / `pool_operator_attested` at the
  coordinator, with a payable credit. The old gateway rejects that token
  source ("not settlement-capable") and holds the reservation indefinitely
  (12 of 12). So the provider is paid and the buyer never debited.
- **Assessment:** runbook §9 orders v2 allowlists after the gateway deploy,
  so this is outside the documented order. Nothing enforces the order,
  though. The coordinator routes pool loopback attempts for a gateway that
  never sent `X-MacProvider-Internal-Settlement-Trailers`.
- **Suggestion:** refuse pool-loopback routing unless the request negotiated.

### E2E-F11 (HIGH, runbook): a coordinator rollback can't start on a #1690 feed

- **Repro:** origin/main coordinator with the signed lab feed produced by the
  #1690 labtool.
- **Effect:** the coordinator exits at startup:
  - `autotune.catalog_artifacts schema: json: unknown field "file_path"` (GGUF
    tuple, M4a `254026ca`, `buyer/catalog_artifacts_feed.go:146`);
  - then `runtime_format "mlx_safetensors" may not allow runtime source
    "mlxlm_loopback"` (M8).
- **Consequence:** once production publishes GGUF or mlxlm artifacts (step 4
  of the rollout), the §9 coordinator rollback leaves no coordinator. It came
  up only after the feed was stripped of those fields and re-signed
  (`scripts/lab/1690-e2e/mixb_feed.go`).
- **Fix needed:** runbook §9 must add "publish a pre-#1690 feed first" to the
  coordinator rollback, or the coordinator's feed decode must tolerate
  unknown fields.

### Harness issues found and fixed on the way (not product bugs)

- `buyer.py` concurrency tripped `account_request_rate_exceeded` at the default
  rate; `write_configs.py` now raises the lab account rate and daily tokens
  under `E2E_*`.
- One provider switching engines revokes the previous candidate
  (`runtime_identity_drift`, SPEC-047-R006), and any admission row excludes the
  provider from native default routing (SPEC-047-R003). `rig.sh` now re-offers
  (`E2E_REOFFER`) and clears the lab provider's admission rows before native
  (`E2E_NATIVE_CLEAR_ADMISSION`), with a backup under `LAB/logs/`.
- Native needed `model_artifact_*` and `model_catalog_*` config (normally from
  `autotune --apply`, never run next to the live provider). It also needed a
  lab-only CLI (`rig.sh build-native`) because the shipped CLI skips the
  native catalog preflight for an isolated loopback join
  (`relaxesJoinAdmissionForLab`), so native joined uncatalogued.
- **Observation (LOW):** the lab CLI's signed-static loader GETs
  `https://coordinator.malibu.tech/v1/<name>` on every serve preflight
  (`AutotuneRecommend.swift:1954,1968`, hardcoded). The lab build now points it
  at a closed loopback port (`static_swift` in `rig.sh`). Before that patch, the
  first native bring-ups issued those GETs to production, read-only and
  unauthenticated.
- The rotation socket path, described above.

## Not run, or not staged

| Item | Why |
|---|---|
| Previous-key receipt injected directly | The CLI can't be made to sign with a stale key without a patched CLI; covered only by F9's in-flight rotation |
| mlx_lm / Ollama engine killed mid-stream | Only llama-server was killed |
| Observe mode for external engines | An observe pool with an allowlist is invalid by design |
| Mix B pools, llama.cpp | The old coordinator has no v2 core or loopback pricing (fail closed) |
| Mix A / Mix B with pin on | Mix A's gateway has no pin; Mix B ran pin off only |
| Slow reader on non-streaming | Not defined for a buffered body |
| R1 rotation | Harness socket path; R2 is the rotation evidence |

## Settings and deviations from production

- `settlement.pending_deadline_seconds: 90` (lab default 300), to keep settle
  waits short.
- `quotas.account_request_rate_per_second: 50`,
  `account_daily_tokens: 100000000`.
- llama-server runs with `--jinja` (tool calls need it).
- Circuit breaker: lab `breaker_failure_threshold: 2` in 120 s (F6 trips it).

## Live provider

The live provider (`:8080`, PID 3647) was never signalled, paused or drained.
Every lab process was started and stopped by recorded, pidguard-verified
identity. `:8080` was up at every run boundary through the end of Mix B
(2026-09-25 05:43Z). After that, another session announced a live CLI swap
(1.8.192 → 1.8.195), and at the final check `:8080` had no listener. That was
the other session's swap, not this run. At the end: no lab process and no
191xx listener, memory 98% free.

## Reproduce

```bash
# on the Studio, in a worktree of e2e/1690-harness
LAB=/Users/a1/lab-1690-m6/e2e scripts/lab/1690-e2e/setup.sh
. scripts/lab/1690-e2e/env.sh
LAB=... scripts/lab/1690-m6/rig.sh model && ... rig.sh build && ... rig.sh build-native
LAB=... scripts/lab/1690-e2e/full_run.sh R1   # engines, faults, observe
LAB=... scripts/lab/1690-e2e/full_run.sh R2
scripts/lab/1690-e2e/mix_setup.sh A           # then run_matrix.sh MIXA native|llamacpp "0"
python3 scripts/lab/1690-e2e/summarize.py --prefix R1
```
