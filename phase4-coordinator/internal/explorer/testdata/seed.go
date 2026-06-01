// Package testdata documents the deterministic SPEC-007 seed shape used by
// explorer tests. Go does not compile testdata packages during ./... runs.
package testdata

const (
	BuyerCount      = 3
	ProviderCount   = 2
	SessionCount    = 5
	LedgerRowCount  = 10
	SettlementCount = 2
)
