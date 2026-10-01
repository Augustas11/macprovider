# Pool-scoped model admission (#1816)

A Trusted Pool creator can admit a model that is **not** in the global
catalog, for that pool only. The provider proposes the exact artifact. The
creator reviews the licence and price and signs the entry into the pool's
policy core. The coordinator then binds matching provider sessions to the
pool, and only that pool's buyers can reach them. Settlement is
`pool_operator_attested` and is credited to the provider. The model never
becomes a global catalog identity, never reaches `settlement_capable`, and is
disclosed as **Pool-attested, not network-verified**.

Normative sources: SPEC-042-R015/R016 (entries, member attestations),
SPEC-047-R011 (binding), SPEC-005-R015 (trusted price and bounds),
SPEC-022-R013 (route-snapshot identity source), and SPEC-043-R014 (buyer
disclosure).

Encoding: entries are signed as the `pool_model_entries/v1` extension of a
**v2** policy core. They are part of that core's digest and signature. A v2
core without the extension keeps its exact bytes.

Lab rehearsal: [docs/testing/1816-pool-model-e2e-brief.md](../testing/1816-pool-model-e2e-brief.md).
Pool creation, keys and the base manifest flow:
[trusted-pool-m1-activation-plan.md](trusted-pool-m1-activation-plan.md) §4.

## 0. Preconditions

| Check | Pass |
|---|---|
| Coordinator, gateway, and member CLI contain the #1816 build | the deployed commit contains the #1816 merge |
| Trusted pools enabled (M1 plan P6) | `trusted_pools.enabled: true`, gateway `features.trusted_pools.enabled: true` |
| Pricing bounds configured (§1) | `trusted_pools.pool_model_pricing_bounds` present in the live coordinator config |
| Pool is `enforce` with the runtime in its allowlist | `get-pool` shows `settlement_mode: enforce` and the engine in `runtime_allowlist` (not needed for native `mlx_cache`) |
| Provider is a member, and its owner account is the creator or an R016 attested member | `get-pool` `members`; the account in the core's `pool_attested_members/v1` |

## 1. Pricing bounds (coordinator config)

Every entry's three rates must fall inside inclusive per-rate bounds held in
coordinator config. If the bounds are absent, every manifest that carries
entries is refused (`ErrPoolModelPricingBounds`). The bounds are **not** a
rate-card field: the signed rate card is a closed schema (SPEC-023
FeedSchema-A), and the fleet CLI rejects extra keys as
`rate_card_integrity_failure`. Changing the bounds is a coordinator config
change; it is not a catalog release.

**Operator TODO, proposed values.** These are derived from the current signed
rate card (`phase3-binary/dist/static/rate-card.json`, and equal to
`rewards.rate_card` in `phase4-coordinator/dist/coordinator.yaml`). They are the
minimum and maximum of each rate across the 18 model rows. The `default`
fall-through row is excluded.

| Rate (credits per Mtok) | Min (row) | Max (row) |
|---|---|---|
| `prompt_rate_per_mtok` | 13,500 (`meta-llama/llama-3.1-8b-instruct`) | 425,000 (`qwen2.5-coder-32b-instruct`) |
| `prompt_cache_hit_rate_per_mtok` | 3,375 (`meta-llama/llama-3.1-8b-instruct`) | 106,250 (`qwen2.5-coder-32b-instruct`) |
| `completion_rate_per_mtok` | 27,000 (`meta-llama/llama-3.1-8b-instruct`) | 2,160,000 (`qwen3.6-27b`) |

```yaml
trusted_pools:
  pool_model_pricing_bounds:
    min_prompt_rate_per_mtok: 13500
    max_prompt_rate_per_mtok: 425000
    min_prompt_cache_hit_rate_per_mtok: 3375
    max_prompt_cache_hit_rate_per_mtok: 106250
    min_completion_rate_per_mtok: 27000
    max_completion_rate_per_mtok: 2160000
```

Recompute these from the rate card in force when you apply them. The key
shape (without values) is a comment in `phase4-coordinator/dist/coordinator.yaml`.
Each minimum must be at most its maximum. An entry also needs cache-hit ≤ prompt.

## 2. Provider: propose

On the member Mac, with the model served by the intended engine (for example
`llama-server` for a GGUF file, or native MLX for a snapshot):

1. Run the CLI's pool-model propose step. It writes a
   `pool_model_proposal.v1` bundle (`schema_version` plus the R015 entry
   fields), with the hash computed by the CLI from the exact file
   (`macprovider.gguf-file.v1`) or snapshot (`macprovider.snapshot-manifest.v1`).
   Take the exact command from `macprovider-cli models --help` on the
   #1816 build.
2. Fields the provider fills, and the creator must check:
   - `pool_model_id`: `pool/<pool_id>/<slug>`, where the middle segment is
     the pool id and `slug` matches `[a-z0-9][a-z0-9-]{0,62}`;
   - `allowed_runtime_sources`: GGUF → `llamacpp_loopback`,
     `lmstudio_loopback`, `ollama_loopback`; snapshot → `mlx_cache` (native),
     `mlxlm_loopback`, `omlx_loopback`. Every loopback value must also be in
     the core's `runtime_allowlist`;
   - `license`, `paid_serving_attested: true`, the three `pricing` rates,
     `disclosure_class: pool_attested_unverified`, `max_context_tokens`.
3. Send the bundle to the creator out of band. It contains hashes and
   metadata only; it has no keys and no tokens.

A proposal is a request, not a price source. No route uses a provider's
proposed price until the creator signs it into the pool's core.

## 3. Creator: review and sign

Review before signing. The signature is the creator's administrative
attestation (SPEC-042-R004):

- **Identity.** Recompute the hash on a trusted copy of the artifact. Use
  `shasum -a 256 <file>.gguf` for GGUF; for a snapshot, run the CLI's
  snapshot-manifest hash. It must equal `artifact_hash`.
- **Not already global.** If the artifact pair is already in the global
  catalog, the coordinator rejects the manifest
  (`ErrPoolModelCatalogOverlap`), and the catalog path applies to that
  model. Do not propose catalog models as pool entries.
- **Licence.** `license` must be a pinned SPDX id or `LicenseRef-*`. A
  `LicenseRef-*` needs the licence text in the pool's reviewed disclosure
  bundle. Read the licence: it must permit paid serving, because
  `paid_serving_attested: true` is the creator's claim. Refuse non-commercial
  licences (for example `CC-BY-NC-4.0`) for a paid pool.
- **Price.** Each rate must fall inside §1's bounds, with cache-hit ≤ prompt.
  The price is what buyers in this pool pay under the unchanged SPEC-005
  formula and platform fee.
- **Context.** `max_context_tokens` must be no larger than what the engine is
  started with (`llama-server -c`).

Sign the next manifest with the entry, using `coordinator-cli trust-pool-admin
sign-manifest` (the M1 plan §4.3 step 6 flags, plus `--prev <current
manifest event>` and the entries input file). Never hand-encode a core. The
entries file is a JSON array of entries, strictly ascending by
`pool_model_id`. Pass it as `--model-entries <file>` (confirm the flag name
against the #1816 `coordinator-cli` build). Then submit it:

```bash
coordinator-cli trust-pool-admin submit-policy --admin-url http://127.0.0.1:8444 --input manifest-vN.json
```

Acceptance refuses the whole manifest if any entry is wrong, for these
reasons: order or duplicates, a foreign pool segment, a shadowed catalog id,
catalog overlap, a bad runtime pairing, a bad licence, an unattested paid
serving flag, out-of-bounds or missing bounds, a context out of range, or
`observe` mode.

**Windows.** `sign-manifest` refuses a `--not-before` earlier than the
current window's end, and routing uses the ACTIVE window. A new entry
therefore takes effect when the new window starts, not on submit. A pool
that adds entries often should use short windows.

## 4. Admission and status

After the new window is active, restart the member's `serve` so its session
re-evaluates the offer. The binding is pool-scoped `catalog_priced` under
the signed-manifest actor (SPEC-047-R011).

```bash
coordinator-cli trust-pool-admin get-pool --admin-url http://127.0.0.1:8444 --pool-id "$POOL_ID"
```

Pass: `manifest_core_digest` equals the submitted event's digest, and the
entry is listed with `disclosure_class: pool_attested_unverified`. The
provider's `/poolz` row shows the engine's `runtime_source`, the entry's hash
algorithm, `hash_status: hash_verified`, and `state: ready`.

## 5. Buyer request

`model` is the `pool_model_id`. Send the pool and engine selectors:

```bash
curl -sS -D h.txt https://api.malibu.tech/v1/chat/completions \
  -H "Authorization: Bearer $BUYER_KEY" -H 'Content-Type: application/json' \
  -H "X-MacProvider-Pool-Select: $POOL_ID" -H 'X-MacProvider-Engine-Select: llamacpp' \
  -d '{"model":"pool/'"$POOL_ID"'/<slug>","messages":[{"role":"user","content":"ref <uuid>: hi"}],"max_tokens":64}'
```

Expected: `200` and `X-MacProvider-Engine: llamacpp_loopback`. The route and
response disclosure say pool-attested, not network-verified. For a native
snapshot entry, omit the engine selector. The same `model` with no pool
header, with another pool's header, or on the global `/v1/models` list is
refused or absent.

## 6. Verification SQL (read-only)

New route-snapshot keys are named by SPEC-022-R013. Confirm the JSON keys
against the deployed build before relying on a zero-row result.

```bash
C="sqlite3 -readonly -header /var/lib/macprovider/coordinator.db"
G="sqlite3 -readonly -header /var/lib/macprovider/gateway.db"
RID=<X-Request-ID>
IDS=$($C -noheader "SELECT group_concat(quote(request_id)) FROM request_log WHERE external_request_id='$RID';")
# admission: the offer bound under the signed-manifest actor
$C "SELECT provider_id, served_model_ref, state, actor, reason_code, expected_catalog_model_hash_algorithm,
           expected_catalog_model_hash, created_at_utc
    FROM model_admission_events WHERE provider_id='$PROVIDER_ID' ORDER BY id DESC LIMIT 5;"
# route snapshot: pool-manifest identity source, exact entry and core digest
$C "SELECT request_id, json_extract(route_snapshot_json,'\$.expected_model_hash_source') src,
           json_extract(route_snapshot_json,'\$.pool_model_id') pmid,
           json_extract(route_snapshot_json,'\$.manifest_version') mv,
           json_extract(route_snapshot_json,'\$.manifest_core_digest') core,
           json_extract(route_snapshot_json,'\$.runtime_source') rt, route_snapshot_mode
    FROM settlement_route_snapshots WHERE request_id IN ($IDS);"
$C "SELECT request_id, usage_source, terminal_state FROM settlement_attempt_outputs WHERE request_id IN ($IDS);"
$C "SELECT request_id, receipt_result, settlement_outcome, reason, pool_label_status, closed
    FROM settlement_receipt_verdicts WHERE request_id IN ($IDS);"
$C "SELECT l.provider_id, l.usage_source, l.provider_credits, l.quarantined, (p.id IS NOT NULL) payable
    FROM ledger_request_credits l LEFT JOIN spec022_payable_request_credits p ON p.id = l.id WHERE l.request_id IN ($IDS);"
$G "SELECT request_id, status, settlement_hold FROM quota_reservations WHERE request_id='$RID';"
$G "SELECT request_id, prompt_tokens, completion_tokens, token_source FROM usage_events WHERE request_id='$RID';"
# never global: no snapshot for this pool_model_id without a pool
$C "SELECT count(*) FROM settlement_route_snapshots
    WHERE json_extract(route_snapshot_json,'\$.pool_model_id') IS NOT NULL
      AND coalesce(json_extract(route_snapshot_json,'\$.pool_id'),'')='';"
```

Pass: `src=pool_manifest`, `pmid` and `core` equal to the active entry and
digest, `usage_source=pool_operator_attested`, `settlement_outcome=verified`,
`pool_label_status=verified`, one payable ledger row with
`provider_credits>0`, a settled reservation, and `token_source=pool_operator_attested`.
The last query must return 0.

## 7. Rollback

In order of speed:

1. **Pause the pool** (immediate; new pool requests fail closed, global
   traffic untouched):

   ```bash
   coordinator-cli trust-pool-admin set-lifecycle --admin-url http://127.0.0.1:8444 \
     --pool-id "$POOL_ID" --lifecycle paused --reason "1816 rollback" --operation-id pm-pause-<n>
   ```

   In-flight attempts settle from their immutable route snapshot (M1 plan
   §6).
2. **Remove the entry**: sign the next manifest without it. Removing the
   last entry omits the extension. Submit it. When its window is active,
   every binding to the entry is revoked with `pool_manifest_entry_revoked`,
   and no new route snapshot is inserted for it. A later manifest cannot
   resurrect the entry by rollback. Because of the window rule (§3), pause
   first if the removal must be immediate.
3. **Revoke the member** (`revoke-provider`) or remove its R016
   attestation, to remove one provider rather than the model.
4. **Retire**: pause (or drain) first, then `set-lifecycle --lifecycle
   retired`. An `active` pool cannot be retired directly, and `retired`
   returns `delivery_drain_pending` until in-flight deliveries finish.

After rollback, re-run §6's queries with a fresh request: expect a refusal
and zero new snapshots for the `pool_model_id`.
