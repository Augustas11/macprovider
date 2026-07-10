# AUDIT_SPEC_015_IMPL_STEP_1 — JCS canonicalizer extensions

You are auditing the implementation branch for BUILD_SPEC_015 Step 1 in
`/Users/augstar/macprovider-poc-spec015-step01`.

## Normative sources

- `specs/BUILD_SPEC_015_IMPL_PROMPT.md` Step 1.
- `specs/SPEC-015-receipts.md` v0.1.3, especially §3.2 and AC-5/AC-6.
- `phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift`.
- `phase3-binary/Tests/macprovider-cliTests/RFC8785JCSTests.swift`.
- `phase3-binary/implementation-notes.html`.

## Scope under audit

Step 1 is limited to the Swift JCS canonicalizer prerequisite for receipts:

1. Add NFC normalization on JSON string values before escaping.
2. Add RFC 8785 §3.2.2.3 / ECMAScript-compatible finite `Double`
   serialization via `RFC8785JCS.Value.double(Double)`.
3. Reject NaN and infinities.
4. Keep existing int, bool, null, string, array, object behavior
   backward-compatible.
5. Add focused Swift tests and phase3 implementation notes.

No receipt signing, Keychain, coordinator, gateway, locked-spec text, or
wire-protocol work should land in this step.

## Required local commands

Run or inspect equivalent fresh evidence:

```bash
git diff --check
env CLANG_MODULE_CACHE_PATH=/private/tmp/macprovider-swift-module-cache swift test --package-path phase3-binary --filter RFC8785JCSTests
env CLANG_MODULE_CACHE_PATH=/private/tmp/macprovider-swift-module-cache swift test --package-path phase3-binary
```

## Audit lenses

### Code auditor

- Verify `.double(Double)` is integrated into `RFC8785JCS.Value` and
  `canonicalString(_:)` without changing existing object/array/int/bool/null
  semantics.
- Verify NFC normalization is applied before escaping string values.
- Verify object key sorting remains UTF-16 lexicographic and existing ASCII
  tuple-tier fields remain byte-stable.
- Verify the tests cover the minimum cases from the BUILD prompt: decomposed
  vs precomposed NFC equality, ASCII no-op, `0.0`, `-0.0`, `1.0`, `1.1`,
  `1e-7`, `1e20`, NaN rejection, infinity rejection, and old-type behavior.

### Security auditor

- Verify NaN and infinities cannot serialize as `null`, `"nan"`, `"inf"`, or
  any other accepted canonical number.
- Verify the implementation does not add receipt persistence, secret logging,
  key material, network calls, or external package dependencies.
- Verify the JavaScriptCore use cannot execute attacker-controlled script; it
  should only format a numeric value with a fixed script.
- Verify no receipt tuple hashes, signatures, or pubkeys are logged.

### Architect auditor

- Verify the implementation remains one shared canonicalizer and does not
  introduce a parallel receipt-specific JCS path.
- Verify the JavaScriptCore number-formatting decision is documented with the
  platform constraint and future Linux caveat.
- Verify Step 1 does not leak into later BUILD_SPEC_015 steps.
- Verify the design is compatible with later prompt hashing, where only
  prompt canonical-object floats exercise `.double`.

## Severity contract

Report findings with severities:

- `CRITICAL`: violates a locked spec, emits wrong canonical bytes for required
  RFC 8785/JCS cases, accepts non-finite numbers, or implements out-of-scope
  receipt/key/coordinator/gateway behavior.
- `HIGH`: likely receipt verification divergence, unsafe script execution,
  missing required tests for a mandatory Step 1 behavior, or architecture that
  creates a parallel canonicalizer.
- `MEDIUM`: incomplete edge-case coverage, undocumented tradeoff that future
  implementers need, or fragile implementation likely to break AC-5/AC-6.
- `LOW`: style, clarity, or optional additional coverage.

The gate to proceed is **0 CRITICAL / 0 HIGH / 0 MEDIUM**. LOW findings may
remain if explicitly justified.

## Expected output

Return:

1. Verdict: `READY` or `FIX REQUIRED`.
2. Counts: `CRITICAL n / HIGH n / MEDIUM n / LOW n`.
3. Findings grouped by code/security/architecture lens, with concrete file and
   line references.
4. Verification commands actually run and their results.
5. Any residual risk.
