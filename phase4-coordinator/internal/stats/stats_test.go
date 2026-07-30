package stats

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// TestOpenDisabledReturnsSentinel — when Config.Enabled = false,
// Open returns ErrDisabled and does NOT touch any DSN. BUILD
// §C.4: the /v1/stats/* mux subtree is skipped on this branch.
func TestOpenDisabledReturnsSentinel(t *testing.T) {
	_, err := Open(context.Background(), Config{Enabled: false})
	if !errors.Is(err, ErrDisabled) {
		t.Fatalf("Open(Enabled=false) returned %v, want ErrDisabled", err)
	}
}

// TestOpenMissingDSNFailClosed — BUILD §C.3: any missing required
// runtime DSN MUST prevent Open from succeeding.
func TestOpenMissingDSNFailClosed(t *testing.T) {
	cases := []struct {
		name      string
		cfg       Config
		wantField string
	}{
		{
			name: "missing reader",
			cfg: Config{
				Enabled:   true,
				ReaderDSN: "",
				RollupDSN: "x",
			},
			wantField: "stats_reader",
		},
		{
			name: "missing rollup",
			cfg: Config{
				Enabled:   true,
				ReaderDSN: "x",
				RollupDSN: "",
			},
			wantField: "stats_rollup",
		},
		{
			name: "writer enabled but DSN missing",
			cfg: Config{
				Enabled:   true,
				ReaderDSN: "x",
				RollupDSN: "x",
				PartnerKeys: PartnerKeysConfig{
					LastUsedAtUpdatesEnabled: true,
					WriterDSN:                "",
				},
			},
			wantField: "partner_keys_writer",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := Open(context.Background(), c.cfg)
			if err == nil {
				t.Fatal("Open succeeded with missing DSN; want fail-closed")
			}
			if !strings.Contains(err.Error(), c.wantField) {
				t.Errorf("error %q does not name the missing field %q", err.Error(), c.wantField)
			}
		})
	}
}

// TestPoolsCloseNilSafe — Close on a zero-value or nil-field
// Pools must not panic.
func TestPoolsCloseNilSafe(t *testing.T) {
	var nilPools *Pools
	if err := nilPools.Close(); err != nil {
		t.Errorf("nil Pools.Close() = %v, want nil", err)
	}
	zero := &Pools{}
	if err := zero.Close(); err != nil {
		t.Errorf("zero Pools.Close() = %v, want nil", err)
	}
}
