# JOURNEY-TRUSTED-POOL-EXTERNAL-RUNTIME

Status: defined; no signed run yet (SPEC-022-R012, SPEC-042-R013 and SPEC-042-R014 stay pending until a signed envelope from this contract is promoted)
Owner: settlement / Trusted Pool conformance
Specs: SPEC-022, SPEC-042
Requirements: SPEC-022-R012, SPEC-042-R013, SPEC-042-R014
Authority domains: verified-model-settlement, pool-control-plane
Issue: https://github.com/Augustas11/macprovider/issues/1690
Execution mode: production-operator-internal-pool
Run plan: `docs/runbooks/trusted-pool-m1-activation-plan.md` §5A (M1)
Evidence builder: `scripts/build-trusted-pool-external-runtime-journey-result.py` (`capture` writes the redacted evidence, `payload` builds the unsigned journey-result)
Signer: `.github/workflows/promote-signed-trusted-pool-external-runtime-journey.yml`

## Purpose

This journey defines the evidence for one paid buyer request pair (one
non-streaming, one streaming) served by an external runtime
(`llamacpp_loopback`) on an operator-owned Trusted Pool whose signed v2 policy
core allowlists that runtime in `enforce` mode, and settled `verified` with
usage source `pool_operator_attested`: provider credited, buyer debited exactly
the finality tokens. It is the "signed enforce-mode pool journey" named by the
gaps of SPEC-022-R012 (pool-scoped settlement eligibility, R-12 and R-12.8
signed finality), SPEC-042-R013 (external-runtime serving on Trusted Pools) and
SPEC-042-R014 (buyer engine selection on pool routes).

This document is a test contract. It is not evidence that the journey passed
or that any mapped requirement is conformant.

## Out of scope

- A SPEC-043 external-creator production launch (`launch_environment` other
  than `candidate`, `trusted_pools.production_activation`, public
  announcement). This journey runs an operator-internal `candidate` pool.
- Global (non-pool) settlement of a GGUF member. A GGUF member never reaches
  `settlement_capable` globally (SPEC-047-R003(iv)).
- Streaming disconnects, tool calls, and failover across members.
- Payout execution. Payout stays disabled; the ledger credit is the evidence.
- Buyer-visible `usage.prompt_tokens` equal to the debit on a templated prompt
  (E2E-F1, carried): the builder records the comparison, it does not require
  equality.

## Preconditions

All of these are captured, with timestamps, in `preconditions.json` (below).

- `P1`-`P8` of the run plan §1: coordinator and gateway on a build that
  contains `747557cc` and `ca809589`, gateway schema 14, the step-6 deploy
  smoke passed, `coordinator.require_settlement_trailers: true` live, an
  accepted member CLI candidate that contains `747557cc` and the artifact-feed
  release, trusted pools enabled on coordinator and gateway, the artifact feed
  served with `gguf-q4-k-m`, and the gateway→coordinator hop direct.
- `payout-disabled`: payout execution is off on the coordinator, so the run
  cannot move a credit to payout-ready.
- The pool was created, root-registered and manifest-signed with
  `coordinator-cli trust-pool-admin keygen` / `sign-root` / `sign-manifest`,
  with a v2 core: `runtime_allowlist = ["llamacpp_loopback"]`,
  `settlement_mode = enforce`. The member was admitted without a
  `delegation_id` (a delegated member cannot be `pool_operator_attested`).
- The buyer is a dedicated operator gateway account with an API key that
  never appears in any capture.

## Physical steps

1. `step-01-preconditions` - `P1`-`P8` and `payout-disabled` pass, captured
   with the deployed commit, the `accepted_ids` entry, the member CLI binary
   sha256, the llama-server build and the GGUF sha256.
2. `step-02-pool-policy` - `get-pool` shows the pool `active` and routeable,
   `launch_environment: candidate`, exactly one member and the buyer
   authorized; its `manifest_core_digest` equals the submitted
   `manifest_accepted` event's; the pool's event history has one
   `pool_created`, one `root_issuer_registered`, at least one
   `manifest_accepted`, `member_admitted` and `buyer_authorized`, and no
   `delegation_granted`. (`get-pool` does not print `runtime_allowlist` or
   `settlement_mode`; the digest binds them, and step 05 shows them in force.)
3. `step-03-nonstream-request` - a non-streaming paid request with
   `X-MacProvider-Pool-Select` and `X-MacProvider-Engine-Select: llamacpp`
   returns 200 with `X-MacProvider-Engine: llamacpp_loopback`, an
   `X-Request-ID`, and `X-Provider-Id` equal to the member.
4. `step-04-stream-request` - the same for a streaming request; the stream
   carries a `finish_reason` chunk and ends with `data: [DONE]`.
5. `step-05-route-snapshots` - every route snapshot of both requests names the
   pool, `runtime_source = llamacpp_loopback`, the manifest version and
   digest of step 02, the pool operator account, `route_snapshot_mode =
   enforce`, and the GGUF identity (`expected_catalog_model_hash` and
   `artifact_hash` equal the GGUF sha256, `artifact_id = gguf-q4-k-m`).
6. `step-06-receipts-and-attempts` - for each request an attempt output with
   `usage_source = pool_operator_attested`, `terminal_state = normal_done`,
   and its receipt verdict `receipt_version = 4`, `receipt_result = valid`,
   `settlement_outcome = verified`, `reason = verified_settlement`,
   `pool_label_status = verified`, `closed = 1`.
7. `step-07-ledger-and-finality` - for each request exactly one payable ledger
   row: the member, `provider_credits > 0`, `quarantined = 0`,
   `settlement_policy_mode = enforce`, `usage_source =
   pool_operator_attested`; the signed finality is `closed`, `outcome =
   verified`, `token_source = pool_operator_attested`.
8. `step-08-gateway-debit` - for each request the gateway reservation is
   `settled` with `settlement_hold = 0`, one `usage_events` row with
   `token_source = pool_operator_attested`, and `(prompt, completion)` equal
   across `usage_events`, finality and the ledger
   (`charged_prompt_tokens`, `completion_tokens`).
9. `step-09-negative-controls` - in the same session: no pool header (503
   `engine_unavailable`), no selector and no pool (503
   `byom_non_settlement_unavailable`), pool header with
   `X-MacProvider-Engine-Select: ollama` (503 `engine_unavailable`), and
   `X-MacProvider-Engine-Select: LLAMACPP` (400 `invalid_engine_selection`).
   Each leaves zero route snapshots and zero ledger rows. The coordinator
   records a route snapshot before it dispatches to a provider, so zero
   snapshots also means zero upstream calls.
10. `step-10-gateway-holds` - the held-reservation count and the
    `missing_settlement_finality_trailer` log count are 0 before and after.
11. `step-11-redaction` - the redacted evidence has no prompt, completion,
    key, token, or account secret: account and provider ids are
    HMAC-SHA256 fingerprints keyed by a random per-run salt (recorded,
    non-secret, as `candidate_identity.fingerprint_salt`), completions are
    sha256 digests, each `preconditions.*.observed` note is printable ASCII
    of at most 200 characters, and the secret scan passes.

## Capture layout

The operator captures into a local directory (mode 0700, never committed).
SQL results use `sqlite3 -readonly -json` (an empty result is an empty file).
`$RID` is the request's `X-Request-ID`.

```
capture/
  run.json                  # operator-authored identifiers (below)
  preconditions.json        # {"P1": {"status": "pass", "observed": "...", "checked_at": "...Z"}, ... "P8", "payout-disabled"}
  gateway-holds.json        # {"before": {"held_reservations": 0, "missing_trailer_log_count": 0}, "after": {...}}
  pool/get-pool.json        # coordinator-cli trust-pool-admin get-pool output
  pool/manifest-accepted.json  # the manifest_accepted event submitted (sign-manifest --out)
  pool/trustpool-events.json   # SELECT event_type, COUNT(*) AS n FROM trustpool_events WHERE pool_id='$POOL_ID' GROUP BY 1;
  requests/nonstream/response.headers   # curl -D
  requests/nonstream/response.json
  requests/stream/response.headers
  requests/stream/response.sse
  requests/<kind>/request_log.json      # the §5A SQL, one file per query, below
  requests/<kind>/route_snapshots.json
  requests/<kind>/attempt_outputs.json
  requests/<kind>/receipt_verdicts.json
  requests/<kind>/ledger.json
  requests/<kind>/quota_reservations.json
  requests/<kind>/usage_events.json
  requests/<kind>/finality.json         # the finality GET body
  controls/<name>/response.headers      # name: no-pool-selector, no-selector-no-pool,
  controls/<name>/response.json         #   pool-ollama-selector, uppercase-selector
  controls/<name>/route_snapshots.json
  controls/<name>/ledger.json
```

`run.json`:

```json
{
  "run_id": "trusted-pool-external-runtime-<UTC yyyymmddThhmmssZ>",
  "captured_at": "<UTC RFC3339 Z>",
  "expires_at": "<YYYY-MM-DD, at most 30 days out>",
  "source_commit": "<40-hex commit of the deployed coordinator/gateway tag>",
  "coordinator_version": "v1.8.200",
  "accepted_id": "Augustas11/macprovider:v<ver>@<commit>",
  "member_cli_sha256": "<64-hex>",
  "llama_server_build": "b11149",
  "gguf_sha256": "<64-hex>",
  "gguf_artifact_id": "gguf-q4-k-m",
  "model_id": "mlx-community/Llama-3.2-3B-Instruct-4bit",
  "operator_role": "pearl-actor",
  "operator_identity": "<text; only its sha256 is kept>",
  "hardware_profile": "<member host>",
  "pool_id": "<POOL_ID>",
  "member_provider_id": "<M1_PROVIDER_ID>",
  "buyer_account_id": "<M1_BUYER_ACCOUNT>",
  "pool_operator_account_id": "<creator account id>"
}
```

SQL per request (`C` and `G` as in the run plan §5A; `-json` instead of
`-header`):

```bash
IDS="SELECT request_id FROM request_log WHERE external_request_id='$RID'"
$C "SELECT request_id, attempt_n, status, pool_id FROM request_log WHERE external_request_id='$RID';" > request_log.json
$C "SELECT request_id, attempt_n, route_snapshot_mode,
           json_extract(route_snapshot_json,'\$.pool_id') pool_id,
           json_extract(route_snapshot_json,'\$.runtime_source') runtime_source,
           json_extract(route_snapshot_json,'\$.manifest_version') manifest_version,
           json_extract(route_snapshot_json,'\$.manifest_core_digest') manifest_core_digest,
           json_extract(route_snapshot_json,'\$.pool_generation') pool_generation,
           json_extract(route_snapshot_json,'\$.pool_operator_account_id') pool_operator_account_id,
           json_extract(route_snapshot_json,'\$.expected_catalog_model_hash') expected_catalog_model_hash,
           json_extract(route_snapshot_json,'\$.artifact_hash') artifact_hash,
           json_extract(route_snapshot_json,'\$.artifact_id') artifact_id
    FROM settlement_route_snapshots WHERE request_id IN ($IDS);" > route_snapshots.json
$C "SELECT request_id, attempt_n, terminal_state, usage_source FROM settlement_attempt_outputs WHERE request_id IN ($IDS);" > attempt_outputs.json
$C "SELECT request_id, attempt_n, receipt_version, receipt_result, settlement_outcome, reason, closed, pool_label_status
    FROM settlement_receipt_verdicts WHERE request_id IN ($IDS);" > receipt_verdicts.json
$C "SELECT l.id, l.request_id, l.provider_id, l.status, l.charged_prompt_tokens, l.completion_tokens, l.usage_source,
           l.provider_credits, l.quarantined, l.settlement_policy_mode, (p.id IS NOT NULL) payable
    FROM ledger_request_credits l LEFT JOIN spec022_payable_request_credits p ON p.id = l.id
    WHERE l.request_id IN ($IDS);" > ledger.json
$G "SELECT request_id, status, settled_tokens, settlement_hold FROM quota_reservations WHERE request_id='$RID';" > quota_reservations.json
$G "SELECT request_id, prompt_tokens, completion_tokens, token_source, outcome FROM usage_events WHERE request_id='$RID';" > usage_events.json
```

The controls use the same `route_snapshots.json` and `ledger.json` queries.
Wait at least one `pending_deadline_seconds` before the verdict, ledger and
finality captures.

## Required journey-result contract

`build-trusted-pool-external-runtime-journey-result.py capture --capture-dir
<dir> --output journeys/evidence/trusted-pool-external-runtime-<run>.redacted.json`
checks every step above and writes the redacted evidence (schema
`macprovider.trusted-pool-external-runtime-evidence.v1`). It fails closed on
any unmet expectation and never copies a prompt, completion, key or raw
account id. After that file is reviewed and merged, the signing workflow runs
`payload`, which builds the unsigned `macprovider.journey-result.v1` payload
carrying:

- `journey_id` `JOURNEY-TRUSTED-POOL-EXTERNAL-RUNTIME`, `requirement_ids` (a
  subset of the three above), `run_id`, the deployed source commit,
  operator role and identity fingerprint, and UTC timestamps;
- `execution_mode` and `environment.class` `production-operator-internal-pool`;
- one result entry per physical step, in order, each referencing the one
  artifact `redacted-trusted-pool-external-runtime` (the redacted evidence's
  sha256);
- `observations`: `settlement_mode` (`enforce`), `enforce_activated` (true),
  `enforce_scope` (`pool`), `production_coordinator` (true),
  `launch_environment` (`candidate`), `payout_ready_mutated` (false),
  `raw_prompt_output_redacted` (true), `bearer_tokens_redacted` (true),
  `buyer_visible_usage_equals_debit` (boolean, E2E-F1);
- `candidate_identity`: `coordinator_version`, `accepted_id`,
  `member_cli_sha256`, `llama_server_build`, `gguf_sha256`,
  `gguf_artifact_id`, `model_id`, `pool_id`, `manifest_version`,
  `manifest_core_digest`, `runtime_source`, `fingerprint_salt` (64 hex).

The payload is signed in CI (`production-release`,
`MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM`, key id
`macprovider-acceptance-p256-v1`) and promoted with
`promote-signed-journey-result.py`.

## Pass criteria

Every step passes, the redacted evidence is committed and byte-equal at the
evidence commit, the signed envelope validates, and the evidence is fresh.
This journey may promote only SPEC-022-R012, SPEC-042-R013 and SPEC-042-R014.
It is evidence about one `candidate` operator pool; it does not authorize a
SPEC-043 production launch or `trusted_pools.production_activation`.
