# JOURNEY-NETWORK-MODEL-ADMISSION physical run (BYOM v0.2 slice 7)

**Epic:** #1453. **Handoff:** #1486. **Journey contract:** `journeys/JOURNEY-NETWORK-MODEL-ADMISSION.md`.
**Evidence pipeline:** `docs/runbooks/byom-journey-evidence.md` (this runbook produces its step 1 output).

This is the physical-provider counterpart of the hermetic discovery driver.
It drives one candidate through all twelve SPEC-047 steps on real Apple
Silicon against a real coordinator, captures every CLI document, measures the
money-path ledgers, and emits `run-manifest.json`. Signing is the operator's
step and is not part of this run.

## What the run proves, and what it deliberately does not

The manifest must show every one of the ten money-path ledgers at zero,
`request_log` included. So step 9 proves the `settlement_capable` state and
that the route-time snapshot and receipt-verification gates are armed. It
does not move money. There is no gateway and no buyer traffic in the run.

GGUF candidates cannot reach `settlement_capable` until SPEC-010 R007(e); the
settleable candidate is MLX. The GGUF ref (`--gguf-ref`, required) is the
novel non-catalog candidate of the status-presentation step: its status must
report `earning_path_class: no_earning_path_in_v0_1`. The opaque endpoint is
not a substitute; it never reaches the coordinator (step 3).

## Preconditions

| Need | Why |
|---|---|
| A Mac that is not a live earner | The run installs a provider and mutates coordinator state |
| Coordinator with Postgres and onboarding enabled | Admission store, hardware trust, and the ten ledgers |
| Two operator actors under `auth.operator_keys` with distinct secrets | Dual control: the proposer of `settlement_capable` may not approve it |
| The same-release signed feed set incl. `catalog-artifacts.json` served under one signer | The settleable candidate must catalog-match through a trusted binding; the shipped CLI verifies served feeds against its compiled-in keyring, so this must be the release signer's feed, not a rig key |
| An MLX candidate in the HF cache whose artifact is `verified` in that feed | e.g. `mlx-community/Llama-3.2-3B-Instruct-4bit` at the feed's revision |
| An `openai_compatible:` origin serving one model | The opaque-endpoint rejection case |
| A GGUF candidate (Ollama, LM Studio or llama.cpp) | The novel non-catalog candidate with no earning path (step 10) |
| `psql` on PATH and a read DSN for the ledgers | `observations.money_path_zero_rows` is measured, not declared |
| The provider serve log and the coordinator log, as files | Step 12 reviews what both append during the run |
| A drift hook | Step 7 needs a changed admitted predicate that the coordinator detects on its own (SPEC-047-R006); an operator revoke proves nothing |

## Secrets

Operator secrets and the ledger DSN are read from environment variables named
on the command line. Their values never appear in argv, logs, captures, or
the manifest; the redaction review in step 12 fails the run if they do.

The DSN is never passed to `psql` on its command line either (argv is
readable through process inspection). For each ledger read the runner
writes it as a libpq service file, mode 0600 in a private 0700 directory
that exists only for the duration of that read, and points `psql` at it
through `PGSERVICEFILE`/`PGSERVICE`; every other `PG*` variable is dropped
from the child's environment. The DSN may be a `postgresql://` URI or libpq
`key=value` pairs; only `host`, `hostaddr`, `port`, `dbname`, `user`,
`password`, `sslmode`, `sslrootcert`, `application_name`, `connect_timeout`
and `target_session_attrs` are carried, anything else fails the run.

```bash
export MACPROVIDER_JOURNEY_OPERATOR_A=...   # rig_a's per-actor operator key
export MACPROVIDER_JOURNEY_OPERATOR_B=...   # rig_b's per-actor operator key, distinct
export MACPROVIDER_JOURNEY_LEDGER_DSN=postgres://...   # read access to the ten tables
```

## Run

```bash
test/e2e/byom/run-cli-onboarding-e2e.py --journey-evidence \
  --out ~/byom-admission-run \
  --cli-binary <candidate macprovider-cli> \
  --provider-config ~/.config/macprovider/config.yaml \
  --coordinator-admin-origin http://127.0.0.1:18444 \
  --operator-actor-a rig_a --operator-actor-b rig_b \
  --settleable-ref mlx-community/Llama-3.2-3B-Instruct-4bit \
  --opaque-ref openai_compatible:<model id> \
  --gguf-ref ollama:<model> \
  --provider-log ~/Library/Logs/macprovider/macprovider.err.log \
  --coordinator-log <rig coordinator log file> \
  --drift-hook ./drift-hook.sh \
  --discovery-arg --skip-lmstudio --discovery-arg --skip-llamacpp
```

`--out` must be new or empty. A failing run publishes no manifest.

## What the operator surface is asked, exactly

Decisions go to `POST /admin/model-admission/decisions` with the head the
runner has just read as `expected_coordinator_event_id`, a fresh
`idempotency_key`, and one of four reasons inside the coordinator's
`^operator_[a-z0-9_]{2,56}$` grammar: `operator_experimental_disclosure`
(step 5), `operator_catalog_binding_verified` (steps 6 and 9),
`operator_dual_control_settlement` (step 9) and `operator_matrix_probe`
(step 11). A reason outside the grammar is refused by the runner before it
reaches the wire. Approvals go to `POST /admin/model-admission/decisions/<pending_decision_id>/approve`
with the closed approval body (provider, candidate, pending id, the evaluated
head the proposal returned, and its own idempotency key).

Every refusal the journey relies on is pinned to the coordinator's exact
verdict, never to "some 4xx": the proposer's own approval must be
`409 dual_control_required`; the out-of-matrix transition in step 11 must be
`409 invalid_transition` with the head and state unchanged. A `400
invalid_request`, `401`, `404` or `409 stale_head` in either place fails the
run, because it proves nothing about dual control or the matrix.

## The drift hook

Step 7 calls the hook once and then waits for the candidate to reach
`revoked` with a `provider_guidance.transition_reason_code` in the closed
SPEC-047-R006 drift set. The hook must change something the coordinator
re-checks at hello/heartbeat/refresh. Two inductions that need no re-signing:

- **`runtime_identity_drift`**: point the provider's serve at a copy of the
  same model whose snapshot manifest differs (one changed byte in a
  safetensors file suffices) and restart serve; the next heartbeat reports a
  different artifact hash.
- **`receipt_key_unavailable`**: rotate the provider's receipt key away.

Changing the served catalog artifact feed also drifts
(`catalog_artifact_feed_changed`) but requires re-signing the feed with the
trusted key, which a rig cannot do.

## Step 12, the surfaces reviewed

The three redaction observations are set only after six surfaces are clean:
the runner's own log, the verbatim transcript of every CLI invocation and
operator-surface exchange, every captured document, the coordinator's event
listing for the provider (`GET /admin/model-admission/offers`), and the bytes
the provider and coordinator logs gained during the run. Each is checked for
both operator secrets, the DSN and its password, the shared credential-shape
scanner, the synthetic probe prompt (`Reply with ok.`) and chat request
shapes, and chat completion shapes. A failure names the category and the
surface, never the value.

## Step 11 and `offer_rejected`

SPEC-047 v0.1.9 reserves `offer_rejected`: no coordinator code path appends
it in v0.2 (a failed synthetic probe revokes with `synthetic_probe_failed`,
and the intake surface does not reject), so the journey contract carries 15
true observations and step 11 has no rejection leg. The runner probes one
transition outside the SPEC-047 matrix and asserts the state is unchanged;
the fresh-evidence-on-re-entry invariant (R001/R006) is measured on the two
reachable paths, `revoked` (step 7) and `withdrawn` (step 8), each of which
requires a re-offer to append a new provider-signed event. No hook is needed.

## After the run

Follow `docs/runbooks/byom-journey-evidence.md` from step 3:
`capture-byom-journey-evidence.py --journey admission --run-manifest
~/byom-admission-run/run-manifest.json ...`, then build, preflight, and hand
the unsigned payload to the operator for signing. The first physical run's
captures also become the typed fixtures under
`scripts/tests/fixtures/byom_journeys/admission/captures/` (today's are
placeholders), after which `ADMISSION_CONTRACT.typed_capture_validation`
turns on.

## Tests

`scripts/tests/test_admission_journey_runner.py` drives all twelve steps
against a fake coordinator that implements the SPEC-047-R001 matrix and dual
control, and asserts the resulting manifest passes `build_evidence`. It also
proves the runner fails closed on: self-approval accepted, operator-origin
revocation, an accepted illegal transition, a non-zero ledger, a secret in
the transcript, a non-loopback origin, shared or same-actor operator
credentials, and a non-empty output directory.
