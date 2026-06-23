# phase7-verify fixture corpus

These fixtures are shipped AC-24 artifacts for SPEC-015 v0.2 verification.
Each `.bundle.json` file is generated from a deterministic signed receipt
unless the fixture is explicitly malformed to test exit 65 input handling.

## Corpus index

| Fixture | Description |
|---|---|
| `valid_fresh.bundle.json` | Current-key receipt with matching prompt and output hashes. |
| `valid_prev_key_in_grace.bundle.json` | Previous-key receipt with `unix_ts` inside `rotated_at - 60s <= unix_ts <= expires_at`. |
| `invalid_tampered_output.bundle.json` | Valid bundle cloned, then `response.choices[0].message.content` changed without re-signing. |
| `invalid_tampered_prompt.bundle.json` | Valid bundle cloned, then `request.messages[1].content` changed without re-signing. |
| `invalid_tampered_unix_ts.bundle.json` | Valid receipt tuple cloned, then the `unix_ts` byte sequence changed without re-signing. |
| `invalid_pubkey_not_endorsed.bundle.json` | Receipt signed by a deterministic foreign key not returned by the resolver. |
| `invalid_prev_key_outside_grace.bundle.json` | Previous-key receipt with `unix_ts = expires_at + 1s`. |
| `inconclusive_resolver_404.bundle.json` | Uses `provider_id: unknown-provider`; mock returns 404. |
| `inconclusive_stale_cache_live_fail.bundle.json` | Omits `provider_id`; test resolves via stale single-match cache, then mock returns 503. |
| `malformed_bundle.bundle.json` | Valid bundle cloned, then an unknown top-level field added for strict decoder rejection. |
| `malformed_receipt.bundle.json` | Well-formed bundle object with a receipt string that has no `.` separator. |
| `invalid_bundle_pubkey_provider_mismatch.bundle.json` | Valid bundle paired with a pre-seeded cache entry for the same provider but a different pubkey. |

Expected exit/result/reason/warning-kind values are documented in
`EXPECTED_RESULTS.md` and asserted by the tagged integration test.

## Regeneration

From the `phase7-verify` module root:

```sh
go run ./testdata/generator -seed 0xCAFEBABE -out testdata
```

The generator is deterministic: the same seed and source code produce
byte-identical fixture files. The integration gate verifies behavior from the
committed fixtures; maintainers can additionally run the generator twice and
compare hashes to catch drift.

For a future v0.3+ provider build, regenerate by replacing the generator's
canonical request/response construction with bytes captured from the provider
build, preserving the one-mutation-per-fixture rule and the deterministic key
derivation. Do not hand-edit signatures; start from a real signed bundle and
apply the fixture's single documented mutation.
