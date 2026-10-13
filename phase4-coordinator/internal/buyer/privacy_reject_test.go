package buyer

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
	"github.com/rs/zerolog"
)

type recordingRouteMetrics struct {
	mu     sync.Mutex
	counts map[string]int
}

func (r *recordingRouteMetrics) IncPrivacyPostureRejection(string)          {}
func (r *recordingRouteMetrics) SetPrivacyReleaseIdentityVersions([]string) {}
func (r *recordingRouteMetrics) IncPrivacyRouteRejection(phase, reason string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.counts == nil {
		r.counts = map[string]int{}
	}
	r.counts[phase+"/"+reason]++
}

func (r *recordingRouteMetrics) count(phase, reason string) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.counts[phase+"/"+reason]
}

func privacyReservationBody(model string) []byte {
	raw, _ := json.Marshal(relayblind.ReservationRequest{EndpointFamily: relayblind.EndpointChatCompletions, Model: model, MaxOutputTokens: 32, InputTokenUpperBound: 96, EncryptedRequestBytes: 2048})
	return raw
}

// routeRejection returns the one privacy_route_rejected log event.
func routeRejection(t *testing.T, logs *bytes.Buffer) map[string]any {
	t.Helper()
	var found map[string]any
	for _, line := range bytes.Split(logs.Bytes(), []byte("\n")) {
		var event map[string]any
		if len(line) == 0 || json.Unmarshal(line, &event) != nil || event["event"] != "privacy_route_rejected" {
			continue
		}
		if found != nil {
			t.Fatalf("more than one privacy_route_rejected event: %s", logs.String())
		}
		found = event
	}
	if found == nil {
		t.Fatalf("no privacy_route_rejected event: %s", logs.String())
	}
	return found
}

// SPEC-049-R030: a refused reservation logs and counts the real cause with
// closed labels and hands it to the gateway in the internal header, while
// the buyer error stays the unchanged §4.9 code and message.
func TestPrivacyReservationRecordsRealRejectReason(t *testing.T) {
	for _, tc := range []struct {
		name, model, reason, code string
		cfg                       privacyHarnessConfig
		mutate                    func(*testing.T, *privacyHarness)
	}{
		{name: "model not served", model: "model-zzz", reason: relayblind.PrivacyRejectModelNotServed, code: privacyClassUnavailable, cfg: privacyHarnessConfig{privacyKey: true}},
		{name: "model not private capable", model: "model-a", reason: relayblind.PrivacyRejectModelNotPrivateCapable, code: privacyClassUnavailable, cfg: privacyHarnessConfig{privacyEnabled: true}},
		{name: "posture expired", model: "model-a", reason: relayblind.PrivacyRejectPostureExpired, code: privacyClassUnavailable, cfg: privacyHarnessConfig{privacyKey: true},
			mutate: func(t *testing.T, h *privacyHarness) { h.clock.Advance(151 * time.Second) }},
		{name: "quarantined", model: "model-a", reason: relayblind.PrivacyRejectProviderQuarantined, code: privacyClassUnavailable, cfg: privacyHarnessConfig{privacyKey: true},
			mutate: func(t *testing.T, h *privacyHarness) {
				if err := h.store.Quarantine(context.Background(), "provider-a", "review", h.clock.Now(), time.Hour); err != nil {
					t.Fatal(err)
				}
			}},
		{name: "quarantine revoked the keys", model: "model-a", reason: relayblind.PrivacyRejectProviderQuarantined, code: privacyClassUnavailable, cfg: privacyHarnessConfig{privacyKey: true},
			mutate: func(t *testing.T, h *privacyHarness) {
				if err := h.store.QuarantineAndRevokePrivacy(context.Background(), "provider-a", "review", h.clock.Now(), time.Hour, 5*time.Minute); err != nil {
					t.Fatal(err)
				}
			}},
		{name: "unapproved code identity", model: "model-a", reason: relayblind.PrivacyRejectCodeIdentityUnapproved, code: privacyClassUnavailable, cfg: privacyHarnessConfig{privacyEnabled: true},
			mutate: func(t *testing.T, h *privacyHarness) {
				_, key := privacyTestKey(t, h.identity, h.clock.Now())
				record := privacyTestRecord(t, h.identity, key)
				record.Attestation.CodeCDHash = strings.Repeat("f", 40)
				framed, err := record.Attestation.Framing()
				if err != nil {
					t.Fatal(err)
				}
				record.Signature = signEd25519(h.identity, framed)
				if err := h.authority.AcceptPrivacyKeys(context.Background(), "provider-a", "session-a", []relayblind.PrivacyKeyRecord{record}, h.clock.Now()); err == nil {
					t.Fatal("unapproved code identity was accepted")
				}
			}},
		{name: "kill switch", model: "model-a", reason: relayblind.PrivacyRejectKillSwitch, code: privacyClassDisabled, cfg: privacyHarnessConfig{privacyKey: true},
			mutate: func(t *testing.T, h *privacyHarness) {
				if err := h.store.SetPrivacyDisabled(context.Background(), true, "drill", h.clock.Now()); err != nil {
					t.Fatal(err)
				}
			}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newPrivacyHarness(t, tc.cfg)
			metrics := &recordingRouteMetrics{}
			h.authority.UseMetrics(metrics)
			if tc.mutate != nil {
				tc.mutate(t, h)
			}
			var logs bytes.Buffer
			h.server.log = zerolog.New(&logs)
			response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/route-reservations", privacyReservationBody(tc.model), "", nil)
			if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"`+tc.code+`"`) {
				t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
			}
			if strings.Contains(response.Body.String(), tc.reason) || !strings.Contains(response.Body.String(), privacyErrorMessage(tc.code)) {
				t.Fatalf("buyer error changed or carries the reason: %s", response.Body.String())
			}
			if got := response.Header().Get(relayblind.PrivacyRejectReasonHeader); got != tc.reason {
				t.Fatalf("reason header=%q want %q", got, tc.reason)
			}
			event := routeRejection(t, &logs)
			if event["phase"] != relayblind.PrivacyRejectPhaseReservation || event["reason"] != tc.reason || event["code"] != tc.code {
				t.Fatalf("event=%v", event)
			}
			if got := metrics.count(relayblind.PrivacyRejectPhaseReservation, tc.reason); got != 1 {
				t.Fatalf("metric count=%d", got)
			}
			for _, secret := range []string{"provider-a", "session-a", "account-a", "wallet-a", "review", "drill"} {
				if strings.Contains(logs.String(), secret) {
					t.Fatalf("privacy reject log exposed %q: %s", secret, logs.String())
				}
			}
		})
	}
}

// The internal reason header goes only to an authenticated gateway; the log
// line is written either way.
func TestPrivacyRejectReasonHeaderOnlyForGateway(t *testing.T) {
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyEnabled: true})
	var logs bytes.Buffer
	h.server.log = zerolog.New(&logs)
	request := httptest.NewRequest(http.MethodPost, "/v1/relay-blind/route-reservations", nil)
	request.RemoteAddr = "127.0.0.1:43210"
	request.Header.Set("Authorization", "Bearer not-the-gateway")
	response := httptest.NewRecorder()
	h.server.notePrivacyRouteRejection(response, request, relayblind.PrivacyRejectPhaseReservation, privacyClassUnavailable, relayblind.PrivacyRejectPostureExpired)
	if got := response.Header().Get(relayblind.PrivacyRejectReasonHeader); got != "" {
		t.Fatalf("reason header leaked without gateway context: %q", got)
	}
	if event := routeRejection(t, &logs); event["reason"] != relayblind.PrivacyRejectPostureExpired {
		t.Fatalf("event=%v", event)
	}
	logs.Reset()
	h.server.notePrivacyRouteRejection(nil, request, relayblind.PrivacyRejectPhaseReservation, privacyClassUnavailable, "provider-a\nforged=1")
	if event := routeRejection(t, &logs); event["reason"] != relayblind.PrivacyRejectOther {
		t.Fatalf("unvetted reason was logged: %v", event)
	}
}

// A posture that expires between reservation and consume is logged as
// posture_expired at the consume phase; the buyer still sees posture_stale.
func TestPrivacyConsumeRecordsRealRejectReason(t *testing.T) {
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, maxAge: 150, ttl: 600})
	h.clock.Advance(100 * time.Second)
	reservation := h.reserve(t, true)
	raw := h.seal(t, reservation, "privacy-reason-consume", h.privacyPrivate)
	h.clock.Advance(55 * time.Second)
	var logs bytes.Buffer
	h.server.log = zerolog.New(&logs)
	response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", raw, "", nil)
	if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"privacy_class_posture_stale"`) {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	event := routeRejection(t, &logs)
	if event["phase"] != relayblind.PrivacyRejectPhaseConsume || event["reason"] != relayblind.PrivacyRejectPostureExpired {
		t.Fatalf("event=%v", event)
	}
	if got := response.Header().Get(relayblind.PrivacyRejectReasonHeader); got != relayblind.PrivacyRejectPostureExpired {
		t.Fatalf("reason header=%q", got)
	}
}

// When several candidates fail, the request reports the one closest to
// serving it.
func TestCloserPrivacyRejectPrefersDeeperCause(t *testing.T) {
	reason := relayblind.PrivacyRejectModelNotServed
	for _, next := range []string{relayblind.PrivacyRejectModelNotPrivateCapable, relayblind.PrivacyRejectPostureExpired, relayblind.PrivacyRejectProviderQuarantined, relayblind.PrivacyRejectOther} {
		reason = closerPrivacyReject(reason, next)
	}
	if reason != relayblind.PrivacyRejectPostureExpired {
		t.Fatalf("reason=%q", reason)
	}
}

func signEd25519(key []byte, message []byte) string {
	return base64.RawURLEncoding.EncodeToString(ed25519Sign(key, message))
}

func ed25519Sign(key, message []byte) []byte { return ed25519.Sign(ed25519.PrivateKey(key), message) }

// A private chat that only lacks a seat keeps the SPEC-049-R029 capacity
// code and is recorded as slot_unavailable at the dispatch phase.
func TestPrivacyDispatchCapacityRecordsSlotUnavailable(t *testing.T) {
	var dispatches atomic.Int32
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, relay: privacyCountingRelay(&dispatches)})
	h.server.slotQueueDeadline = 40 * time.Millisecond
	h.server.slotQueuePollInterval = 5 * time.Millisecond
	_, raw, authorization := h.consumePrivacy(t, "privacy-reason-capacity")
	h.setSlots(t, pool.StateBusy, 0)
	metrics := &recordingRouteMetrics{}
	h.authority.UseMetrics(metrics)
	var logs bytes.Buffer
	h.server.log = zerolog.New(&logs)
	response := h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, authorization, nil)
	if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"relay_blind_provider_unsupported"`) {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	event := routeRejection(t, &logs)
	if event["phase"] != relayblind.PrivacyRejectPhaseDispatch || event["reason"] != relayblind.PrivacyRejectSlotUnavailable || event["code"] != "relay_blind_provider_unsupported" {
		t.Fatalf("event=%v", event)
	}
	if got := response.Header().Get(relayblind.PrivacyRejectReasonHeader); got != relayblind.PrivacyRejectSlotUnavailable {
		t.Fatalf("reason header=%q", got)
	}
	if metrics.count(relayblind.PrivacyRejectPhaseDispatch, relayblind.PrivacyRejectSlotUnavailable) != 1 {
		t.Fatal("dispatch capacity rejection was not counted")
	}
}

// A posture that lapses while the chat waits for a seat is recorded as
// posture_expired, not as a capacity miss.
func TestPrivacyDispatchPostureLapseRecordsRealReason(t *testing.T) {
	var dispatches atomic.Int32
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, maxAge: 150, ttl: 600, relay: privacyCountingRelay(&dispatches)})
	h.server.slotQueueDeadline = 40 * time.Millisecond
	h.server.slotQueuePollInterval = 5 * time.Millisecond
	h.clock.Advance(100 * time.Second)
	_, raw, authorization := h.consumePrivacy(t, "privacy-reason-lapse")
	h.setSlots(t, pool.StateBusy, 0)
	h.clock.Advance(55 * time.Second)
	var logs bytes.Buffer
	h.server.log = zerolog.New(&logs)
	response := h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, authorization, nil)
	if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"privacy_class_posture_stale"`) {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	event := routeRejection(t, &logs)
	if event["phase"] != relayblind.PrivacyRejectPhaseDispatch || event["reason"] != relayblind.PrivacyRejectPostureExpired {
		t.Fatalf("event=%v", event)
	}
}

// SPEC-049-R031 item 9: a held reservation rejected by an identity key
// rotation is the retryable posture-stale outcome, not a replay.
func TestPrivacyRotatedReservationIsPostureStale(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	row := relayblind.Reservation{PrivacyClass: true, State: relayblind.ReservationStateRejected, ExpiresAtUnix: now.Unix() + 30, TerminalCode: relayblind.PrivacyKeyRotatedTerminalCode}
	if got := privacyInvalidatedCode(row, now); got != privacyClassStale {
		t.Fatalf("code=%q", got)
	}
	row.PrivacyClass = false
	if got := privacyInvalidatedCode(row, now); got != "" {
		t.Fatalf("relay-blind row mapped to %q", got)
	}
}
