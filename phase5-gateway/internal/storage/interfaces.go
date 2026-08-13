package storage

import (
	"context"
	"time"
)

type AuthStore interface {
	CreateAccount(ctx context.Context, account Account) error
	AddAccountIdentity(ctx context.Context, identity AccountIdentity) error
	LookupAccountByIdentity(ctx context.Context, provider, providerUserID string) (Account, error)
	LookupAccount(ctx context.Context, accountID string) (Account, error)
	CreateAPIKey(ctx context.Context, key APIKey) error
	ValidateAPIKeyHash(ctx context.Context, keyHash []byte) (KeyValidation, error)
	ListAPIKeys(ctx context.Context, accountID string) ([]APIKeySummary, error)
	RevokeAPIKey(ctx context.Context, keyID, actor, requestID string) error
	RevokeAPIKeyForAccount(ctx context.Context, accountID, keyID, actor, requestID string) error
	RotateAPIKey(ctx context.Context, oldKeyID, accountID string, newKey APIKey, actor, requestID string) error
	StoreOAuthState(ctx context.Context, state OAuthState) error
	StoreOAuthStateWithCap(ctx context.Context, state OAuthState, maxPerIP int, now time.Time) error
	ConsumeOAuthState(ctx context.Context, stateHash []byte, sessionID string, now time.Time) (redirectURI, action, returnTo string, err error)
	StoreOAuthHandoff(ctx context.Context, handoff OAuthHandoff) error
	ConsumeOAuthHandoff(ctx context.Context, tokenHash []byte, now time.Time) (apiKey string, err error)
	PruneExpiredOAuthHandoffs(ctx context.Context, now time.Time) (int64, error)
	PruneExpiredOAuthState(ctx context.Context, now time.Time) (int64, error)
	ReservePublicIssuance(ctx context.Context, reservation PublicIssuanceReservation) error
	RecordSignupEvent(ctx context.Context, event SignupEvent) error
	CountSignupEventsSince(ctx context.Context, clientIP string, since time.Time) (int, error)
	RecordDemoSessionEvent(ctx context.Context, event DemoSessionEvent) error
	CountDemoSessionEventsSince(ctx context.Context, clientIP string, since time.Time) (int, error)
}

type AccountStore interface {
	CreateAccount(ctx context.Context, account Account) error
	AddAccountIdentity(ctx context.Context, identity AccountIdentity) error
	LookupAccountByIdentity(ctx context.Context, provider, providerUserID string) (Account, error)
	LookupAccount(ctx context.Context, accountID string) (Account, error)
	RecordSignupEvent(ctx context.Context, event SignupEvent) error
	CountSignupEventsSince(ctx context.Context, clientIP string, since time.Time) (int, error)
	ReservePublicIssuance(ctx context.Context, reservation PublicIssuanceReservation) error
}

type KeyStore interface {
	CreateAPIKey(ctx context.Context, key APIKey) error
	ValidateAPIKeyHash(ctx context.Context, keyHash []byte) (KeyValidation, error)
	ListAPIKeys(ctx context.Context, accountID string) ([]APIKeySummary, error)
	RevokeAPIKey(ctx context.Context, keyID, actor, requestID string) error
	RevokeAPIKeyForAccount(ctx context.Context, accountID, keyID, actor, requestID string) error
	RotateAPIKey(ctx context.Context, oldKeyID, accountID string, newKey APIKey, actor, requestID string) error
}

type OAuthStateStore interface {
	StoreOAuthState(ctx context.Context, state OAuthState) error
	StoreOAuthStateWithCap(ctx context.Context, state OAuthState, maxPerIP int, now time.Time) error
	ConsumeOAuthState(ctx context.Context, stateHash []byte, sessionID string, now time.Time) (redirectURI, action, returnTo string, err error)
	StoreOAuthHandoff(ctx context.Context, handoff OAuthHandoff) error
	ConsumeOAuthHandoff(ctx context.Context, tokenHash []byte, now time.Time) (apiKey string, err error)
	PruneExpiredOAuthHandoffs(ctx context.Context, now time.Time) (int64, error)
	PruneExpiredOAuthState(ctx context.Context, now time.Time) (int64, error)
}

type DemoSessionStore interface {
	RecordDemoSessionEvent(ctx context.Context, event DemoSessionEvent) error
	CountDemoSessionEventsSince(ctx context.Context, clientIP string, since time.Time) (int, error)
}

type UsageStore interface {
	ReserveQuota(ctx context.Context, req ReservationRequest) (QuotaDecision, error)
	SettleReservation(ctx context.Context, settlement ReservationSettlement) error
	SettleDemoReservation(ctx context.Context, settlement ReservationSettlement, demo DemoUsageEvent) error
	RefundReservation(ctx context.Context, accountID, requestID string, refundedAt int64) error
	ExpireReservation(ctx context.Context, accountID, requestID string, expiredAt time.Time) error
	MarkReservationStaleHeld(ctx context.Context, accountID, requestID string, staleAt time.Time) error
	MarkReservationSettlementHold(ctx context.Context, accountID, requestID string) error
	ClampReservationExpiry(ctx context.Context, accountID, requestID string, expiresAt time.Time) error
	ListSettlementHeldReservations(ctx context.Context, limit int) ([]ActiveReservation, error)
	InsertUsageEvent(ctx context.Context, event UsageEvent) error
	// EnsureUsageEvent inserts a usage_events row idempotently. The
	// idempotency key is the composite (account_id, request_id), matching
	// the usage_events primary key. That is the SPEC-006 § 17.7 money-path
	// contract for the failure-mode fallback in chat_proxy.settleAfterCommit
	// (issue #187):
	//
	//   - Returns nil on a fresh insert.
	//   - Returns nil when an existing row at the same account_id and
	//     request_id matches the incoming event in EVERY billing-relevant
	//     field (demo_identity, window_date, prompt_tokens,
	//     completion_tokens, total_tokens, token_source, outcome).
	//   - Returns ErrUsageEventConflict when an existing row at the same
	//     account_id and request_id DIFFERS from the incoming event in any
	//     of those fields.
	//   - Allows the same request_id under a different account_id to be
	//     stored independently; cross-account ambiguity is handled by
	//     lookup callers that accept request_id without account_id.
	//
	// The caller must treat ErrUsageEventConflict as a failure to
	// settle (i.e., the audit trail is unrecoverable for THIS event)
	// and proceed to refund + log loudly.
	EnsureUsageEvent(ctx context.Context, event UsageEvent) error
	// EnsureDemoUsageEvent is the demo-token sibling of
	// EnsureUsageEvent: idempotently inserts a demo_usage_events row
	// (INSERT OR IGNORE on request_id PK). Used by the SPEC-006
	// fallback path when SettleDemoReservation fails so the demo
	// audit trail required by SPEC-006 §4.5 / §14.3 still exists.
	// Returns nil on insert OR on a benign duplicate; the gateway's
	// fallback path bounds collision exposure via the earlier
	// EnsureUsageEvent call, which already runs the cross-account
	// payload-mismatch check.
	EnsureDemoUsageEvent(ctx context.Context, event DemoUsageEvent) error
	DailyUsage(ctx context.Context, accountID, windowDate string) (usedTokens, activeReservedTokens int64, err error)
	ReapExpiredReservations(ctx context.Context, now time.Time) (int64, error)
	// DeleteTerminalQuotaReservations drops quota_reservations rows in a
	// terminal status (expired / settled / refunded) whose settled_at is
	// strictly before `before`. M2-4 / PERF-1 Part B. Implementations
	// MUST leave concurrency_reservations alone — that table is protected
	// by an append-only trigger (Q4 territory).
	DeleteTerminalQuotaReservations(ctx context.Context, before time.Time) (int64, error)
	AcquireConcurrency(ctx context.Context, req ConcurrencyRequest) (ConcurrencyDecision, error)
	ReleaseConcurrency(ctx context.Context, accountID, requestID string, releasedAt time.Time) error
}

type WalletSessionStore interface {
	StoreWalletSessionChallenge(ctx context.Context, challenge WalletSessionChallenge) error
	RegisterWalletSession(ctx context.Context, req WalletSessionRegistrationRequest) (WalletSession, error)
	LookupWalletSessionByBearerHash(ctx context.Context, bearerHash []byte) (WalletSession, error)
	ListWalletSessions(ctx context.Context, accountID string) ([]WalletSession, error)
	GetWalletSession(ctx context.Context, accountID, sessionID string) (WalletSession, error)
	WalletSessionUsage(ctx context.Context, accountID, sessionID string) (WalletSessionUsage, error)
	ListWalletSessionUsageDetails(ctx context.Context, accountID, sessionID string, limit int, cursor string, since, until time.Time) ([]WalletSessionUsageDetail, string, error)
	RevokeWalletSession(ctx context.Context, accountID, sessionID, actor, reason string, revokedAt time.Time) error
	AdmitWalletSessionInference(ctx context.Context, req WalletSessionAdmissionRequest) (WalletSessionAdmissionDecision, error)
	AdmitWalletSessionMetadata(ctx context.Context, req WalletSessionMetadataAdmissionRequest) error
	ArmWalletSessionDispatch(ctx context.Context, arm WalletSessionDispatchArm) error
	MarkWalletSessionDispatched(ctx context.Context, sessionID, requestID string, dispatchedAt time.Time) error
	HoldStaleWalletSessionDispatchArms(ctx context.Context, before, heldAt time.Time) (int64, error)
	RefundStaleWalletSessionClaims(ctx context.Context, before, refundedAt time.Time) (int64, error)
	FinalizeWalletSessionReservation(ctx context.Context, settlement WalletSessionReservationSettlement) error
	SealWalletSessionUsageEvent(ctx context.Context, accountID, sessionID, requestID string, settledTokens int64, sealedAt time.Time) error
	RefundWalletSessionReservation(ctx context.Context, accountID, sessionID, requestID string, refundedAt time.Time) error
	HoldWalletSessionReservation(ctx context.Context, accountID, sessionID, requestID string, heldAt time.Time) error
	QuarantineWalletSessionReservation(ctx context.Context, accountID, sessionID, requestID string, quarantinedAt time.Time) error
	MarkWalletSessionReservationStaleHeld(ctx context.Context, accountID, sessionID, requestID string, staleAt time.Time) error
}

type HealthStore interface {
	Ping(ctx context.Context) error
}

type FeedbackStore interface {
	InsertFeedbackEvent(ctx context.Context, event FeedbackEvent) error
	ListFeedbackEventsSince(ctx context.Context, since time.Time) ([]FeedbackSummaryEvent, error)
	ListFeedbackEventsSinceLimit(ctx context.Context, since time.Time, limit int) ([]FeedbackSummaryEvent, error)
}

type AuditStore interface {
	InsertAuditEvent(ctx context.Context, event AuditEvent) error
}

type CapacityStore interface {
	InsertCapacitySignalEvent(ctx context.Context, event CapacitySignalEvent) error
	LatestCapacitySignals(ctx context.Context) ([]CapacitySignalEvent, error)
	GetCapacityTier(ctx context.Context) (CapacityTier, error)
	SetCapacityTier(ctx context.Context, tier CapacityTier) error
	GetKillSwitch(ctx context.Context) (KillSwitchState, error)
	SetKillSwitch(ctx context.Context, state KillSwitchState) error
	CompareAndSwapKillSwitch(ctx context.Context, expectedVersion int64, state KillSwitchState) (bool, error)
}

type ExplorerStore interface {
	ExplorerListBuyers(ctx context.Context, q ExplorerBuyerQuery) (ExplorerBuyerList, error)
	ExplorerBuyerDetail(ctx context.Context, accountID string, q ExplorerDetailQuery) (ExplorerBuyerDetail, error)
	ExplorerListSessions(ctx context.Context, q ExplorerSessionQuery) (ExplorerSessionList, error)
	// ExplorerSessionDetail looks up the row trail for a request_id.
	// accountID may be empty for backward-compat callers; when empty
	// AND the request_id resolves to multiple accounts (allowed since
	// issue #196 made usage_events PK composite), the call returns
	// ErrExplorerAmbiguousRequestID and populates
	// ExplorerSessionDetail.MatchedAccountIDs so the caller can
	// disambiguate.
	ExplorerSessionDetail(ctx context.Context, accountID, requestID string) (ExplorerSessionDetail, error)
	ExplorerActivity(ctx context.Context, q ExplorerActivityQuery) (ExplorerActivityList, error)
	ExplorerHealth(ctx context.Context, since time.Time) (ExplorerHealth, error)
}
