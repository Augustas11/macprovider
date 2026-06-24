// Package version centralizes the verifier binary and SPEC compatibility versions.
//
// Updated to BinaryVersion 1.1.0 per SPEC-015 v0.3 IMPL bundle ship
// (see beta/DECISION_CRITERIA.md Entry 85). v1.1.x ADDS v0.3.3 receipt
// verification on top of the v1.0.x v0.1/v0.2 compatibility floor —
// the §M.1.2 forward-incompat guarantee still holds (locked v0.2.4
// verifiers report v0.3 receipts as `invalid`).
package version

const (
	BinaryVersion  = "1.1.0"
	MaxSPECVersion = "0.3.3"
)
