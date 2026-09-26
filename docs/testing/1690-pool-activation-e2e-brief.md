# #1690 Trusted Pool activation: local e2e brief

**For:** an external hardware tester running on their own Apple Silicon Mac.
**Issue:** #1690 (engine-agnostic serving on Trusted Pools, merged as
`747557cc`). **Report to:** a comment on #1690 (format in §9).

This run exercises the same pool-activation procedure the production plan
uses ([`docs/runbooks/trusted-pool-m1-activation-plan.md`](../runbooks/trusted-pool-m1-activation-plan.md)
§4-§6), but on a stack that is entirely yours. You build and run a
coordinator, gateway and provider CLI from `main` on `127.0.0.1` ports
19101-19131, with test keys you generate, and serve a llama.cpp
`llama-server` as a Trusted Pool member. Nothing touches a production
host, and you need no production credential of any kind.

The rig already exists: `scripts/lab/1690-m6/` (rig, pool setup, buyer,
cases) and `scripts/lab/1690-e2e/` (request matrix, invariants, summary).
It was written on a Mac Studio, so a few defaults point at `/Users/a1/...`.
Every one of them is overridable with an environment variable (§2).

## 0. Do not

- Do not send any request to `coordinator.malibu.tech`,
  `coordinator.streamvc.live`, `api.malibu.tech`, `api.streamvc.live` or any
  other production host. The rig refuses non-loopback coordinator URLs
  (`cli.sh`), and §3 confirms the lab CLI cannot fetch the production
  static feed.
- Do not run the lab CLI you build without the `static_swift` patch. In
  `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`,
  `loadSignedStatic` fetches `https://coordinator.malibu.tech/v1/<name>` and
  `.sig` on every serve preflight (lines 1954 and 1968). `rig.sh build`
  applies the patch to its exported copy only: it points both URLs at the
  closed port `127.0.0.1:19108`, so the fetch fails fast and the baked lab
  release is used. Use only `rig.sh build`, `build-spoof` or
  `build-native` to build CLIs.
- Do not use real provider credentials, a real Malibu account, or a real
  `~/.config/macprovider`. If you run a Malibu provider on the same Mac, the
  rig leaves it alone: `cli.sh` redirects home, config, credentials,
  lifecycle, control socket and temp dirs into `$LAB`, and processes are
  stopped only by recorded PID. Do not use ports 8080, 8443 or 8444.
- Do not edit the worktree while the rig runs. `rig.sh build` and `rig.sh
  up` refuse uncommitted tracked changes, because the lab builds and runs
  `HEAD` only.
- Do not post prompts, completions, keys, tokens or full DB dumps in the
  report. Post request ids, digests, counts and labels.

## 1. Prerequisites

| Item | Version / note |
|---|---|
| Mac | Apple Silicon, macOS 14 or later, 16 GB RAM is enough (0.5B model) |
| Xcode | with command-line tools, for `swift build -c release` (Swift tools 5.9) |
| Go | exactly `1.26.6`; the rig sets `GOTOOLCHAIN=local` |
| llama.cpp | a `llama-server` binary; the lab used release `b11149` (macOS arm64 zip from the llama.cpp GitHub releases) |
| Python | 3.10 or later, standard library only |
| `sqlite3`, `curl`, `git`, `shasum` | macOS built-ins are fine |
| Disk | about 6 GB (source exports, Swift build cache, model) |
| Network | GitHub and Hugging Face only, for the source and the model |

Model (pinned by the rig, downloaded by `rig.sh model` and checked by
sha256):

| Field | Value |
|---|---|
| repo | `Qwen/Qwen2.5-0.5B-Instruct-GGUF` |
| revision | `9217f5db79a29953eb74d5343926648285ec7e67` |
| file | `qwen2.5-0.5b-instruct-q4_k_m.gguf` |
| sha256 | `74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db` (= HF LFS oid) |
| size | 491,400,032 bytes |

`mlx.metallib`: the build copies one into `$LAB/bin`. Take it from the public
`macprovider-cli v1.8.123` release tarball
(`macprovider-cli-v1.8.123-darwin-arm64.tar.gz`, file `mlx.metallib`). The
llama.cpp member does not run MLX kernels. Note its sha256 in the report.

Estimated time: 45-75 min for the first build (Swift release build
dominates), 10 min for model and rig bring-up, about 60-90 min for §4-§8.
Plan for half a day including the report.

## 2. Setup

```bash
git clone https://github.com/Augustas11/macprovider.git ~/mp-1690 && cd ~/mp-1690
git checkout --detach ca809589   # v1.8.200 (#1690 + startup fix), or any later main commit; report the one you used
git log -1 --format='%H %s'

export LAB=$HOME/lab-1690                   # every lab file lives here
export LLAMA_DIR=$HOME/llama.cpp/b11149     # directory containing llama-server
export METALLIB=$HOME/mp-assets/mlx.metallib
export GO_BIN="$(dirname "$(command -v go)")"
go version                                  # must print go1.26.6
"$LLAMA_DIR/llama-server" --version

scripts/lab/1690-m6/rig.sh model            # downloads + sha256-checks the GGUF into $LAB/models
scripts/lab/1690-m6/rig.sh build            # coordinator, coordinator-cli, gateway, labtool, lab CLI
```

Test keys are all generated locally, under `$LAB/keys` (mode 0700), the
first time they are needed:

- `write_configs.py` (run by `rig.sh up`) creates `$LAB/keys/secrets.json`
  with random operator keys (`operator_key`, `operator_lab_a`,
  `operator_lab_b`), the gateway service token, and the gateway key-hash
  and demo secrets.
- `labtool static-release` (run by `rig.sh build`) creates the Ed25519
  static-feed key `$LAB/keys/static-feed.ed25519` and signs a one-row lab
  catalog (`qwen2.5-0.5b-instruct`) whose artifact feed carries the GGUF
  as a `verified` `huggingface_revision` sibling allowing
  `llamacpp_loopback`. That is the same tuple shape production uses.
- `scripts/sign-catalog.go keygen` creates the lab Tier-2 catalog key.
- `coordinator-cli issue-token` (run by `rig.sh up`) issues the lab
  provider token.
- `labtool pool-keygen` (§4) creates the pool keys: a P-256 root issuer
  key, an Ed25519 manifest-authority key and an Ed25519 policy-signer key.

## 3. Bring up the stack and check isolation

```bash
E2E_GATEWAY_PIN=1 scripts/lab/1690-m6/rig.sh up
scripts/lab/1690-m6/rig.sh status
```

`up` starts the coordinator (`:19101` buyer, `:19102` provider/admin), the
gateway (`:19110`), llama-server (`:19130`, see below), a usage tap
(`:19131`) that records the usage llama-server returns, and the provider
CLI (`:19120`). It then offers the GGUF candidate, has lab operator `lab_a`
price it (`catalog_priced`), and creates rig pool **A** (v2,
`["llamacpp_loopback"]`) through raw admin HTTP. Pool A is the harness
baseline. §4 creates a second pool by hand, the production way.

llama-server runs with the flags proven in the lab:

```
llama-server -m $LAB/models/qwen2.5-0.5b-instruct-q4_k_m.gguf --host 127.0.0.1 --port 19130 -c 8192 -np 4 -ngl 99 --jinja
```

`--jinja` applies the chat template (tool calls need it). The CLI always
calls llama-server with `stream: true`, `stream_options.include_usage` and
`timings_per_token`, so no usage flag is needed.

`E2E_GATEWAY_PIN=1` sets the gateway's `coordinator.require_settlement_trailers:
true` (production runbook §9 step 2a).

Isolation checks. All must pass before §4:

```bash
grep -c 'https://coordinator.malibu.tech/v1/' "$LAB/src/phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift"   # 0
grep -c '127.0.0.1:19108/v1/' "$LAB/src/phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift"                   # 2
grep coordinator_url "$LAB/provider/config.yaml"                                                                         # ws://127.0.0.1:19102/ws/provider
python3 -c "import json;print(json.load(open('$LAB/run/gateway.yaml'))['coordinator'].get('require_settlement_trailers'))"  # True
for pid in $(pgrep -f "$LAB/bin/macprovider-cli-lab"); do lsof -nP -a -p "$pid" -i | awk 'NR>1{print $9}'; done | sort -u   # only 127.0.0.1 endpoints
```

Any non-loopback endpoint is a stop-and-report finding.

Member check (expect `runtime_source: llamacpp_loopback`,
`model_hash_algorithm: macprovider.gguf-file.v1`, `hash_status:
hash_verified`, `catalog_admission_mode: current`): the `rig.sh status`
output above.

## 4. Pool activation, the production procedure

This mirrors the production plan §4.3 with `coordinator-cli trust-pool-admin`
against your lab admin port. Only the key custody and the
`launch_environment` value (`candidate`) differ from a real launch.

```bash
cd ~/mp-1690
export MACPROVIDER_OPERATOR_KEY=$(python3 -c "import json;print(json.load(open('$LAB/keys/secrets.json'))['operator_key'])")
CLI=$LAB/bin/coordinator-cli; ADMIN=http://127.0.0.1:19102; LT=$LAB/bin/labtool
P=$LAB/pools/P; mkdir -p "$P"; chmod 700 "$P"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
```

1. Creator approval.

   ```bash
   python3 - "$P/creator.json" <<'PY'
   import hashlib, json, sys
   from datetime import datetime, timedelta, timezone
   t = datetime.now(timezone.utc); f = "%Y-%m-%dT%H:%M:%SZ"; h = lambda s: hashlib.sha256(s.encode()).hexdigest()
   json.dump({"creator_account_id": "acct-e2e-m1-creator", "approval_record_id": "approval-e2e-m1-v1",
     "current_approval_version": "approval-version-1", "public_display_name": "E2E M1 Creator",
     "legal_support_contact": "legal@e2e.invalid", "billing_contact": "billing@e2e.invalid",
     "emergency_notification_endpoint": "https://e2e.invalid/emergency", "acknowledged_max_response_time": "15m",
     "allowed_product_category": "design-partner", "data_retention_category": "standard", "support_owner": "e2e-ops",
     "allowed_launch_environment": "candidate", "creator_agreement_id": "agreement-e2e-m1", "creator_agreement_version": "v1",
     "creator_agreement_expires_at_utc": (t + timedelta(days=30)).strftime(f),
     "creator_agreement_grace_ends_at_utc": (t + timedelta(days=31)).strftime(f),
     "pricing_schedule_id": "pricing-e2e-m1", "pricing_schedule_version": "v1",
     "prohibited_claim_acknowledgment_hash": h("e2e prohibited claims"), "buyer_disclosure_commitment_hash": h("e2e disclosure"),
     "approval_criteria_hash": h("e2e approval criteria"), "approved_by": "e2e-operator",
     "approved_at_utc": t.strftime(f), "status": "enabled"}, open(sys.argv[1], "w"))
   PY
   $CLI trust-pool-admin upsert-creator --admin-url $ADMIN --operation-id e2e-creator-1 --input "$P/creator.json"
   ```
2. Pool keys and pool id (keep `keys.json` private; it is your test key):

   ```bash
   POOL_ID=$($LT pool-keygen --out "$P/keys.json"); echo "$POOL_ID" > "$P/pool_id"; echo "$POOL_ID"
   ```
3. Root registration nonce:

   ```bash
   $CLI trust-pool-admin issue-root-nonce --admin-url $ADMIN --creator-account-id acct-e2e-m1-creator \
     --approval-record-id approval-e2e-m1-v1 --approval-version approval-version-1 --launch-environment candidate \
     --purpose root_issuer_registration --expires-at "$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ)" --operation-id e2e-nonce-1 | tee "$P/nonce.json"
   ```
4. Create the pool:

   ```bash
   $CLI trust-pool-admin create-pool --admin-url $ADMIN --pool-id "$POOL_ID" \
     --creator-account-id acct-e2e-m1-creator --approval-record-id approval-e2e-m1-v1 --operation-id e2e-create-1
   ```
5. Signed root:

   ```bash
   NONCE=$(python3 -c "import json;d=json.load(open('$P/nonce.json'));n=d.get('root_registration_nonce',d);print(n['nonce'])")
   NEXP=$(python3 -c "import json;d=json.load(open('$P/nonce.json'));n=d.get('root_registration_nonce',d);print(n['expires_at_utc'])")
   $LT pool-root --keys "$P/keys.json" --op e2e-root-1 --creator acct-e2e-m1-creator --approval approval-e2e-m1-v1 \
     --approval-version approval-version-1 --nonce "$NONCE" --nonce-expiry "$NEXP" > "$P/root.json"
   $CLI trust-pool-admin append-event --admin-url $ADMIN --input "$P/root.json"
   ```
6. Signed v2 policy core with the llama.cpp allowlist (policy-core/v2,
   `enforce`, window 30 days, `min_binary_version` 1.8.123):

   ```bash
   $LT pool-manifest --keys "$P/keys.json" --op e2e-manifest-1 --encoding 2 --settlement-mode enforce \
     --runtime-allowlist llamacpp_loopback --models mlx-community/Qwen2.5-0.5B-Instruct-4bit \
     --min-binary-version 1.8.123 --window-seconds 2592000 > "$P/manifest-v1.json"
   $CLI trust-pool-admin submit-policy --admin-url $ADMIN --input "$P/manifest-v1.json"
   ```
7. Member and buyer (no delegation; the rig's provider and buyer):

   ```bash
   $CLI trust-pool-admin admit-provider --admin-url $ADMIN --pool-id "$POOL_ID" --provider-id lab-1690-m6-provider --operation-id e2e-member-1
   $CLI trust-pool-admin authorize-buyer --admin-url $ADMIN --pool-id "$POOL_ID" --buyer-account-id acct-lab-1690-buyer --operation-id e2e-buyer-1
   ```
8. Disclosure check, then activate:

   ```bash
   $CLI trust-pool-admin get-pool --admin-url $ADMIN --pool-id "$POOL_ID" | tee "$P/get-pool-before.json"
   $CLI trust-pool-admin promote --admin-url $ADMIN --pool-id "$POOL_ID" --operation-id e2e-promote-1 --reason e2e-m1
   $CLI trust-pool-admin get-pool --admin-url $ADMIN --pool-id "$POOL_ID" | tee "$P/get-pool-active.json"
   ```

   Pass: `runtime_allowlist: ["llamacpp_loopback"]`, settlement `enforce`,
   one member, one buyer, lifecycle `active`. Any command that fails is a
   finding: record the exact command, status and body.

## 5. Paid requests on pool P

```bash
cd ~/mp-1690
B=scripts/lab/1690-m6/buyer.py
python3 $B --pool P --engine llamacpp --n 2               | tee $LAB/logs/e2e-paid-nonstream.jsonl
python3 $B --pool P --engine llamacpp --stream --n 2      | tee $LAB/logs/e2e-paid-stream.jsonl
```

`buyer.py` sends `X-MacProvider-Pool-Select: <pool P id>` and
`X-MacProvider-Engine-Select: llamacpp` to the gateway at `:19110`, with a
unique prompt each time. It prints one sanitized JSON line per request with
`status`, `engine` (the response's `X-MacProvider-Engine`), `provider`
(`X-Provider-Id`) and `usage`. It does not print request ids; §7 shows
how to find them.

Expected per request: `200`, `engine: llamacpp_loopback`, `provider:
lab-1690-m6-provider`; streams end with a `finish_reason` and `[DONE]`.
Wait 2 minutes, then check §7 for each request.

Then run the harness's own paid and engine cases on rig pool A as the
baseline:

```bash
python3 scripts/lab/1690-m6/cases.py --only paid engine_llamacpp_pool engine_absent engine_invalid
```

## 6. Fail-closed cases

Each must refuse before dispatch: no route snapshot, no upstream call in
`$LAB/logs/upstream-usage.jsonl`, no ledger credit, and the reservation
refunded or never created.

| # | Case | How | Expected |
|---|---|---|---|
| F-a | Global route loopback must not earn | `python3 scripts/lab/1690-m6/cases.py --only global engine_llamacpp_global` | 503 `byom_non_settlement_unavailable` without the selector; 503 `engine_unavailable` with `llamacpp` |
| F-b | Runtime not allowlisted | `cases.py --only engine_ollama_pool fail_closed_pools` (pool with `ollama_loopback` only, a v1 core, and an empty v2 list) | 503 (`engine_unavailable` for the selector case) on every one |
| F-c | Unknown selector | `python3 $B --pool P --engine LLAMACPP` and `--engine vllm` | 400 `invalid_engine_selection` |
| F-d | Old gateway pairing | §6.1 | 503 before dispatch, 0 snapshots, 0 ledger rows, 0 upstream calls, reservation refunded, 0 holds |
| F-e | The pin is on | proxy strip faults, §6.2 | every stripped/tampered trailer ends as a hold that the reconciler settles to the coordinator's finality; never debited from headers |
| F-f | Disconnect mid-stream | §6.3 | no charge for undelivered tokens, no stuck hold (see note) |

### 6.1 Old gateway (pre-#1690) against the new coordinator

```bash
git -C ~/mp-1690 worktree add ~/mp-1690-old v1.8.198 --detach      # last tag without 747557cc
(cd ~/mp-1690-old/phase5-gateway && GOTOOLCHAIN=local go build -o $LAB/gateway-old ./cmd/gateway)
export LAB_MIX=$HOME/lab-1690-mixA
mkdir -p $LAB_MIX/{bin,logs,keys,db,run,static,pools,home,tmp,provider,models}; chmod 700 $LAB_MIX/keys $LAB_MIX/home
cp -p $LAB/keys/{secrets.json,static-feed.ed25519,tier2.priv,tier2.pub} $LAB_MIX/keys/
cp -p $LAB/static/* $LAB_MIX/static/; cp -p $LAB/bin/* $LAB_MIX/bin/; cp -c $LAB/models/*.gguf $LAB_MIX/models/
cp -p $LAB/gateway-old $LAB_MIX/bin/gateway
scripts/lab/1690-m6/rig.sh down                                    # one rig at a time: same ports
LAB=$LAB_MIX scripts/lab/1690-m6/rig.sh up
LAB=$LAB_MIX python3 scripts/lab/1690-m6/buyer.py --pool A --n 2
LAB=$LAB_MIX python3 scripts/lab/1690-m6/buyer.py --pool A --stream --n 2
```

The old gateway does not negotiate signed settlement finality, so the
coordinator withholds the pool's runtime allowlist and refuses before
dispatch. Check §7 queries against `$LAB_MIX/db`. If `rig.sh up` fails on
the old gateway (for example seeding the buyer), report that as a harness
finding with the log, and stop this case. When done: `LAB=$LAB_MIX
scripts/lab/1690-m6/rig.sh down`, then bring `$LAB` back up (§3).

### 6.2 The pin

```bash
LAB=$LAB E2E_PROXY_PORT=19105 E2E_GATEWAY_PIN=1 scripts/lab/1690-m6/rig.sh configs
scripts/lab/1690-m6/rig.sh proxy-start && scripts/lab/1690-m6/rig.sh gateway-restart
for mode in pass strip_capability strip_decl strip_trailers strip_mac tamper_mac tamper_outcome; do
  echo "$mode" > $LAB/run/proxy-mode
  python3 $B --pool P --engine llamacpp --n 1; python3 $B --pool P --engine llamacpp --stream --n 1
done
echo pass > $LAB/run/proxy-mode
```

Modes are defined in `scripts/lab/1690-e2e/trailer_proxy.py`. Expected: `pass` settles with no hold;
`strip_capability` means the coordinator never negotiates, so pool P
refuses with 503 before dispatch (the old-gateway case again); every
other mode holds (`missing_settlement_finality_trailer` or a MAC
mismatch in `$LAB/logs/gateway.log`) and the reconciler then settles it to
the coordinator's finality (`verified`, never `refunded` from a forged
tuple). Then restore: `E2E_GATEWAY_PIN=1 scripts/lab/1690-m6/rig.sh configs
&& scripts/lab/1690-m6/rig.sh proxy-stop && scripts/lab/1690-m6/rig.sh
gateway-restart`.

### 6.3 Disconnect mid-stream, plus the request matrix

```bash
LAB=$LAB E2E_KEEP_RIG=1 E2E_SKIP_SELECTION=1 E2E_POOL=P scripts/lab/1690-e2e/run_matrix.sh s1 llamacpp "1"
python3 scripts/lab/1690-e2e/summarize.py --lab $LAB --prefix s1
```

`run_matrix.sh` sends shapes `plain`, `tool`, `long` (700 tokens), `cap`,
each streaming and not, with behaviours `normal`, `disconnect`, `slow`,
`early_close`, `abort` on pool P and the global route, then settles every
request against the invariants. `E2E_KEEP_RIG=1` stops it restarting your
rig; `E2E_SKIP_SELECTION=1` skips the selection matrix, which expects pools
M and O you do not have (F-a/F-b/F-c cover selection).

Known and expected (report as carried, not new):

- E2E-F1: with `--jinja`, the buyer-visible `usage.prompt_tokens` is higher
  than the prompt the buyer is charged (the coordinator bounds prompt
  tokens by request bytes). `buyer_usage_eq_debit[F1-prompt-bound]` fails
  are expected; plain `buyer_usage_eq_debit` fails are not.
- E2E-F3 is FIXED for llama.cpp in `747557cc`. A mid-stream `disconnect`
  on the llama.cpp member must end with a signed `buyer_cancel` receipt,
  settle `verified`, and debit exactly the delivered prefix (for example 4
  completion tokens for 4 events received). A disconnect that is refunded
  as `missing_receipt_deadline_elapsed` is a finding (regression). A
  disconnect before the first token bills nothing, which is expected.
  (Ollama and mlx_lm disconnects are still free by design, but this brief
  only runs llama.cpp.)

## 7. Invariants and SQL

```bash
C="sqlite3 -readonly -header $LAB/db/coordinator.db"; G="sqlite3 -readonly -header $LAB/db/gateway.db"
# buyer.py does not print request ids; take the newest gateway reservations (one per request, newest first)
$G "SELECT request_id, status FROM quota_reservations ORDER BY rowid DESC LIMIT 4;"
RID=<one request_id from that list>
IDS=$(sqlite3 -readonly $LAB/db/coordinator.db "SELECT group_concat(quote(request_id)) FROM request_log WHERE external_request_id='$RID';")
$C "SELECT request_id, attempt_n, json_extract(route_snapshot_json,'\$.pool_id') pool, json_extract(route_snapshot_json,'\$.runtime_source') rt,
           json_extract(route_snapshot_json,'\$.manifest_version') mv, json_extract(route_snapshot_json,'\$.pool_generation') gen,
           json_extract(route_snapshot_json,'\$.pool_operator_account_id') op, route_snapshot_mode FROM settlement_route_snapshots WHERE request_id IN ($IDS);"
$C "SELECT request_id, attempt_n, terminal_state, usage_source, json_extract(usage_canonical_json,'\$.billable_input_tokens') bin,
           json_extract(usage_canonical_json,'\$.billable_output_tokens') bout FROM settlement_attempt_outputs WHERE request_id IN ($IDS);"
$C "SELECT request_id, attempt_n, receipt_version, receipt_result, settlement_outcome, reason, closed, pool_label_status
    FROM settlement_receipt_verdicts WHERE request_id IN ($IDS);"
$C "SELECT l.provider_id, l.status, l.charged_prompt_tokens, l.completion_tokens, l.usage_source, l.provider_credits, l.quarantined,
           l.quarantine_reason, (p.id IS NOT NULL) payable FROM ledger_request_credits l
    LEFT JOIN spec022_payable_request_credits p ON p.id = l.id WHERE l.request_id IN ($IDS);"
$G "SELECT status, settled_tokens, reserved_tokens, settlement_hold FROM quota_reservations WHERE request_id='$RID';"
$G "SELECT prompt_tokens, completion_tokens, token_source, outcome FROM usage_events WHERE request_id='$RID';"
# whole-run checks
$G "SELECT COUNT(*) stuck FROM quota_reservations WHERE status='active' AND settlement_hold=1;"
$C "SELECT COUNT(*) global_loopback_credits FROM ledger_request_credits l JOIN settlement_route_snapshots s
      ON s.request_id=l.request_id AND s.attempt_n=l.attempt_n
    WHERE l.provider_credits>0 AND (json_extract(s.route_snapshot_json,'\$.pool_id') IS NULL OR json_extract(s.route_snapshot_json,'\$.pool_id')='');"
```

`global_loopback_credits` counts credits on non-pool routes; the rig's only
provider is the loopback member, so it must be 0.

| Invariant | Pass condition |
|---|---|
| I1 route labels | paid pool rows: `pool` = P id, `rt = llamacpp_loopback`, `mv = 1`, `gen` set, `op = acct-e2e-m1-creator`, mode `enforce` |
| I2 attested usage | `usage_source = pool_operator_attested`, `terminal_state = normal_done`, billable == the llama-server usage for that request in `upstream-usage.jsonl` |
| I3 receipt | `receipt_version = 4`, `receipt_result = valid`, `settlement_outcome = verified`, `pool_label_status = verified`, `closed = 1` |
| I4 provider credit | one payable row, `provider_credits > 0`, `quarantined = 0` |
| I5 finality | `token_source = pool_operator_attested`, `outcome = verified` (gateway `usage_events.token_source` shows it) |
| I6 buyer debit == finality | `usage_events (prompt, completion)` == ledger `(charged_prompt_tokens, completion_tokens)`; reservation `settled`, `settlement_hold = 0` |
| I7 global never earns | `global_loopback_credits = 0`; every F-a request left no snapshot |
| I8 unallowlisted refused | F-b: 503, no snapshot, no upstream call |
| I9 old gateway refused | F-d: 503 before dispatch, 0 snapshots/ledger rows/upstream calls, refunded |
| I10 pin | F-e as expected; `pass` mode 0 holds |
| I11 disconnect | F-f: never billed beyond what was delivered; no stuck hold |
| I12 no stuck holds | `stuck = 0` at the end, after at least one `pending_deadline_seconds` (300 s by default) |
| I13 rollback gate | §8 `pool-rollback-preflight` reaches exit 0 |
| I14 isolation | §3 checks, and no production host in any log (`grep -r malibu.tech $LAB/logs` only shows config text, not connections) |

## 8. Pause, deactivate, rollback

```bash
# pause: pool P refuses new requests; global traffic unaffected
$CLI trust-pool-admin set-lifecycle --admin-url $ADMIN --pool-id "$POOL_ID" --lifecycle paused --reason e2e-pause --operation-id e2e-pause-1
python3 $B --pool P --engine llamacpp --n 1          # expect 503, no snapshot
# in-flight during pause: start a long stream first, pause while it runs
python3 $B --pool P --engine llamacpp --stream --max-tokens 600 --n 1 & sleep 2
$CLI trust-pool-admin set-lifecycle --admin-url $ADMIN --pool-id "$POOL_ID" --lifecycle paused --reason e2e-pause-inflight --operation-id e2e-pause-2
wait
# resume
$CLI trust-pool-admin promote --admin-url $ADMIN --pool-id "$POOL_ID" --operation-id e2e-resume-1 --reason e2e-resume
python3 $B --pool P --engine llamacpp --n 1          # expect 200 again
# remove the member
$CLI trust-pool-admin revoke-provider --admin-url $ADMIN --pool-id "$POOL_ID" --provider-id lab-1690-m6-provider --operation-id e2e-revoke-1
python3 $B --pool P --engine llamacpp --n 1          # expect 503
# retire
$CLI trust-pool-admin set-lifecycle --admin-url $ADMIN --pool-id "$POOL_ID" --lifecycle retired --reason e2e-retire --operation-id e2e-retire-1
# rollback gate (reads the lab DB only)
$LAB/bin/coordinator pool-rollback-preflight --config $LAB/run/coordinator.yaml; echo "exit $?"
```

Record for the in-flight stream: its status, whether it completed, and its
§7 rows. Expected: the stream keeps the route snapshot it started with and
settles from it (a valid receipt settles `verified`); nothing is left
open. The rollback gate may exit 3 while pool verdicts are open; re-run it
every 30 s until 0 and record how long it took (the expiry sweep closes
past-deadline verdicts about a minute after the deadline).

Teardown: `scripts/lab/1690-m6/rig.sh down`. Check `lsof -nP -iTCP:19101-19131
-sTCP:LISTEN` prints nothing.

## 9. Report (one comment on #1690)

```markdown
## #1690 pool activation e2e — <your handle>, <date>

**Environment**
- Hardware: <model, chip, RAM>; macOS <version (build)>
- Commit: <full sha of main used>; Go <go version>; Xcode <version>; Swift <swift --version>
- llama.cpp: <build/tag>, sha256(llama-server) <…>
- Model: Qwen/Qwen2.5-0.5B-Instruct-GGUF @ 9217f5db…, sha256 74a4da8c… (matched: yes/no)
- mlx.metallib sha256: <…> (source: v1.8.123 tarball)
- Lab CLI sha256: <shasum -a 256 $LAB/bin/macprovider-cli-lab>

**Results**
| # | Case | Result | Evidence (request ids, key values) |
|---|---|---|---|
| 4 | Pool activation (creator, root, v2 manifest, member, buyer, promote) | PASS/FAIL | pool_id, manifest digest |
| 5 | Paid non-stream ×2 | | I1-I6 values |
| 5 | Paid stream ×2 | | |
| F-a | Global route | | |
| F-b | Not allowlisted / v1 / empty v2 | | |
| F-c | Unknown selector | | |
| F-d | Old gateway | | |
| F-e | Pin (per proxy mode) | | |
| F-f | Disconnect / matrix (summarize.py table) | | |
| 8 | Pause / in-flight / resume / revoke / retire | | |
| 8 | pool-rollback-preflight | | exit codes, time to 0 |
| 3 | Isolation | | |

**Findings**
### <ID> (<CRITICAL|HIGH|MEDIUM|LOW>) <one-line title>
- Repro: <exact commands>
- Expected / observed: <…>
- Logs: <trimmed lines from $LAB/logs/*.log, no secrets>
- New or carried (E2E-F1/F3): <…>

**Not run** (and why): <…>
```

Severity: CRITICAL/HIGH = money moves wrongly (a credit without a verified
receipt, a debit for undelivered output, a loopback that earns on a global
route, a stuck hold) or a lab process reaches a production host; MEDIUM = a
fail-closed case fails open without money moving, or the procedure cannot
be completed as written; LOW = docs, harness, or cosmetic.

Attach `summarize.py` output and `$LAB/captures/results.txt` (from
`cases.py`) as collapsed blocks. Keep `$LAB` until the report is reviewed.
