package reward

import (
	"time"
)

// EventType represents the different stages in the reward lifecycle
type EventType string

const (
	EventTypeHold     EventType = "HOLD"
	EventTypeCap      EventType = "CAP"
	EventTypeUnlock   EventType = "UNLOCK"
	EventTypeDispute  EventType = "DISPUTE"
)

// Evidence represents supporting documentation or data for an audit entry
type Evidence struct {
	Type      string    `json:"type"`
	Value     any       `json:"value"`
	CreatedAt time.Time `json:"created_at"`
}

// AuditEntry represents a single trail in the reward's history
type AuditEntry struct {
	ID          string    `json:"id"`
	EventType   EventType  `json:"event_type"`
	Evidence    Evidence   `json:"evidence"`
	CreatedBy   string    `json:"created_by"`
	Timestamp   time.Time `json:"timestamp"`
	Version     int        `json:"version"`
	Notes       string    `json:"notes"`
	RelatedID   string    `json:"related_id"`
}

// Reward holds the main reward entity with complete audit trail
type Reward struct {
	ID              string             `json:"id"`
	EvidenceList    []Evidence          `json:"evidence"`
	Entries         []AuditEntry        `json:"audit_trail"`
	Type            string              `json:"type"`
	Status          string              `json:"status"`
	Amount          float64             `json:"amount"`
	HeldAmount      float64             `json:"held_amount"`
	CappedAmount    float64             `json:"capped_amount"`
	DisputedAmount  float64             `json:"disputed_amount"`
	Version         int                 `json:"version"`
	CreatedAt       time.Time           `json:"created_at"`
	UpdatedAt       time.Time           `json:"updated_at"`
	Currency        string              `json:"currency"`
	Metadata        map[string]any      `json:"metadata"`
}

// RewardAuditManager handles all reward audit trail operations
type RewardAuditManager struct {
	rewards     map[string]*Reward
	sequence    int
}

// NewRewardAuditManager creates a new manager instance
func NewRewardAuditManager() *RewardAuditManager {
	return &RewardAuditManager{
		rewards:   make(map[string]*Reward),
		sequence:  0,
	}
}

// GetOrCreateReward fetches or creates a reward with initialized audit trail
func (m *RewardAuditManager) GetOrCreateReward(id string) *Reward {
	if _, exists := m.rewards[id]; exists {
		return m.rewards[id]
	}
	reward := &Reward{
		ID:     id,
		Version: 0,
		Entries: make([]AuditEntry, 0),
		EvidenceList: make([]Evidence, 0),
	}
	m.rewards[id] = reward
	return reward
}

// AddEvidence attaches supporting evidence to the reward
func (m *RewardAuditManager) AddEvidence(reward *Reward, eventType EventType, evidence Evidence) *Reward {
	if reward == nil {
		reward = m.GetOrCreateReward("")
	}
	evidence.CreatedAt = time.Now()
	reward.EvidenceList = append(reward.EvidenceList, evidence)
	return reward
}

// RecordEntry adds an audit entry to track state changes
func (m *RewardAuditManager) RecordEntry(reward *Reward, eventType EventType, createdBy string, notes string) *Reward {
	if reward == nil {
		reward = m.GetOrCreateReward(reward.ID)
	}
	entry := AuditEntry{
		ID:          m.generateEntryID(),
		EventType:   eventType,
		Evidence:    Evidence{Type: "LOG", Value: reward.Status, CreatedAt: time.Now()},
		CreatedBy:   createdBy,
		Timestamp:   time.Now(),
		Version:     reward.Version + 1,
		Notes:       notes,
	}
	reward.Entries = append(reward.Entries, entry)
	reward.Version = entry.Version
	return reward
}

// Hold marks the reward amount as held pending distribution
func (m *RewardAuditManager) Hold(reward *Reward, holder string, evidence any, notes string) *Reward {
	return m.RecordEntry(reward, EventTypeHold, holder, notes)
}

// Cap limits the reward based on predefined thresholds
func (m *RewardAuditManager) Cap(reward *Reward, capper string, capValue float64, notes string) *Reward {
	m.AddEvidence(reward, EventTypeCap, Evidence{
		Type:  "CAP",
		Value: capValue,
	})
	return m.RecordEntry(reward, EventTypeCap, capper, notes)
}

// Unlock releases the held portion of the reward
func (m *RewardAuditManager) Unlock(reward *Reward, unlockedBy string, amount float64, notes string) *Reward {
	return m.RecordEntry(reward, EventTypeUnlock, unlockedBy, notes)
}

// Dispute initiates a formal dispute on the reward amount
func (m *RewardAuditManager) Dispute(reward *Reward, disputant string, evidence any, notes string) *Reward {
	evidence.Evidence = Evidence{
		Type:      "DISPUTE",
		Value:     evidence,
		CreatedAt: time.Now(),
	}
	return m.RecordEntry(reward, EventTypeDispute, disputant, notes)
}

// generateEntryID creates a unique identifier for audit entries
func (m *RewardAuditManager) generateEntryID() string {
	m.sequence++
	return fmt.Sprintf("AUDIT-%d", m.sequence)
}

func (m *RewardAuditManager) CountEntries() int {
	if m.rewards[""] == nil {
		return len(m.sequence)
	}
	total := 0
	for _, r := range m.rewards {
		total += len(r.Entries)
	}
	return total
}