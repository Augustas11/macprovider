package pool

import (
	"net"
	"runtime"
	"testing"
	"time"
)

func admissionGuardRegistry(t *testing.T) *Registry {
	t.Helper()
	r := NewRegistry(nil)
	conn, peer := net.Pipe()
	t.Cleanup(func() { _ = conn.Close(); _ = peer.Close() })
	if _, ok := r.Register(&Provider{ProviderID: "p", AssignedID: "s", State: StateReady, AuthState: AuthBearerValidated, ReceiptPubkey: []byte{1, 2, 3}}, conn); !ok {
		t.Fatal("register failed")
	}
	r.ApplyStateUpdate("p", "s", StateUpdate{State: StateReady})
	return r
}

func TestModelAdmissionProviderPinOwnershipAndContention(t *testing.T) {
	r := admissionGuardRegistry(t)
	before, _ := r.Resolve("p", "s")
	before.PendingReceiptPubkey = append(before.PendingReceiptPubkey, 9)
	before.ReceiptPubkey[0] = 99
	view, sanctioned, release, ok := r.TryPinModelAdmissionProvider("p", "s")
	if !ok || sanctioned || view.ReceiptPubkey[0] != 1 || view.conn != nil || view.Tier2Session != nil {
		t.Fatal("pin did not return independent authority")
	}
	view.ReceiptPubkey[0] = 88
	release()
	after, _ := r.Resolve("p", "s")
	if after.ReceiptPubkey[0] != 1 {
		t.Fatal("guard snapshot aliases registry")
	}
	r.mu.Lock()
	_, _, release, ok = r.TryPinModelAdmissionProvider("p", "s")
	r.mu.Unlock()
	if ok || release != nil {
		t.Fatal("contended pin succeeded")
	}
	for _, ids := range [][2]string{{"", "s"}, {"p", ""}, {"p", "old"}, {"missing", "s"}} {
		if _, _, release, ok := r.TryPinModelAdmissionProvider(ids[0], ids[1]); ok || release != nil {
			t.Fatalf("accepted %v", ids)
		}
	}
	r.mu.Lock()
	r.providers["p"].conn = nil
	r.mu.Unlock()
	if _, _, release, ok := r.TryPinModelAdmissionProvider("p", "s"); ok || release != nil {
		t.Fatal("accepted disconnected session")
	}
	if !r.mu.TryLock() {
		t.Fatal("failed pin leaked registry lock")
	}
	r.mu.Unlock()
}

func TestModelAdmissionProviderPublicationOwnsInput(t *testing.T) {
	r := NewRegistry(nil)
	conn, peer := net.Pipe()
	defer conn.Close()
	defer peer.Close()
	input := &Provider{ProviderID: "p", AssignedID: "s", ModelID: "model", State: StateReady, AuthState: AuthBearerValidated, ReceiptPubkey: []byte{1, 2, 3}}
	if _, ok := r.Register(input, conn); !ok {
		t.Fatal("registration failed")
	}
	r.ApplyStateUpdate("p", "s", StateUpdate{State: StateReady})
	input.ModelID = "changed"
	input.AssignedID = "changed"
	input.State = StateUnavailable
	input.PendingReceiptPubkey[0] = 99
	input.PendingReceiptPubkey = []byte{99}
	view, _, release, ok := r.TryPinModelAdmissionProvider("p", "s")
	if !ok {
		t.Fatal("caller changed published identity")
	}
	release()
	if view.ModelID != "model" || view.State != StateReady || view.ReceiptPubkey[0] != 1 || len(view.PendingReceiptPubkey) != 0 {
		t.Fatal("caller retained admission authority alias")
	}
	for _, snapshot := range r.Snapshot() {
		snapshot.ReceiptPubkey[0] = 88
	}
	updated, ok := r.ApplyStateUpdate("p", "s", StateUpdate{State: StateReady})
	if !ok {
		t.Fatal("state update failed")
	}
	updated.ReceiptPubkey[0] = 77
	r.SetBuyerServingPredicate(func(p Provider) bool { p.ReceiptPubkey[0] = 66; return true })
	r.RecordCanaryResult("p", "s", false, time.Now(), 1)
	view, _, release, ok = r.TryPinModelAdmissionProvider("p", "s")
	if !ok {
		t.Fatal("final pin failed")
	}
	defer release()
	if view.ReceiptPubkey[0] != 1 {
		t.Fatal("getter returned registry-owned receipt bytes")
	}
}

func TestModelAdmissionProviderPinSerializesRealMutators(t *testing.T) {
	mutators := map[string]func(*Registry){
		"heartbeat":           func(r *Registry) { r.ApplyHeartbeat("p", "s", HeartbeatUpdate{Status: StateBusy, At: time.Now()}) },
		"receipt_publication": func(r *Registry) { r.ApplyStateUpdate("p", "s", StateUpdate{State: StateReady}) },
		"state":               func(r *Registry) { r.MarkState("p", "s", StateUnavailable) },
		"exclusions":          func(r *Registry) { r.SetAdmissionGateFlags("p", "s", AdmissionGateFlags{AdmissionSandboxed: true}) },
		"quarantine":          func(r *Registry) { r.SetBenchmarkQuarantine("p", "s", true) },
		"sanction":            func(r *Registry) { r.LoadCanarySanctions([]CanarySanctionSnapshot{{ProviderID: "p", FailCount: 2}}) },
		"canary_result":       func(r *Registry) { r.RecordCanaryResult("p", "s", false, time.Now(), 3) },
		"clear_sanction":      func(r *Registry) { r.ClearCanarySanction("p") },
		"remove":              func(r *Registry) { r.RemoveIfSession("p", "s") },
		"replace": func(r *Registry) {
			r.Register(&Provider{ProviderID: "p", AssignedID: "new", AuthState: AuthBearerValidated}, nil)
		},
	}
	for name, mutate := range mutators {
		t.Run(name, func(t *testing.T) {
			r := admissionGuardRegistry(t)
			if name == "receipt_publication" {
				r.mu.Lock()
				r.providers["p"].PendingReceiptPubkey = []byte{4, 5, 6}
				r.mu.Unlock()
			}
			_, _, release, ok := r.TryPinModelAdmissionProvider("p", "s")
			if !ok {
				t.Fatal("initial pin failed")
			}
			done := make(chan struct{})
			go func() { mutate(r); close(done) }()
			deadline := time.Now().Add(5 * time.Second)
			for r.mu.TryRLock() {
				r.mu.RUnlock()
				if time.Now().After(deadline) {
					release()
					t.Fatal("mutator never waited for pin")
				}
				runtime.Gosched()
			}
			// A pending writer must cause prompt failure, not recursive RLock.
			if _, _, secondRelease, ok := r.TryPinModelAdmissionProvider("p", "s"); ok || secondRelease != nil {
				release()
				t.Fatal("pin ignored pending writer")
			}
			select {
			case <-done:
				release()
				t.Fatal("mutator completed through pin")
			default:
			}
			release()
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				t.Fatal("mutator blocked after release")
			}
			view, sanctioned, release, ok := r.TryPinModelAdmissionProvider("p", "s")
			if name == "remove" || name == "replace" {
				if ok {
					release()
					t.Fatal("old session remained pinnable")
				}
				return
			}
			if !ok {
				t.Fatal("pin not reacquirable")
			}
			defer release()
			if name == "state" && view.State != StateUnavailable || name == "exclusions" && !view.AdmissionSandboxed || name == "quarantine" && !view.BenchmarkQuarantined || name == "sanction" && !sanctioned || name == "heartbeat" && view.State != StateBusy || name == "receipt_publication" && (len(view.PendingReceiptPubkey) != 0 || view.ReceiptPubkey[0] != 4) {
				t.Fatal("completed mutation not observed")
			}
		})
	}
}
