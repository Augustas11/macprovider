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
	ConsumeOAuthState(ctx context.Context, stateHash []byte, sessionID string, now time.Time) (redirectURI string, err error)
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
	ConsumeOAuthState(ctx context.Context, stateHash []byte, sessionID string, now time.Time) (redirectURI string, err error)
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
	InsertUsageEvent(ctx context.Context, event UsageEvent) error
	DailyUsage(ctx context.Context, accountID, windowDate string) (usedTokens, activeReservedTokens int64, err error)
	ReapExpiredReservations(ctx context.Context, now time.Time) (int64, error)
	AcquireConcurrency(ctx context.Context, req ConcurrencyRequest) (ConcurrencyDecision, error)
	ReleaseConcurrency(ctx context.Context, accountID, requestID string, releasedAt time.Time) error
}

type HealthStore interface {
	Ping(ctx context.Context) error
}

type FeedbackStore interface {
	InsertFeedbackEvent(ctx context.Context, event FeedbackEvent) error
	ListFeedbackEventsSince(ctx context.Context, since time.Time) ([]FeedbackSummaryEvent, error)
}

type AuditStore interface {
	InsertAuditEvent(ctx context.Context, event AuditEvent) error
}

type CapacityStore interface {
	InsertCapacitySignalEvent(ctx context.Context, event CapacitySignalEvent) error
	LatestCapacitySignals(ctx context.Context) ([]CapacitySignalEvent, error)
	GetCapacityTier(ctx context.Context) (CapacityTier, error)
	SetCapacityTier(ctx context.Context, tier CapacityTier) error
}
