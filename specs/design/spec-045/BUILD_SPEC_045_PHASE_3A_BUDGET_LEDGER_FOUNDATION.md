# BUILD_SPEC_045_PHASE_3A_BUDGET_LEDGER_FOUNDATION

Implement the fail-closed SPEC-045 budget-ledger foundation needed before the
full trusted-pricing and proxy-settlement Phase 3 work. This slice narrows the
current implementation step because Phase 2 still does not proxy chargeable chat
requests upstream.

## Target Result

`macprovider-cli consume` supports local budget flags, model admission, durable
micro-USD ledger reservation state, held-reservation recovery, redacted status,
and unpriced override handling without forwarding chargeable requests.

Chargeable `POST /v1/chat/completions` requests remain fail-closed:

- unconfigured budget mode returns `local_budget_required`;
- disallowed models return `local_model_not_allowed` before budget mutation;
- budgeted mode without trusted pricing returns `local_pricing_unavailable`;
- budgeted `--allow-unpriced` reserves and immediately holds the full remaining
  budget, then returns `local_upstream_unavailable` because live proxying is
  not in this slice;
- per-request cap rejection occurs before any ledger append.

## Required Implementation Shape

1. Implement budget flags:
   - positive `--budget-usd`;
   - optional positive `--max-request-usd`;
   - explicit `--no-budget`;
   - optional `--ledger <path>` only when budgeted or no-budget mode is
     selected;
   - explicit `--allow-unpriced` warning surface.

2. Implement local model admission for chat-completions:
   - parse only the duplicate-key-free JSON body accepted by Phase 2;
   - reject missing or disallowed `model` as `local_model_not_allowed`;
   - perform model admission before any budget mutation.

3. Implement a local micro-USD ledger foundation:
   - schema version `local_consumer_endpoint.ledger.phase3a.v1`;
   - treat this as a Phase 3A foundation schema, not the final
     `local_consumer_endpoint.ledger.v1` schema required by SPEC-045-R005;
     the full Phase 3 implementation must either migrate these rows or add an
     explicit compatibility reader before writing final v1 rows;
   - string-encoded integer micro-USD amounts;
   - 128-bit CSPRNG reservation ids;
   - `reserved`, `held`, and `released` transitions;
   - immutable `run_id`, `reservation_id`, and amount across transitions;
   - no raw prompts, completions, bearer tokens, local tokens, raw receipts, or
     full upstream errors.

4. Implement ledger path and lock handling:
   - default macOS user-state ledger path;
   - explicit absolute and startup-directory-relative paths;
   - path class reporting;
   - user-private parent/file checks;
   - symlink rejection;
   - exclusive advisory lock on `<ledger>.lock`;
   - pinned validated ledger file descriptor for reads and appends.

5. Implement atomic local unpriced admission:
   - serialize read-plus-reserve-plus-hold inside the process;
   - reserve the full remaining run budget under `--allow-unpriced`;
   - reject concurrent full-remaining admissions once budget is held;
   - reject requests above `--max-request-usd` before appending ledger rows.

6. Implement recovery/status commands:
   - `macprovider-cli consume budget status`;
   - `macprovider-cli consume budget release-held --ledger <path>|default
     --run-id <id> --confirm-release-held`;
   - `release-held` changes only matching held reservations and exits nonzero
     with `local_no_held_reservations` when no eligible row exists.

7. Implement status truthfulness:
   - budgeted healthy ledgers report configured, used, held, and remaining
     micro-USD values;
   - corrupt, replaced, unparsable, or unavailable ledgers must not be reported
     as empty/fully available;
   - `--no-budget` status reports budget configured/used/held/remaining as
     JSON null values.

## Acceptance Tests

- budget, max-request, no-budget, ledger, and unpriced flag parsing;
- model rejection before budget mutation;
- unconfigured budget rejection remains `local_budget_required`;
- unpriced budgeted request reserves and holds full remaining budget;
- per-request cap rejection creates no ledger rows;
- concurrent unpriced admission admits only one full-budget hold;
- status does not mask corrupt ledgers as empty;
- ledger rejects path replacement after open;
- ledger rejects run-id or amount mutation across transitions;
- held reservation release updates only matching run ids;
- startup output reports budget mode without leaking local paths.

## Non-Goals

- Do not implement trusted SPEC-006 rate-card or SPEC-023 signature validation.
- Do not implement conservative priced estimate math.
- Do not proxy chargeable chat-completions upstream.
- Do not implement terminal upstream settlement, streaming settlement,
  `estimate_exceeded`, graceful shutdown draining, or signed journey evidence.
- Do not change gateway billing, coordinator settlement, provider payout,
  receipt semantics, or public gateway behavior.
