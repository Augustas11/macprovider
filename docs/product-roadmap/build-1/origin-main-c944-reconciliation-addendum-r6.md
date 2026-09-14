# Build 1 origin/main c944 reconciliation addendum r6

Status: proposed. This revision incorporates r1-r5 and changes only the common
numeric ceiling needed for RFC 8785/I-JSON interoperability. All earlier
authority, schema, migration, compatibility and test requirements remain in
force. Conflict implementation remains blocked pending a fresh independent
zero-Critical/High/Medium gate over the complete bundle.

## R6-01 — interoperable safe-integer ceiling

The SPEC-047 successor MUST bound every numeric member of
`macprovider.artifact_admission.v2` to the inclusive range 0 through
9,007,199,254,740,991 (`2^53 - 1`) after the exact integer-token grammar in r5
and before any narrower field rule. The prior r5 int64 maximum is superseded.

This ceiling is part of the wire and persisted canonical schema, not merely an
implementation limit. It ensures an accepted integer is exactly representable
by an IEEE-754 binary64 value and therefore has one RFC 8785/JCS representation
across the coordinator, gateway, recovery tools and other conforming decoders.
No accepted v2 value may depend on Go's wider exact int64 serialization.

Each owner-defined constraint is then applied: configuration and expiry values
remain positive; rates, provider share and multiplier retain their existing
zero and upper-bound rules. Because v2 is new and unshipped, this narrows no
historical accepted record. Historical c944 six-field and no-extension records
contain none of these numeric extension members and remain byte-identical.

## R6 stop condition

Do not implement or publish the v2 schema if SPEC-047, conformance metadata and
the decoder disagree on the `2^53 - 1` ceiling, or if a golden accepted value
canonicalizes differently through the repository JCS path and an independent
RFC-8785-compatible number serializer.
