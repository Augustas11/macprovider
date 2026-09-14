# Build 1 origin/main c944 reconciliation addendum r5

Status: proposed. This revision incorporates r1-r4 and resolves M6 from
independent GPT-5.6 Sol review `origin-main-c944-plan-r4-sol.md` SHA-256
`0dbfdb5d8a413971eb9d00258e5ec6a9884ae5cecb9a859654e96751903a9744`.
It changes only the normative lexical grammar for the eight numeric v2 fields;
all prior requirements remain in force. Conflict implementation remains blocked
until the complete r1-r5/r5-r9 bundle passes a fresh independent gate at zero
Critical, High, and Medium.

## R5-01 — SPEC-047 owns the exact integer-token grammar

The versioned SPEC-047 amendment required by r4 MUST state that every numeric
member of `macprovider.artifact_admission.v2` is encoded as a non-negative
base-10 JSON number token with lexical form `0` or `[1-9][0-9]*`. The parsed
magnitude MUST fit signed int64, from 0 through 9223372036854775807 inclusive,
before the field's narrower owner-defined range is applied.

Negative tokens including `-0`, leading-zero forms, a decimal point, exponent
syntax, quoted numbers, JSON null, booleans, arrays, and objects are invalid.
JSON whitespace outside the token follows the JSON grammar and is not part of
the numeric token. This lexical contract applies to all eight numeric members:
billing configuration snapshot ID; prompt, cache-hit prompt and completion
rates; provider share; global multiplier; authority expiry; and probe expiry.

After lexical parsing, existing owner rules remain unchanged. Configuration and
expiry values are positive; rates, provider share and multiplier use their
existing bounds and zero-valid rules. Canonicalization uses the validated int64
value. A mathematically integral token such as `1.0` or `1e0` remains invalid,
so every conforming producer, recovery tool and decoder agrees before hashing
persisted money-path evidence.

## R5 stop condition

Do not implement the decoder or amend conformance selectors unless the actual
SPEC-047 successor contains this exact grammar and bounds. A test-only lexical
restriction is insufficient.
