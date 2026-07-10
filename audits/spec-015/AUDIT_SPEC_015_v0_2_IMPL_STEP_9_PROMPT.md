# AUDIT SPEC-015 v0.2 Implementation Step 9

You are auditing Step 9 of `BUILD_SPEC_015_v0_2_VERIFY_IMPL_PROMPT.md` on
branch `impl/spec-015-v0-2-step-09`.

Scope:

1. Fixture coverage completeness:
   - Confirm every §10.4.2 result/reason value exercised by Step 9 has a
     committed fixture or a documented prior unit-test fixture.
   - Confirm the Step 9 corpus covers:
     `signature_and_canonicalization_match`, `signature_verify_failed`,
     `prompt_hash_mismatch`, `output_hash_mismatch`, `pubkey_not_endorsed`,
     `previous_key_outside_grace_window`,
     `bundle_pubkey_provider_mismatch`, `provider_id_not_in_pool`, and
     `pubkey_unresolvable`, and `cache_stale_and_live_unreachable`.
   - Confirm malformed bundle and malformed receipt paths exit 65 and do not
     emit schema JSON.

2. Fixture generation reproducibility:
   - Run `cd phase7-verify && go run ./testdata/generator -seed 0xCAFEBABE -out <tmpdir>`
     twice and confirm byte-identical `*.bundle.json` outputs.
   - Confirm generated outputs are byte-identical to committed
     `phase7-verify/testdata/*.bundle.json`.
   - Confirm no fixture signature was hand-edited; invalid fixtures start from
     a real signed artifact and apply exactly one documented mutation.

3. `bundle_pubkey_provider_mismatch` correctness:
   - Confirm detection is in the CLI/bundle layer, before `verify.Verify`.
   - Confirm it triggers only in bundle/stdin mode with a resolved provider ID
     and exactly one cached entry for that provider whose cached current pubkey
     differs from the receipt's embedded `provider_pubkey`.
   - Confirm header+hashes mode with the same cache mismatch does not emit
     `bundle_pubkey_provider_mismatch`.

4. Schema gate effectiveness:
   - Confirm `phase7-verify/internal/schemavalidator.Validate` is the single
     local schema validation implementation used by output tests and Step 9
     integration tests.
   - Confirm every JSON-emitting fixture validates against
     `phase7-verify/schemas/output.schema.json`, including invalid and
     inconclusive outcomes.

5. Mock `/v1/receipt-keys` parity:
   - Compare the integration mock response shape to SPEC-015 §10.7 and the
     real coordinator handler contract.
   - Confirm 200, 404, and 5xx resolver dispositions are all exercised.
   - Confirm the test does not call external network targets.

6. CI flakiness and runtime:
   - Confirm the integration test is deterministic, completes in under
     60 seconds, and isolates cache state per fixture.
   - Confirm local TLS trust setup does not weaken production HTTPS
     enforcement.

7. Silent corner cases:
   - Confirm the absent `provider_id` bundle path is tested via a single-match
     cache entry and does not scan providers.
   - Confirm cache pre-seeding uses the same on-disk format and path the binary
     uses at runtime.

Report CRITICAL/MAJOR/MINOR findings with file:line evidence and exact
reproduction commands. If no blocking findings remain, state `READY TO LOCK`.
