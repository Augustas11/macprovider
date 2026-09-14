# Build 1 test specification r9 — c944 integer-token grammar

Status: proposed. This revision incorporates r5-r8 and pairs with reconciliation
r5. It adds the normative/conformance proof required by M6 without weakening the
existing r8 per-field matrix.

## R9-01 — normative selector and decoder agreement

The amended SPEC-047 R003 text and R008 conformance selector must name the exact
non-negative int64 lexical contract from plan r5 and select the actual decoder
tests. For each of the eight numeric fields, start from a valid v2 golden object
and prove:

- `0` reaches the field's owner range check and succeeds exactly where zero is
  allowed;
- `1` and `9223372036854775807` reach the owner range check, with acceptance or
  rejection determined by that field's narrower bound;
- `9223372036854775808`, an arbitrarily longer digit string, `-0`, `-1`, `1.0`,
  `0.0`, `1e0`, `1E+0`, quoted numbers, null, boolean, array, and object fail at
  lexical/type parsing before canonicalization or persistence; and
- leading-zero forms are rejected as invalid JSON input rather than normalized.

Also prove permitted JSON whitespace around a valid token decodes to the same
typed value and canonical bytes. Assert the implementation test name is selected
by the updated SPEC-047 conformance entry; zero selected tests fails the gate.
Run governance generation/checking and confirm the SPEC version, README,
AUTHORITY and CONFORMANCE indexes agree.

## Evidence

Record exact command, base/head SHA, selected/pass/fail/skip counts, duration and
log hash. R9 remains additive to r5-r8 and does not qualify physical MLX,
release signing, deployed settlement, enforcement or economic activation.
