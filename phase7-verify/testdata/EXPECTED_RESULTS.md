# Expected fixture results

All JSON-emitting outcomes must validate against `../schemas/output.schema.json`.
The mock coordinator is non-default, so network-backed JSON outcomes include
`non_default_coordinator`.

| Fixture | Exit | Result | Reason | Warning kinds |
|---|---:|---|---|---|
| `valid_fresh.bundle.json` | 0 | `valid` | `signature_and_canonicalization_match` | `non_default_coordinator` |
| `valid_prev_key_in_grace.bundle.json` | 0 | `valid` | `signature_and_canonicalization_match` | `non_default_coordinator` |
| `invalid_tampered_output.bundle.json` | 1 | `invalid` | `output_hash_mismatch` | `non_default_coordinator` |
| `invalid_tampered_prompt.bundle.json` | 1 | `invalid` | `prompt_hash_mismatch` | `non_default_coordinator` |
| `invalid_tampered_unix_ts.bundle.json` | 1 | `invalid` | `signature_verify_failed` | `non_default_coordinator` |
| `invalid_pubkey_not_endorsed.bundle.json` | 1 | `invalid` | `pubkey_not_endorsed` | `non_default_coordinator` |
| `invalid_prev_key_outside_grace.bundle.json` | 1 | `invalid` | `previous_key_outside_grace_window` | `non_default_coordinator` |
| `valid_fresh.bundle.json` with live 5xx and no cache | 2 | `inconclusive` | `pubkey_unresolvable` | `live_check_skipped`, `non_default_coordinator` |
| `inconclusive_resolver_404.bundle.json` | 2 | `inconclusive` | `provider_id_not_in_pool` | `non_default_coordinator` |
| `inconclusive_stale_cache_live_fail.bundle.json` | 2 | `inconclusive` | `cache_stale_and_live_unreachable` | `live_check_skipped`, `non_default_coordinator` |
| `malformed_bundle.bundle.json` | 65 | n/a | unknown top-level bundle field | n/a |
| `malformed_receipt.bundle.json` | 65 | n/a | receipt has no `.` separator | n/a |

`inconclusive_stale_cache_live_fail.bundle.json` intentionally omits
`provider_id`; the integration test resolves it through a single matching cache
entry, then proves stale-cache plus live-5xx returns the expected inconclusive
result.
