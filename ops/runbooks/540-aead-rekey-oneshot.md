# #540 isolated AEAD rekey one-shot

Use this runbook only to collect the two missing physical gates for issue #540.
The harness exercises the merged SPEC-008 v0.5 in-band protocol. It does not
authorize a production threshold change, scheduled canary re-enable, public
release, or Pearl provider promotion.

## Hard stop conditions

Stop without improvising if any of these is true:

- an operator has not approved the exact gate, isolated host, dedicated
  provider, binary/set identity, request/token/time caps, and evidence path;
- the coordinator or buyer endpoint cannot be isolated from Pearl;
- the dedicated provider is the sole Pearl-serving provider or the drill could
  route Pearl buyer traffic;
- the coordinator would need a Pearl `rekey_after_*` edit or restart;
- `/etc/macprovider-canary-buyer/enabled` or
  `/etc/macprovider/canary-buyer.enabled` exists, or anyone proposes enabling
  `canary-buyer.timer`;
- the intended coordinator/gateway/provider artifacts are not the reviewed
  production-equivalent binaries and signed CLI set;
- a failed run would require an automatic or immediate full-probe replay.

Do not inspect `d-inference` source. Do not create either canary enable gate.
Do not enable `canary-buyer.timer`.

## Operator approval record

Before any physical Mac, service start, or Pearl-adjacent check, record all of:

- approver and UTC timestamp;
- `G-req` or `G-age`;
- isolated host and loopback coordinator/gateway ports;
- dedicated `provider_id` and signed provider CLI compatibility-set identity;
- coordinator and gateway binary versions/digests;
- exact absolute coordinator base/overlay/database/log paths, gateway config
  path, and coordinator/gateway PIDs;
- selected overlay and its SHA-256;
- caps (default: 20 requests, 60 seconds, concurrency 2, 16 output tokens);
- artifact destination and the statement “one shot; no automatic retry.”

Use the approval comment/ticket URL as `--operator-approval-ref`. Approval for
one gate does not authorize the other gate or a rerun.

## Build the isolated environment

1. Provision a separate coordinator state directory/database and separate
   provider credentials. Copy the reviewed production-equivalent coordinator
   config to an operator-local base file. Keep `listen.bind_address` on
   loopback, `coordinator.require_gateway_context: true`, and
   `routing.max_retries: 0`. Use numeric loopback addresses, absolute
   `storage.db_path`, separate ports, and never reuse Pearl state.
2. For G-req, start the isolated coordinator with
   `coordinator.request-threshold.overlay.yaml`. For G-age, use
   `coordinator.age-threshold.overlay.yaml`. Pass the overlay at startup:

   ```bash
   ./coordinator --config /absolute/path/isolated-base.yaml \
     --config-overlay /absolute/path/coordinator.request-threshold.overlay.yaml \
     > /absolute/path/coordinator.jsonl 2>&1 &
   coordinator_pid=$!
   ```

   Both keys are startup-only. Never substitute SIGHUP for this start.
3. Start a production-equivalent gateway pointed only at the isolated
   coordinator buyer and operator listeners. Keep the gateway on numeric
   loopback and set `retry_503.enabled: false`; the harness rejects a retrying
   gateway because it could hide a rekey-correlated 503.
4. Connect one dedicated physical provider using the reviewed signed CLI set.
   It must not be the sole Pearl-serving provider. Wait for exactly one `/poolz`
   entry with the approved `provider_id`, a nonempty `assigned_id`,
   `encrypted_leg:true`, `state:ready`, and `routing_eligible:true`.
5. Confirm the external canary remains inert. These commands are observations,
   not activation:

   ```bash
   timer_enabled=$(systemctl is-enabled canary-buyer.timer 2>/dev/null || true)
   case "$timer_enabled" in disabled|not-found) ;; *) false ;; esac
   timer_active=$(systemctl is-active canary-buyer.timer 2>/dev/null || true)
   case "$timer_active" in inactive|unknown) ;; *) false ;; esac
   test ! -e /etc/macprovider-canary-buyer/enabled
   test ! -e /etc/macprovider/canary-buyer.enabled
   ```

If any check fails, stop. Do not fix it by enabling the timer or creating a
gate.

## Execute exactly one gate

Export secrets without placing them in argv or evidence:

```bash
export MACPROVIDER_REKEY_BUYER_TOKEN='...'
export MACPROVIDER_REKEY_OPERATOR_TOKEN='...'
```

Create one persistent local ledger outside the artifact directory. Never delete
or rotate it to permit a rerun; a new attempt requires a new approval comment.

```bash
install -d -m 700 /var/lib/macprovider-rekey-oneshot
touch /var/lib/macprovider-rekey-oneshot/attempts.jsonl
chmod 600 /var/lib/macprovider-rekey-oneshot/attempts.jsonl
```

Run the harness on the isolated coordinator host. Replace the gate/overlay and
approved identifiers as appropriate:

```bash
python3 test/e2e/aead-rekey-oneshot/aead_rekey_oneshot.py \
  --gate request_threshold \
  --operator-approval-ref 'https://github.com/Augustas11/macprovider/issues/540#issuecomment-...' \
  --buyer-url http://127.0.0.1:19443/v1/chat/completions \
  --poolz-url http://127.0.0.1:18444/poolz \
  --provider-id mp-dedicated \
  --model APPROVED_MODEL_ID \
  --base-config /absolute/path/isolated-base.yaml \
  --config-overlay /absolute/path/coordinator.request-threshold.overlay.yaml \
  --gateway-config /absolute/path/isolated-gateway.yaml \
  --coordinator-log /absolute/path/coordinator.jsonl \
  --coordinator-db /absolute/path/coordinator.db \
  --coordinator-pid "$coordinator_pid" \
  --gateway-pid "$gateway_pid" \
  --attempt-ledger /var/lib/macprovider-rekey-oneshot/attempts.jsonl \
  --expected-coordinator-sha256 APPROVED_64_HEX_COORDINATOR_SHA256 \
  --expected-gateway-sha256 APPROVED_64_HEX_GATEWAY_SHA256 \
  --expected-provider-cli-version APPROVED_POOLZ_BINARY_VERSION \
  --expected-provider-compatibility-set-id APPROVED_COMPATIBILITY_SET_ID \
  --max-requests 20 \
  --max-seconds 60 \
  --concurrency 2 \
  --max-tokens 16 \
  --post-commit-successes 3 \
  --output-dir test/e2e/aead-rekey-oneshot/artifacts/g-req-UTC
```

For G-req, the harness sends exactly `threshold - 1` successful warmups, starts
one bounded sentinel, observes the provider Busy, and then starts the trigger.
For G-age, it derives the deadline from `/poolz.connected_at`, starts the
sentinel two seconds before the configured age by default, observes Busy, and
starts the trigger only after the threshold is due. If the provider is already
too near the age deadline, stop and restart only the isolated setup; do not
improvise on Pearl. The tracked age overlay uses 30 seconds to leave setup
margin while remaining a bounded one-shot drill.

The process returns 0 only when the isolated SQLite request log maps the
harness trigger to the internal rekey `request_id`, records the provider Busy
with a distinct sentinel before trigger dispatch, proves that successful
sentinel remained outstanding when `aead_rekey` started, and proves the trigger
remained outstanding through commit,
records one expected rekey and commit, distinct old/new KIDs, unchanged
provider/assigned/connection identity, ready-or-busy serving states only, 100%
buyer HTTP 200, three successful post-commit requests by default, and no
failure, close/reconnect, 503, retry, or `no_provider_available` evidence.

On any nonzero exit, preserve the artifact, stop the isolated drill, and post
the exact remaining gap. Do not rerun under the same approval.

## Postflight and reporting

1. Stop the isolated gateway and coordinator. Disconnect only the dedicated
   drill provider. Do not touch Pearl configuration or services.
2. Review `evidence.json` for secret-free content and compare binary/config
   digests with the approval record. Post the table from `evidence.md` on #540.
3. Label the comment PASS, FAIL, or BLOCKED. A harness PASS is one gate only.
   Keep #540 open until separate approved G-req and G-age comments both PASS.
4. The orchestrator/operator, not this harness, decides when to close #540.

There is no retry step. A second attempt requires a new diagnosis, new explicit
operator approval, and a new artifact directory.

## Evidence boundary and #540 disposition

The physical artifact observes identity, KIDs, event correlation, buyer status,
and the old-epoch drain barrier. It intentionally does not expose plaintext,
keys, full process argv, raw responses, or unrelated pool/log fields.
Sequence-0/sequence-1 and bidirectional AEAD correctness remain covered by
`TestEncryptedRelayRekeysAfterRequestThreshold`,
`TestEncryptedRelayQueuesDispatchUntilActiveRequestsFinishAndRekeyCommits`,
`TestBuyerHTTPMaintainsOneProviderContinuityAcrossRequestThresholdRekey`,
`TestBuyerHTTPMaintainsOneProviderContinuityAcrossAgeThresholdRekey`, and Swift
`CoordinatorClientTests.testInBandAEADRekeyProvesFreshKeysBeforeSameSessionCutover`.

Entry 180 is the later issue-specific operations decision: separate approved
isolated G-req and G-age PASS comments satisfy #540's physical acceptance even
though Entry 138 originally named Pearl. This exception exists because Pearl's
request threshold is startup-only and unsafe to force. It does not authorize a
Pearl threshold edit, rollout, binary promotion, scheduled canary, or release.
