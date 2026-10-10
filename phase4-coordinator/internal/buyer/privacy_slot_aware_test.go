package buyer

import (
	"context"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// SPEC-049-R029 slot-aware private selection across several providers.

type privacyFleetMember struct {
	id, session string
	enrolled    bool // privacy key accepted and posture verified
	keyOnly     bool // privacy key accepted, no posture
}

type privacyFleet struct {
	*privacyHarness
	registry *pool.Registry
}

func newPrivacyFleet(t *testing.T, members []privacyFleetMember) *privacyFleet {
	t.Helper()
	now := time.Unix(1_800_000_000, 0).UTC()
	clock := &privacyClock{at: now}
	store, err := relayblind.OpenStore(filepath.Join(t.TempDir(), "relay-blind.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	type keys struct {
		identity ed25519.PrivateKey
		se       *ecdsa.PrivateKey
		seRaw    []byte
	}
	material := map[string]keys{}
	sePublic, identityPublic := map[string]string{}, map[string]string{}
	for _, member := range members {
		public, private, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		se, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		seRaw := make([]byte, 64)
		se.X.FillBytes(seRaw[:32])
		se.Y.FillBytes(seRaw[32:])
		material[member.id] = keys{identity: private, se: se, seRaw: seRaw}
		sePublic[member.id] = base64.StdEncoding.EncodeToString(seRaw)
		identityPublic[member.id] = base64.RawURLEncoding.EncodeToString(public)
	}
	privacyCfg := config.PrivacyClassConfig{
		Enabled: true, ProviderSEPublicKeys: sePublic,
		ApprovedCodeIdentities: []config.ApprovedCodeIdentity{{
			TeamID: privacyTestTeamID, SigningIdentifier: privacyTestSigning, CDHash: privacyTestCDHash, BinaryVersion: privacyTestBinary,
		}},
		AllowedSEKeyBackends:            []string{relayblind.PrivacySEBackendFile, relayblind.PrivacySEBackendKeychain},
		PostureChallengeIntervalSeconds: 60, PostureMaxAgeSeconds: 150, PostureResponseTimeoutSeconds: 10, QuarantineSeconds: 86400,
	}
	authority, err := relayblind.NewPrivacyAuthority(store, privacyCfg, identityPublic, 8, 5*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	registry := pool.NewRegistry(nil)
	for _, member := range members {
		m := material[member.id]
		if member.enrolled || member.keyOnly {
			_, key := privacyTestKey(t, m.identity, now)
			if err := authority.AcceptPrivacyKeys(context.Background(), member.id, member.session, []relayblind.PrivacyKeyRecord{privacyTestRecord(t, m.identity, key)}, now); err != nil {
				t.Fatal(err)
			}
			if member.enrolled {
				if err := privacyVerifyPostureFor(t, authority, member.id, member.session, m.identity, m.se, m.seRaw, key.KeyRecordDigest, now); err != nil {
					t.Fatal(err)
				}
			}
		}
		provider := pool.Provider{
			ProviderID: member.id, AssignedID: member.session, ModelID: "model-a", MaxContextTokens: 4096,
			MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1, State: pool.StateReady, AuthState: pool.AuthBearerValidated,
			InferencePath: pool.InferencePathWSTunneled,
		}
		if _, registered := registry.RegisterAt(&provider, nil, now); !registered {
			t.Fatal("provider registration rejected")
		}
	}
	relayCfg := config.Default().RelayBlind
	relayCfg.Enabled = true
	relayCfg.ReservationTTLSeconds = 30
	relayCfg.MaxClockSkewSeconds = 60
	relayCfg.MaxActiveReservations = 1000
	relayCfg.MetadataRequestsPerMinute = 1000
	relay := func(context.Context, pool.Provider, string, []byte, bool, providerws.RelayBlindDispatchContext) (*providerws.RelayStream, error) {
		return nil, context.Canceled
	}
	server := NewServer(registry, zerolog.Nop(), now, WithGatewayServiceToken("gateway-token"), WithRequireGatewayContext(true),
		WithRelayBlind(relayCfg, store, relay), WithPrivacyAuthority(authority))
	server.now = clock.Now
	return &privacyFleet{privacyHarness: &privacyHarness{server: server, store: store, clock: clock, authority: authority}, registry: registry}
}

func (f *privacyFleet) setSlots(t *testing.T, providerID, session string, free int) {
	t.Helper()
	state, total := pool.StateReady, 1
	if free == 0 {
		state = pool.StateBusy
	}
	if _, ok := f.registry.ApplyStateUpdate(providerID, session, pool.StateUpdate{State: state, SlotsFree: &free, SlotsTotal: &total, At: f.clock.Now()}); !ok {
		t.Fatal("state update rejected")
	}
}

// reservePrivate makes one privacy-class reservation and returns the bound
// provider and binding.
func (f *privacyFleet) reservePrivate(t *testing.T) (string, string) {
	t.Helper()
	reservation := f.reserve(t, true)
	row, err := f.store.LookupReservation(context.Background(), reservation.ProviderBinding)
	if err != nil || !row.PrivacyClass {
		t.Fatalf("row=%#v err=%v", row, err)
	}
	return row.ProviderID, reservation.ProviderBinding
}

func fleetMembers(enrolled int, extra ...privacyFleetMember) []privacyFleetMember {
	var members []privacyFleetMember
	for i := range enrolled {
		id := fmt.Sprintf("enrolled-%d", i)
		members = append(members, privacyFleetMember{id: id, session: "session-" + id, enrolled: true})
	}
	return append(members, extra...)
}

// Concurrent reservations, none dispatched yet, land on distinct providers:
// an undispatched reservation counts against its provider's free seat, so
// spreading does not depend on the random tier start.
func TestPrivacySelectionSpreadsUndispatchedReservations(t *testing.T) {
	f := newPrivacyFleet(t, fleetMembers(3))
	for round := range 20 {
		seen := map[string]string{}
		for range 3 {
			providerID, binding := f.reservePrivate(t)
			if _, dup := seen[providerID]; dup {
				t.Fatalf("round %d: two undispatched reservations bound %s while another provider was idle", round, providerID)
			}
			seen[providerID] = binding
		}
		for providerID, binding := range seen {
			f.server.relayBlind.clearPending("account-a", providerID, binding)
		}
	}
}

// Simultaneous reservations of one account still land on distinct
// providers: selection through pending publication is serialized per account.
func TestPrivacySelectionSpreadsSimultaneousReservations(t *testing.T) {
	f := newPrivacyFleet(t, fleetMembers(4))
	f.server.relayBlind.pick = func(int) int { return 0 }
	for round := range 10 {
		results := make(chan [2]string, 4)
		start := make(chan struct{})
		for range 4 {
			go func() {
				<-start
				raw, _ := json.Marshal(relayblind.ReservationRequest{EndpointFamily: relayblind.EndpointChatCompletions, Model: "model-a", MaxOutputTokens: 32, InputTokenUpperBound: 96, EncryptedRequestBytes: 2048})
				response := f.privacyRequest(t, http.MethodPost, "/v1/relay-blind/route-reservations", raw, "", nil)
				parsed, err := relayblind.ParseReservationResponse(response.Body.Bytes())
				if err != nil {
					results <- [2]string{"", fmt.Sprintf("status=%d body=%s", response.Code, response.Body.String())}
					return
				}
				row, err := f.store.LookupReservation(context.Background(), parsed.ProviderBinding)
				if err != nil {
					results <- [2]string{"", err.Error()}
					return
				}
				results <- [2]string{row.ProviderID, parsed.ProviderBinding}
			}()
		}
		close(start)
		seen := map[string]string{}
		for range 4 {
			got := <-results
			if got[0] == "" {
				t.Fatalf("round %d: reservation failed: %s", round, got[1])
			}
			if _, dup := seen[got[0]]; dup {
				t.Fatalf("round %d: two simultaneous reservations bound %s while another provider was idle", round, got[0])
			}
			seen[got[0]] = got[1]
		}
		for providerID, binding := range seen {
			f.server.relayBlind.clearPending("account-a", providerID, binding)
		}
	}
}

// Rotation spreads load across N enrolled providers, and providers without
// a verified posture or without a privacy key are never chosen, even when
// they are the only ones with a free slot.
func TestPrivacySelectionRotatesAndNeverChoosesIneligible(t *testing.T) {
	members := fleetMembers(4,
		privacyFleetMember{id: "no-posture", session: "session-no-posture", keyOnly: true},
		privacyFleetMember{id: "no-key", session: "session-no-key"},
	)
	f := newPrivacyFleet(t, members)
	f.server.relayBlind.pick = cyclingPick()
	counts := map[string]int{}
	for range 40 {
		providerID, binding := f.reservePrivate(t)
		counts[providerID]++
		f.server.relayBlind.clearPending("account-a", providerID, binding)
	}
	for i := range 4 {
		if id := fmt.Sprintf("enrolled-%d", i); counts[id] != 10 {
			t.Fatalf("counts=%v, want 10 reservations on each enrolled provider", counts)
		}
	}
	if counts["no-posture"] != 0 || counts["no-key"] != 0 {
		t.Fatalf("counts=%v, ineligible provider chosen", counts)
	}

	// Every enrolled provider busy, the ineligible ones free: still only
	// enrolled providers, from the busy tier.
	f.server.relayBlind.pick = nil
	for i := range 4 {
		id := fmt.Sprintf("enrolled-%d", i)
		f.setSlots(t, id, "session-"+id, 0)
	}
	for range 40 {
		providerID, binding := f.reservePrivate(t)
		if providerID == "no-posture" || providerID == "no-key" {
			t.Fatalf("ineligible provider %s chosen while every enrolled provider was busy", providerID)
		}
		f.server.relayBlind.clearPending("account-a", providerID, binding)
	}
}

// A free enrolled provider wins over a busy one regardless of the start.
func TestPrivacySelectionPrefersFreeEnrolledProvider(t *testing.T) {
	f := newPrivacyFleet(t, fleetMembers(3))
	f.setSlots(t, "enrolled-0", "session-enrolled-0", 0)
	f.setSlots(t, "enrolled-2", "session-enrolled-2", 0)
	for range 20 {
		providerID, binding := f.reservePrivate(t)
		if providerID != "enrolled-1" {
			t.Fatalf("bound %s while enrolled-1 had the only free slot", providerID)
		}
		f.server.relayBlind.clearPending("account-a", providerID, binding)
	}
}

func TestRelayBlindPendingExpiresAndIsBounded(t *testing.T) {
	r := &relayBlindService{}
	now := time.Unix(1_800_000_000, 0)
	r.notePending("acct", "p", "live", now.Add(time.Minute).Unix(), now)
	r.notePending("acct", "p", "expired", now.Unix(), now)
	if got := r.pendingOn("acct", "p", now); got != 1 {
		t.Fatalf("pending=%d, want only the unexpired reservation", got)
	}
	if got := r.pendingOn("other", "p", now); got != 0 {
		t.Fatalf("another account sees pending=%d", got)
	}
	r.clearPending("acct", "p", "live")
	r.clearPending("acct", "p", "live")
	if got := r.pendingOn("acct", "p", now); got != 0 || r.pendingCount != 0 || len(r.pending) != 0 {
		t.Fatalf("pending=%d count=%d map=%v after clear", got, r.pendingCount, r.pending)
	}
	for i := range relayBlindPendingPerAccount + 10 {
		r.notePending("acct", fmt.Sprintf("p%d", i%7), fmt.Sprintf("b%d", i), now.Add(time.Minute).Unix(), now)
	}
	if r.pendingCount != relayBlindPendingPerAccount {
		t.Fatalf("pending count=%d, want one account capped at %d", r.pendingCount, relayBlindPendingPerAccount)
	}
	// Other accounts holding many entries never stop this account's
	// tracking: there is no shared cap.
	for i := range 5000 {
		r.notePending(fmt.Sprintf("acct-%d", i), "p", "b", now.Add(time.Minute).Unix(), now)
	}
	r.notePending("mine", "q", "mine", now.Add(time.Minute).Unix(), now)
	if got := r.pendingOn("mine", "q", now); got != 1 {
		t.Fatalf("pending=%d, want this account tracked whatever other accounts hold", got)
	}
}

// Expired entries of idle accounts are swept by the timer with no further
// reservation traffic, and the timer stops once the index is empty.
func TestRelayBlindPendingSweepsWithoutTraffic(t *testing.T) {
	r := &relayBlindService{sweepEvery: 10 * time.Millisecond}
	now := time.Now()
	r.notePending("idle-a", "p", "b1", now.Add(time.Second).Unix(), now)
	r.notePending("idle-b", "q", "b2", now.Add(time.Second).Unix(), now)
	deadline := time.Now().Add(5 * time.Second)
	for {
		r.mu.Lock()
		count, accounts, timer := r.pendingCount, len(r.pending), r.pendingTimer
		r.mu.Unlock()
		if count == 0 && accounts == 0 && timer == nil {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("pending count=%d accounts=%d timer armed=%v, want swept and stopped", count, accounts, timer != nil)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// Another account's undispatched reservations neither steer nor reveal
// anything to this buyer's selection.
func TestPrivacySelectionIgnoresOtherAccountsPending(t *testing.T) {
	f := newPrivacyFleet(t, fleetMembers(2))
	f.server.relayBlind.pick = func(int) int { return 0 }
	for i := range 8 {
		f.server.relayBlind.notePending("account-other", "enrolled-0", fmt.Sprintf("other-%d", i), f.clock.Now().Add(time.Minute).Unix(), f.clock.Now())
	}
	providerID, binding := f.reservePrivate(t)
	if providerID != "enrolled-0" {
		t.Fatalf("bound %s, want the fixed start enrolled-0 despite another account's pending reservations", providerID)
	}
	f.server.relayBlind.clearPending("account-a", providerID, binding)
}

// The reservation is tracked until its chat reaches dispatch.
func TestPrivacyReservationPendingClearsAtDispatch(t *testing.T) {
	body := privacyTestResponseBody(t)
	var gotClass atomic.Value
	var dispatches atomic.Int32
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, relay: privacySuccessRelay(body, &gotClass, &dispatches)})
	_, raw, authorization := h.consumePrivacy(t, "privacy-pending-clear")
	if got := h.server.relayBlind.pendingOn("account-a", h.provider.ProviderID, h.clock.Now()); got != 1 {
		t.Fatalf("pending=%d after reservation, want 1", got)
	}
	response := h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, authorization, nil)
	if response.Code != http.StatusOK || dispatches.Load() != 1 {
		t.Fatalf("chat status=%d dispatches=%d body=%s", response.Code, dispatches.Load(), response.Body.String())
	}
	if got := h.server.relayBlind.pendingOn("account-a", h.provider.ProviderID, h.clock.Now()); got != 0 {
		t.Fatalf("pending=%d after dispatch, want 0", got)
	}
}

// Under sustained plaintext load a pinned private waiter keeps waiting while
// the provider keeps granting seats, even past one slot-queue deadline, and
// is served at its share. Plaintext keeps getting seats meanwhile.
func TestPrivacyChatWaitsThroughSustainedPlaintextLoad(t *testing.T) {
	body := privacyTestResponseBody(t)
	var gotClass atomic.Value
	var dispatches atomic.Int32
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, relay: privacySuccessRelay(body, &gotClass, &dispatches)})
	h.server.slotQueue = newSlotQueue(8)
	h.server.slotQueueDeadline = 150 * time.Millisecond
	h.server.slotQueuePollInterval = 2 * time.Millisecond
	_, raw, authorization := h.consumePrivacy(t, "privacy-sustained-load")
	providerID := h.provider.ProviderID
	queue := h.server.slotQueue

	// The provider's one seat is taken until the driver frees it.
	if !queue.reserveProvider(providerID, fixedSlots(1)) {
		t.Fatal("could not occupy the seat")
	}
	// Two earlier private waiters and a full plaintext lane are ahead.
	var fakes []*slotWaiter
	for range 2 {
		waiter, ok := queue.enterPinned(providerID, relayBlindPinnedLaneCap(8, 1))
		if !ok {
			t.Fatal("pinned waiter rejected")
		}
		fakes = append(fakes, waiter)
	}
	refill := func() {
		for {
			waiter, ok := queue.enter(providerID)
			if !ok {
				return
			}
			fakes = append(fakes, waiter)
		}
	}
	refill()

	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		done <- h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, authorization, nil)
	}()
	deadline := time.Now().Add(3 * time.Second)
	for {
		queue.mu.Lock()
		pinned := queue.laneLenLocked(providerID, slotWaiterPinned)
		queue.mu.Unlock()
		if pinned == 3 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("private chat never entered the pinned lane")
		}
		time.Sleep(time.Millisecond)
	}

	// A seat frees every 60ms; over the run that is several stall deadlines
	// of wall time but never one deadline without a grant.
	start := time.Now()
	plaintextGrants, pinnedFakeGrants := 0, 0
	var response *httptest.ResponseRecorder
	for response == nil {
		time.Sleep(60 * time.Millisecond)
		select {
		case response = <-done:
			continue
		default:
		}
		queue.releaseReservation(providerID)
		granted := false
		for i := 0; i < 200 && !granted; i++ {
			for _, waiter := range fakes {
				if queue.head(waiter) && queue.reserveHead(waiter, fixedSlots(1)) {
					granted = true
					if waiter.pinned() {
						pinnedFakeGrants++
					} else {
						plaintextGrants++
					}
					break
				}
			}
			if !granted {
				select {
				case response = <-done:
					granted = true
				case <-time.After(time.Millisecond):
				}
			}
		}
		refill()
		if time.Since(start) > 5*time.Second {
			t.Fatal("private chat was never served")
		}
	}
	if response.Code != http.StatusOK || dispatches.Load() != 1 {
		t.Fatalf("chat status=%d dispatches=%d body=%s", response.Code, dispatches.Load(), response.Body.String())
	}
	if waited := time.Since(start); waited < h.server.slotQueueDeadline {
		t.Fatalf("served after %v, want a wait longer than one stall deadline to exercise the progress rule", waited)
	}
	if pinnedFakeGrants != 2 || plaintextGrants < 2 {
		t.Fatalf("pinned grants ahead=%d plaintext grants=%d, want the two earlier private waiters and at least two plaintext grants first", pinnedFakeGrants, plaintextGrants)
	}
}
