package payout

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
)

// TestAcquire_ConflictEmitsLeaseConflictEvent is the §4.3 "IMPL test
// required (1)" for the payout_runner_lease_conflict PAGE alert: when a
// second Acquire runs against a DB row held by a FRESH holder, Acquire
// MUST emit payout_runner_lease_conflict per §7.1 with the full field
// set AND return ErrLeaseConflict (SPEC-016 §4.8b acquire step 3).
func TestAcquire_ConflictEmitsLeaseConflictEvent(t *testing.T) {
	db := openTestDB(t)

	// First acquire wins the (fresh) lease. Its INSERT stamps a live
	// heartbeat, so the second acquire below sees a fresh holder.
	quiet, _ := quietLogger()
	state1, _, err := Acquire(context.Background(), db, testRunInterval, quiet)
	if err != nil {
		t.Fatalf("Acquire #1: %v", err)
	}

	// Second acquire conflicts. Capture its structured output.
	logger, buf := quietLogger()
	_, _, err = Acquire(context.Background(), db, testRunInterval, logger)
	if !errors.Is(err, ErrLeaseConflict) {
		t.Fatalf("Acquire #2 err = %v, want ErrLeaseConflict", err)
	}

	var ev map[string]any
	if e := json.Unmarshal(buf.Bytes(), &ev); e != nil {
		t.Fatalf("parse emitted event %q: %v", buf.String(), e)
	}

	if got := ev["event"]; got != "payout_runner_lease_conflict" {
		t.Errorf("event = %v, want payout_runner_lease_conflict", got)
	}
	if got := ev["severity"]; got != "PAGE" {
		t.Errorf("severity = %v, want PAGE", got)
	}
	if got := ev["level"]; got != "error" {
		t.Errorf("level = %v, want error", got)
	}

	// Every §7.1 field must be present.
	for _, f := range []string{
		"local_pid", "local_started_at_utc",
		"holder_host", "holder_pid", "holder_started_at_utc",
		"holder_heartbeat_at_utc", "ts_utc",
	} {
		if _, ok := ev[f]; !ok {
			t.Errorf("missing §7.1 field %q in %v", f, ev)
		}
	}

	// The holder_* fields must describe the FIRST (surviving) holder,
	// not the conflicting caller.
	if got := ev["holder_host"]; got != state1.HolderHost {
		t.Errorf("holder_host = %v, want %v (first holder)", got, state1.HolderHost)
	}
	if got, ok := ev["holder_pid"].(float64); !ok || int(got) != state1.HolderPID {
		t.Errorf("holder_pid = %v, want %d (first holder)", ev["holder_pid"], state1.HolderPID)
	}
	// local_pid is this process's pid (the same value Acquire would use
	// for its own INSERT); with both acquires in one test process it
	// equals the first holder's pid — assert it is present + numeric.
	if _, ok := ev["local_pid"].(float64); !ok {
		t.Errorf("local_pid not numeric: %v", ev["local_pid"])
	}
}
