# BUILD_SPEC_045_PHASE_3_BUDGET_LEDGER

Implement SPEC-045 local model admission, trusted pricing, budget caps, micro-USD ledger, settlement, restart recovery, and graceful shutdown. This slice is required before chargeable chat completions may be forwarded in conformant budgeted mode.

## Target result

Chargeable `POST /v1/chat/completions` requests are admitted only when the model is allowed, trusted pricing/output-bound metadata is available or an explicit override applies, a conservative local exposure estimate fits the configured caps, and any durable ledger reservation has been appended before upstream forwarding.

## Required implementation shape

1. Implement model allowlist behavior:
   - default allowlist is empty;
   - `/v1/models` returns only upstream-visible gateway models allowed locally;
   - empty allowlist returns an OpenAI-compatible empty list and may warn;
   - chat completions reject disallowed models as `local_model_not_allowed`.

2. Implement budget flags:
   - require positive `--budget-usd` or explicit `--no-budget` for chargeable requests;
   - reject zero, negative, non-finite, and unparsable budget values with `local_budget_flag_rejected`;
   - support optional `--max-request-usd` with the same parser rules;
   - `--ledger <path>` without `--budget-usd` or `--no-budget` fails with `local_budget_flag_rejected`;
   - `--no-budget --max-request-usd --allow-unpriced` fails as `local_pricing_unavailable` when trusted pricing is unavailable.

3. Implement trusted pricing admission:
   - trust only SPEC-006 `/v1/rate-card` plus `/v1/rate-card.sig` verified under SPEC-023, or a future SPEC-defined quote surface;
   - enforce SPEC-023 sidecar, keyring, policy version, generated-at freshness, stale-warning, maximum-age, and future-skew rules;
   - use the catalog release shape validated by `scripts/catalog-release.py`;
   - model lookup follows SPEC-005 exact, normalized, then default resolution;
   - unsigned local files, client request fields, environment values, provider hints, response metadata, and client token counts are not trusted admission metadata.

4. Implement conservative estimate math:
   - canonical unit is signed integer micro-USD;
   - use gross buyer-side exposure, never provider payout/provider-share exposure;
   - use full prompt rate unless a future trusted quote distinguishes safe cache-hit token counts;
   - use explicit output bound or trusted model maximum output bound;
   - fail closed on missing operands, overflow, precision loss, non-finite values, or under-reserving ambiguity;
   - round upward to the smallest local ledger unit;
   - apply `global_multiplier_ppm` and trusted credits-to-USD conversion when needed.

5. Implement unpriced override behavior:
   - with positive run budget and `--allow-unpriced`, reserve the entire remaining local budget;
   - concurrent unpriced admissions fail while that reservation is active;
   - warnings appear at startup, status, ledger records, and response header `X-MacProvider-Warning`;
   - `--allow-unpriced` never bypasses per-request cap or process-level `estimate_exceeded` stop.

6. Implement ledger path and locking:
   - default macOS ledger path `$HOME/Library/Application Support/macprovider/consume/ledgers/default.jsonl`;
   - explicit relative ledger paths resolve against process startup working directory;
   - path classes are `default_user_state`, `explicit_absolute`, and `explicit_relative`;
   - use OS-enforced exclusive advisory lock on `<ledger-filename>.lock`;
   - verify local filesystem lock support;
   - reject non-user-private, symlink-ambiguous, or lock-unsupported paths.

7. Implement durable ledger rows:
   - every row includes `schema_version: "local_consumer_endpoint.ledger.v1"`;
   - no separate header row;
   - immutable `run_id` and unique 128-bit CSPRNG `reservation_id`;
   - amount fields are string-encoded integer micro-USD values;
   - no raw prompts, completions, bearer tokens, local tokens, raw receipts, full upstream errors, hostnames, OS usernames, hardware serials, MAC addresses, or stable hardware UUIDs;
   - reservation append is durable before upstream forwarding;
   - every settlement, held, released, `estimate_exceeded`, and recovery audit transition is durable before status/response/recovery relies on it.

8. Implement state transitions and settlement:
   - closed transitions: `reserved` to `settled`, `held`, or `estimate_exceeded`; `held` to `released` or trusted late `settled`; terminal states are `settled`, `released`, and `estimate_exceeded`;
   - non-streaming trusted evidence is a complete bounded upstream JSON response with usage or SPEC-006 cost metadata;
   - SSE trusted evidence requires final usage or earlier usage confirmed by subsequent `data: [DONE]`;
   - if trusted evidence is unavailable, settle to admission estimate;
   - if trusted evidence exceeds estimate, record per-reservation `estimate_exceeded`, set process pricing trust state `estimate_exceeded`, and stop new chargeable admission;
   - in-flight requests admitted before process `estimate_exceeded` may complete.

9. Implement disconnect, restart, and recovery:
   - streaming client disconnect cancels/closes upstream when possible, waits no more than one second for synchronous cancellation acknowledgement, and settles conservatively unless trusted partial evidence is bound to the request;
   - restart treats in-flight reservations as held;
   - graceful shutdown stops new requests, drains up to five seconds, settles terminal requests, cancels/closes remaining upstream work, marks remaining reservations held, removes descriptor when possible, and exits;
   - implement `macprovider-cli consume budget status`;
   - implement `macprovider-cli consume budget release-held --ledger <path>|default --run-id <id> --confirm-release-held`;
   - release-held modifies only matching held reservations, audits releases, refuses while another process holds the lock, and exits nonzero `local_no_held_reservations` when no eligible rows match.

## Acceptance tests

- default-empty and explicit model allowlists;
- budget/per-request/no-budget/unpriced flag parsing and interactions;
- trusted rate-card signature, keyring, policy, freshness, stale warning, max-age, future-skew, and shape rejection;
- exact gross buyer-exposure arithmetic vectors, upward rounding, overflow fail-closed, cache-discount exclusion, provider-share exclusion, and micro-USD string fields;
- atomic concurrent admission and per-request cap rejection before ledger append/forwarding;
- ledger path class, relative resolution, local filesystem lock support, stale lock files, descriptor interactions, and fsync failure rollback;
- all closed state transitions, invalid transition rejection, per-row schema version, held recovery, wrong-run refusal, no-match failure, and recovery audit entries;
- non-streaming settlement to trusted evidence;
- SSE settlement only after `[DONE]` or conservative fallback;
- streaming disconnect, graceful shutdown, restart held reservations, `estimate_exceeded` process stop, and in-flight completion behavior.

## Non-goals

- Do not change gateway billing, coordinator settlement, provider payout, or receipt semantics.
- Do not treat local estimates as settlement evidence.
- Do not implement future cache-hit discount evidence.
