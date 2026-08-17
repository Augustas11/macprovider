package mdm

import (
	"errors"
	"strings"
	"sync"
	"time"
)

// Binding is a coordinator-owned exclusive provider↔device association.
// Serial is always stored normalized (trim + upper). UDID may be empty until
// the device appears in MicroMDM.
type Binding struct {
	ProviderID string
	Serial     string
	UDID       string
	ClaimedAt  time.Time
}

var (
	// ErrSerialAlreadyBound is returned when another provider already owns the serial.
	ErrSerialAlreadyBound = errors.New("mdm: serial already bound to another provider")
	// ErrEmptySerial is returned when the serial is missing after normalization.
	ErrEmptySerial = errors.New("mdm: serial_number required")
	// ErrEmptyProviderID is returned when provider_id is empty.
	ErrEmptyProviderID = errors.New("mdm: provider_id required")
	// ErrEnrolledUnboundRejected blocks remote token-auth claims of an
	// already-enrolled unbound serial (R2-H1 borrow prevention). Ops may
	// bootstrap via the internal claim endpoint with AllowEnrolledUnbound.
	ErrEnrolledUnboundRejected = errors.New("mdm: enrolled device requires internal bootstrap claim")
	// ErrPendingClaimRejected blocks creating a binding for a serial that is
	// not yet enrolled in MicroMDM (R3-H1). Pending UDID-empty bindings are
	// never creatable by token-auth or internal bootstrap — that closed the
	// pre-enrollment serial squat race.
	ErrPendingClaimRejected = errors.New("mdm: device must be enrolled in MicroMDM before binding")
)

// DeviceBindingStore is an exclusive provider↔serial binding index.
// In-memory for hot-path lookups; LiveMDAService persists via MDAStore (R4-M2).
// Safe for concurrent use.
type DeviceBindingStore struct {
	mu         sync.Mutex
	byProvider map[string]Binding // providerID → binding
	bySerial   map[string]string  // serial (upper) → providerID
}

// NewDeviceBindingStore creates an empty binding store.
func NewDeviceBindingStore() *DeviceBindingStore {
	return &DeviceBindingStore{
		byProvider: make(map[string]Binding),
		bySerial:   make(map[string]string),
	}
}

// NormalizeSerial trims and uppercases a hardware serial.
func NormalizeSerial(serial string) string {
	return strings.ToUpper(strings.TrimSpace(serial))
}

// Restore loads a durable binding into memory (startup hydrate). Same-serial
// conflicts prefer the first restored binding; later duplicates are skipped.
func (s *DeviceBindingStore) Restore(b Binding) error {
	providerID := strings.TrimSpace(b.ProviderID)
	serial := NormalizeSerial(b.Serial)
	if providerID == "" {
		return ErrEmptyProviderID
	}
	if serial == "" {
		return ErrEmptySerial
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if owner, ok := s.bySerial[serial]; ok && owner != providerID {
		return ErrSerialAlreadyBound
	}
	if prev, ok := s.byProvider[providerID]; ok && prev.Serial != "" && prev.Serial != serial {
		delete(s.bySerial, prev.Serial)
	}
	b.ProviderID = providerID
	b.Serial = serial
	b.UDID = strings.TrimSpace(b.UDID)
	if b.ClaimedAt.IsZero() {
		b.ClaimedAt = time.Now().UTC()
	}
	s.byProvider[providerID] = b
	s.bySerial[serial] = providerID
	return nil
}

// Claim exclusively binds serial to providerID (possession-order).
// Same-provider re-claim of the same serial is idempotent. A provider may
// only hold one serial at a time (claiming a different serial releases the old).
// Enrollment / unbound-enrolled policy is enforced by LiveMDAService, not here.
func (s *DeviceBindingStore) Claim(providerID, serial string) error {
	providerID = strings.TrimSpace(providerID)
	serial = NormalizeSerial(serial)
	if providerID == "" {
		return ErrEmptyProviderID
	}
	if serial == "" {
		return ErrEmptySerial
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if owner, ok := s.bySerial[serial]; ok && owner != providerID {
		return ErrSerialAlreadyBound
	}
	now := time.Now().UTC()
	b := Binding{
		ProviderID: providerID,
		Serial:     serial,
		ClaimedAt:  now,
	}
	if prev, ok := s.byProvider[providerID]; ok {
		if prev.Serial == serial {
			b.UDID = prev.UDID
			b.ClaimedAt = prev.ClaimedAt
		} else if prev.Serial != "" {
			delete(s.bySerial, prev.Serial)
		}
	}
	s.byProvider[providerID] = b
	s.bySerial[serial] = providerID
	return nil
}

// SetUDID records the MicroMDM UDID for an already-claimed serial.
// No-op when the serial is unbound.
func (s *DeviceBindingStore) SetUDID(serial, udid string) {
	serial = NormalizeSerial(serial)
	udid = strings.TrimSpace(udid)
	if serial == "" || udid == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	owner, ok := s.bySerial[serial]
	if !ok {
		return
	}
	b := s.byProvider[owner]
	b.UDID = udid
	s.byProvider[owner] = b
}

// LookupByProvider returns the binding for providerID, if any.
func (s *DeviceBindingStore) LookupByProvider(providerID string) (Binding, bool) {
	providerID = strings.TrimSpace(providerID)
	if providerID == "" {
		return Binding{}, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	b, ok := s.byProvider[providerID]
	return b, ok
}

// LookupBySerial returns the binding that owns serial, if any.
func (s *DeviceBindingStore) LookupBySerial(serial string) (Binding, bool) {
	serial = NormalizeSerial(serial)
	if serial == "" {
		return Binding{}, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	owner, ok := s.bySerial[serial]
	if !ok {
		return Binding{}, false
	}
	b, ok := s.byProvider[owner]
	return b, ok
}
