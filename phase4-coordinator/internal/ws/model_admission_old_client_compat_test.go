package ws_test

import (
	"context"
	"database/sql"
	"net/http"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
)

// #1248 old-client compatibility: a pre-BYOM provider CLI sends a hello and
// heartbeat with no admission offer and no BYOM fields at all (validHello and
// heartbeat() are exactly that wire shape). With the SPEC-047 admission store
// wired, such a provider must still be admitted, pooled and carry no BYOM
// identity fields it never sent.
func TestPreBYOMProviderHelloAndHeartbeatStayPooledWithModelAdmissionStore(t *testing.T) {
	store := providerws.NewMemoryModelAdmissionStore()
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithModelAdmissionStore(store),
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assignedID := assertHelloAck(t, conn)

	hb := heartbeat()
	if err := wsutil.WriteClientText(conn, mustJSON(hb)); err != nil {
		t.Fatalf("write heartbeat: %v", err)
	}
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", assignedID)
		return ok && provider.State == pool.StateReady
	})

	provider, ok := h.Registry.Resolve("m4-anon", assignedID)
	if !ok {
		t.Fatal("pre-BYOM provider missing from the pool")
	}
	if provider.ModelAdmissionCandidateID != "" ||
		provider.ModelAdmissionServedModelRef != "" ||
		provider.ModelAdmissionCatalogModelKey != "" ||
		provider.ModelAdmissionCoordinatorEventID != "" ||
		provider.ModelAdmissionDiscoveryDigestSHA256 != "" ||
		provider.ModelAdmissionEvaluationDigestSHA256 != "" {
		t.Fatalf("pre-BYOM provider acquired BYOM admission fields: %+v", provider)
	}
	if provider.ModelID != hb["model_id"] {
		t.Fatalf("heartbeat model_id = %q, want %v", provider.ModelID, hb["model_id"])
	}
}

// A provider that never submitted an offer (every pre-BYOM CLI) reads back the
// documented not-offered shape rather than an error, and the coordinator
// invents no served model reference or catalog key for it.
func TestModelAdmissionStatusForPreBYOMProviderReturnsNotOffered(t *testing.T) {
	h, bearer, _ := newModelAdmissionHarness(t, "provider-legacy")
	defer h.HTTP.Close()

	status, body := getModelAdmissionStatus(t, h.HTTP.URL, bearer, stableModelAdmissionCandidateID("l"))
	if status != http.StatusOK {
		t.Fatalf("status=%d body=%s, want 200", status, body)
	}
	object := decodeMap(t, body)
	if object["admission_state"] != "not_offered" ||
		object["admission_state_source"] != "coordinator" ||
		object["provider_id"] != "provider-legacy" ||
		object["served_model_ref"] != "" ||
		object["catalog_model_key"] != nil ||
		object["coordinator_event_id"] != nil {
		t.Fatalf("unexpected not-offered readback: %s", body)
	}
	guidance := object["provider_guidance"].(map[string]any)
	if guidance["next_action"] != "submit_offer" || guidance["earning_path_class"] != "local_inventory_only" {
		t.Fatalf("unexpected not-offered guidance: %#v", guidance)
	}
}

// The BYOM schema init is additive: pointing it at a database created before
// the admission tables existed creates them without touching pre-existing
// request-log or provider-token rows, and re-running it is a no-op.
func TestSQLiteModelAdmissionSchemaInitIsAdditiveOnPreBYOMDatabase(t *testing.T) {
	dir := t.TempDir()

	// Pre-BYOM request-log database with one row.
	reqStore, err := requestlog.OpenStore(filepath.Join(dir, "requests.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer reqStore.Close()
	prompt := int64(11)
	completion := int64(22)
	if err := reqStore.Insert(context.Background(), requestlog.Row{
		TSUtc:              time.Unix(1800000000, 0).UTC(),
		RequestID:          "req-pre-byom",
		Model:              "model-a",
		ProviderAssignedID: "assigned-a",
		PromptTokens:       &prompt,
		CompletionTokens:   &completion,
		Status:             200,
		BuyerIP:            "127.0.0.1",
	}); err != nil {
		t.Fatal(err)
	}
	if !sqliteTableMissing(t, reqStore.DB(), "model_admission_events") {
		t.Fatal("pre-BYOM request-log database already had model_admission_events")
	}

	admissions, err := providerws.NewSQLiteModelAdmissionStore(reqStore.DB())
	if err != nil {
		t.Fatalf("model admission schema init on pre-BYOM database: %v", err)
	}
	if got := sqliteCount(t, reqStore.DB(), "SELECT COUNT(*) FROM request_log"); got != 1 {
		t.Fatalf("request_log rows = %d after admission schema init, want 1", got)
	}
	if got := sqliteCount(t, reqStore.DB(), "SELECT COUNT(*) FROM model_admission_events"); got != 0 {
		t.Fatalf("model_admission_events rows = %d on a fresh install, want 0", got)
	}
	if _, err := providerws.NewSQLiteModelAdmissionStore(reqStore.DB()); err != nil {
		t.Fatalf("re-running admission schema init: %v", err)
	}
	if got := sqliteCount(t, reqStore.DB(), "SELECT COUNT(*) FROM request_log"); got != 1 {
		t.Fatalf("request_log rows = %d after a second schema init, want 1", got)
	}
	if _, found, err := admissions.LatestModelAdmissionStatus(context.Background(), "provider-legacy", stableModelAdmissionCandidateID("l")); err != nil || found {
		t.Fatalf("pre-BYOM database reported an admission event found=%v err=%v", found, err)
	}

	// Pre-BYOM provider-token database: tokens keep validating afterwards.
	authStore, err := auth.OpenStore(filepath.Join(dir, "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer authStore.Close()
	_, bearer, err := authStore.IssueToken(context.Background(), "provider-legacy", "legacy")
	if err != nil {
		t.Fatal(err)
	}
	tokensBefore := sqliteCount(t, authStore.DB(), "SELECT COUNT(*) FROM provider_tokens")
	if _, err := providerws.NewSQLiteModelAdmissionStore(authStore.DB()); err != nil {
		t.Fatalf("model admission schema init on provider-token database: %v", err)
	}
	if got := sqliteCount(t, authStore.DB(), "SELECT COUNT(*) FROM provider_tokens"); got != tokensBefore {
		t.Fatalf("provider_tokens rows = %d after admission schema init, want %d", got, tokensBefore)
	}
	providerID, valid, err := authStore.ValidateToken(context.Background(), bearer)
	if err != nil || !valid || providerID != "provider-legacy" {
		t.Fatalf("pre-BYOM provider token stopped validating: provider=%q valid=%v err=%v", providerID, valid, err)
	}
}

func sqliteCount(t *testing.T, db *sql.DB, query string) int {
	t.Helper()
	var count int
	if err := db.QueryRowContext(context.Background(), query).Scan(&count); err != nil {
		t.Fatalf("%s: %v", query, err)
	}
	return count
}

func sqliteTableMissing(t *testing.T, db *sql.DB, table string) bool {
	t.Helper()
	var name string
	err := db.QueryRowContext(context.Background(),
		`SELECT name FROM sqlite_master WHERE type='table' AND name = ?`, table).Scan(&name)
	if err == sql.ErrNoRows {
		return true
	}
	if err != nil {
		t.Fatalf("sqlite_master lookup for %s: %v", table, err)
	}
	return false
}
