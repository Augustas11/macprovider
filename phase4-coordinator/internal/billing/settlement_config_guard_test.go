package billing

import (
	"testing"
	"time"
)

func TestTryPinSettlementConfigPreservesEffectiveSelection(t *testing.T) {
	defaults := SettlementConfig{CadenceDays: 7, VerifiedModelSettlementMode: "observe"}
	for _, tc := range []struct {
		name string
		set  SettlementConfig
		want SettlementConfig
	}{
		{"unset", SettlementConfig{}, defaults},
		{"zero_cadence_uses_entire_default", SettlementConfig{VerifiedModelSettlementMode: "enforce"}, defaults},
		{"configured", SettlementConfig{CadenceDays: 1, VerifiedModelSettlementMode: "enforce"}, SettlementConfig{CadenceDays: 1, VerifiedModelSettlementMode: "enforce"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			store := &Store{}
			store.SetSettlementConfig(tc.set)
			if got := store.SettlementConfig(defaults); got != tc.want {
				t.Fatalf("ordinary getter = %+v, want %+v", got, tc.want)
			}
			got, release, ok := store.TryPinSettlementConfig(defaults)
			if !ok || release == nil {
				t.Fatal("uncontended pin failed")
			}
			defer release()
			if got != tc.want {
				t.Fatalf("pinned value = %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestTryPinSettlementConfigRejectsContentionWithoutOwnership(t *testing.T) {
	store := &Store{}
	store.settlementMu.Lock()
	defer store.settlementMu.Unlock()
	got, release, ok := store.TryPinSettlementConfig(SettlementConfig{CadenceDays: 7})
	if ok || release != nil || got != (SettlementConfig{}) {
		t.Fatalf("contended pin exposed authority: value=%+v ok=%v release=%v", got, ok, release != nil)
	}
}

func TestTryPinSettlementConfigExcludesSetterUntilRelease(t *testing.T) {
	store := &Store{}
	old := SettlementConfig{CadenceDays: 1, VerifiedModelSettlementMode: "enforce"}
	next := SettlementConfig{CadenceDays: 2, VerifiedModelSettlementMode: "observe"}
	store.SetSettlementConfig(old)
	got, release, ok := store.TryPinSettlementConfig(SettlementConfig{})
	if !ok || release == nil {
		t.Fatal("initial pin failed")
	}
	defer func() {
		if release != nil {
			release()
		}
	}()
	// Assert exclusion on the setter's actual mutex without relying on sleep or
	// scheduler ordering to infer that a goroutine has reached Lock.
	if store.settlementMu.TryLock() {
		store.settlementMu.Unlock()
		t.Fatal("setter mutex was writable during pin")
	}
	started, completed := make(chan struct{}), make(chan struct{})
	go func() {
		close(started)
		store.SetSettlementConfig(next)
		close(completed)
	}()
	<-started
	select {
	case <-completed:
		t.Fatal("setter completed while authority was pinned")
	default:
	}
	if got != old {
		t.Fatalf("captured authority changed: %+v", got)
	}
	release()
	release = nil
	select {
	case <-completed:
	case <-time.After(5 * time.Second):
		t.Fatal("setter did not resume after release")
	}
	current, releaseAgain, ok := store.TryPinSettlementConfig(SettlementConfig{})
	if !ok || releaseAgain == nil {
		t.Fatal("reacquisition failed")
	}
	defer releaseAgain()
	if current != next {
		t.Fatalf("new authority = %+v, want %+v", current, next)
	}
}
