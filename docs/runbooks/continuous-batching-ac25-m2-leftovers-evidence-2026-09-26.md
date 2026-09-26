# AC-25 M2 leftovers — joined Studio evidence, 2026-09-26

## Result: PASS

AC-25 case 6's receipt/finalization half and case 10's warm-swap drain are
complete on the #1646 Studio candidate. Only successful request IDs below are
acceptance evidence. This document is a sanitized summary: it contains no
secrets, raw tokens, raw receipt blobs, authorization headers, or private logs.

## Build and validation

- Full Swift validation was run by the leader outside the sandbox:
  `cd phase3-binary && perl -e 'alarm 5400; exec @ARGV' swift test --skip testWaitForReadyDeadlineCancelsDrippingSpoofResponse`.
  **PASS:** 3,545 tests, 55 skipped, 0 failures, 244.765 seconds.
- Studio branch binary SHA-256:
  `95d9b943cee6c7cdf3dee458e1a4d96786baa44bdceb496c2f4d98811fc4b08b`.
- The isolated candidate joined on `:18080` as provider
  `mp-5aad6b654611666e16edf83dc0f326eb`, initially loaded with
  `qwen/qwen3.6-27b` at artifact hash
  `518ef47c298783d8547b50406e84548e5bf7705b82355a38f9eaef1368817931`.
  Readiness showed `connected=true`, `buyer_serving`, catalog
  `live_verified`, and `ready` / `model_loaded`.

## Case 6 — receipt and finalization binding

- External request `37dce7d1-7f99-4668-af7f-ac599ed0168c`; internal request
  `30c2b94f-f851-4dc0-bc63-15eca5642ab7`.
- HTTP 200; response body SHA-256
  `3afb9d71355e5b1e17c3d1904a2ad218ce5413ecb551e8aee478f2e2b4521ab9`;
  479 bytes; usage 18 prompt, 2 completion, 20 total tokens.
- Exactly one `normal_done` settlement attempt: `output_available=1`,
  `coordinator_observed`, with no duplicate.
- A v4 receipt was present and valid. Its outcome was `verified`, reason
  `verified_settlement`, and terminal/finalization fields were
  `first_terminal`, `closed`, and `normal_done`. Every receipt model-hash field
  carried the old hash above.
- Ledger: status 200; usage 18/2; `provider_reported`; 8 credits; no fault; not
  quarantined; `enforce`.

The ledger currently reports `no_money_movement_step5`. This case therefore
proves receipt/finalization binding, not payout finality.

## Case 10 — accepted work drains under its old model snapshot

- Long external request `728b7141-2d27-411d-9944-dfd6bbd8daaf`; internal
  request `1947ce6a-96f4-4970-81b3-93c4ee306d60`.
- Immediately before the switch, `requests_in_flight=1` and
  `active_request_id_count=1` under the old model/hash tuple.
- Switch transaction `06a4d900-d94e-48c3-aa11-4646326e7aa7` progressed
  `requested` -> `loading` at 1 ms -> `draining` at 16,368 ms -> `loaded` at
  17,908 ms.
- The request completed HTTP 200 under the old model/hash with usage 41 prompt,
  1,024 completion, 1,065 total tokens. Response body SHA-256 was
  `f16b538bd5efe66f7004335df6cc4ecae23979767ec49950c76f0b96387c4506`,
  1,500 bytes.
- The newly loaded tuple was
  `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` at hash
  `10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0`.
- Exactly one `normal_done` attempt produced one valid v4 verified receipt,
  with no duplicate. Every receipt model and hash field retained the old
  `qwen/qwen3.6-27b` tuple.
- Ledger: usage 41/1,024; 2,000 credits; no fault; not quarantined; `enforce`.

This proves that work accepted before a warm switch drains under the immutable
old snapshot and cannot be rebound to the newly loaded weights.

## Harness and operational boundaries

[`scripts/lab/cb-studio/m2-joined-provider.sh`](../../scripts/lab/cb-studio/m2-joined-provider.sh)
is the reproducible joined-provider harness. It gives the isolated candidate a
1,050-second (17.5-minute) deadline, leaving 30 seconds inside the 18-minute
`bench.sh` window for forced cleanup. It launches the candidate with `setsid`,
requires the child's process-group ID to equal its PID, and addresses only that
exact process group. Its `EXIT`, `INT`, and `TERM` traps send `TERM`, wait up to
20 one-second polls, send `KILL` only if the exact child remains non-zombie, and
then reap it. If session setup fails, cleanup falls back to the exact child PID.

The control socket is not guessed: the runner derives it from the exact child's
open file descriptors, accepts exactly one
`/private/tmp/macprovider-autotune-*/control.sock`, and checks the owning UID,
socket type, `0700` root, and lifecycle state file before recording it. Cleanup
is process-scoped; the runner neither broadly kills provider processes nor
unlinks an unrelated control socket.

Initial fresh-ID 503 responses arose because the paused incumbent and isolated
candidate shared a provider identity and raced coordinator heartbeat state.
They are not acceptance evidence. No successful request ID ran duplicate
inference.

Setup corrections were bounded to an unsupported initial current-model
selection and a BSD `awk` portability bug. Each associated pause lasted about
36–37 seconds; neither is recorded as a product failure.

The final live pause stayed under 11 minutes. `bench.sh` encountered the known
#1755 resume stall and recovered through its automatic restart. The final
explicit `macprovider-cli status` output was exactly `Provider is ready`. No
listener remained on `:18080`; only the installed live `serve` remained.
