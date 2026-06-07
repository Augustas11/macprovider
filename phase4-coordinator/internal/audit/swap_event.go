package audit

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

type swapPayload struct {
	Event                  string `json:"event"`
	TS                     string `json:"ts"`
	ProviderAssignedID     string `json:"provider_assigned_id"`
	FromModelID            string `json:"from_model_id"`
	FromModelHash          string `json:"from_model_hash,omitempty"`
	ToModelID              string `json:"to_model_id"`
	ToModelHash            string `json:"to_model_hash"`
	LoadingWindowMs        int64  `json:"loading_window_ms"`
	HashVerificationResult string `json:"hash_verification_result"`
	// SPEC-002 v1.3.5 R-7.10.4: drain_inflight_count_estimate is
	// OPTIONAL and MAY be omitted; observability-only. v1.3.5 ships
	// without it because Phase 2C's SwapEvent does not carry the inflight
	// count, and adding it would require a Phase 2C reach-back.
}

// buildSwapPayload is intentionally limited to pool.SwapEvent fields. SPEC-002
// v1.3.5 R-7.10.9 and SPEC-011 v0.5 R-3.6.5 prohibit payload inputs that could
// carry sticky derivation material, buyer prompts, conv: prefixes, or raw
// account_id values.
func buildSwapPayload(event pool.SwapEvent) ([]byte, error) {
	payload := swapPayload{
		Event: "operator_model_swap",
		// SPEC-002 v1.3.5 §7.10.1 R-7.10.2 mandates ts_utc be RFC3339 in
		// UTC; SPEC-011 v0.5 §3.6 example shows subsecond precision
		// ("2026-06-06T14:23:09.123Z"). RFC3339Nano is a superset
		// (parses cleanly as RFC3339) and matches the precision of the
		// audit_log.ts_utc column at store.go to keep payload/row
		// timestamps consistent for forensic correlation across
		// same-second swaps.
		TS:                     event.CompletedAt.UTC().Format(time.RFC3339Nano),
		ProviderAssignedID:     event.AssignedID,
		FromModelID:            event.FromModelID,
		FromModelHash:          event.FromModelHash,
		ToModelID:              event.ToModelID,
		ToModelHash:            event.ToModelHash,
		LoadingWindowMs:        loadingWindowMillis(event),
		HashVerificationResult: string(event.HashVerificationResult),
	}
	return json.Marshal(payload)
}

func loadingWindowMillis(event pool.SwapEvent) int64 {
	if event.LoadingStartedAt.IsZero() {
		return 0
	}
	return event.CompletedAt.Sub(event.LoadingStartedAt).Milliseconds()
}

var forbiddenPayloadSubstrings = [][]byte{
	[]byte("conv:"),
	[]byte("account_id"),
}

// assertNoForbiddenSubstrings enforces SPEC-002 v1.3.5 R-7.10.9 and SPEC-011
// v0.5 R-3.6.5 at runtime: operator_model_swap payload JSON must not contain
// conv: or account_id anywhere. EmitSwap drops rejected events instead of
// writing invariant-violating rows.
func assertNoForbiddenSubstrings(payload []byte) error {
	var found []string
	for i, b := range payload {
		for _, forbidden := range forbiddenPayloadSubstrings {
			if b == forbidden[0] && i+len(forbidden) <= len(payload) && bytes.Equal(payload[i:i+len(forbidden)], forbidden) {
				found = append(found, string(forbidden))
			}
		}
	}
	if len(found) > 0 {
		return fmt.Errorf("operator_model_swap payload violates F-1.5 invariant: %s", strings.Join(found, ", "))
	}
	return nil
}
