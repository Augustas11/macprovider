package auth_test

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

func TestMintPortalReadSessionRejectsUnknownProvider(t *testing.T) {
	ctx := context.Background()
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	_, err = store.MintPortalReadSession(ctx, "mp-missing", "https://portal.malibu.tech", time.Now().UTC())
	if err != auth.ErrPortalSessionUnknownProvider {
		t.Fatalf("err=%v, want unknown provider", err)
	}
}

func TestMintAndValidatePortalReadSession(t *testing.T) {
	ctx := context.Background()
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if _, _, err := store.IssueToken(ctx, "mp-local", "local mac"); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 8, 22, 10, 0, 0, 0, time.UTC)
	mint, err := store.MintPortalReadSession(ctx, "mp-local", "https://portal.malibu.tech", now)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(mint.Token, auth.PortalReadSessionPrefix) {
		t.Fatalf("token %q missing prefix", mint.Token)
	}
	if mint.PortalURL != "https://portal.malibu.tech/?ps="+mint.Token {
		t.Fatalf("portal_url=%q", mint.PortalURL)
	}
	if !mint.ExpiresAt.Equal(now.Add(auth.PortalReadSessionTTL)) {
		t.Fatalf("expires=%s", mint.ExpiresAt)
	}
	subject, ok, err := store.ValidatePortalReadSession(ctx, mint.Token, now.Add(time.Minute))
	if err != nil || !ok || subject != "mp-local" {
		t.Fatalf("validate subject=%q ok=%v err=%v", subject, ok, err)
	}
	if subject, ok, err := store.ValidateAndMarkTokenUsed(ctx, mint.Token); err != nil || ok || subject != "" {
		t.Fatalf("provider-token validator accepted portal session subject=%q ok=%v err=%v", subject, ok, err)
	}
	if subject, ok, err := auth.ValidateProviderAPIReadAndMark(ctx, store, mint.Token); err != nil || !ok || subject != "mp-local" {
		t.Fatalf("api read subject=%q ok=%v err=%v", subject, ok, err)
	}
}

func TestPortalReadSessionExpires(t *testing.T) {
	ctx := context.Background()
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if _, _, err := store.IssueToken(ctx, "mp-local", "local mac"); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 8, 22, 10, 0, 0, 0, time.UTC)
	mint, err := store.MintPortalReadSession(ctx, "mp-local", "", now)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok, err := store.ValidatePortalReadSession(ctx, mint.Token, now.Add(auth.PortalReadSessionTTL+time.Second)); err != nil || ok {
		t.Fatalf("expired session ok=%v err=%v", ok, err)
	}
}

func TestPortalReadSessionMintRateLimit(t *testing.T) {
	ctx := context.Background()
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if _, _, err := store.IssueToken(ctx, "mp-local", "local mac"); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 8, 22, 10, 0, 0, 0, time.UTC)
	for i := 0; i < auth.PortalReadSessionMintLimitPerHour; i++ {
		if _, err := store.MintPortalReadSession(ctx, "mp-local", "", now); err != nil {
			t.Fatalf("mint %d: %v", i, err)
		}
	}
	if _, err := store.MintPortalReadSession(ctx, "mp-local", "", now); err != auth.ErrPortalSessionRateLimited {
		t.Fatalf("err=%v, want rate limited", err)
	}
}

func TestPortalSessionMintAndMeHandlers(t *testing.T) {
	ctx := context.Background()
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if _, _, err := store.IssueToken(ctx, "mp-local", "local mac"); err != nil {
		t.Fatal(err)
	}
	mintH := auth.NewPortalSessionMintHandler(store, "operator-secret", "https://portal.malibu.tech")
	req := httptest.NewRequest(http.MethodPost, "/admin/portal-sessions", bytes.NewBufferString(`{"provider_id":"mp-local"}`))
	req.Header.Set("Authorization", "Bearer operator-secret")
	rec := httptest.NewRecorder()
	mintH.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("mint status=%d body=%s", rec.Code, rec.Body.String())
	}
	var minted struct {
		ProviderID string `json:"provider_id"`
		PortalURL  string `json:"portal_url"`
		Scope      string `json:"scope"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &minted); err != nil {
		t.Fatal(err)
	}
	if minted.ProviderID != "mp-local" || minted.Scope != "portal_read" || !strings.Contains(minted.PortalURL, "?ps=") {
		t.Fatalf("minted=%+v", minted)
	}
	token := minted.PortalURL[strings.Index(minted.PortalURL, "ps=")+3:]
	me := auth.NewPortalSessionMeHandler(store)
	meReq := httptest.NewRequest(http.MethodGet, "/v1/portal/session", nil)
	meReq.Header.Set("Authorization", "Bearer "+token)
	meRec := httptest.NewRecorder()
	me.ServeHTTP(meRec, meReq)
	if meRec.Code != http.StatusOK {
		t.Fatalf("me status=%d body=%s", meRec.Code, meRec.Body.String())
	}
	unauth := httptest.NewRequest(http.MethodPost, "/admin/portal-sessions", bytes.NewBufferString(`{"provider_id":"mp-local"}`))
	unauthRec := httptest.NewRecorder()
	mintH.ServeHTTP(unauthRec, unauth)
	if unauthRec.Code != http.StatusUnauthorized {
		t.Fatalf("unauth status=%d", unauthRec.Code)
	}
}
