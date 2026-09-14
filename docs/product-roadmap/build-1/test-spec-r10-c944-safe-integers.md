# Build 1 test specification r10 — c944 safe-integer interoperability

Status: proposed. This revision incorporates r5-r9 and pairs with reconciliation
r6. It supersedes only r9's int64-maximum boundary; the lexical and per-field
matrices remain unchanged.

## R10-01 — boundary and canonicalization matrix

For each of the eight numeric v2 members, prove that 9,007,199,254,740,991
passes the common schema ceiling and then reaches the field's narrower owner
range, while 9,007,199,254,740,992 and larger values fail before canonicalization,
route persistence or settlement. Retain the r9 zero, one, negative, `-0`,
fraction, exponent, quoted, null, boolean, array, object, leading-zero and
whitespace arms.

For values accepted by the field-specific contract, compare exact canonical
bytes and SHA-256 from the repository canonicalizer with a separate
RFC-8785-compatible binary64 serialization fixture. Include values around
`2^53`: `9007199254740990`, `9007199254740991`, and the rejected
`9007199254740992`. Restart/replay must reproduce the stored accepted digest
without consulting mutable feed, index, keyring or rate state.

The amended SPEC-047 R003/R008 text and conformance selector must state and
select this exact safe-integer boundary. Governance checking fails on stale
version/index metadata or a zero-selected test.

## Evidence

Record exact command, base/head SHA, selected/pass/fail/skip counts, duration and
log hash. This test remains local compatibility evidence and does not qualify
physical MLX, release signing, deployment, enforcement or economic activation.
