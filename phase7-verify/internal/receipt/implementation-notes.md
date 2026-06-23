# Receipt Parser Implementation Notes

## Fixture Provenance

`phase7-verify/testdata/receipt_fixtures.json` uses synthetic Go ed25519
fixtures, not Swift-generated receipts. The integration corpus currently builds
receipt headers in-process rather than storing stable header files, so static
Go fixtures keep the package tests hermetic while exercising the same
SPEC-015 §3.4 wire contract.

The valid fixture uses:

- ed25519 seed bytes `00 01 02 ... 1f`
- `model_id: "fixture-model"`
- `prompt_hash: "a" * 64`
- `output_hash: "b" * 64`
- `ttft_ms: 123`
- `tokens_out: 4`
- `unix_ts: 1800000000`

To regenerate, run a small Go program that constructs the tuple bytes in
canonical key order, signs those exact bytes with
`ed25519.NewKeyFromSeed([]byte{0, 1, ..., 31})`, and writes the same fixture
keys. Then run:

```bash
cd phase7-verify
go test ./internal/receipt/... -race -count=1 -v
```

## Raw-Bytes Verification Invariant

`Parsed.TupleRaw` is the decoded `base64(JCS(T))` byte slice from the header.
`Verify` passes those bytes directly to `ed25519.Verify`.

This is load-bearing: the provider signs the exact bytes emitted by its JCS
canonicalizer. The verifier must not re-canonicalize before signature
verification, because re-canonicalization would replace the signed byte string
with a verifier-derived byte string and could either reject valid historical
receipts or hide byte-level canonicalization drift.

Parse-time tuple checks are intentionally limited to envelope validity, JSON
well-formedness, exact seven-key shape, field types, non-negative integer
fields, hash/base64 field formats, duplicate top-level key rejection, and
leading/trailing whitespace rejection. Key-order canonicality is not
re-derived; the signature check enforces byte fidelity for syntactically valid
but noncanonical ordering.

## Error Taxonomy Mapping

Step 3 exposes `errors.Is`-compatible typed errors so Step 7 can map verifier
outcomes cleanly.

| Error | Step 7 mapping |
|---|---|
| `ErrSignatureFailed` | `result: invalid`, `reason: signature_verify_failed`, `details.field: signature` |
| `ErrPubkeyLength` from trusted pubkey input | input validation failure for malformed explicit/resolved key before result classification |
| `ErrHeaderShape` | malformed receipt input before §10.4.2 result classification |
| `ErrBase64Decode` | malformed receipt or malformed explicit pubkey input before result classification |
| `ErrSigLength` | malformed receipt input before signature verification |
| `ErrTupleJSON` | malformed receipt input before signature verification |
| `ErrTupleMissingKey` | malformed receipt input before signature verification |
| `ErrTupleExtraKey` | malformed receipt input before signature verification |
| `ErrTupleWrongType` | malformed receipt input before signature verification |

SPEC-015 §10.4.2 has no v0.2 `reason` enum for malformed local input; those
errors are expected to stay in the CLI/input-validation lane. The only Step 3
error that directly maps to a §10.4.2 invalid reason is
`ErrSignatureFailed`.

## Strictness Decisions

- Header parsing uses `strings.IndexByte` for the first separator and then
  rejects any second `.` as `ErrHeaderShape`, matching the "exactly one"
  delimiter contract.
- Tuple JSON with leading or trailing whitespace is rejected as `ErrTupleJSON`
  because §3.4 says the base64 tuple contains `JCS(T)` and §3.2 says no
  whitespace or trailing newline.
- Syntactically valid JSON with noncanonical key order is accepted by `Parse`
  and rejected by `Verify` unless it was signed as-is.
- `model_id` must be non-empty. The verifier does not enforce ASCII in Step 3;
  v0.2 keeps ASCII as a producer-side invariant and preserves tuple bytes for
  signature verification.
- `prompt_hash` and `output_hash` must be exactly 64 lowercase hex characters.
- `provider_pubkey` must be standard padded base64 matching
  `^[A-Za-z0-9+/]{43}=$` and decode to 32 bytes.

## Scope Boundaries

This package does not implement Step 4 prompt/output canonicalization, Step 5
pubkey resolution/cache behavior, trust-source selection, rotation grace
windows, CLI exit codes, or JSON output formatting.
