# AUDIT SPEC-015 v0.2 Implementation Step 3

You are auditing Step 3 of `BUILD_SPEC_015_v0_2_VERIFY_IMPL_PROMPT.md`: the
receipt parser and ed25519 signature verifier for
`phase7-verify/internal/receipt`.

Target branch: `impl/spec-015-v0-2-step-03`

## Scope

Review only the Step 3 implementation surface:

- `phase7-verify/internal/receipt/receipt.go`
- `phase7-verify/internal/receipt/receipt_test.go`
- `phase7-verify/internal/receipt/implementation-notes.md`
- `phase7-verify/testdata/receipt_fixtures.json`

Do not request Step 4 canonicalization, Step 5 resolver/cache behavior, CLI
flag wiring, coordinator changes, Swift signer changes, CI changes, or edits
to any `specs/SPEC-*.md` file.

## Required Checks

1. Header parsing correctness vs SPEC-015 §3.4 and §10.0 steps 1-3.
   Confirm the parser splits on the first literal `.`, rejects headers that do
   not contain exactly one separator, base64-decodes the tuple and signature
   independently, and rejects decoded signatures whose length is not exactly
   64 bytes.

2. Tuple shape strictness vs SPEC-015 §3.1 and §10.0 step 4.
   Confirm the parser rejects extra keys, missing keys, duplicate top-level
   keys, wrong JSON types, non-integer numeric encodings, negative integer
   fields, malformed JSON, and leading/trailing whitespace. Confirm string
   format checks cover 64-char lowercase hex hashes and standard padded
   44-char provider pubkeys.

3. Canonical vs noncanonical tuple behavior.
   Confirm the implementation does not re-canonicalize the tuple for
   verification. Syntactically valid but noncanonical key order should parse
   but fail signature verification unless signed as-is; tuple bytes with
   trailing whitespace should fail parse as non-JCS surface bytes.

4. Signature verification correctness vs SPEC-015 §3.3 and §10.0 step 6.
   Confirm `crypto/ed25519.Verify` receives `Parsed.TupleRaw` exactly as
   decoded from the header, uses a caller-supplied trusted pubkey, rejects
   non-32-byte pubkeys, and returns `ErrSignatureFailed` for failed checks.
   Note whether stdlib ed25519 provides the required constant-time semantics.

5. Error taxonomy completeness.
   Confirm all exported typed errors are reachable in tests and remain
   `errors.Is`-compatible when field context is appended. Confirm the mapping
   in `implementation-notes.md` aligns with SPEC-015 §10.4.2: signature
   failure maps to `reason: signature_verify_failed`, while malformed local
   input stays outside the v0.2 result reason enum.

6. Fixture provenance and adversarial coverage.
   Inspect `receipt_fixtures.json` and tests for: valid receipt plus pubkey,
   one-byte tuple tamper, one-byte signature tamper, no-dot header, two-dot
   header, extra key, missing key, wrong type, noncanonical ordering,
   trailing whitespace, and 63-byte signature. Confirm provenance is documented
   and regeneration is plausible.

7. Dependency and scope control.
   Confirm Step 3 uses only Go stdlib packages and does not modify Step 1
   scaffold files, Step 2 JCS files, CI workflow files, `phase3-binary`,
   `phase4-coordinator`, or normative `specs/SPEC-*.md` files.

## Validation Commands

Run:

```bash
cd phase7-verify
go vet ./internal/receipt/...
go test ./internal/receipt/... -race -count=1 -v
go test ./... -race -count=1
```

Also inspect:

```bash
git diff --stat
git diff -- phase7-verify/internal/receipt phase7-verify/testdata/receipt_fixtures.json specs/AUDIT_SPEC_015_v0_2_IMPL_STEP_3_PROMPT.md
```

## Output Format

Report findings first, ordered by severity:

- `CRITICAL`: signature verification accepts forged or untrusted bytes, tuple
  bytes are re-canonicalized before verification, malformed headers bypass
  validation, or non-stdlib dependencies are added.
- `MAJOR`: missing required error path, incomplete fixture coverage, incorrect
  field validation, non-`errors.Is`-compatible taxonomy, or scope creep into
  later steps.
- `MINOR`: documentation, naming, or maintainability issue that does not affect
  verification correctness.

For every finding, include file path, line number, evidence, impact, and a
specific recommended fix. If there are no findings, state that clearly and list
remaining residual risks.
