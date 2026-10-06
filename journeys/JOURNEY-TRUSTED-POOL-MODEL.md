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
- Proving an in-flight attempt actually spanned a window boundary. The
  builder checks the attempt routed under the earlier terms and settled at
  their rates; the operator starts it before the boundary.

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
- Six role manifests, in `run.json.manifest_versions`:
  `native_genesis` (native entry) < `gguf_added` (both entries, GGUF owner
  attested) < `window_rotation` (window-only: same terms digest) <
  `price_change` (exactly one entry's rates change, nothing else), then
  `entry_removal` (native entry removed) and `attestation_removal` (GGUF
  owner's attestation removed), both after `price_change`, in either order.
- Keeper rotations between them are fine. A route snapshot or `/v1/models`
  digest at any version needs that version's `pool/v<N>/` directory, and its
  terms digest must equal the latest role manifest at or below it.

## Physical steps

1. `step-01-preconditions` - `deploy-build`, `trusted-pools-enabled`,
   `pricing-bounds-configured`, `gateway-route-snapshot-v2` and
   `payout-disabled` pass; the coordinator deployed before the gateway, and the
   gateway before both member CLIs.
2. `step-02-pricing-bounds-and-owner-authority` - the live
   `trusted_pools.pool_model_pricing_bounds` is the closed six-key object with
   each min at most its max; every rate of every role manifest's entries sits
   inside it with cache-hit at most prompt; the SIGHUP reload applied the
   owner map (`provider_owner_account_ids`).
3. `step-03-pool-genesis-with-entries` - `get-pool` at `native_genesis` shows
   the pool active, routeable, candidate, enforce, `llamacpp_loopback`
   allowlisted, and the native entry with its exact hash, algorithm,
   `mlx_cache`, a licence, `paid_serving_attested: true` and
   `pool_attested_unverified`; its digest equals the submitted manifest's. The
   pool history has one `pool_created` and one `root_issuer_registered`.
4. `step-04-non-creator-members` - at `gguf_added` both providers are
   members, neither member account is the creator, the GGUF owner is attested
   for `llamacpp_loopback`, the native member is not attested (it is
   delegated), and the history has at least two `delegation_granted` and two
   `member_admitted`.
5. `step-05-proposal-bundles` - each `pool_model_proposal.v1` bundle names
   the pool, its runtime, no catalog key, null licence and paid-serving flag,
   and exactly the signed entry's id, hash and algorithm.
6. `step-06-offer-binding` - each member has a `catalog_priced`,
   `binding_scope=pool`, `pool_manifest_bound` event for its exact entry under
   actor `pool_manifest:<pool>:...`, and no `settlement_capable` event.
7. `step-07-pool-models-disclosure` - the buyer's pool `/v1/models` lists
   both entries with the closed `macprovider_pool_model` object
   (`pool_attested_unverified`, `Pool-attested, not network-verified`,
   `pool_creator_signed`, the exact hash, a captured core digest and that
   core's entry rates); the global view lists no `pool/` model; the
   never-global SQL count is 0.
8. `step-08-native-entry-paid` - a non-streaming and a streaming request for
   the native entry: 200, `X-MacProvider-Engine: mlx_cache`,
   `X-MacProvider-Model-Disclosure: pool_attested_unverified`,
   `X-MacProvider-Pool-Manifest-Core-Digest` equal to the snapshot's digest;
   every route snapshot is `pool_manifest`-sourced for the exact entry
   (`pool_model_id`, `model_id`, expected hash and algorithm),
   `spec022-route-snapshot-v2`, `enforce`, the delegated member as provider,
   the version's core digest and the signed entry rates; one
   `coordinator_observed` `normal_done` attempt output with a `valid`,
   `verified`, `pool_label_status=verified`, closed verdict; exactly one
   payable, unquarantined ledger row to the member with `provider_credits > 0`
   and the snapshot's prompt and completion rates; a settled, unheld
   reservation; one usage event with `token_source=coordinator_observed`; and
   debit tokens equal to ledger tokens.
9. `step-09-attested-member-paid` - the same for the GGUF entry,
   `llamacpp_loopback`, `pool_operator_attested`, with
   `pool_operator_account_id` the creator and `pool_member_account_id` the
   attested owner, attested at the snapshot's version.
10. `step-10-refusals` - the native or GGUF model with no pool header (404
    `model_not_found`), with another authorized pool's header (404
    `model_not_found`), and with a wrong engine selector (503
    `engine_unavailable`): no route snapshot, no ledger row, every
    reservation `refunded`.
11. `step-11-window-rotation-no-gap` - `window_rotation` keeps the terms
    digest and the entries and attestations byte-equal under a new core; the
    delegated native member gets `pool_manifest_rebound` at that version; a
    probe loop across the boundary is all 200; a request routed under the
    `window_rotation` terms is paid as in step 08/09.
12. `step-12-price-change-in-flight` - `price_change` changes exactly one
    entry's rates and nothing else; a request for that entry routed under the
    prior terms settles at the old rates (snapshot and ledger), and a request
    routed under the `price_change` terms settles at the new rates.
13. `step-13-current-generation-revocation` - `entry_removal` drops the
    native entry and the native binding is revoked with
    `pool_manifest_entry_revoked`; a native request routed before it settles
    verified and payable; the native model afterwards answers 404
    `model_not_found`. `attestation_removal` drops the GGUF owner and the GGUF
    binding is revoked with `pool_membership_revoked`; the GGUF model
    afterwards is refused (any 4xx/5xx with a closed error code). Both
    refusals leave no route snapshot or ledger row and refund.
14. `step-14-pause-resume-rollback` - while paused a pool request answers 503
    `pool_unavailable` with no snapshot or ledger row; after resume a pool
    request is paid; the history has at least two `lifecycle_changed`;
    `coordinator pool-rollback-preflight --target-tier m9` exits 3 with
    `rollback_blocked: true` and a non-empty `manifest_history.cannot_replay`,
    and `--target-tier p1816` exits 0 with `rollback_blocked: false` and an
    empty `cannot_replay`.
15. `step-15-restart-ordering` - the coordinator restarts before the gateway,
    and afterwards a pool-model request is paid (the bindings and pool state
    reconstruct).
16. `step-16-redaction` - the redacted evidence holds no prompt, completion,
    key, URL, host name, IP address or absolute path; account, provider and
    other-pool ids are HMAC-SHA256 fingerprints under a per-run salt
    (`candidate_identity.fingerprint_salt`); every raw capture file appears
    only as `raw_documents.<capture path> = {sha256, bytes}`; `observed`
    facts are structured; no capture path component is a symlink.

## Capture layout

The operator captures into a local directory (mode 0700, never committed).
SQL results use `sqlite3 -readonly -json` (an empty result is an empty file).
`$RID` is the request's `X-Request-ID`; `C`, `G` and `IDS` are defined with
the SQL below.

```
capture/
  run.json                                 # operator identifiers (below)
  preconditions.json                       # {"deploy-build": {"status": "pass", "observed": {<facts>}, "checked_at": "...Z"},
                                           #  "trusted-pools-enabled", "pricing-bounds-configured",
                                           #  "gateway-route-snapshot-v2", "payout-disabled"}
  deploy.json                              # {"coordinator_deployed_at", "gateway_deployed_at",
                                           #  "native_member_cli_installed_at", "gguf_member_cli_installed_at"}: UTC ...Z
  config/pricing-bounds.json               # the live trusted_pools.pool_model_pricing_bounds object (six integer keys)
  config/owner-authority-reload.json       # {"reloaded": true, "provider_owner_account_ids_applied": true,
                                           #  "provider_owner_account_ids_providers": <n>, "provider_owner_account_ids_sha256": "<64 hex>"}
                                           #  from the "trusted pools pool-model bounds and owner authority reloaded" log line
  pool/trustpool-events.json               # SELECT event_type, COUNT(*) AS n FROM trustpool_events WHERE pool_id='$POOL_ID' GROUP BY 1;
  pool/v<N>/manifest-accepted.json         # every role version and every version a snapshot/listing names (sign-manifest --out)
  pool/v<N>/policy-terms-digest.txt        # trust-pool-admin policy-terms-digest --manifest pool/v<N>/manifest-accepted.json
  pool/v<N>/get-pool.json                  # role versions only: trust-pool-admin get-pool, right after that version activates
  proposals/native.json                    # macprovider-cli models propose ... --json (native member)
  proposals/gguf.json                      # same, GGUF member
  admission/model-admission-events.json    # SQL below
  models/pool.json                         # buyer GET /v1/models with X-MacProvider-Pool-Select (both entries live)
  models/global.json                       # buyer GET /v1/models without a pool header
  never-global.json                        # the runbook §6 never-global count, aliased: SELECT count(*) AS n ...
  requests/native-nonstream/               # paid request directories (files below)
  requests/native-stream/
  requests/gguf-nonstream/
  requests/gguf-stream/
  rotation/window-only/after/              # paid, routed under the window_rotation terms
  rotation/window-only/probes.json         # [{"at": "...Z", "status": 200}, ...] across the window boundary, time order, >= 2
  rotation/price-change/inflight/          # paid, repriced entry, started before price_change activates
  rotation/price-change/after/             # paid, repriced entry, routed under the price_change terms
  rotation/entry-removal/inflight/         # paid, native entry, started before entry_removal activates
  rotation/entry-removal/after/            # refusal: native entry after removal (404 model_not_found)
  rotation/attestation-removal/after/      # refusal: GGUF entry after the attestation removal (any 4xx/5xx)
  refusals/no-pool-header/                 # refusal: 404 model_not_found
  refusals/other-pool/                     # refusal: another authorized pool's header, 404 model_not_found
  refusals/wrong-engine/                   # refusal: GGUF entry with X-MacProvider-Engine-Select: ollama, 503 engine_unavailable
  pause/paused/                            # refusal while paused: 503 pool_unavailable
  pause/resumed/                           # paid, after resume
  rollback/preflight-m9.json               # stdout of coordinator pool-rollback-preflight --target-tier m9 (one JSON object)
  rollback/preflight-m9.rc                 # its exit status, e.g. "3"
  rollback/preflight-p1816.json
  rollback/preflight-p1816.rc              # "0"
  restart/order.json                       # {"coordinator_restarted_at": "...Z", "gateway_restarted_at": "...Z"}
  restart/after/                           # paid, after the restart
```

A **paid request directory** holds `response.headers` (`curl -D`),
`response.json` (non-streaming) **or** `response.sse` (streaming; only the
`*-stream` directories), and `request_log.json`, `route_snapshots.json`,
`attempt_outputs.json`, `receipt_verdicts.json`, `ledger.json`,
`quota_reservations.json`, `usage_events.json`. A **refusal directory**
holds `response.headers`, `response.json`, `route_snapshots.json`,
`ledger.json` and `quota_reservations.json`. Wait at least one
`pending_deadline_seconds` before the verdict and ledger captures.

`run.json`:

```json
{
  "run_id": "trusted-pool-model-<UTC yyyymmddThhmmssZ>",
  "captured_at": "<UTC RFC3339 Z>",
  "expires_at": "<YYYY-MM-DD, at most 30 days out>",
  "source_commit": "<40-hex commit of the deployed coordinator/gateway>",
  "coordinator_version": "v1.8.217",
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
  "manifest_versions": {"native_genesis": 1, "gguf_added": 3, "window_rotation": 4,
                        "price_change": 5, "entry_removal": 7, "attestation_removal": 8}
}
```

`observed` facts follow JOURNEY-TRUSTED-POOL-EXTERNAL-RUNTIME: 1-8 named
facts, a snake_case name naming no credential, a value that is a boolean, an
integer from 0 to 2^53, or a token of at most 19 characters.

SQL per request directory (an empty `IDS` is a valid empty `IN ()` list):

```bash
C="sqlite3 -readonly -json /var/lib/macprovider/coordinator.db"
G="sqlite3 -readonly -json /var/lib/macprovider/gateway.db"
IDS=$(sqlite3 -readonly -noheader /var/lib/macprovider/coordinator.db \
  "SELECT group_concat(quote(request_id)) FROM request_log WHERE external_request_id='$RID';")
$C "SELECT request_id, attempt_n, status, pool_id FROM request_log WHERE external_request_id='$RID';" > request_log.json
$C "SELECT request_id, attempt_n, route_snapshot_mode,
           json_extract(route_snapshot_json,'\$.provider_id') provider_id,
           json_extract(route_snapshot_json,'\$.pool_id') pool_id,
           json_extract(route_snapshot_json,'\$.model_id') model_id,
           json_extract(route_snapshot_json,'\$.route_snapshot_policy_version') route_snapshot_policy_version,
           json_extract(route_snapshot_json,'\$.expected_model_hash_source') expected_model_hash_source,
           json_extract(route_snapshot_json,'\$.pool_model_id') pool_model_id,
           json_extract(route_snapshot_json,'\$.manifest_version') manifest_version,
           json_extract(route_snapshot_json,'\$.manifest_core_digest') manifest_core_digest,
           json_extract(route_snapshot_json,'\$.runtime_source') runtime_source,
           json_extract(route_snapshot_json,'\$.pool_operator_account_id') pool_operator_account_id,
           json_extract(route_snapshot_json,'\$.pool_member_account_id') pool_member_account_id,
           json_extract(route_snapshot_json,'\$.expected_catalog_model_hash') expected_catalog_model_hash,
           json_extract(route_snapshot_json,'\$.expected_catalog_model_hash_algorithm') expected_catalog_model_hash_algorithm,
           json_extract(route_snapshot_json,'\$.pool_model_prompt_rate_per_mtok') pool_model_prompt_rate_per_mtok,
           json_extract(route_snapshot_json,'\$.pool_model_prompt_cache_hit_rate_per_mtok') pool_model_prompt_cache_hit_rate_per_mtok,
           json_extract(route_snapshot_json,'\$.pool_model_completion_rate_per_mtok') pool_model_completion_rate_per_mtok,
           json_extract(route_snapshot_json,'\$.pool_model_pricing_bounds_sha256') pool_model_pricing_bounds_sha256
    FROM settlement_route_snapshots WHERE request_id IN ($IDS);" > route_snapshots.json
$C "SELECT request_id, attempt_n, terminal_state, usage_source FROM settlement_attempt_outputs WHERE request_id IN ($IDS);" > attempt_outputs.json
$C "SELECT request_id, attempt_n, receipt_result, settlement_outcome, reason, closed, pool_label_status
    FROM settlement_receipt_verdicts WHERE request_id IN ($IDS);" > receipt_verdicts.json
$C "SELECT l.id, l.request_id, l.attempt_n, l.provider_id, l.status, l.charged_prompt_tokens, l.completion_tokens,
           l.prompt_rate_per_mtok, l.completion_rate_per_mtok, l.provider_credits, l.quarantined, (p.id IS NOT NULL) payable
    FROM ledger_request_credits l LEFT JOIN spec022_payable_request_credits p ON p.id = l.id
    WHERE l.request_id IN ($IDS);" > ledger.json
$G "SELECT request_id, status, settled_tokens, settlement_hold FROM quota_reservations WHERE request_id='$RID';" > quota_reservations.json
$G "SELECT request_id, prompt_tokens, completion_tokens, token_source, outcome FROM usage_events WHERE request_id='$RID';" > usage_events.json
```

Admission events (both members, every row, id order):

```bash
$C "SELECT id, provider_id, state, actor, reason_code, binding_scope, pool_id, pool_model_id,
           pool_manifest_version, pool_manifest_core_digest, expected_catalog_model_hash_algorithm,
           expected_catalog_model_hash, created_at_utc
    FROM model_admission_events WHERE provider_id IN ('$NATIVE_PROVIDER_ID','$GGUF_PROVIDER_ID') ORDER BY id;" \
  > admission/model-admission-events.json
```

## Required journey-result contract

`build-trusted-pool-model-journey-result.py capture --capture-dir <dir>
--output journeys/evidence/trusted-pool-model-<run>.redacted.json` checks
every step above and writes the redacted evidence (schema
`macprovider.trusted-pool-model-evidence.v1`). It fails closed on any unmet
expectation, naming the file and field. After that file is reviewed and
merged, the signing workflow runs `payload`, which builds the unsigned
`macprovider.journey-result.v1` payload carrying:

- `journey_id` `JOURNEY-TRUSTED-POOL-MODEL`, `requirement_ids` (a subset of
  the five above), `run_id`, the deployed source commit, operator role and
  identity fingerprint, and UTC timestamps;
- `execution_mode` and `environment.class` `production-operator-internal-pool`;
- one result entry per physical step, in order, each referencing the one
  artifact `redacted-trusted-pool-model` (the redacted evidence's sha256);
- `observations`: `settlement_mode` (`enforce`), `enforce_activated`,
  `enforce_scope` (`pool`), `production_coordinator`, `launch_environment`
  (`candidate`), `payout_ready_mutated` (false), `raw_prompt_output_redacted`,
  `bearer_tokens_redacted`, `native_entry_served`, `attested_member_served`,
  `global_route_absent`, `current_generation_revocation` (all true), and
  `buyer_visible_usage_equals_debit` (boolean, E2E-F1);
- `candidate_identity`: `coordinator_version`, `accepted_id`,
  `native_member_cli_sha256`, `gguf_member_cli_sha256`, `llama_server_build`,
  `pool_id`, `native_pool_model_id`, `native_artifact_hash`,
  `gguf_pool_model_id`, `gguf_artifact_hash`, `manifest_version` and
  `manifest_core_digest` (the highest captured version), the single
  `pricing_bounds_sha256` every pool route carried, and `fingerprint_salt`.

The payload is signed in CI (`production-release`,
`MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM`, key id
`macprovider-acceptance-p256-v1`) and promoted with
`promote-signed-journey-result.py`.

## Pass criteria

Every step passes, the redacted evidence is committed and byte-equal at the
evidence commit, the signed envelope validates, and the evidence is fresh.
This journey may promote only SPEC-005-R015, SPEC-006-R018, SPEC-022-R013,
SPEC-042-R015 and SPEC-042-R016. It is evidence about one `candidate`
operator pool; it does not authorize a SPEC-043 production launch or
`trusted_pools.production_activation`.
