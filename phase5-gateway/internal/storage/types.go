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
	ReturnTo    string
	ClientIP    string
	// Action is an optional operator-initiated intent threaded from the
	// /auth/github/start query string to the /auth/github/callback handler.
	// Binding it to the state row (rather than a sibling cookie) eliminates
	// stale-cookie pollution, parallel-flow races, and uncleared cookies on
	// early callback errors. Currently the only non-empty value is "mint".
	Action     string
	CreatedAt  time.Time
	ExpiresAt  time.Time
	ConsumedAt time.Time
}

type OAuthHandoff struct {
	TokenHash  []byte
	APIKey     string
	CreatedAt  time.Time
	ExpiresAt  time.Time
	ConsumedAt time.Time
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

type PublicIssuanceReservation struct {
	Surface     string
	ClientIP    string
	WindowStart time.Time
	Limit       int
	CreatedAt   time.Time
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

type ActiveReservation struct {
	AccountID      string
	RequestID      string
	WindowDate     string
	ReservedTokens int64
	ExpiresAt      time.Time
	CreatedAt      time.Time
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
	MaxTotalTokens   int64
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

type KillSwitchState struct {
	DemoOnly     bool      `json:"demo_only"`
	AllPublicAPI bool      `json:"all_public_api"`
	UpdatedAt    time.Time `json:"updated_at"`
}

type ExplorerBuyerQuery struct {
	From             time.Time
	To               time.Time
	Status           string
	QuotaClass       string
	ConcurrencyClass string
	AccountID        string
	Email            string
	EmailPrefix      string
	KeyStatus        string
	Limit            int
	Cursor           string
}

type ExplorerDetailQuery struct {
	From   time.Time
	To     time.Time
	Limit  int
	Cursor string
}

type ExplorerSessionQuery struct {
	From      time.Time
	To        time.Time
	AccountID string
	Limit     int
	Cursor    string
}

type ExplorerActivityQuery struct {
	From        time.Time
	To          time.Time
	Type        string
	AccountID   string
	RequestID   string
	Limit       int
	Cursor      string
	SinceCursor string
}

type ExplorerBuyerList struct {
	Items      []ExplorerBuyerSummary `json:"items"`
	NextCursor *string                `json:"next_cursor"`
	Partial    bool                   `json:"partial"`
	Error      any                    `json:"error"`
	Summary    ExplorerBuyerRollup    `json:"summary"`
}

type ExplorerBuyerRollup struct {
	ActiveAccountsWindow int `json:"active_accounts_window"`
	NewAccountsWindow    int `json:"new_accounts_window"`
	ActiveAPIKeys        int `json:"active_api_keys"`
	BlockedAccounts      int `json:"blocked_accounts"`
}

type ExplorerBuyerSummary struct {
	AccountID                     string             `json:"account_id"`
	Status                        string             `json:"status"`
	QuotaClass                    string             `json:"quota_class"`
	ConcurrencyClass              string             `json:"concurrency_class"`
	CreatedAt                     time.Time          `json:"created_at"`
	Identities                    []ExplorerIdentity `json:"identities"`
	APIKeys                       []ExplorerAPIKey   `json:"api_keys"`
	DailyTokensUsed               int64              `json:"daily_tokens_used"`
	DailyTokensReserved           int64              `json:"daily_tokens_reserved"`
	DailyTokenLimit               int64              `json:"daily_token_limit"`
	DailyTokensRemaining          int64              `json:"daily_tokens_remaining"`
	ActiveConcurrencyReservations int                `json:"active_concurrency_reservations"`
	LastUsageTime                 *time.Time         `json:"last_usage_time"`
	LastRequestID                 *string            `json:"last_request_id"`
	FeedbackCount                 int                `json:"feedback_count"`
	AverageRating                 *float64           `json:"average_rating"`
}

type ExplorerIdentity struct {
	Provider       string    `json:"provider"`
	ProviderUserID string    `json:"provider_user_id"`
	Email          string    `json:"email"`
	CreatedAt      time.Time `json:"created_at"`
}

type ExplorerAPIKey struct {
	KeyID         string     `json:"key_id"`
	KeyHashPrefix string     `json:"key_hash_prefix"`
	Status        string     `json:"status"`
	CreatedAt     time.Time  `json:"created_at"`
	RevokedAt     *time.Time `json:"revoked_at"`
}

type ExplorerBuyerDetail struct {
	AccountID   string                   `json:"account_id"`
	Account     ExplorerBuyerAccount     `json:"account"`
	Identities  []ExplorerIdentity       `json:"identities"`
	APIKeys     []ExplorerAPIKey         `json:"api_keys"`
	Usage       ExplorerBuyerUsage       `json:"usage"`
	Quota       ExplorerBuyerQuota       `json:"quota"`
	Concurrency ExplorerBuyerConcurrency `json:"concurrency"`
	Feedback    ExplorerBuyerFeedback    `json:"feedback"`
	Audit       ExplorerBuyerAudit       `json:"audit"`
	NextCursor  *string                  `json:"next_cursor"`
	Partial     bool                     `json:"partial"`
	Error       any                      `json:"error"`
}

type ExplorerBuyerAccount struct {
	Status           string    `json:"status"`
	QuotaClass       string    `json:"quota_class"`
	ConcurrencyClass string    `json:"concurrency_class"`
	CreatedAt        time.Time `json:"created_at"`
}

type ExplorerBuyerUsage struct {
	Events        []ExplorerUsageEvent `json:"events"`
	TokensWindow  int64                `json:"tokens_window"`
	TokensToday   int64                `json:"tokens_today"`
	LastUsageTime *time.Time           `json:"last_usage_time"`
	LastRequestID *string              `json:"last_request_id"`
}

type ExplorerBuyerQuota struct {
	Reservations         []ExplorerQuotaReservation `json:"reservations"`
	ActiveReservedTokens int64                      `json:"active_reserved_tokens"`
	ExpiredReservations  int                        `json:"expired_reservations"`
}

type ExplorerBuyerConcurrency struct {
	ActiveReservations int                              `json:"active_reservations"`
	Reservations       []ExplorerConcurrencyReservation `json:"reservations"`
}

type ExplorerBuyerFeedback struct {
	Events        []ExplorerFeedbackEvent `json:"events"`
	Count         int                     `json:"count"`
	AverageRating *float64                `json:"average_rating"`
}

type ExplorerBuyerAudit struct {
	Events []ExplorerAuditEvent `json:"events"`
}

type ExplorerSessionList struct {
	Items      []ExplorerUsageEvent `json:"items"`
	NextCursor *string              `json:"next_cursor"`
	Partial    bool                 `json:"partial"`
	Error      any                  `json:"error"`
}

type ExplorerSessionDetail struct {
	RequestID              string                          `json:"request_id"`
	AccountID              string                          `json:"account_id,omitempty"`
	UsageEvent             *ExplorerUsageEvent             `json:"usage_event"`
	QuotaReservation       *ExplorerQuotaReservation       `json:"quota_reservation"`
	ConcurrencyReservation *ExplorerConcurrencyReservation `json:"concurrency_reservation"`
	FeedbackEvents         []ExplorerFeedbackEvent         `json:"feedback_events"`
	AuditEvents            []ExplorerAuditEvent            `json:"audit_events"`
	// MatchedAccountIDs is populated when the lookup is ambiguous —
	// i.e. accountID was empty AND the request_id resolves to rows
	// from multiple accounts (issue #196 composite-PK semantics).
	// Returned together with ErrExplorerAmbiguousRequestID so the
	// caller can re-issue scoped lookups.
	//
	// #231 v0.4: bounded at ExplorerMatchedAccountIDsCap entries; the
	// MatchedAccountIDsTruncated flag is set when the underlying UNION
	// resolved to more than the cap and protects the 409 body against
	// malicious collision floods + bounds operator log noise. The
	// bounded forensic sample (capped at ExplorerForensicMatchedAccountIDsCap)
	// is emitted to audit_events for forensic retrieval — never
	// silently dropped.
	MatchedAccountIDs               []string `json:"matched_account_ids,omitempty"`
	MatchedAccountIDsTruncated      bool     `json:"matched_account_ids_truncated"` // #231 R1 arch LOW: explicit presence required by SPEC §6.4 contract — `omitempty` would drop `false` and break clients that branch on field presence.
	MatchedAccountIDsForensicSample []string `json:"-"`                             // #231 R2: bounded forensic sample (cap ExplorerForensicMatchedAccountIDsCap+1) for the audit_events emit; never sent over the wire. Renamed from MatchedAccountIDsUntrimmed in R2 — the list is bounded, not "untrimmed", and the audit payload surfaces partial capture via forensic_truncated_at.
	// MatchedAccountIDsForensicDegraded is true when the forensic
	// SELECT failed and the slice fell back to the bounded ambiguity
	// probe. Surface in audit payload as `forensic_source =
	// "response_probe"` so an operator can tell the partial sample
	// apart from a genuine "exactly 11 accounts" result.
	MatchedAccountIDsForensicDegraded bool `json:"-"`
	Partial                           bool `json:"partial"`
	Error                             any  `json:"error"`
}

// ExplorerMatchedAccountIDsCap is the §6.4 v0.4 normative cap on the
// number of entries returned in the 409 ambiguity response body
// (#231). The 11th row triggers the truncation flag.
const ExplorerMatchedAccountIDsCap = 10

// ExplorerForensicMatchedAccountIDsCap bounds the size of the FULL
// forensic account_id sample emitted to audit_events on the
// truncation path. R1 SEC HIGH closure: caps both the SQL scan AND
// the audit row so a malicious cross-account-collision attacker
// cannot drive an unbounded scan/materialization in the request
// path. When more accounts than the cap exist, the audit payload's
// `forensic_truncated_at` field surfaces the partial capture.
const ExplorerForensicMatchedAccountIDsCap = 100

type ExplorerUsageEvent struct {
	RequestID        string    `json:"request_id"`
	AccountID        string    `json:"account_id"`
	DemoIdentity     string    `json:"demo_identity"`
	WindowDate       string    `json:"window_date"`
	PromptTokens     int64     `json:"prompt_tokens"`
	CompletionTokens int64     `json:"completion_tokens"`
	TotalTokens      int64     `json:"total_tokens"`
	TokenSource      string    `json:"token_source"`
	Outcome          string    `json:"outcome"`
	CreatedAt        time.Time `json:"created_at"`
}

type ExplorerQuotaReservation struct {
	AccountID      string     `json:"account_id"`
	RequestID      string     `json:"request_id"`
	WindowDate     string     `json:"window_date"`
	ReservedTokens int64      `json:"reserved_tokens"`
	SettledTokens  int64      `json:"settled_tokens"`
	Status         string     `json:"status"`
	ExpiresAt      time.Time  `json:"expires_at"`
	CreatedAt      time.Time  `json:"created_at"`
	SettledAt      *time.Time `json:"settled_at"`
}

type ExplorerConcurrencyReservation struct {
	AccountID  string     `json:"account_id"`
	RequestID  string     `json:"request_id"`
	Status     string     `json:"status"`
	ExpiresAt  time.Time  `json:"expires_at"`
	CreatedAt  time.Time  `json:"created_at"`
	ReleasedAt *time.Time `json:"released_at"`
}

type ExplorerFeedbackEvent struct {
	EventID   string    `json:"event_id"`
	RequestID string    `json:"request_id"`
	AccountID string    `json:"account_id,omitempty"`
	Scope     string    `json:"scope"`
	Rating    int       `json:"rating"`
	Comment   string    `json:"comment"`
	CreatedAt time.Time `json:"created_at"`
}

type ExplorerAuditEvent struct {
	EventID     string    `json:"event_id"`
	RequestID   string    `json:"request_id"`
	AccountID   string    `json:"account_id,omitempty"`
	Actor       string    `json:"actor"`
	EventType   string    `json:"event_type"`
	PayloadJSON string    `json:"payload_json"`
	CreatedAt   time.Time `json:"created_at"`
}

type ExplorerActivityList struct {
	Items        []ExplorerActivityEvent `json:"events"`
	LatestCursor *string                 `json:"latest_cursor"`
	NextCursor   *string                 `json:"next_cursor"`
	Partial      bool                    `json:"partial"`
	Error        any                     `json:"error"`
}

type ExplorerActivityEvent struct {
	EventTimeUTC time.Time `json:"event_time_utc"`
	EventType    string    `json:"event_type"`
	Severity     string    `json:"severity"`
	Source       string    `json:"source"`
	SourceID     string    `json:"source_id"`
	RequestID    *string   `json:"request_id"`
	AccountID    *string   `json:"account_id"`
	KeyID        *string   `json:"key_id"`
	ProviderID   *string   `json:"provider_id"`
	ModelID      *string   `json:"model_id"`
	Status       *string   `json:"status"`
	ErrorCode    *string   `json:"error_code"`
	Tokens       *int64    `json:"tokens"`
	Credits      *int64    `json:"credits"`
	LinkTarget   string    `json:"link_target"`
	Cursor       string    `json:"cursor"`
}

type ExplorerHealth struct {
	CheckedAtUTC                  time.Time `json:"checked_at_utc"`
	GatewayHealth                 string    `json:"gateway_health"`
	PublicStatus                  string    `json:"public_status"`
	CapacityTier                  int       `json:"capacity_tier"`
	CapacitySignalsFiring         int       `json:"capacity_signals_firing"`
	PublicAPIPaused               bool      `json:"public_api_paused"`
	DemoPaused                    bool      `json:"demo_paused"`
	ActiveAccountsWindow          int       `json:"active_accounts_window"`
	NewAccountsWindow             int       `json:"new_accounts_window"`
	ActiveAPIKeys                 int       `json:"active_api_keys"`
	ActiveQuotaReservations       int       `json:"active_quota_reservations"`
	ExpiredQuotaReservations      int       `json:"expired_quota_reservations"`
	ActiveConcurrencyReservations int       `json:"active_concurrency_reservations"`
	UsageEventsWindow             int       `json:"usage_events_window"`
	DemoUsageEventsWindow         int       `json:"demo_usage_events_window"`
	QuotaReservationsWindow       int       `json:"quota_reservations_window"`
	SignupEventsWindow            int       `json:"signup_events_window"`
	FeedbackEventsWindow          int       `json:"feedback_events_window"`
	AuditEventsWindow             int       `json:"audit_events_window"`
}
