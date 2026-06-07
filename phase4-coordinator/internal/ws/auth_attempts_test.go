package ws

import (
	"strings"
	"testing"
	"time"

	"golang.org/x/text/unicode/norm"
)

func TestAuthAttemptStoreTryReserveAndRelease(t *testing.T) {
	store := newAuthAttemptStore(1024)
	state := AuthAttemptState{
		AuthAttemptID: "auth-1",
		ProviderID:    "m4-anon",
		StartedAt:     time.Now().UTC(),
		ExpiresAt:     time.Now().Add(time.Minute).UTC(),
	}

	if !store.tryReserve(state) {
		t.Fatal("tryReserve returned false")
	}
	got, ok := store.lookup("auth-1")
	if !ok {
		t.Fatal("lookup returned ok=false")
	}
	if got.ProviderID != "m4-anon" {
		t.Fatalf("ProviderID = %q", got.ProviderID)
	}
	store.release("auth-1")
	if _, ok := store.lookup("auth-1"); ok {
		t.Fatal("lookup after release returned ok=true")
	}
}

func TestAuthAttemptStoreEnforces1024Bound(t *testing.T) {
	store := newAuthAttemptStore(1024)
	for i := 0; i < 1024; i++ {
		store.entries["auth-"+itoa(i)] = AuthAttemptState{AuthAttemptID: "auth-" + itoa(i)}
	}

	if store.tryReserve(AuthAttemptState{AuthAttemptID: "auth-1024"}) {
		t.Fatal("tryReserve at bound returned true")
	}
	if got := store.count(); got != 1024 {
		t.Fatalf("count = %d, want 1024", got)
	}
	store.release("auth-1")
	if !store.tryReserve(AuthAttemptState{AuthAttemptID: "auth-1024"}) {
		t.Fatal("tryReserve after release returned false")
	}
}

func TestNormalizeSupportedModelEntry(t *testing.T) {
	nfd := "Model-" + string([]byte{0x43, 0xCC, 0xA7})
	want := "model-" + strings.ToLower(norm.NFC.String("Ç"))
	if got := normalizeSupportedModelEntry(nfd); got != want {
		t.Fatalf("normalizeSupportedModelEntry = %q, want %q", got, want)
	}
}

func TestSupportedModelsEqualUnderNFCASCIIFoldHandlesCaseAndForm(t *testing.T) {
	if !supportedModelsEqualUnderNFCASCIIFold([]string{"Model-A"}, []string{"model-a"}) {
		t.Fatal("case-equivalent models did not compare equal")
	}
	if supportedModelsEqualUnderNFCASCIIFold([]string{"Model-A"}, []string{"Model-B"}) {
		t.Fatal("different models compared equal")
	}
	if supportedModelsEqualUnderNFCASCIIFold([]string{"A", "B"}, []string{"B", "A"}) {
		t.Fatal("different order compared equal")
	}
	if !supportedModelsEqualUnderNFCASCIIFold([]string{"Model-" + string([]byte{0x43, 0xCC, 0xA7})}, []string{"model-Ç"}) {
		t.Fatal("NFC-equivalent models did not compare equal")
	}
}
