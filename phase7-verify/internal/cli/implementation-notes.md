# CLI Implementation Notes

## Flag to Mode Resolution

`Run` parses flags with the stdlib `flag` package, then resolves exactly one
input mode before calling `verify.Verify`:

1. `--bundle` plus `--receipt` is a CLI usage error (`64`).
2. `--bundle <path|->` selects bundle mode. `-` is decoded from injected stdin.
3. `--receipt` selects header+hashes mode and requires both `--prompt-hash`
   and `--output-hash`.
4. No input mode is a CLI usage error (`64`).

The legacy stdin spelling `macprovider-verify -` is accepted as `--bundle -`.

## 64 vs 65 Boundary

The CLI returns `64` for invocation problems: unknown flags, mutually exclusive
flags, missing required flags, malformed `--pubkey`, malformed
`--provider-id`, or malformed hash flag values.

The CLI returns `65` for data-format problems: malformed bundle JSON, unknown
bundle top-level keys, missing bundle fields, unsupported `bundle_version`, and
receipt parse failures discovered while resolving provider identity.

`json.Decoder.DisallowUnknownFields()` enforces strict bundle top-level parsing.

The top-level `Run` wrapper also recovers an unexpected panic as `70`
(`EX_SOFTWARE`) and prints `internal error`. That path is a last-resort safety
net only. Documented verifier outcomes take precedence through ordinary control
flow: `0` valid, `1` invalid, `2` inconclusive, `64` usage errors, and `65`
input-format errors. No observed CLI invocation path intentionally produces
`70`; seeing it means an implementation bug escaped the typed error/result
mapping above.

## JSON vs Human Output

Step 7 intentionally keeps output minimal. `--json` calls `json.Marshal` on
`verify.Result`; `verify.Result.MarshalJSON` renders unresolved `provider_id`
as JSON `null`, and `verify.Warning.MarshalJSON` flattens warning fields into
the warning object. Human output is one line with result, reason, provider,
model, and trust source. Step 8 owns final formatting polish.

`--quiet` suppresses stderr only. JSON `warnings[]` records are preserved.
`--explain` prints the Step 7 inline trust-boundary text after a valid result
unless `--quiet` suppresses stderr.

`bundle_pubkey_provider_mismatch` is reserved per SPEC-015 §10.4.2; the v0.2
detection path is a bundle-layer check landing with Step 9 end-to-end fixtures
and integration, while Step 6 already reports `pubkey_not_endorsed` for
receipt-embedded pubkey vs resolver-endorsed pubkey divergence and the reserved
reason is the narrower case where the bundle's own `provider_id` claim conflicts
with the receipt-embedded `provider_pubkey`'s cached/resolved provider identity.

Step 8 ships the output schema, inline validator, and synthetic valid/invalid/
inconclusive schema validation tests. Step 9 owns `testdata/*.bundle.json`
end-to-end fixtures and the integration test that routes those fixture outputs
through the schema gate.

## Provider-ID Resolution

Provider identity is resolved before verification:

1. `--provider-id` wins.
2. Bundle `provider_id` is used when the flag is absent.
3. A read-only single-match cache fallback scans the cache JSONL file for
   exactly one entry under the configured coordinator whose `receipt_pubkey`
   matches the receipt tuple's embedded pubkey. Zero or multiple provider IDs
   fall through.
4. If still missing and no `--pubkey` was supplied, the CLI returns `64` with
   an error naming `--provider-id`.
5. If still missing and `--pubkey` was supplied, verification proceeds with
   `ProviderID == ""`. The resolver records `live_check_skipped` with
   `reason: provider_id_unresolvable`; JSON output renders `provider_id: null`.

The cache fallback reads provider IDs only from exact pubkey matches and does
not fingerprint-scan coordinator state or perform any live discovery.

## Explicit Hash Bypass

Header+hashes mode does not have request/response objects to canonicalize.
The CLI decodes `--prompt-hash` and `--output-hash` into
`VerifyInput.ExplicitPromptHash` and `VerifyInput.ExplicitOutputHash`.
`verify.Verify` uses those 32-byte values directly and skips canonicalization
only when the explicit fields are set. Bundle mode leaves those fields empty
and continues to use Step 4 canonicalization.
