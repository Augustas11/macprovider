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
| Coordinator, gateway, and member CLI contain the #1816 build, deployed coordinator first, then gateway, then CLI | the deployed commit contains the #1816 merge |
| Trusted pools enabled (M1 plan P6) | `trusted_pools.enabled: true`, gateway `features.trusted_pools.enabled: true` |
| Pricing bounds configured (§1) | `trusted_pools.pool_model_pricing_bounds` present in the live coordinator config |
| Pool is `enforce` with the runtime in its allowlist | `get-pool` shows `settlement_mode: enforce` and the engine in `runtime_allowlist` (not needed for native `mlx_cache`) |
| Provider is a member, and its owner account is the creator or an R016 attested member | `get-pool` `members`; for a non-creator member, the account in the core's `pool_attested_members/v1` and the provider under that account in `trusted_pools.provider_owner_account_ids` (§1) |

**Deploy order and the mixed window.** Deploy the coordinator, then the
gateway at once (the order of
[trusted-pool-production-launch.md](trusted-pool-production-launch.md) §9;
the Pearl updater does both in one run with the gateway stopped). A pool-model
attempt, and one served by an R016 attested member, settles under
`spec022-route-snapshot-v2`, which only a #1816 gateway reads; it advertises
that with `X-MacProvider-Internal-Settlement-Route-Snapshot-V2`. While the
#1816 coordinator runs behind an older gateway, a pool-model request answers
`503 pool_model_requires_gateway_upgrade` before dispatch (no buyer debit,
no provider credit) and R016 attested members are not selected; catalog
traffic is unaffected. A gateway-only rollback has the same effect for new
requests. A v2 hold the older gateway keeps (`invalid_settlement_policy_version`)
settles or refunds once the #1816 gateway is back: its startup catch-up
re-checks every hold, ignoring the reconcile backoff.

## 1. Pricing bounds (coordinator config)

Every entry's three rates must fall inside inclusive per-rate bounds held in
coordinator config. If the bounds are absent, every manifest that carries
entries is refused (`pool_model_pricing_bounds_unset`; a rate outside them is
`pool_model_pricing_out_of_bounds`). The bounds are **not** a
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
  manifest_acceptance_witness_path: /var/lib/macprovider/trustpool-manifest-witness.json
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
The object is closed: all six keys, integers only, no other key. Each minimum
must be at most its maximum, and each maximum times 1,048,576 tokens times
`rewards.global_multiplier` in ppm must fit in a signed 64-bit integer (at
multiplier 1.0, a maximum of at most 8,796,093). Anything else fails config
load: the coordinator does not start, or a SIGHUP reload is rejected and the
prior config stays in force. An entry also needs cache-hit ≤ prompt.

**Manifest-acceptance witness.** Do not add
`manifest_acceptance_witness_path` alone to a coordinator that already has
accepted manifests (Pearl does): with the witness file missing, startup logs
`pool support disabled` and keeps running with every trusted pool disabled. It
does not crash. Follow
[trusted-pool-production-launch.md](trusted-pool-production-launch.md) §3a:
one locked step bootstraps the witness with `coordinator-cli trust-pool-admin
manifest-witness-init`, swaps in the config and restarts, followed by the
mandatory post-restart routeability check.

A SIGHUP that changes the bounds or `provider_owner_account_ids` /
`provider_owner_public_keys` applies them everywhere at once: manifest
acceptance, binding, routing, the pool `/v1/models` view, and provider status.
Existing route snapshots keep their recorded prices. A binding whose rates
fall outside tightened bounds stops routing (and its status stops claiming
`pool_attested_earning`) until the creator publishes conforming rates.
An applied reload logs `trusted pools pool-model bounds and owner authority
reloaded` with `trusted_pools_provider_owner_account_ids_applied`, `_changed`,
`_providers` (count) and `_sha256` (digest of the provider -> account map; no
account id is logged). Compare the digest before and after to confirm an
owner remap took effect; a rejected reload logs the rejection instead.

**Owner accounts for attested members (SPEC-042-R016).** A loopback session
of a member the creator does not own binds only when the core's
`pool_attested_members/v1` extension names that member's owner account. The
coordinator matches that account only against
`trusted_pools.provider_owner_account_ids` (owner account → provider ids; a
provider may be listed under one account only):

```yaml
trusted_pools:
  provider_owner_account_ids:
    acct-example-member: ["provider-example-1"]
```

Creator-owned members and native `mlx_cache` sessions need no entry here.

## 2. Provider: propose

On the member Mac, with the model served by the intended engine (for example
`llama-server` for a GGUF file, or native MLX for a snapshot):

1. Run the CLI's propose step against the served model:

   ```bash
   macprovider-cli models propose <candidate> --pool "$POOL_ID" [--slug <slug>] \
     [--prompt-rate-per-mtok N --prompt-cache-hit-rate-per-mtok N --completion-rate-per-mtok N] --json
   ```

   It writes the closed `pool_model_proposal.v1` bundle (`schema`,
   `pool_id`, `candidate_id`, `served_model_ref`, `runtime_source`, and so
   on, with the R015 entry fields under `model_entry`). The hash is computed
   by the CLI from the exact file (`macprovider.gguf-file.v1`) or snapshot
   (`macprovider.snapshot-manifest.v1`). For a llama.cpp file add the
   `--llamacpp-origin` and `--llamacpp-model-path` flags the server uses.
2. `model_entry` fields, which the creator must check:
   - `pool_model_id`: `pool/<pool_id>/<slug>`, where the middle segment is
     the pool id and `slug` matches `[a-z0-9][a-z0-9-]{0,62}`;
   - `allowed_runtime_sources`: GGUF → `llamacpp_loopback`,
     `lmstudio_loopback`, `ollama_loopback`; snapshot → `mlx_cache` (native),
     `mlxlm_loopback`, `omlx_loopback`. Every loopback value must also be in
     the core's `runtime_allowlist`;
   - `disclosure_class: pool_attested_unverified`;
   - `pricing` (the three rates) and `max_context_tokens` are the
     provider's suggestion, or `null` when it gave none;
   - `license` and `paid_serving_attested` are always `null`: they are the
     creator's fields (§3). `creator_requirements` lists what the creator
     must still supply.
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
  (`pool_model_entry_catalog_overlap`), and the catalog path applies to that
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
sign-manifest --encoding 2` (the M1 plan §4.3 step 6 flags, plus `--prev
<current manifest event>` and `--pool-models <file>`). Never hand-encode a
core. The `--pool-models` file is one closed JSON object:

```json
{"model_entries": [{"pool_model_id": "pool/<pool_id>/<slug>",
   "artifact_hash_algorithm": "macprovider.gguf-file.v1", "artifact_hash": "<64 hex>",
   "allowed_runtime_sources": ["llamacpp_loopback"], "license": "Apache-2.0",
   "paid_serving_attested": true,
   "pricing": {"prompt_rate_per_mtok": 20000, "prompt_cache_hit_rate_per_mtok": 5000,
               "completion_rate_per_mtok": 40000},
   "disclosure_class": "pool_attested_unverified", "max_context_tokens": 16384}],
 "attested_members": [{"provider_account_id": "acct-example-member",
                       "runtime_classes": ["llamacpp_loopback"]}]}
```

Each `model_entries[]` item is the bundle's `model_entry` with the creator's
`license`, `paid_serving_attested: true`, and final `pricing` and
`max_context_tokens` filled in; unknown fields are refused. The signer sorts
both lists into canonical order. `attested_members` may be `[]`. Every
manifest must carry the full current lists: an entry or member left out is
removed. Then submit it:

```bash
coordinator-cli trust-pool-admin submit-policy --admin-url http://127.0.0.1:8444 --input manifest-vN.json
```

Acceptance refuses the whole manifest if any entry is wrong, for these
reasons: order or duplicates, a foreign pool segment, a shadowed catalog id,
catalog overlap, a bad runtime pairing, a bad licence, an unattested paid
serving flag, out-of-bounds or missing bounds, a context out of range, or
`observe` mode. The admin surface answers HTTP 400 with the specific closed
code (SPEC-042-R010 manifest acceptance codes, for example
`pool_model_entry_duplicate`, `pool_model_entry_runtime_pairing`,
`pool_model_entry_license_invalid`,
`pool_model_entry_paid_serving_unattested`,
`pool_model_entry_limit_exceeded`), and the coordinator logs
`trusted_pool_manifest_rejected` with the reason.

**Windows.** `sign-manifest` refuses a `--not-before` earlier than the
current window's end, and routing uses the ACTIVE window. A new entry
therefore takes effect when the new window starts, not on submit. A pool
that adds entries often should use short windows.

**Rotation without a gap.** When the new window starts, the binding sweep
runs at once and appends `pool_manifest_rebound` for every unchanged entry.
Until it does, a binding to the immediately prior generation still routes
when the new core carries the same entry byte-identically, so buyers see no
`503` across a rotation that keeps the entry. A changed entry (any field)
routes only after its rebind.

## 4. Admission and status

After the new window is active, the member submits (or keeps) its offer for
the candidate (`macprovider-cli models offer <candidate> --json`) and
restarts `serve` so its session re-evaluates it. Re-submitting the identical
offer is idempotent: it answers the candidate's current status (and
re-evaluates the pool binding), not `409 replay_conflict`.

**Delegated (non-creator) members re-delegate only on substantive changes.**
A new `ProviderPoolDelegationV1` grant binds to the core's policy-terms
digest (`manifest_terms_digest`, SPEC-043-R006). That digest covers every
core field except `manifest_version`, `prev_manifest_core_hash`,
`not_before_unix`, and `expires_at_unix`. Get it from the signed manifest
event with
`coordinator-cli trust-pool-admin policy-terms-digest --manifest manifest-vN.json`.

- A rotation that only moves the window, the version, and the chain keeps
  the terms digest. A delegated member stays bound and paid across it with
  no owner action. This is the normal window-keeper case.
- Any other change is substantive: a model entry or its price, an R016
  attestation, the model or runtime allowlist, the settlement mode, any
  predicate, retention, the split fields, or the signer set version.
  Under it the member stops routing when the new core activates and never
  binds under that core, so the owner must re-delegate. Every R016-attested
  member is a delegated member.
- To re-delegate, wait until the new core is active. The provider owner
  revokes the old grant (`delegation_revoked`, naming the old grant's
  binding) and signs a new grant for the new core's `manifest_terms_digest`.
  The operator then appends `member_admitted` with the new `delegation_id`.
  The binding sweep binds the live offer within seconds; no new offer is
  needed.
- A legacy grant that names a full `manifest_core_digest` keeps working
  exactly as before: it binds only that exact core and needs a
  re-delegation after every rotation, window-only included. Re-delegate it
  with a terms-bound grant at the next rotation.

The coordinator binds the
offer from `offer_submitted`, or from the synthetic-probe states it reaches
first (`sandbox_probe_only`, `network_visible_unpriced`,
`network_admitted_unsettled`). The binding is pool-scoped `catalog_priced`
under the signed-manifest actor (SPEC-047-R011). The provider reads it back
with `macprovider-cli models admission status <candidate> --json`: the
status carries a `pool_binding` object (`binding_scope: pool`, `pool_id`,
`pool_model_id`, `manifest_version`, `manifest_core_digest`, the three
rates, `provider_account_id`, and nullable `observed_catalog_model_key` and
`probe_evidence_digest`), and `catalog_model_key` stays `null`.

```bash
coordinator-cli trust-pool-admin get-pool --admin-url http://127.0.0.1:8444 --pool-id "$POOL_ID"
```

Pass: `manifest_core_digest` equals the submitted event's digest, and the
entry is listed in `model_entries` with `disclosure_class:
pool_attested_unverified` (R016 attestations are in `attested_members`). The
provider's `/poolz` row shows the engine's `runtime_source`, the entry's hash
algorithm, `catalog_admission_mode: pool_entry`, `hash_status: uncatalogued`,
and `state: ready`. `hash_status` is the Tier-2 catalog status, and a pool
entry's pair is by definition not catalog-priced; the pair is checked against
the entry at route time (SPEC-032-R004 case (b), creator-attested), which is
not `hash_verified`. A native
`mlx_cache` member's `/poolz` `runtime_source` is null: it echoes the hello,
which the native CLI omits.

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

New route-snapshot keys are named by SPEC-022-R013 and are the JSON keys of
the coordinator's `RouteSnapshot` (`expected_model_hash_source`,
`pool_model_id`, `manifest_version`, `manifest_core_digest`,
`runtime_source`, `pool_id`, and the `pool_model_*_rate_per_mtok` rates).

```bash
C="sqlite3 -readonly -header /var/lib/macprovider/coordinator.db"
G="sqlite3 -readonly -header /var/lib/macprovider/gateway.db"
RID=<X-Request-ID>
IDS=$($C -noheader "SELECT group_concat(quote(request_id)) FROM request_log WHERE external_request_id='$RID';")
# admission: the offer bound under the signed-manifest actor
$C "SELECT provider_id, served_model_ref, state, actor, reason_code, binding_scope, pool_id, pool_model_id,
           pool_manifest_version, pool_manifest_core_digest, expected_catalog_model_hash_algorithm,
           expected_catalog_model_hash, created_at_utc
    FROM model_admission_events WHERE provider_id='$PROVIDER_ID' ORDER BY id DESC LIMIT 5;"
# route snapshot: pool-manifest identity source, exact entry and core digest
$C "SELECT request_id, json_extract(route_snapshot_json,'\$.expected_model_hash_source') src,
           json_extract(route_snapshot_json,'\$.pool_model_id') pmid,
           json_extract(route_snapshot_json,'\$.manifest_version') mv,
           json_extract(route_snapshot_json,'\$.manifest_core_digest') core,
           json_extract(route_snapshot_json,'\$.runtime_source') rt,
           json_extract(route_snapshot_json,'\$.pool_model_completion_rate_per_mtok') completion_rate, route_snapshot_mode
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

Pass: the newest admission event is `catalog_priced` with
`binding_scope=pool`, `reason_code` `pool_manifest_bound` (or
`pool_manifest_rebound`) and `actor` `pool_manifest:<pool_id>:<version>:<digest>`;
`src=pool_manifest`, `pmid` and `core` equal to the active entry and
digest, `completion_rate` equal to the entry's rate, `rt` the loopback class
(null for a native `mlx_cache` route by contract, SPEC-022 R-13.5),
`settlement_attempt_outputs.usage_source=pool_operator_attested`
(`coordinator_observed` for native), `settlement_outcome=verified`,
`pool_label_status=verified`, one payable ledger row with
`provider_credits>0`, a settled reservation, and `token_source=pool_operator_attested`.
The last query must return 0. `ledger_request_credits.usage_source` reads
`provider_reported` (or `byte_estimated`) on pool routes by contract: it is
the closed SPEC-005 ledger vocabulary, and the attested source is in
`settlement_attempt_outputs` (#1750). A catalog route snapshot has no
`expected_model_hash_source` key; absent means `catalog`.

**In-flight attempts across a rotation.** An attempt routed before a new
generation activates settles from its own snapshot, at its snapshot's rates,
even if the new core removes or changes its entry. It is zero-billed only if,
between routing and settlement, the provider's membership or delegation was
revoked, its R016 attestation was removed by a later core, or the pool was
retired or frozen (SPEC-042-R015).

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

## 8. Global catalog graduation (not built)

SPEC-023 §16.9 specifies a pool-proven path from a pool model to a global
`listed` row. It is not executable yet: the coordinator's
`/admin/model-admission/pool-proven` aggregate, the known-answer probe-evidence
record, and the generator's `macprovider.intake-decision.v2` do not exist, and
`scripts/catalog-release.py` rejects a v2 decision. Do not author one. Until
they land, a pool model joins the global catalog only through the ordinary
intake (`macprovider.intake-decision.v1` with that intake's own evidence). Its
pool binding keeps earning meanwhile; promotion to `recommendable` later
supersedes it (`pool_manifest_catalog_superseded`).

## 9. Signed journey capture (JOURNEY-TRUSTED-POOL-MODEL)

The production run's evidence for SPEC-005-R015, SPEC-006-R018,
SPEC-022-R013, SPEC-042-R015 and SPEC-042-R016 is
[JOURNEY-TRUSTED-POOL-MODEL](../../journeys/JOURNEY-TRUSTED-POOL-MODEL.md).
That file has the step list, the capture-directory layout, `run.json`, and the
SQL; this section is the order of work. SPEC-047-R011 is not promoted by it
(the probe-evidence record does not exist yet).

1. Make a capture directory outside every checkout (`mkdir -m 0700`).
2. Record `preconditions.json` (exact facts in the journey file),
   `deploy.json`, the live bounds (`config/pricing-bounds.json`), the whole
   live `trusted_pools.provider_owner_account_ids` map
   (`config/provider-owner-account-ids.json`), and the owner-authority reload
   log fields (`config/owner-authority-reload.json`).
3. Save the pool's `root_issuer_registered` event as
   `pool/root-issuer-registered.json`. For every manifest you or the keeper
   sign, keep the `sign-manifest --out` file as
   `pool/v<N>/manifest-accepted.json`; every version a route snapshot or a
   relied-on binding names must be there. Right after each of the six role
   manifests activates (native genesis, window-only rotation, price change,
   native entry removal, GGUF added with the attestation, GGUF attestation
   removal; the journey file has the ordering rules), save `get-pool` as
   `pool/v<N>/get-pool.json` and write the six versions into `run.json`.
4. Save both members' `models propose --json` bundles, then, with both
   entries live, the pool and global `/v1/models` views.
5. For each paid request directory, send the request with `curl -D
   response.headers -o response.json` (streams: `-N -o response.sse`), wait
   one pending deadline, then run the per-request SQL. Start each `inflight`
   request (long `max_tokens`) just before its manifest's `not_before`, so it
   is dispatched before and settles after the boundary, and capture its rows
   after it settles. After the price change, the delegated member re-delegates
   and resubmits its offer (re-delegation alone does not rebind).
6. Capture the refusals (each refusal's reservation row too), the
   window-boundary probe loop (probes on both sides of the boundary, each
   naming the `pool_model_id`), the pause and resume, both
   `pool-rollback-preflight` runs (stdout and exit status), the restart times
   and a request dispatched after the gateway restart, then the admission
   events, the pool event counts, and the never-global count (aliased `AS n`).
7. Build `coordinator-cli` from the reviewed `main` commit and build the
   redacted evidence locally:

   ```bash
   (cd phase4-coordinator && go build -o /tmp/coordinator-cli ./cmd/coordinator-cli)
   python3 scripts/build-trusted-pool-model-journey-result.py capture \
     --capture-dir <capture dir> --coordinator-cli /tmp/coordinator-cli \
     --output journeys/evidence/trusted-pool-model-<run>.redacted.json
   ```

   It verifies the signed events, then fails on the first unmet expectation
   and names the file and field. Commit the `.redacted.json` and the
   `.manifests/` bundle beside it, in a PR, never the capture directory.
   After it merges, dispatch `promote-signed-trusted-pool-model-journey.yml`
   with the deployed source SHA, the evidence path and the requirement ids.
