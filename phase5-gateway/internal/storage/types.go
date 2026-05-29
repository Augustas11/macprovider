package storage

import "time"

type Account struct {
	AccountID        string
	Status           string
	QuotaClass       string
	ConcurrencyClass string
	CreatedAt        time.Time
}

type AccountIdentity struct {
	AccountID      string
	Provider       string
	ProviderUserID string
	Email          string
	CreatedAt      time.Time
}

type APIKey struct {
	KeyID         string
	AccountID     string
	KeyHash       []byte
	KeyHashPrefix string
	Status        string
	CreatedAt     time.Time
}

type APIKeySummary struct {
	KeyID         string
	KeyHashPrefix string
	Status        string
	CreatedAt     time.Time
	RevokedAt     time.Time
}

type KeyValidation struct {
	KeyID            string
	AccountID        string
	KeyStatus        string
	AccountStatus    string
	QuotaClass       string
	ConcurrencyClass string
	KeyHashPrefix    string
	Active           bool
	CreatedAt        time.Time
}

type OAuthState struct {
	StateHash   []byte
	SessionID   string
	RedirectURI string
	ClientIP    string
	CreatedAt   time.Time
	ExpiresAt   time.Time
	ConsumedAt  time.Time
}

type SignupEvent struct {
	EventID   string
	AccountID string
	ClientIP  string
	Provider  string
	CreatedAt time.Time
}

type DemoSessionEvent struct {
	EventID   string
	ClientIP  string
	CreatedAt time.Time
}

type DemoUsageEvent struct {
	RequestID     string
	ClientIP      string
	DemoTokenHash string
	WindowDate    string
	TotalTokens   int64
	CreatedAt     time.Time
}

type UsageEvent struct {
	RequestID        string
	AccountID        string
	DemoIdentity     string
	WindowDate       string
	PromptTokens     int64
	CompletionTokens int64
	TotalTokens      int64
	TokenSource      string
	Outcome          string
	CreatedAt        time.Time
}

type ReservationRequest struct {
	AccountID       string
	RequestID       string
	WindowDate      string
	RequestedTokens int64
	DailyQuota      int64
	ExpiresAt       time.Time
	CreatedAt       time.Time
}

type QuotaDecision struct {
	Admitted        bool
	LimitTokens     int64
	UsedTokens      int64
	ReservedTokens  int64
	RemainingTokens int64
	ResetUnix       int64
}

type ReservationSettlement struct {
	AccountID        string
	RequestID        string
	PromptTokens     int64
	CompletionTokens int64
	TotalTokens      int64
	TokenSource      string
	Outcome          string
	SettledAt        time.Time
}

type ConcurrencyRequest struct {
	AccountID string
	RequestID string
	Limit     int
	ExpiresAt time.Time
	CreatedAt time.Time
}

type ConcurrencyDecision struct {
	Admitted bool
	Limit    int
	Active   int
}

type FeedbackEvent struct {
	EventID   string
	RequestID string
	AccountID string
	Scope     string
	Rating    int
	Comment   string
	CreatedAt time.Time
}

type FeedbackSummaryEvent struct {
	EventID   string
	RequestID string
	AccountID string
	Scope     string
	Rating    int
	Comment   string
	CreatedAt time.Time
}

type AuditEvent struct {
	EventID   string
	RequestID string
	AccountID string
	Actor     string
	Type      string
	Payload   string
	CreatedAt time.Time
}

type CapacitySignalEvent struct {
	EventID   string
	Signal    string
	Value     float64
	Threshold float64
	Firing    bool
	CreatedAt time.Time
}

type CapacityTier struct {
	Tier      int
	Signals   string
	UpdatedAt time.Time
}
