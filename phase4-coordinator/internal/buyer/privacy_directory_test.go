package buyer

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/relayblind"
)

func privacyErrorCodeOf(t *testing.T, body []byte) string {
	t.Helper()
	var wire struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &wire); err != nil {
		t.Fatalf("error body %q: %v", body, err)
	}
	return wire.Error.Code
}

// SPEC-049-R028: the coordinator directory route serves the signed envelope
// on the gateway-context port, fails closed when disabled, and never
// serves an unsigned or partial body.
func TestPrivacyDirectoryRoute(t *testing.T) {
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true})
	missing := h.privacyRequest(t, http.MethodGet, "/v1/privacy-class/directory", nil, "", nil)
	if missing.Code != http.StatusServiceUnavailable || privacyErrorCodeOf(t, missing.Body.Bytes()) != privacyClassDisabled {
		t.Fatalf("directory without signer = %d %s", missing.Code, missing.Body.String())
	}

	signer := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x31}, ed25519.SeedSize))
	if err := h.authority.UseIdentityDirectoryKey(signer, 300*time.Second); err != nil {
		t.Fatal(err)
	}
	response := h.privacyRequest(t, http.MethodGet, "/v1/privacy-class/directory", nil, "", nil)
	if response.Code != http.StatusOK || response.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("directory = %d %v %s", response.Code, response.Header(), response.Body.String())
	}
	directory, err := relayblind.VerifyIdentityDirectory(response.Body.Bytes(), signer.Public().(ed25519.PublicKey), h.clock.Now())
	if err != nil {
		t.Fatalf("served directory does not verify: %v", err)
	}
	if len(directory.Entries) != 1 || directory.Entries[0].Source != relayblind.IdentityDirectorySourceOperatorPin || directory.Entries[0].Revoked {
		t.Fatalf("directory entries = %+v", directory.Entries)
	}
	if _, err := h.authority.BuildIdentityDirectory(context.Background(), h.clock.Now(), 300*time.Second); err != nil {
		t.Fatal(err)
	}

	unauthenticated := h.privacyRequest(t, http.MethodGet, "/v1/privacy-class/directory", nil, "", func(r *http.Request) {
		r.Header.Set("Authorization", "Bearer wrong-token")
	})
	if unauthenticated.Code == http.StatusOK {
		t.Fatal("directory served without gateway context")
	}

	if err := h.store.SetPrivacyDisabled(context.Background(), true, "incident", h.clock.Now()); err != nil {
		t.Fatal(err)
	}
	killed := h.privacyRequest(t, http.MethodGet, "/v1/privacy-class/directory", nil, "", nil)
	if killed.Code != http.StatusServiceUnavailable || privacyErrorCodeOf(t, killed.Body.Bytes()) != privacyClassDisabled {
		t.Fatalf("directory under kill switch = %d %s", killed.Code, killed.Body.String())
	}
}
