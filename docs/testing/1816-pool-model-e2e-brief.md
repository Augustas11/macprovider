# #1816 pool-scoped model: local e2e brief

**Issue:** #1816 (pool-scoped trust for non-catalog models). **Report to:** a
comment on #1816 (format in §7).

This run proves, on a stack entirely on `127.0.0.1`, that a model **outside**
the global catalog can be served and settled inside one Trusted Pool, and
nowhere else:

propose (provider) → review and sign (creator) → bind (coordinator) →
paid pool request settled `pool_operator_attested` with a provider credit.

It also proves the refusals:

- a global request is refused;
- a cross-pool request is refused;
- an out-of-bounds price is refused;
- an entry whose hash is already in the global catalog is refused, and the
  catalog path applies;
- removing the entry revokes the binding.

Run it for a GGUF on llama.cpp and for a native MLX snapshot.

The rig is the #1690 lab: `scripts/lab/1690-m6/`. Follow
[1690-pool-activation-e2e-brief.md](1690-pool-activation-e2e-brief.md)
§0-§3 for the hard rules, the prerequisites, the build, and `rig.sh up`.
That brief's "Do not" list applies unchanged: no production host, no real
credentials, `rig.sh build` only, and no worktree edits while the rig runs.
Operator procedure: [pool-scoped-model-admission.md](../runbooks/pool-scoped-model-admission.md).

## 1. Build and inputs

Use a `main` commit that contains all three #1816 lanes: coordinator
(`pool_model_entries/v1`, bounds, binding), CLI (the
`pool_model_proposal.v1` propose step), and these lab tools. Report the
commit.

Models (the lab catalog release built by `rig.sh build` contains the
Q4_K_M GGUF and the 4-bit MLX snapshot of Qwen2.5-0.5B-Instruct; everything
else is non-catalog):

| Case | Artifact | In lab catalog |
|---|---|---|
| G (GGUF, non-catalog) | `Qwen/Qwen2.5-0.5B-Instruct-GGUF@9217f5db…` file `qwen2.5-0.5b-instruct-q8_0.gguf` | no |
| N (native MLX, non-catalog) | `mlx-community/Qwen2.5-0.5B-Instruct-8bit` snapshot | no |
| C (catalog overlap) | `qwen2.5-0.5b-instruct-q4_k_m.gguf` (sha256 `74a4da8c…`) | **yes** |

Download G into `$LAB/models/` and record `shasum -a 256` and the size.
Download N into `$LAB/models/mlx/`. Record the revision you used.

Coordinator pricing bounds: before `rig.sh configs` / `rig.sh up`, export
the production-derived bounds from the runbook §1, so the lab enforces the
same bounds:

```bash
export LAB_POOL_MODEL_PRICING_BOUNDS='{"min_prompt_rate_per_mtok":13500,"max_prompt_rate_per_mtok":425000,
 "min_prompt_cache_hit_rate_per_mtok":3375,"max_prompt_cache_hit_rate_per_mtok":106250,
 "min_completion_rate_per_mtok":27000,"max_completion_rate_per_mtok":2160000}'
```

## 2. Pools

`rig.sh up` creates pool **A** with the labtool signer, as in #1690. Model
entries are signed only by the reviewed `coordinator-cli trust-pool-admin
sign-manifest`, so create a second pool **Q** with that signer. Use a short
window, because a new entry takes effect only when the successor window
starts:

```bash
H=scripts/lab/1690-m6; PS="python3 $H/pool_setup.py"
$PS create Q --signer coordinator-cli --encoding 2 --runtime-allowlist llamacpp_loopback --window-seconds 300
cat $LAB/pools/Q/pool_id
```

Every later `$PS manifest Q --signer coordinator-cli --encoding 2
--runtime-allowlist llamacpp_loopback --window-seconds 300` signs the next
core and starts when the current one ends. Wait for that boundary
(`windows.json` in the pool dir) before you expect routing to change.

`pool_setup.py` notes:

- `manifest` records `manifest-vN.json` and its `windows.json` slot only
  after the coordinator accepts the event. A refused manifest leaves no
  phantom `--prev`; fix the cause and run `manifest` again.
- Every operation id carries a per-directory run id (`$LAB/pools/<name>/run_id`),
  so a pool name can be reused in a fresh `$LAB` without 409
  `operation_conflict`.
- For `--encoding 2` the script always passes `--runtime-allowlist`; the
  default `""` is a native-only pool (an `mlx_cache` entry needs no
  allowlist).
- A manifest refused for its entries answers a specific code, for example
  `pool_model_pricing_out_of_bounds`, `pool_model_entry_catalog_overlap`, or
  `pool_model_entry_license_invalid` (SPEC-042-R010 manifest acceptance
  codes), never the opaque `invalid_event`.
- `get-pool` / `pool-status` list the active core's `model_entries` and
  `attested_members`.

## 3. Case G: GGUF, non-catalog (the paid path)

1. Serve G: `LAB_SERVE_GGUF_FILE=qwen2.5-0.5b-instruct-q8_0.gguf ENGINE=llamacpp scripts/lab/1690-m6/rig.sh server-start`.
2. **Propose (provider).** Run the CLI propose step against the served file
   through the lab CLI (`cli.sh`; export
   `LAB_LLAMACPP_MODEL_PATH=$LAB/models/qwen2.5-0.5b-instruct-q8_0.gguf` so
   the CLI names the Q8_0 file, not the default Q4_K_M), with the llama.cpp
   origin flags from
   `rig.sh`:
   `models propose llamacpp:qwen2.5-0.5b-instruct-q8_0 --pool <Q pool_id>
   --slug qwen25-05b-q8 --json`. Save the `pool_model_proposal.v1` output
   as `$LAB/proposal-g.json`. Check that `model_entry.pool_model_id` is
   `pool/<Q pool_id>/qwen25-05b-q8`, `model_entry.allowed_runtime_sources`
   is `["llamacpp_loopback"]`, and `model_entry.artifact_hash` equals your
   `shasum` of the file. `license` and `paid_serving_attested` are `null`;
   the creator supplies them in step 3.
3. **Sign (creator).** Stage the entry with the creator fields, then sign
   and submit the next manifest. `max_context_tokens` must be ≤ the
   llama-server `-c` (16384); pass `--max-context-tokens` when the bundle
   has none or a larger value:

   ```bash
   $PS entry Q --proposal $LAB/proposal-g.json --license Apache-2.0 --paid-serving-attested \
     --prompt-rate 20000 --cache-hit-rate 5000 --completion-rate 40000 --max-context-tokens 16384
   $PS manifest Q --signer coordinator-cli --encoding 2 --runtime-allowlist llamacpp_loopback --window-seconds 300
   ```

   `entry` writes `$LAB/pools/Q/pool-models.json`, the closed
   `{"model_entries": [...], "attested_members": [...]}` input of
   `coordinator-cli trust-pool-admin sign-manifest`. Expect
   `manifest_accepted` → 202, and a `--pool-models` argument in the signer
   call. `get-pool` for Q lists the entry with
   `disclosure_class: pool_attested_unverified`.
4. **Bind.** After the new window starts, restart `serve` and offer the
   served model (`models offer llamacpp:qwen2.5-0.5b-instruct-q8_0 --yes
   --json` with the llama.cpp origin flags from `rig.sh`). Expect a
   pool-scoped `catalog_priced` binding under the signed-manifest actor, and
   no global admission. `models admission status <candidate> --json` shows a
   `pool_binding` object with `binding_scope: pool` and the Q
   `manifest_core_digest`, and `catalog_model_key: null`.
5. **Paid request**, non-streaming and streaming:

   ```bash
   M="pool/$(cat $LAB/pools/Q/pool_id)/qwen25-05b-q8"
   python3 $H/buyer.py --pool Q --engine llamacpp --model "$M" --n 1
   python3 $H/buyer.py --pool Q --engine llamacpp --model "$M" --stream --n 1
   ```

   Expect `200` and `engine: llamacpp_loopback`. Run the runbook §6 SQL
   against `$LAB/db/coordinator.db` and `$LAB/db/gateway.db`. Pass:
   - `expected_model_hash_source=pool_manifest`, with the entry's
     `pool_model_id` and the Q `manifest_core_digest`;
   - `settlement_attempt_outputs.usage_source=pool_operator_attested`,
     `settlement_outcome=verified`, `pool_label_status=verified`.
     `ledger_request_credits.usage_source` reads `provider_reported` on pool
     routes by contract (the closed SPEC-005 ledger vocabulary, #1750); join
     on `request_id` / `attempt_n` to read the attested source;
   - one payable ledger row with `provider_credits>0`;
   - a settled reservation;
   - buyer debit equal to finality equal to the ledger, priced at the entry's
     rates.

## 4. Refusals (each: no route snapshot, no ledger row, no upstream call)

| # | Request / action | Expect |
|---|---|---|
| R1 global | `buyer.py --engine llamacpp --model "$M"` (no `--pool`) | refused (503 `engine_unavailable`, or the coordinator's unknown-model refusal); `$M` absent from global `/v1/models` |
| R2 cross-pool | `buyer.py --pool A --engine llamacpp --model "$M"` (A is authorized for the buyer and has the same member) | refused; the `pool/<Q>/…` id is not authority on A's routes |
| R3 out-of-bounds price | the same proposal with a fresh `--slug`, staged with `--completion-rate 2160001` (or `--prompt-rate 13499`), `entry` + `manifest` | `manifest_accepted` refused with the pricing-bounds error; `get-pool` unchanged. `$PS entry Q --remove <id>` before continuing |
| R4 catalog overlap (case C) | a proposal for the Q4_K_M file (sha256 `74a4da8c…`), `entry` + `manifest` | manifest refused with `pool_model_entry_catalog_overlap`. Serving Q4_K_M on pool A still settles through the catalog path: the snapshot has **no** `expected_model_hash_source` key (absent means `catalog`, so catalog preimages stay byte-identical) |
| R5 revocation | `$PS entry Q --remove "$M"`, then `manifest` (the extension is omitted); after the window boundary, `buyer.py --pool Q --engine llamacpp --model "$M"` | the binding is `revoked` with `pool_manifest_entry_revoked`; the request is refused; no new snapshot for `$M` |

For R5, also send one long streaming request just before the boundary. It
must settle from its own snapshot (SPEC-042-R015 in-flight rule): verified,
payable, priced at the snapshot's rates.

**Rollover keeping the entry (no gap).** Sign one more manifest for Q with
the entry unchanged and drive a steady request loop across the window
boundary. Expect zero `503 byom_non_settlement_unavailable`: until the sweep
records `pool_manifest_rebound` (it now runs at activation), a binding to the
immediately prior generation routes when the active core carries the entry
byte-identically. In-flight requests across the boundary settle verified.

Only a revocation between routing and settlement zero-bills an in-flight
attempt: `member_revoked` / `delegation_revoked` for the provider, an R016
attestation removed by a later core, or the pool retired or frozen.

## 5. Case N: native MLX, non-catalog

Repeat §3 and R1/R2/R5 for N on a pool whose entry names `mlx_cache`. Native
MLX is never listed in `runtime_allowlist`, so create the pool with no
allowlist:

```bash
$PS create QN --signer coordinator-cli --encoding 2 --window-seconds 300
```

1. Serve N natively with the lab native CLI (`rig.sh build-native`). Use the
   provider `model` set to the N snapshot and no catalog key. The native
   propose and serve config needs `model_artifact_path` (the snapshot
   directory) and `pool_model_id` (`pool/<QN pool_id>/qwen25-05b-mlx8`).
   `--mlx-cache-dir` takes the Hugging Face `.../hub` directory, not the
   snapshot directory.
2. Propose with `models propose <candidate> --pool <QN pool_id> --slug
   qwen25-05b-mlx8 --json`; the bundle's `model_entry` must carry
   `artifact_hash_algorithm: macprovider.snapshot-manifest.v1` and
   `allowed_runtime_sources: ["mlx_cache"]`. Stage it with `$PS entry QN`
   and the same creator flags as §3 step 3, then sign it into QN.
3. Send requests with `--pool QN --model pool/<QN>/qwen25-05b-mlx8` and no
   engine selector. Expect `200` and settlement as in §3 step 5, with
   `settlement_attempt_outputs.usage_source=coordinator_observed`. The native
   route snapshot carries **no** `runtime_source` (null): a native session's
   runtime class is the empty `runtime_source` under SPEC-022 R-12.1/R-13.5,
   and setting it would route the snapshot through the loopback attestation
   path. `/poolz` echoes the provider hello's `runtime_source`, which the
   native CLI omits, so it is null there too. The pool view of `/v1/models`
   lists the entry with `provider_count` and `total_slots` from the bound
   members and `max_context_tokens` from the entry.
4. Negative: a snapshot entry naming `llamacpp_loopback`, or a GGUF entry
   naming `mlx_cache`, is refused at acceptance (runtime/format pairing).

## 6. Teardown

`$PS event Q member_revoked --provider-id lab-1690-m6-provider` is optional.

The SPEC-042-R016 non-creator member case (a delegated member paid
`pool_operator_attested` only when the creator's core attests its owner
account) needs signed `ProviderPoolDelegationV1` grants, which the lab has no
tooling for. It is covered by
`test/integration/trusted_pool_model_r016_journey_test.go`
(`TestTrustedPoolModelR016NonCreatorMember`) instead.
`rig.sh down` stops only recorded PIDs. Leave `$LAB` for the report digests.

## 7. Report

Post this on #1816. It must contain no prompts, completions, keys or tokens.

- commit, `go version`, llama.cpp build, the G/N/C artifact hashes and
  sizes;
- the `get-pool` JSON for Q and QN after each manifest (digests, entries);
- §3 step 5: status, `engine`, request ids, and every §6 SQL result;
- R1-R5 and the §5 negatives: status, error code, and zero-row SQL;
- the R5 boundary timing: the window `not_before` against the first refused
  request.
