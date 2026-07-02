package storage

import "errors"

var (
	ErrNotFound            = errors.New("not found")
	ErrBadCursor           = errors.New("bad cursor")
	ErrQuotaExceeded       = errors.New("quota exceeded")
	ErrReservationExists   = errors.New("quota reservation exists")
	ErrReservationNotFound = errors.New("quota reservation not found")
	ErrReservationTerminal = errors.New("quota reservation is terminal")
	// ErrUsageEventConflict is returned by EnsureUsageEvent when the
	// request_id PK already has a row whose identity fields
	// (account_id, demo_identity, token_source, outcome) DISAGREE
	// with the incoming event. Pre-existing #196 PK-collision attack
	// surface: this sentinel forces the caller to refund + log
	// instead of silently absorbing the duplicate.
	ErrUsageEventConflict = errors.New("usage event conflicts with existing row for request_id")
	// ErrExplorerAmbiguousRequestID is returned by ExplorerSessionDetail
	// when the request_id resolves to rows from multiple accounts and
	// the caller did not supply an account scope. Issue #196 made
	// (account_id, request_id) the usage_events PK, which allows
	// legitimate cross-account collisions; explorer callers must
	// disambiguate.
	ErrExplorerAmbiguousRequestID = errors.New("explorer session request_id matches multiple accounts; supply account_id")
)
