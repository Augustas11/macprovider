// Package version centralizes the verifier binary and SPEC compatibility versions.
//
// BinaryVersion 1.1.1 accepts live SPEC-015 v0.3 receipts whose
// model_hash is a string or JSON null. 1.1.0 rejected those tuples
// before signature verification. MaxSPECVersion stays 0.3.3: a
// receipt_version other than "3", including settlement "4", stays
// inconclusive (unknown_receipt_version). The compiled-in key-lookup
// host is coordinator.malibu.tech.
package version

const (
	BinaryVersion  = "1.1.1"
	MaxSPECVersion = "0.3.3"
)
