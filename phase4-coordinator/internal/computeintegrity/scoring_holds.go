package computeintegrity

import "time"

// HoldStatus is the SPEC-022 R-16 hold status.
type HoldStatus string

const (
	HoldHeld     HoldStatus = "held"
	HoldReleased HoldStatus = "released"
)

// EarningsHold is one SPEC-022 R-16 compute-integrity earnings hold.
type EarningsHold struct {
	ID            int64      `json:"hold_id"`
	ProviderID    string     `json:"provider_id"`
	ModelID       string     `json:"model_id"`
	Kind          HoldKind   `json:"kind"`
	WindowStart   time.Time  `json:"window_start"`
	WindowEnd     *time.Time `json:"window_end,omitempty"`
	Reason        string     `json:"reason"`
	Status        HoldStatus `json:"status"`
	HeldCredits   int64      `json:"held_credits"`
	CreatedAt     time.Time  `json:"created_at"`
	ReleasedAt    *time.Time `json:"released_at,omitempty"`
	ReleasedBy    string     `json:"released_by,omitempty"`
	ReleaseReason string     `json:"release_reason,omitempty"`
}
