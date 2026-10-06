# JOURNEY-TRUSTED-POOL-MODEL

Status: defined; no signed run yet (SPEC-005-R015, SPEC-006-R018, SPEC-022-R013, SPEC-042-R015 and SPEC-042-R016 stay pending until a signed envelope from this contract is promoted)
Owner: settlement / Trusted Pool conformance
Specs: SPEC-005, SPEC-006, SPEC-022, SPEC-042, SPEC-047
Requirements: SPEC-005-R015, SPEC-006-R018, SPEC-022-R013, SPEC-042-R015, SPEC-042-R016
Authority domains: billing-settlement-formula, buyer-api-error-contract, verified-model-settlement, pool-control-plane
Issue: https://github.com/Augustas11/macprovider/issues/1816
Execution mode: production-operator-internal-pool
Run plan: `docs/runbooks/pool-scoped-model-admission.md` (§9 is the capture recipe)
Evidence builder: `scripts/build-trusted-pool-model-journey-result.py` (`capture` writes the redacted evidence, `payload` builds the unsigned journey-result)
Signer: `.github/workflows/promote-signed-trusted-pool-model-journey.yml`

## Purpose

This journey defines the evidence that pool-scoped, non-catalog models
(#1816) work end to end on a production coordinator: a creator signs two
`pool_model_entries/v1` entries into an `enforce` candidate pool's v2 core,
non-creator members bind to them, buyers of that pool alone see and buy them
at the signed entry price, settlement is `verified` with a payable provider
credit, and the entries and attestations revoke at the current generation.

It is the signed journey SPEC-042 asks of a core that carries the R015/R016
extensions: one enforce-mode pool request served by an allowlisted runtime
with a verified receipt and a provider ledger credit, plus exact entry and
member matching, native `mlx_cache` entry serving, and current-generation
revocation.

This document is a test contract. It is not evidence that the journey passed
or that any mapped requirement is conformant.

## Requirements this journey may promote

SPEC-005-R015 (entry pricing within bounds), SPEC-006-R018 (pool `/v1/models`
view and disclosure), SPEC-022-R013 (pool-manifest route-snapshot identity),
SPEC-042-R015 (pool model entries) and SPEC-042-R016 (attested non-creator
members).

SPEC-047-R011 is **not** promotable by this journey. Its promotion also needs
the coordinator-owned `model_admission_probe_evidence.v1` record linked from
the bind event, which does not exist yet (`probe_evidence_digest` is always
null). The journey still checks and records what R011's signed-journey clause
describes: each member's offer binds pool-scoped `catalog_priced` under the
signed-manifest actor (with whether an unmatched pre-bind state preceded the
bind), serves and settles on its pool route, never reaches
`settlement_capable`, and is absent from global routing. R011 stays mapped
only to JOURNEY-NETWORK-MODEL-ADMISSION.

## Out of scope

- A SPEC-043 external-creator production launch. The pool is an operator
  `candidate` pool.
- Global catalog graduation (SPEC-023 §16.9, not built).
- Payout execution. Payout stays disabled; the ledger credit is the evidence.
- Buyer-visible `usage.prompt_tokens` equal to the debit on a templated prompt
  (E2E-F1, carried): recorded, not required.

## Fixed shape of the run

- Pool: v2 core, `settlement_mode: enforce`, `runtime_allowlist` including
  `llamacpp_loopback`, `launch_environment: candidate`.
- **Native entry** `pool/<pool>/<native slug>`:
  `macprovider.snapshot-manifest.v1`, `allowed_runtime_sources` including
  `mlx_cache`, served by a **delegated non-creator** member
  (`ProviderPoolDelegationV1` bound to the terms digest). Native routes settle
  `coordinator_observed` and carry no `runtime_source`,
  `pool_operator_account_id` or `pool_member_account_id` (SPEC-022 R-13.5).
- **GGUF entry** `pool/<pool>/<gguf slug>`: `macprovider.gguf-file.v1`,
  `llamacpp_loopback`, served by a **non-creator member whose owner account
  is attested** in `pool_attested_members/v1`. GGUF routes settle
  `pool_operator_attested` and carry the creator and member accounts.
- Six role manifests, six different versions, in
  `run.json.manifest_versions`: `native_genesis` (the native entry),
  `window_rotation` (window-only: the same terms digest and byte-equal
  entries as the role manifest before it), `price_change` (exactly one
  entry's rates change against the role manifest before it, nothing else),
  `entry_removal` (the native entry removed; zero entries and no extension
  is fine), `gguf_added` (both entries, the GGUF owner attested for
  `llamacpp_loopback`), and `attestation_removal` (the GGUF owner's
  attestation removed).
- The only ordering rules: `native_genesis` is the smallest version;
  `window_rotation` < `price_change` < `entry_removal`; and
  `attestation_removal` comes after `gguf_added`. `gguf_added` may come before the window rotation or after
  the entry removal (the Pearl run: v1 genesis, v2 window, v3 price change,
  v4 entry removal, v5 GGUF added with the native entry re-added, keeper
  versions, then the attestation removal).
- A price change is substantive: the delegated member's binding is revoked
  (`pool_membership_revoked`), and re-delegation alone does not rebind. The
  member re-delegates and resubmits its offer, which binds
  (`pool_manifest_bound`) under the `price_change` terms
  (`test/e2e-1816/vm/s5-rotation.sh` `reoffer_5`).
- Keeper rotations between roles are fine. Every captured manifest that is
  not a role manifest must be a window-only rotation of the latest role at or
  below it (equal terms digest, entries and attestations). Every manifest
  version a route snapshot, a binding the journey relies on, or the pool
  `/v1/models` view names must be captured (`pool/v<N>/manifest-accepted.json`).
- Manifests are verified, not trusted: the builder runs
  `coordinator-cli trust-pool-admin verify-manifest` (the root registration's
  proof of possession, each event's root signature and snapshot, each core's
  R001/R015/R016 acceptance grammar, and one chain) and derives every entry,
  attestation, digest, terms digest and `not_before` from its output.
  `get-pool` must equal the verified core.

## Physical steps

1. `step-01-preconditions` - the five preconditions hold with their exact
   facts (below), `deploy-build` names the evidence's source commit, and the
   coordinator deployed before the gateway, the gateway before both member CLIs.
2. `step-02-pricing-bounds-and-owner-authority` - the bounds are the closed
   six-key int64 object with each min at most its max and each max times
   1,048,576 times the routes' multiplier inside int64; their recomputed
   SPEC-005-R015 digest is the `pool_model_pricing_bounds_sha256` every pool
   route carries; every rate of every verified core sits inside them; the
   reload applied the owner map, and the captured
   `trusted_pools.provider_owner_account_ids` map recomputes the logged digest
   and provider count.
3. `step-03-pool-genesis-with-entries` - the verified chain belongs to the
   journey pool and creator, candidate, enforce, v2, `llamacpp_loopback`
   allowlisted; `native_genesis` carries exactly the native entry (exact hash,
   algorithm, sorted runtime set paired with the hash format, licence,
   `paid_serving_attested`, `pool_attested_unverified`, context 1..2^20);
   `get-pool` at every role version equals its verified core and the pool is
   active and routeable at genesis.
4. `step-04-non-creator-members` - neither member account is the creator; the
   GGUF member's recorded owner (from the owner map) is the attested account;
   attestations are exactly that account for `[llamacpp_loopback]` from
   `gguf_added` until `attestation_removal`, and none elsewhere; the history
   has at least two `delegation_granted` and two `member_admitted`.
5. `step-05-proposal-bundles` - each `pool_model_proposal.v1` bundle names
   the pool, its runtime, no catalog key, null licence and paid-serving flag,
   and exactly the signed entry's id, hash and algorithm.
6. `step-06-offer-binding` - each member's first `pool_manifest_bound`
   binding is `catalog_priced`, `binding_scope=pool`, for its exact entry,
   with actor exactly `pool_manifest:<pool>:<version>:<core digest>` of a
   verified core and created after that core's `not_before`; every pool
   binding's actor names its own version and core; no `settlement_capable`.
7. `step-07-pool-models-disclosure` - the pool view lists exactly the signed
   entries of one verified manifest, each `object: model` with the closed
   12-field `macprovider_pool_model` object equal to the signed entry (ids,
   hash, version and digest, runtime subset, disclosure, context, the three
   rates and the routes' multiplier), no duplicate or foreign id; the global
   view has no `pool/` id or pool object; the never-global count is 0.
8. `step-08-native-entry-paid` - for each native request: 200 with
   `X-MacProvider-Engine: mlx_cache`, the disclosure header and the core
   digest header; the X-Request-ID maps through `request_log` to exact
   `(request_id, attempt_n)` keys that join the route snapshot, attempt
   output, receipt verdict, ledger row and payable view, and the gateway
   reservation and usage event are the X-Request-ID's; the snapshot is
   `pool_manifest`-sourced, v2, enforce, for the exact entry, with expected
   and provider-reported hash and algorithm equal to the entry, a positive
   `pool_generation`, the version's core digest, and the signed entry rates;
   the verdict binds the snapshot digest, the hashes and `model_id =
   pool_model_id`, and is `valid`, `verified`, label `verified`, closed; the
   single payable unquarantined ledger row's gross and provider credits equal
   the SPEC-005 recomputation (round half even) from the frozen snapshot
   rates, multiplier and share; the reservation settles the debited tokens;
   usage is `coordinator_observed`.
9. `step-09-attested-member-paid` - the same for the GGUF entry,
   `llamacpp_loopback`, `pool_operator_attested`, with
   `pool_operator_account_id` the creator and `pool_member_account_id` the
   attested owner, attested at the snapshot's version.
10. `step-10-refusals` - no pool header (404 `model_not_found`), another
    authorized pool's header (404 `model_not_found`), a wrong engine selector
    (503 `engine_unavailable`): no route snapshot, no ledger row, and exactly
    one reservation for the X-Request-ID, `refunded`, zero tokens, no hold.
11. `step-11-window-rotation-no-gap` - `window_rotation` keeps the terms
    digest, entries and attestations under a new core; the delegated native
    member is `pool_manifest_rebound` at that version after activation;
    probes are all 200 and fall on both sides of its `not_before`; a request
    routed under the `window_rotation` terms after activation is paid.
12. `step-12-price-change-in-flight` - `price_change` changes exactly one
    entry's rates and nothing else; the in-flight request was dispatched
    before the price change's `not_before` and settled after it, at the prior
    rates; the member's binding was revoked (`pool_membership_revoked`) after
    activation, it re-offered, and the new offer bound under the
    `price_change` terms; a request routed under those terms pays the new rates.
13. `step-13-current-generation-revocation` - `entry_removal` removes exactly
    the native entry; the in-flight native request was dispatched before its
    `not_before` and settled after it; the native binding was revoked after
    activation (`pool_manifest_entry_revoked`, or `pool_membership_revoked`
    when the term change voided the delegated grant first) from the binding it
    held; the native model afterwards answers 404 `model_not_found` with no
    snapshot. `attestation_removal` drops the attestation; the GGUF binding
    was revoked `pool_membership_revoked` after activation; the GGUF model
    afterwards is refused (404/503, a no-member code) with no snapshot.
14. `step-14-pause-resume-rollback` - while paused a pool request answers 503
    `pool_unavailable` and refunds; after resume a pool request is paid; the
    history has at least two `lifecycle_changed`; `pool-rollback-preflight
    --target-tier m9` exits 3 with `rollback_blocked: true` and a non-empty
    `cannot_replay`, and `--target-tier p1816` exits 0 with neither.
15. `step-15-restart-ordering` - the coordinator restarts before the gateway,
    and a pool-model request dispatched after the gateway restart is paid.
16. `step-16-redaction` - the evidence is a closed schema (every section
    required, no unknown key at any level); the result, step assertions and
    observations are derived from the evidence, never free text; no prompt,
    completion, key, URL, host name, IP address or path; account, provider and
    other-pool ids are HMAC-SHA256 fingerprints under a per-run salt; every raw
    capture file is kept only as `{sha256, bytes}`.

## Capture layout

The operator captures into a local directory (mode 0700, never committed).
SQL results use `sqlite3 -readonly -json` (an empty result is an empty file).
`$RID` is the request's `X-Request-ID`; `C`, `G` and `IDS` are defined with
the SQL below. Every `response.headers` is `curl -D` output and must carry
`Date` and `X-Request-ID`.

```
capture/
  run.json                                 # operator identifiers (below)
  preconditions.json                       # exact facts, below
  deploy.json                              # {"coordinator_deployed_at", "gateway_deployed_at",
                                           #  "native_member_cli_installed_at", "gguf_member_cli_installed_at"}: UTC ...Z (seconds)
  config/pricing-bounds.json               # the live trusted_pools.pool_model_pricing_bounds object (six integer keys)
  config/owner-authority-reload.json       # from the "trusted pools pool-model bounds and owner authority reloaded" log line:
                                           # {"bounds_set": true, "provider_owner_account_ids_applied": true,
                                           #  "provider_owner_account_ids_providers": <n>, "provider_owner_account_ids_sha256": "<64 hex>"}
  config/provider-owner-account-ids.json   # the live trusted_pools.provider_owner_account_ids map, whole: {"<account>": ["<provider>", ...]}
  pool/root-issuer-registered.json         # the root_issuer_registered event (sign-root --out, or trustpool_events payload)
  pool/trustpool-events.json               # SELECT event_type, COUNT(*) AS n FROM trustpool_events WHERE pool_id='$POOL_ID' GROUP BY 1;
  pool/v<N>/manifest-accepted.json         # every role version, every keeper version captured, and every version a
                                           # snapshot, relied-on binding or the models view names (sign-manifest --out)
  pool/v<N>/get-pool.json                  # role versions only: trust-pool-admin get-pool right after that version activates
  proposals/native.json                    # macprovider-cli models propose ... --json (native member)
  proposals/gguf.json                      # same, GGUF member
  admission/model-admission-events.json    # SQL below (every row of both members, id order, with created_at_utc)
  models/pool.json                         # buyer GET /v1/models with X-MacProvider-Pool-Select (both entries live)
  models/global.json                       # buyer GET /v1/models without a pool header
  never-global.json                        # the runbook §6 never-global count, aliased: [{"n": 0}]
  requests/native-nonstream/  requests/native-stream/  requests/gguf-nonstream/  requests/gguf-stream/
  rotation/window-only/after/              # paid, routed under the window_rotation terms, after its not_before
  rotation/window-only/probes.json         # [{"at": "...Z", "status": 200, "pool_model_id": "pool/<pool>/<slug>"}, ...]:
                                           #  time order, at least one before and one after window_rotation's not_before
  rotation/price-change/inflight/          # paid, repriced entry, dispatched before price_change's not_before, settled after
  rotation/price-change/after/             # paid, repriced entry, routed under the price_change terms
  rotation/entry-removal/inflight/         # paid, native, dispatched before entry_removal's not_before, settled after
  rotation/entry-removal/after/            # refusal after entry_removal activates: 404 model_not_found
  rotation/attestation-removal/after/      # refusal after attestation_removal activates (GGUF entry)
  refusals/no-pool-header/  refusals/other-pool/  refusals/wrong-engine/
  pause/paused/                            # refusal while paused: 503 pool_unavailable
  pause/resumed/                           # paid, after resume
  rollback/preflight-m9.json + .rc         # stdout (one JSON object) and exit status of pool-rollback-preflight --target-tier m9
  rollback/preflight-p1816.json + .rc
  restart/order.json                       # {"coordinator_restarted_at": "...Z", "gateway_restarted_at": "...Z"}
  restart/after/                           # paid, dispatched after the gateway restart
```

A **paid request directory** holds `response.headers`, `response.json`
(non-streaming) **or** `response.sse` (only the `*-stream` directories), and
`request_log.json`, `route_snapshots.json`, `attempt_outputs.json`,
`receipt_verdicts.json`, `ledger.json`, `quota_reservations.json`,
`usage_events.json`. A **refusal directory** holds `response.headers`,
`response.json`, `route_snapshots.json`, `ledger.json` and
`quota_reservations.json`. Capture verdict, ledger and reservation rows only
after the attempt settled (at least one `pending_deadline_seconds`).

`preconditions.json` is
`{"<id>": {"status": "pass", "observed": {...}, "checked_at": "...Z"}}` with
exactly these ids and facts:

| id | `observed` |
|---|---|
| `deploy-build` | `{"production": true, "coordinator_version": "v1.8.N", "gateway_version": "v1.8.N", "contains_commit": "<first 12 hex of source_commit>"}` |
| `trusted-pools-enabled` | `{"coordinator": true, "gateway": true}` |
| `pricing-bounds-configured` | `{"bounds_set": true}` |
| `gateway-route-snapshot-v2` | `{"advertised": true}` |
| `payout-disabled` | `{"payout_enabled": false}` |

`run.json`:

```json
{
  "run_id": "trusted-pool-model-<UTC yyyymmddThhmmssZ>",
  "captured_at": "<UTC ...Z, not in the future>",
  "expires_at": "<YYYY-MM-DD, at most 30 days after captured_at>",
  "source_commit": "<40-hex commit of the deployed coordinator/gateway>",
  "coordinator_version": "v1.8.N",
  "accepted_id": "Augustas11/macprovider:v<ver>@<commit>",
  "native_member_cli_sha256": "<64-hex>",
  "gguf_member_cli_sha256": "<64-hex>",
  "llama_server_build": "b11149",
  "operator_role": "pearl-actor",
  "operator_identity": "<text; only a salted fingerprint is kept>",
  "hardware_profile": "<lowercase snake/kebab token>",
  "pool_id": "<POOL_ID>",
  "other_pool_id": "<the other authorized pool used in refusals/other-pool>",
  "creator_account_id": "<creator account>",
  "buyer_account_id": "<buyer account>",
  "native_member_provider_id": "<provider id>",
  "native_member_account_id": "<its owner account>",
  "gguf_member_provider_id": "<provider id>",
  "gguf_member_account_id": "<its owner account, the attested one>",
  "native_entry": {"slug": "qwen25-05b-mlx8", "artifact_hash": "<64-hex snapshot-manifest hash>"},
  "gguf_entry": {"slug": "qwen25-05b-q8-gguf", "artifact_hash": "<64-hex gguf-file hash>"},
  "manifest_versions": {"native_genesis": 1, "window_rotation": 2, "price_change": 3,
                        "entry_removal": 4, "gguf_added": 5, "attestation_removal": 7}
}
```

SQL per request directory (an empty `IDS` is a valid empty `IN ()` list):

```bash
C="sqlite3 -readonly -json /var/lib/macprovider/coordinator.db"
G="sqlite3 -readonly -json /var/lib/macprovider/gateway.db"
IDS=$(sqlite3 -readonly -noheader /var/lib/macprovider/coordinator.db \
  "SELECT group_concat(quote(request_id)) FROM request_log WHERE external_request_id='$RID';")
$C "SELECT request_id, attempt_n, external_request_id, status, pool_id FROM request_log WHERE external_request_id='$RID';" > request_log.json
$C "SELECT request_id, attempt_n, provider_id, route_snapshot_mode, route_snapshot_policy_version, route_snapshot_digest,
           provider_reported_model_hash, expected_catalog_model_hash, model_id, route_decision_ts_unix_ms,
           json_extract(route_snapshot_json,'\$.pool_id') pool_id,
           json_extract(route_snapshot_json,'\$.expected_model_hash_source') expected_model_hash_source,
           json_extract(route_snapshot_json,'\$.pool_model_id') pool_model_id,
           json_extract(route_snapshot_json,'\$.manifest_version') manifest_version,
           json_extract(route_snapshot_json,'\$.manifest_core_digest') manifest_core_digest,
           json_extract(route_snapshot_json,'\$.pool_generation') pool_generation,
           json_extract(route_snapshot_json,'\$.runtime_source') runtime_source,
           json_extract(route_snapshot_json,'\$.pool_operator_account_id') pool_operator_account_id,
           json_extract(route_snapshot_json,'\$.pool_member_account_id') pool_member_account_id,
           json_extract(route_snapshot_json,'\$.expected_catalog_model_hash_algorithm') expected_catalog_model_hash_algorithm,
           json_extract(route_snapshot_json,'\$.provider_reported_model_hash_algorithm') provider_reported_model_hash_algorithm,
           json_extract(route_snapshot_json,'\$.pool_model_prompt_rate_per_mtok') pool_model_prompt_rate_per_mtok,
           json_extract(route_snapshot_json,'\$.pool_model_prompt_cache_hit_rate_per_mtok') pool_model_prompt_cache_hit_rate_per_mtok,
           json_extract(route_snapshot_json,'\$.pool_model_completion_rate_per_mtok') pool_model_completion_rate_per_mtok,
           json_extract(route_snapshot_json,'\$.pool_model_pricing_bounds_sha256') pool_model_pricing_bounds_sha256,
           json_extract(route_snapshot_json,'\$.pool_model_global_multiplier_ppm') pool_model_global_multiplier_ppm,
           json_extract(route_snapshot_json,'\$.pool_model_provider_share_bps') pool_model_provider_share_bps
    FROM settlement_route_snapshots WHERE request_id IN ($IDS);" > route_snapshots.json
$C "SELECT request_id, attempt_n, provider_id, terminal_state, usage_source, terminal_state_ts_unix_ms
    FROM settlement_attempt_outputs WHERE request_id IN ($IDS);" > attempt_outputs.json
$C "SELECT request_id, attempt_n, provider_id, receipt_result, settlement_outcome, reason, closed, pool_label_status,
           route_snapshot_digest, provider_reported_model_hash, expected_catalog_model_hash, model_id, model_hash, received_at_unix_ms
    FROM settlement_receipt_verdicts WHERE request_id IN ($IDS);" > receipt_verdicts.json
$C "SELECT l.id, l.request_id, l.attempt_n, l.provider_id, l.status, l.charged_prompt_tokens, l.cached_prompt_tokens,
           l.completion_tokens, l.estimated_completion_tokens, l.usage_source, l.prompt_rate_per_mtok, l.completion_rate_per_mtok,
           l.global_multiplier_ppm, l.gross_credits, l.provider_share_bps, l.provider_credits, l.quarantined, (p.id IS NOT NULL) payable
    FROM ledger_request_credits l LEFT JOIN spec022_payable_request_credits p ON p.id = l.id
    WHERE l.request_id IN ($IDS);" > ledger.json
$G "SELECT request_id, status, settled_tokens, settlement_hold FROM quota_reservations WHERE request_id='$RID';" > quota_reservations.json
$G "SELECT request_id, prompt_tokens, completion_tokens, token_source, outcome FROM usage_events WHERE request_id='$RID';" > usage_events.json
```

A refusal directory uses the same `route_snapshots.json`, `ledger.json` and
`quota_reservations.json` queries.

Admission events (both members, every row, id order):

```bash
$C "SELECT id, provider_id, state, actor, reason_code, binding_scope, pool_id, pool_model_id,
           pool_manifest_version, pool_manifest_core_digest, expected_catalog_model_hash_algorithm,
           expected_catalog_model_hash, created_at_utc
    FROM model_admission_events WHERE provider_id IN ('$NATIVE_PROVIDER_ID','$GGUF_PROVIDER_ID') ORDER BY id;" \
  > admission/model-admission-events.json
```

## Required journey-result contract

```bash
(cd phase4-coordinator && go build -o /tmp/coordinator-cli ./cmd/coordinator-cli)   # from the reviewed main commit
python3 scripts/build-trusted-pool-model-journey-result.py capture --capture-dir <dir> \
  --coordinator-cli /tmp/coordinator-cli \
  --output journeys/evidence/trusted-pool-model-<run>.redacted.json
```

`capture` verifies the signed events, normalizes every record into the closed
redacted evidence (schema `macprovider.trusted-pool-model-evidence.v2`), runs
the full semantic validator over it, and writes it with the signed event
bundle beside it: `journeys/evidence/trusted-pool-model-<run>.manifests/`
(`root-issuer-registered.json` and `v<N>.json`). Commit both. The bundle is
the signed public policy record; it carries the creator and attested-member
account ids in the clear (they are signed into the root registration and the
cores), but no prompt, output, key or token.

The signing workflow builds `coordinator-cli` from its own reviewed `main`
checkout (the deployed `source_sha` predates `verify-manifest`) and runs
`payload`, which re-runs the full validator over the committed evidence,
requires the bundle to be byte-equal at the evidence commit, re-verifies it
with the CLI and requires the verified cores to equal the evidence, then
builds the unsigned `macprovider.journey-result.v1` payload:

- `journey_id` `JOURNEY-TRUSTED-POOL-MODEL`, `requirement_ids` (a subset of
  the five above), `run_id`, the deployed source commit, operator role and
  identity fingerprint, and UTC timestamps;
- `execution_mode` and `environment.class` `production-operator-internal-pool`;
- the derived result and one derived step entry per physical step, in order,
  each referencing the one artifact `redacted-trusted-pool-model` (the
  redacted evidence's sha256);
- `observations` derived by the validator: `settlement_mode` (`enforce`),
  `enforce_activated`, `enforce_scope` (`pool`), `production_coordinator`,
  `launch_environment` (`candidate`), `payout_ready_mutated` (false),
  `raw_prompt_output_redacted`, `bearer_tokens_redacted`,
  `native_entry_served`, `attested_member_served`, `global_route_absent`,
  `current_generation_revocation` (all true), and
  `buyer_visible_usage_equals_debit` (boolean, E2E-F1);
- `candidate_identity`: `coordinator_version`, `accepted_id`,
  `native_member_cli_sha256`, `gguf_member_cli_sha256`, `llama_server_build`,
  `pool_id`, `native_pool_model_id`, `native_artifact_hash`,
  `gguf_pool_model_id`, `gguf_artifact_hash`, `manifest_version` and
  `manifest_core_digest` (the newest verified manifest), the recomputed
  `pricing_bounds_sha256`, and `fingerprint_salt`.

At promotion, `check_spec_governance.py` re-runs the same semantic validator
over the committed evidence the signed result names. The payload is signed in
CI (`production-release`, `MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM`, key id
`macprovider-acceptance-p256-v1`) and promoted with
`promote-signed-journey-result.py`.

## Pass criteria

Every step passes, the redacted evidence is committed and byte-equal at the
evidence commit, the signed envelope validates, and the evidence is fresh.
This journey may promote only SPEC-005-R015, SPEC-006-R018, SPEC-022-R013,
SPEC-042-R015 and SPEC-042-R016. It is evidence about one `candidate`
operator pool; it does not authorize a SPEC-043 production launch or
`trusted_pools.production_activation`.
