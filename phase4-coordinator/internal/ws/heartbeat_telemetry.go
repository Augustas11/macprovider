package ws

import (
	"context"
	"encoding/json"
	"regexp"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/onboarding"
)

// Epic #1235 Child B: heartbeat-driven durable telemetry refresh.
//
// Both lanes below are deliberately OFF the heartbeat hot path — they run in
// their own bounded-concurrency goroutine (mirroring
// onboarding.Handler.persistHardwareProfileAsync, the sibling async write
// path for the same provider_hardware_profiles table) so a slow or
// unreachable Postgres can never stall heartbeat processing. A dropped slot
// or a failed write is logged/metriced and otherwise ignored: this is
// best-effort dashboard telemetry, never a routing or billing input.
const (
	// hardwareProfileHeartbeatRefreshInterval throttles the B1 Postgres write
	// to at most once per provider per interval. Heartbeats arrive far more
	// often than dashboards need chip/memory/version freshness, and hammering
	// Postgres once per heartbeat per connected provider does not buy anything
	// the dashboards use. Mirrors the coalescing already done for the
	// providerevents last-known snapshot (lastKnownMinInterval).
	hardwareProfileHeartbeatRefreshInterval = 5 * time.Minute
	hardwareProfileHeartbeatPersistTimeout  = 2 * time.Second
	hardwareProfileHeartbeatPersistSlots    = 2

	autoupdateOutcomePersistTimeout = 2 * time.Second
	autoupdateOutcomePersistSlots   = 2
)

// defaultHardwareProfileRefreshSlots/defaultAutoupdateOutcomeSlots bound the
// process-wide concurrent write fan-out when a Server was not given a
// private lane (tests may inject one via the unexported fields directly).
var (
	defaultHardwareProfileRefreshSlots = make(chan struct{}, hardwareProfileHeartbeatPersistSlots)
	defaultAutoupdateOutcomeSlots      = make(chan struct{}, autoupdateOutcomePersistSlots)
)

// allowHardwareProfileHeartbeatRefresh reports whether enough time has passed
// since the last B1 refresh attempt for providerID. It is intentionally a
// simple per-provider timestamp map (no TTL eviction) — the key space is
// bounded by distinct authenticated provider_ids ever seen, the same
// trade-off already accepted for lastKnownFlush/diagnosticLastKnownFlush.
func (s *Server) allowHardwareProfileHeartbeatRefresh(providerID string) bool {
	now := s.now().UTC()
	s.hardwareProfileRefreshFlushMu.Lock()
	defer s.hardwareProfileRefreshFlushMu.Unlock()
	if s.hardwareProfileRefreshFlush == nil {
		s.hardwareProfileRefreshFlush = make(map[string]time.Time)
	}
	if last, ok := s.hardwareProfileRefreshFlush[providerID]; ok && now.Sub(last) < hardwareProfileHeartbeatRefreshInterval {
		return false
	}
	s.hardwareProfileRefreshFlush[providerID] = now
	return true
}

// refreshHardwareProfileHeartbeatAsync is Epic #1235 Child B / B1. appVersion is
// the running binary version already known from this connection's Hello. It
// refreshes ONLY the freshness (last_reported_at) and reported version so
// version/hardware dashboards stop going stale for providers that upgraded
// without re-registering. It deliberately does NOT carry the heartbeat's
// chip/ram: writing chip_normalized/unified_memory_gb would trip the
// migration-019 trust trigger that clears `verified`, which could demote a
// provider and change admission/routing — this lane must stay observe-only.
func (s *Server) refreshHardwareProfileHeartbeatAsync(providerID, appVersion string, observedAt time.Time) {
	if s == nil || s.hardwareProfileRefresher == nil {
		return
	}
	if !s.allowHardwareProfileHeartbeatRefresh(providerID) {
		return
	}
	slots := s.hardwareProfileRefreshSlots
	if slots == nil {
		slots = defaultHardwareProfileRefreshSlots
	}
	select {
	case slots <- struct{}{}:
	default:
		return
	}
	refresher := s.hardwareProfileRefresher
	go func() {
		defer func() { <-slots }()
		ctx, cancel := context.WithTimeout(context.Background(), hardwareProfileHeartbeatPersistTimeout)
		defer cancel()
		if err := refresher.RefreshProviderHardwareProfile(ctx, providerID, appVersion, observedAt); err != nil {
			s.log.Warn().Err(err).Str("provider_id", providerID).Msg("hardware profile heartbeat refresh failed")
		}
	}()
}

// autoupdateOutcomeWire is the subset of the provider's freeform
// `last_autoupdate_event` object (see AutoUpdateEvent.wireObject() on the
// Swift side) the coordinator persists. Unknown/extra keys (extra_metadata,
// attempt_history, release_url, attempt) are intentionally not carried into
// the durable row: they are either heavy, unstable in shape, or not needed
// for convergence measurement.
type autoupdateOutcomeWire struct {
	UpdateID       string `json:"update_id"`
	CurrentVersion string `json:"current_version"`
	TargetVersion  string `json:"target_version"`
	Source         string `json:"source"`
	Phase          string `json:"phase"`
	Outcome        string `json:"outcome"`
	Reason         string `json:"reason"`
	FailureClass   string `json:"failure_class"`
}

// recordAutoupdateOutcomeIfChanged is Epic #1235 Child B / B2. raw is the
// heartbeat/state_update `last_autoupdate_event` payload as already validated
// by ParseHeartbeat/ParseStateUpdate (a JSON object, <=4096 bytes, or nil).
// The Swift client resends the SAME last event on every heartbeat/state_update
// for the remainder of the connection, so this de-duplicates by raw byte
// content per provider before persisting — otherwise one real autoupdate
// event would fan out into one row per heartbeat for the rest of the session.
//
// The dedup cache advances before the async persist completes: a failed write
// is logged and NOT retried for that exact event. That is an accepted
// trade-off for best-effort dashboard telemetry (matches
// persistHardwareProfileAsync's error handling), not a delivery guarantee.
func (s *Server) recordAutoupdateOutcomeIfChanged(providerID string, raw json.RawMessage, observedAt time.Time) {
	if s == nil || s.autoupdateOutcomes == nil || len(raw) == 0 {
		return
	}
	fingerprint := string(raw)
	if seen, ok := s.autoupdateOutcomeSeen.Load(providerID); ok && seen.(string) == fingerprint {
		return
	}
	var wire autoupdateOutcomeWire
	if err := json.Unmarshal(raw, &wire); err != nil {
		return
	}
	slots := s.autoupdateOutcomeSlots
	if slots == nil {
		slots = defaultAutoupdateOutcomeSlots
	}
	select {
	case slots <- struct{}{}:
	default:
		// Both persist slots are busy: drop this observation WITHOUT advancing the
		// dedup cache, so a later heartbeat echo of the same event is retried
		// rather than permanently suppressed for the session.
		return
	}
	// A slot is held: mark the event seen so subsequent identical echoes coalesce.
	s.autoupdateOutcomeSeen.Store(providerID, fingerprint)
	sink := s.autoupdateOutcomes
	rec := onboarding.AutoupdateOutcomeRecord{
		ProviderID:     providerID,
		ObservedAt:     observedAt,
		UpdateID:       wire.UpdateID,
		CurrentVersion: wire.CurrentVersion,
		TargetVersion:  wire.TargetVersion,
		Source:         wire.Source,
		Phase:          wire.Phase,
		Outcome:        wire.Outcome,
		Reason:         wire.Reason,
		FailureClass:   wire.FailureClass,
	}
	go func() {
		defer func() { <-slots }()
		ctx, cancel := context.WithTimeout(context.Background(), autoupdateOutcomePersistTimeout)
		defer cancel()
		if err := sink.RecordAutoupdateOutcome(ctx, rec); err != nil {
			s.log.Warn().Err(err).Str("provider_id", providerID).Msg("autoupdate outcome persist failed")
		}
	}()
}

const (
	supervisorEventPersistTimeout = 2 * time.Second
	supervisorEventPersistSlots   = 2
)

var defaultSupervisorEventSlots = make(chan struct{}, supervisorEventPersistSlots)

// supervisorEventWire is the projected `last_supervisor_event` beacon the CLI
// already validated/allowlisted before uplink (SPEC-025 §5.4). The coordinator
// re-parses only the fields it persists; unknown keys are ignored.
type supervisorEventWire struct {
	Schema            string                  `json:"schema"`
	Kind              string                  `json:"kind"`
	BootID            string                  `json:"boot_id"`
	Seq               int64                   `json:"seq"`
	SupervisorLabel   string                  `json:"supervisor_label"`
	SupervisorVersion string                  `json:"supervisor_version"`
	RestartsTotal     int64                   `json:"restarts_total"`
	DeferralsTotal    int64                   `json:"deferrals_total"`
	LastRestart       *supervisorRestartWire  `json:"last_restart"`
	LastDeferral      *supervisorDeferralWire `json:"last_deferral"`
}

type supervisorRestartWire struct {
	Seq             int64           `json:"seq"`
	TS              string          `json:"ts"`
	Reason          string          `json:"reason"`
	CooldownState   string          `json:"cooldown_state"`
	ServiceInstance *string         `json:"service_instance"`
	ModelLiveness   json.RawMessage `json:"model_liveness"`
}

type supervisorDeferralWire struct {
	Seq            int64  `json:"seq"`
	TS             string `json:"ts"`
	DeferralReason string `json:"deferral_reason"`
}

// supervisorModelLiveness is the EXACT allowlisted model_liveness shape. The
// coordinator re-projects to this before persisting so no extra/redaction-
// forbidden keys a modified provider might inject survive into the JSONB column.
type supervisorModelLiveness struct {
	TokenAgeMS           *int64 `json:"token_age_ms"`
	ActiveInference      bool   `json:"active_inference"`
	ActiveInferenceAgeMS *int64 `json:"active_inference_age_ms"`
}

const (
	supervisorEventSchema = "macprovider.supervisor-event.v1"
	// maxSupervisorScalar is an absolute sanity cap on seq/counter values so a
	// forged/corrupt beacon cannot store an absurd high-water value that pins the
	// (provider_id, boot_id) row and blinds later legitimate telemetry.
	maxSupervisorScalar = int64(1) << 40
	// supervisorMaxFutureSkew: a ts more than this in the future is nulled at the
	// field level (never rejects the beacon; ordering is by seq alone).
	supervisorMaxFutureSkew = 5 * time.Minute
)

// supervisorUUIDRE matches the canonical UUID shape of RouterHandler.serviceInstanceID
// and of boot_id (kern.bootsessionuuid).
var supervisorUUIDRE = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func isSupervisorUUID(s string) bool { return supervisorUUIDRE.MatchString(s) }

// supervisorVersionRE constrains supervisor_version to a narrow public version
// charset so a modified provider cannot smuggle a hostname/path/PII into it.
var supervisorVersionRE = regexp.MustCompile(`^[A-Za-z0-9._+-]{1,64}$`)

// normalizeSupervisorTS returns ts if it is a valid RFC3339 timestamp no more
// than supervisorMaxFutureSkew ahead of now; otherwise "" (diagnostic-only field
// nulled, never rejecting the beacon).
func normalizeSupervisorTS(ts string, now time.Time) string {
	if ts == "" {
		return ""
	}
	t, err := time.Parse(time.RFC3339, ts)
	if err != nil || t.After(now.Add(supervisorMaxFutureSkew)) {
		return ""
	}
	return ts
}

// normalizeSupervisorWire validates and coerces a parsed beacon in place,
// returning false if it is too malformed/inconsistent to persist. It is
// NON-rejecting at the frame level (the caller already accepted the heartbeat);
// a false result just means no supervisor row is written. Hard-drops: wrong
// schema, unknown kind, missing boot_id, out-of-range seq/counters, or a nested
// action seq greater than the top seq. Soft-coerced: supervisor_label to the
// public allowlist (else "unknown"), cooldown_state to the enum (else "armed"),
// and an invalid/non-object model_liveness or wrong action reason is dropped.
func normalizeSupervisorWire(w *supervisorEventWire, now time.Time) bool {
	if w.Schema != supervisorEventSchema {
		return false
	}
	switch w.Kind {
	case "restart", "deferral", "beacon":
	default:
		return false
	}
	// boot_id is the coordinator's row partition key and is stored; require the
	// canonical bootsession UUID shape so a modified provider cannot smuggle a
	// hostname/path/PII into it or choose an arbitrary partition key.
	if !isSupervisorUUID(w.BootID) {
		return false
	}
	if w.Seq <= 0 || w.Seq > maxSupervisorScalar {
		return false
	}
	if w.RestartsTotal < 0 || w.RestartsTotal > maxSupervisorScalar ||
		w.DeferralsTotal < 0 || w.DeferralsTotal > maxSupervisorScalar {
		return false
	}
	// Internal consistency: the watchdog bumps seq once per tick and each restart/
	// deferral is one tick, so restarts_total + deferrals_total <= seq always
	// holds for a legitimate beacon. This is a strong, forgery-resistant check
	// that also lets the store accept a large first-insert seq (long-uptime first
	// contact) without a step ceiling — the seq is bounded only by the absolute
	// cap above and this ratio.
	if w.RestartsTotal+w.DeferralsTotal > w.Seq {
		return false
	}
	switch w.SupervisorLabel {
	case "provider-watchdog", "legacy-watchdog":
	default:
		w.SupervisorLabel = "unknown"
	}
	if !supervisorVersionRE.MatchString(w.SupervisorVersion) {
		w.SupervisorVersion = "unknown"
	}
	if w.LastRestart != nil {
		lr := w.LastRestart
		// reason is the only watchdog-owned restart reason (SPEC-020 R-4.14); a
		// missing/other reason means this is not a valid supervisor restart. Also
		// require counter consistency: a restart detail (seq>0) is only credible
		// if restarts_total has advanced past zero — otherwise it is forged/corrupt.
		if lr.Reason != "wedge" || lr.Seq <= 0 || lr.Seq > w.Seq || w.RestartsTotal <= 0 {
			w.LastRestart = nil
		} else {
			switch lr.CooldownState {
			case "armed", "cooldown_active":
			default:
				lr.CooldownState = "armed"
			}
			// service_instance is the opaque UUID instance id; drop anything not
			// UUID-shaped so a path/hostname/PII never reaches the store.
			if lr.ServiceInstance != nil && !isSupervisorUUID(*lr.ServiceInstance) {
				lr.ServiceInstance = nil
			}
			lr.TS = normalizeSupervisorTS(lr.TS, now)
			// Re-project model_liveness to EXACTLY the allowlisted shape so no
			// extra/redaction-forbidden keys reach the store. Invalid → null.
			lr.ModelLiveness = projectSupervisorModelLiveness(lr.ModelLiveness)
		}
	}
	if w.LastDeferral != nil {
		if w.LastDeferral.DeferralReason != "pending_autoupdate_marker" ||
			w.LastDeferral.Seq <= 0 || w.LastDeferral.Seq > w.Seq || w.DeferralsTotal <= 0 {
			w.LastDeferral = nil
		} else {
			w.LastDeferral.TS = normalizeSupervisorTS(w.LastDeferral.TS, now)
		}
	}
	return true
}

// projectSupervisorModelLiveness returns model_liveness re-marshaled to exactly
// {token_age_ms, active_inference, active_inference_age_ms} with nonnegative +
// sanity-capped ages, or nil (null) if absent/invalid. Any other keys a modified
// provider injected are dropped before the value can reach the JSONB store.
func projectSupervisorModelLiveness(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	var ml supervisorModelLiveness
	if err := json.Unmarshal(raw, &ml); err != nil {
		return nil
	}
	clamp := func(v *int64) *int64 {
		if v == nil || *v < 0 || *v > maxSupervisorScalar {
			return nil
		}
		return v
	}
	projected := supervisorModelLiveness{
		TokenAgeMS:           clamp(ml.TokenAgeMS),
		ActiveInference:      ml.ActiveInference,
		ActiveInferenceAgeMS: clamp(ml.ActiveInferenceAgeMS),
	}
	out, err := json.Marshal(projected)
	if err != nil {
		return nil
	}
	return out
}

// recordSupervisorEventIfChanged durably upserts the SEPARATE supervisor
// telemetry beacon (RFC-001 §7 / F5; SPEC-025 §5.4). raw is the heartbeat/
// state_update `last_supervisor_event` object (already validated as a JSON
// object <=4096 bytes, or nil, and NON-rejecting — a bad value never blocked the
// frame). serviceInstanceID is the current heartbeat's instance id (the NEW
// post-restart instance, for dwell correlation). Like the autoupdate lane this
// is OFF the heartbeat hot path and best-effort; a dropped slot or failed write
// is logged and never stalls or fails heartbeat processing. De-dupes repeated
// identical echoes per provider so one beacon is not re-upserted every heartbeat.
func (s *Server) recordSupervisorEventIfChanged(providerID string, raw json.RawMessage, serviceInstanceID string, servingEligible bool, observedAt time.Time) {
	if s == nil || s.supervisorEvents == nil || len(raw) == 0 {
		return
	}
	// The current instance id (NEW post-restart instance) is an opaque UUID; a
	// non-UUID value cannot correlate (and must not reach the store), so treat it
	// as unknown.
	if !isSupervisorUUID(serviceInstanceID) {
		serviceInstanceID = ""
	}
	servingTag := "0"
	if servingEligible {
		servingTag = "1"
	}
	// Include serviceInstanceID and the serving verdict in the fingerprint so a
	// pool-view serving flip (or a new instance) is not hidden by beacon-content
	// dedup — dwell continuity depends on observing those transitions.
	fingerprint := servingTag + "\x00" + serviceInstanceID + "\x00" + string(raw)
	if seen, ok := s.supervisorEventSeen.Load(providerID); ok && seen.(string) == fingerprint {
		return
	}
	var wire supervisorEventWire
	if err := json.Unmarshal(raw, &wire); err != nil {
		return
	}
	// Coordinator-side validation: the CLI already projects/allowlists, but the
	// coordinator MUST NOT trust a (possibly modified) provider blindly. Drop a
	// wrong-schema/out-of-range/inconsistent beacon NON-blockingly (the frame was
	// already accepted upstream); coerce soft fields to the allowlist. Nothing
	// wrong-shaped reaches provider_supervisor_events or the rollups.
	if !normalizeSupervisorWire(&wire, observedAt) {
		return
	}
	// Per-provider ordering: the flap/dwell rollup is history-sensitive, so at
	// most ONE persist per provider may be in flight — otherwise two beacons for
	// the same provider could commit out of seq order and lose flap accounting.
	// Heartbeats for a provider arrive in order, so dropping (without advancing
	// dedup) while one is in flight simply defers to the next heartbeat.
	if _, busy := s.supervisorEventInFlight.LoadOrStore(providerID, struct{}{}); busy {
		return
	}
	slots := s.supervisorEventSlots
	if slots == nil {
		slots = defaultSupervisorEventSlots
	}
	select {
	case slots <- struct{}{}:
	default:
		// Both persist slots busy: drop WITHOUT advancing the dedup cache so a
		// later heartbeat echo is retried rather than permanently suppressed.
		s.supervisorEventInFlight.Delete(providerID)
		return
	}
	s.supervisorEventSeen.Store(providerID, fingerprint)
	sink := s.supervisorEvents
	rec := onboarding.SupervisorEventRecord{
		ProviderID:             providerID,
		ObservedAt:             observedAt,
		BootID:                 wire.BootID,
		Schema:                 wire.Schema,
		Kind:                   wire.Kind,
		Seq:                    wire.Seq,
		SupervisorLabel:        wire.SupervisorLabel,
		SupervisorVersion:      wire.SupervisorVersion,
		RestartsTotal:          wire.RestartsTotal,
		DeferralsTotal:         wire.DeferralsTotal,
		CurrentServiceInstance: serviceInstanceID,
		ServingEligible:        servingEligible,
	}
	if wire.LastRestart != nil {
		rec.LastRestartSeq = wire.LastRestart.Seq
		rec.LastRestartTS = wire.LastRestart.TS
		rec.LastRestartCooldown = wire.LastRestart.CooldownState
		if wire.LastRestart.ServiceInstance != nil {
			rec.LastRestartInstance = *wire.LastRestart.ServiceInstance
		}
		if ml := wire.LastRestart.ModelLiveness; len(ml) > 0 && string(ml) != "null" {
			rec.LastRestartModelLiveness = string(ml)
		}
	}
	if wire.LastDeferral != nil {
		rec.LastDeferralSeq = wire.LastDeferral.Seq
		rec.LastDeferralTS = wire.LastDeferral.TS
	}
	go func() {
		defer s.supervisorEventInFlight.Delete(providerID)
		defer func() { <-slots }()
		ctx, cancel := context.WithTimeout(context.Background(), supervisorEventPersistTimeout)
		defer cancel()
		if err := sink.RecordSupervisorEvent(ctx, rec); err != nil {
			s.log.Warn().Err(err).Str("provider_id", providerID).Msg("supervisor event persist failed")
		}
	}()
}

// resetSupervisorDwellOnDisconnect breaks dwell continuity for a provider when
// its session disconnects/is replaced (SPEC-025 §5.4). Best-effort and off the
// disconnect hot path: a pending restart's in-flight dwell timer is cleared so a
// reconnect within the staleness window cannot bridge the silent gap into held.
func (s *Server) resetSupervisorDwellOnDisconnect(providerID string) {
	if s == nil || s.supervisorEvents == nil || providerID == "" {
		return
	}
	// Only providers that actually reported supervisor telemetry this session have
	// dwell state to reset; skipping the rest keeps a mass-disconnect (e.g. a
	// coordinator restart) from fanning out a DB UPDATE per connected provider.
	if _, seen := s.supervisorEventSeen.Load(providerID); !seen {
		return
	}
	slots := s.supervisorEventSlots
	if slots == nil {
		slots = defaultSupervisorEventSlots
	}
	select {
	case slots <- struct{}{}:
	default:
		// Busy: skip. The next accepted beacon's staleness check still breaks
		// continuity, so a dropped reset is safe for this best-effort lane.
		return
	}
	sink := s.supervisorEvents
	go func() {
		defer func() { <-slots }()
		ctx, cancel := context.WithTimeout(context.Background(), supervisorEventPersistTimeout)
		defer cancel()
		if err := sink.ResetSupervisorDwell(ctx, providerID); err != nil {
			s.log.Warn().Err(err).Str("provider_id", providerID).Msg("supervisor dwell reset failed")
		}
	}()
}
