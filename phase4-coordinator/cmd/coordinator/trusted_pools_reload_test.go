package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"path/filepath"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// Freeze audit R1 (#1816) CODE H2/H3: a reload's pool-model bounds and
// provider owner authority (owner keys and owner accounts) are prepared
// without side effects and applied together, so a rejected reload changes
// nothing and an applied one is in force everywhere they are read.
func TestPrepareTrustedPoolsReloadAppliesBoundsAndOwnerAuthority(t *testing.T) {
	t.Cleanup(func() {
		livePoolModelPricingBounds.Store(nil)
		liveTrustPoolOwnerAuthority.Store(nil)
	})
	reqLog, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "request-log.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reqLog.Close() })
	oldKey, _, _ := ed25519.GenerateKey(nil)
	newKey, _, _ := ed25519.GenerateKey(nil)
	store, err := trustpool.NewStore(reqLog.DB(), trustpool.WithProviderOwnerPublicKeys(map[string][]byte{"p1": oldKey}))
	if err != nil {
		t.Fatal(err)
	}
	registry := trustpool.NewRegistry()
	registry.AddPool("pool-a")
	registry.AddMember("pool-a", "p1")
	registry.SetProviderOwnerAccounts(map[string][]string{"acct-old": {"p1"}})
	liveTrustPoolOwnerAuthority.Store(&trustPoolOwnerAuthority{store: store, registry: registry})
	livePoolModelPricingBounds.Store(&poolmanifest.PoolModelPricingBounds{MaxPromptRatePerMtok: 5000, MaxPromptCacheHitRatePerMtok: 5000, MaxCompletionRatePerMtok: 5000})

	next := config.TrustedPoolsConfig{
		PoolModelPricingBounds:  &config.TrustedPoolsPoolModelPricingBounds{MaxPromptRatePerMtok: 1000, MaxPromptCacheHitRatePerMtok: 1000, MaxCompletionRatePerMtok: 1000},
		ProviderOwnerPublicKeys: map[string]string{"p1": base64.StdEncoding.EncodeToString(newKey)},
		ProviderOwnerAccountIDs: map[string][]string{"acct-new": {"p1"}},
	}
	apply, err := prepareTrustedPoolsReload(next)
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	// Nothing changes until the reload commits.
	if b := currentPoolModelPricingBounds(); b == nil || b.MaxCompletionRatePerMtok != 5000 {
		t.Fatalf("bounds changed before apply: %+v", b)
	}
	if key, ok := store.ProviderOwnerPublicKey("p1"); !ok || string(key) != string(oldKey) {
		t.Fatal("owner key changed before apply")
	}
	apply()
	if b := currentPoolModelPricingBounds(); b == nil || b.MaxCompletionRatePerMtok != 1000 {
		t.Fatalf("tightened bounds not applied: %+v", b)
	}
	if key, ok := store.ProviderOwnerPublicKey("p1"); !ok || string(key) != string(newKey) {
		t.Fatal("rotated owner key not applied")
	}
	if got := registry.Snapshot("pool-a").MemberOwnerAccounts["p1"]; got != "acct-new" {
		t.Fatalf("owner account after reload = %q, want acct-new", got)
	}

	// Removing bounds and owner authority applies too (fail closed).
	apply, err = prepareTrustedPoolsReload(config.TrustedPoolsConfig{})
	if err != nil {
		t.Fatalf("prepare removal: %v", err)
	}
	apply()
	if b := currentPoolModelPricingBounds(); b != nil {
		t.Fatalf("removed bounds still in force: %+v", b)
	}
	if _, ok := store.ProviderOwnerPublicKey("p1"); ok {
		t.Fatal("removed owner key still in force")
	}
	if got := registry.Snapshot("pool-a").MemberOwnerAccounts["p1"]; got != "" {
		t.Fatalf("removed owner account still in force: %q", got)
	}

	// An invalid key rejects the reload before anything applies.
	if _, err := prepareTrustedPoolsReload(config.TrustedPoolsConfig{ProviderOwnerPublicKeys: map[string]string{"p1": "not-a-key"}}); err == nil {
		t.Fatal("invalid owner key prepared")
	}
}
