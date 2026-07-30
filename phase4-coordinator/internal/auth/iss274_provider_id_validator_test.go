package auth_test

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

// TestIssueTokenRejectsInvalidProviderID_Iss274 pins that admission
// IssueToken refuses ProviderIDs that violate the canonical pattern.
// Pre-#274 the only gate was strings.TrimSpace + non-empty.
func TestIssueTokenRejectsInvalidProviderID_Iss274(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	ctx := context.Background()

	cases := map[string]string{
		"slash_delimiter_collision_seed": "a/b",
		"space":                          "m4 anon",
		"colon":                          "m4:anon",
		"unicode":                        "café",
		"len_65":                         strings.Repeat("a", 65),
		// R1 CODE LOW-1: admission paths must validate RAW input, so
		// leading/trailing whitespace is rejected symmetrically with WS.
		"leading_whitespace":  " m4-anon",
		"trailing_whitespace": "m4-anon ",
		"only_whitespace":     "   ",
	}
	for name, bad := range cases {
		t.Run(name, func(t *testing.T) {
			_, _, err := store.IssueToken(ctx, bad, "n")
			if err == nil {
				t.Fatalf("IssueToken accepted provider_id=%q", bad)
			}
			if !strings.Contains(err.Error(), "invalid provider_id") {
				t.Fatalf("err = %v, want substring %q", err, "invalid provider_id")
			}
		})
	}
}

// TestMintAdmissionTokenAndPairOTRejectsInvalidProviderID_Iss274 pins the
// same gate for the provisional-provider mint path.
func TestMintAdmissionTokenAndPairOTRejectsInvalidProviderID_Iss274(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	ctx := context.Background()
	now := time.Date(2026, 6, 30, 12, 0, 0, 0, time.UTC)

	for name, bad := range map[string]string{
		"slash_delimiter_collision_seed": "a/b",
		"space":                          "m4 anon",
	} {
		t.Run(name, func(t *testing.T) {
			_, err := store.MintAdmissionTokenAndPairOT(ctx, bad, "n", now)
			if err == nil {
				t.Fatalf("MintAdmissionTokenAndPairOT accepted provider_id=%q", bad)
			}
			if !strings.Contains(err.Error(), "invalid provider_id") {
				t.Fatalf("err = %v, want substring %q", err, "invalid provider_id")
			}
		})
	}
}
