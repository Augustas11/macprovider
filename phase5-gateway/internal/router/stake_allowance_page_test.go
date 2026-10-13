package router

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// SPEC-050-R011/R012: the account page carries the stake panel and the
// exact disclosure text, with no yield language.
func TestAccountPageShowsStakePanelWithDisclosure(t *testing.T) {
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, nil)
	req := httptest.NewRequest(http.MethodGet, "/account", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d", rec.Code)
	}
	body := rec.Body.String()
	for _, want := range []string{`id="stake-panel"`, `id="stake-staked"`, `id="stake-allowance"`, `id="stake-remaining"`, `id="stake-refresh"`, `id="stake-overage"`, `id="stake-wallets"`, `id="stake-key"`, "/v1/stake"} {
		if !strings.Contains(body, want) {
			t.Fatalf("account page missing %q", want)
		}
	}
	if !strings.Contains(body, strings.ReplaceAll(stakeAllowanceDisclosure, "'", "&#39;")) {
		t.Fatal("account page must carry the SPEC-050-R012 disclosure unchanged")
	}
	start := strings.Index(body, `id="stake-panel"`)
	panel := strings.ToLower(body[start:])
	for _, banned := range []string{"apy", "apr", "yield", "interest", "dividend"} {
		if strings.Contains(panel, banned) {
			t.Fatalf("stake panel uses %q", banned)
		}
	}
}

func TestStakeDisclosureMatchesSpec(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "specs", "SPEC-050-malibu-stake-allowance.md"))
	if err != nil {
		t.Fatal(err)
	}
	spec := strings.Join(strings.Fields(string(raw)), " ")
	if !strings.Contains(spec, `"`+stakeAllowanceDisclosure+`"`) {
		t.Fatal("gateway stake disclosure drifted from SPEC-050-R012")
	}
}
