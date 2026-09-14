package integration

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

// The fixture holds only its ready reply, not coordinator authority or socket
// cleanup. The real blacklist producer arms its existing one-minute close timer.
type build1DrainControl struct {
	observed, allowReady, readySent chan struct{}
	once                            sync.Once
}

func (c *build1DrainControl) release() { c.once.Do(func() { close(c.allowReady) }) }

func TestBuild1PaidRouteRejectsClosingBeforeStatusRevocation(t *testing.T) {
	for _, rejectRevocation := range []bool{false, true} {
		t.Run(fmt.Sprintf("reject_revocation_%t", rejectRevocation), func(t *testing.T) {
			control := &build1DrainControl{observed: make(chan struct{}), allowReady: make(chan struct{}), readySent: make(chan struct{})}
			defer control.release()
			s := newScenario(t, scenarioOpts{build1ArtifactAdmission: true, seedAccount: true, settlementReceiptProvider: true, settlementEnforceMode: true,
				build1Catalog: func(s *scenario, c settlementCatalogFixture) settlementCatalogFixture {
					c = s.writeBuild1Feeds(c)
					c.build1.drainControl = control
					return c
				}})
			requireIsolatedCandidate(t, s)
			db, err := sql.Open("sqlite", s.coordinatorDB)
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			pub, priv, err := ed25519.GenerateKey(rand.Reader)
			if err != nil {
				t.Fatal(err)
			}
			now := time.Now().UTC().Format(time.RFC3339)
			if _, err = db.Exec(`INSERT INTO provider_bootstrap_identities(provider_id,receipt_pubkey,created_at,confirmed_at,expires_at) VALUES(?,?,?,?,NULL)`, s.providerID, []byte(pub), now, now); err != nil {
				t.Fatal(err)
			}
			code, status := build1Post(t, s, build1SignedOffer(t, s, priv))
			if code != 200 || status["admission_state"] != "settlement_capable" {
				t.Fatalf("promotion status%d: %v", code, status)
			}
			originalID, originalState := build1LatestAdmission(t, db)
			var originalAuthority string
			if err = db.QueryRow(`SELECT authority_json FROM model_admission_events WHERE coordinator_event_id=?`, originalID).Scan(&originalAuthority); err != nil {
				t.Fatal(err)
			}
			var extension struct {
				Artifact map[string]any `json:"artifact_admission"`
			}
			if err = json.Unmarshal([]byte(originalAuthority), &extension); err != nil {
				t.Fatal(err)
			}
			if originalState != "settlement_capable" {
				t.Fatal("positive event absent")
			}
			before := build1PoolProvider(t, s)
			if before["state"] != "ready" || before["assigned_id"] == "" || before["routing_eligible"] != true {
				t.Fatal("initial exact session is not ready")
			}
			if rejectRevocation {
				if _, err = db.Exec(`CREATE TRIGGER build1_reject_revocation BEFORE INSERT ON model_admission_events WHEN NEW.next_state='revoked' BEGIN SELECT RAISE(ABORT,'fixture_revocation_failure'); END`); err != nil {
					t.Fatal(err)
				}
			}
			started := time.Now()
			req, err := http.NewRequest(http.MethodPost, s.coordProvURL+"/admin/blacklist", bytes.NewReader(build1JSON(t, map[string]any{"provider_id": s.providerID, "assigned_id": before["assigned_id"], "reason": "build1 closing route fixture"})))
			if err != nil {
				t.Fatal(err)
			}
			req.Header.Set("Authorization", "Bearer "+s.operatorKey)
			req.Header.Set("Content-Type", "application/json")
			response, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			responseBody, _ := io.ReadAll(response.Body)
			response.Body.Close()
			if response.StatusCode != 200 {
				t.Fatalf("blacklist status%d: %s", response.StatusCode, responseBody)
			}
			build1AwaitSignal(t, control.observed)
			if draining := build1PoolProvider(t, s); draining["state"] != "draining" || draining["assigned_id"] != before["assigned_id"] {
				t.Fatal("real blacklist did not enter draining on exact session")
			}
			// Publication and timer scheduling completed before this ready update.
			control.release()
			build1AwaitSignal(t, control.readySent)
			s.waitForProviderReady(s.providerID)
			after := build1PoolProvider(t, s)
			for _, key := range []string{"provider_id", "assigned_id", "state", "model_id", "model_hash", "model_hash_algorithm", "receipt_pubkey", "catalog_release_id", "catalog_policy_version", "catalog_candidate_sha256", "catalog_signer_key_id", "catalog_row_identity", "routing_eligible", "canary_fail_count", "auth_state", "encrypted_leg", "catalog_admission_mode", "benchmark_quarantined", "admission_ceiling_excluded", "admission_evidence_stale", "admission_sandboxed", "slots_free", "slots_total", "hash_status", "weights_manifest_sha256", "weights_manifest_algorithm"} {
				if !reflect.DeepEqual(before[key], after[key]) {
					t.Fatalf("session authority changed at %s", key)
				}
			}
			if id, state := build1LatestAdmission(t, db); id != originalID || state != originalState {
				t.Fatal("admission revoked before tested HTTP entrypoint")
			}
			var currentAuthority string
			if err = db.QueryRow(`SELECT authority_json FROM model_admission_events WHERE coordinator_event_id=?`, originalID).Scan(&currentAuthority); err != nil {
				t.Fatal(err)
			}
			if currentAuthority != originalAuthority {
				t.Fatal("captured feed/rate/session authority changed")
			}
			for _, key := range []string{"admission_probe_expires_at_unix_ms", "admission_authority_expires_at_unix_ms"} {
				expiry, ok := extension.Artifact[key].(float64)
				if !ok || int64(expiry) <= time.Now().Add(10*time.Second).UnixMilli() {
					t.Fatalf("authority lease is not fresh: %s", key)
				}
			}
			if extension.Artifact["admission_provider_session_id"] != before["assigned_id"] {
				t.Fatal("positive authority belongs to another session")
			}
			if after["canary_fail_count"] != float64(0) {
				t.Fatal("canary sanction is an alternative rejection reason")
			}
			// No status, models list, retry or route predicate has run since closing.
			// This first buyer request must reject selection, not fail after dispatch.
			requestID := "b4444444-4444-4444-8444-444444444444"
			code, _, body := s.chatRequest(map[string]string{"X-Request-ID": requestID}, fmt.Sprintf(`{"model":%q,"max_tokens":32,"messages":[{"role":"user","content":"closing must not select"}]}`, settlementFixtureModelID))
			if code != http.StatusServiceUnavailable || !strings.Contains(string(body), `"code":"byom_non_settlement_unavailable"`) || !strings.Contains(string(body), `"inference_ran":false`) || !strings.Contains(string(body), `"settlement_ran":false`) {
				t.Fatalf("selection refusal status%d: %s", code, body)
			}
			if time.Since(started) >= time.Minute {
				t.Fatal("assertion ran after scheduled hard-close window")
			}
			s.fakeProv.hitMu.Lock()
			paidFrames, probeFrames := s.fakeProv.hits, s.fakeProv.probeHits
			s.fakeProv.hitMu.Unlock()
			if paidFrames != 0 || probeFrames != 1 {
				t.Fatalf("closing selection dispatched frames: paid=%d probes=%d (only original probe allowed)", paidFrames, probeFrames)
			}
			for _, table := range []string{"settlement_route_snapshots", "settlement_receipt_verdicts", "ledger_request_credits"} {
				var count int
				if err = db.QueryRow("SELECT count(*) FROM " + table).Scan(&count); err != nil {
					t.Fatal(err)
				}
				if count != 0 {
					t.Fatalf("closing selection created %s rows=%d", table, count)
				}
			}
			if s.settledQuotaTokens() != 0 {
				t.Fatal("closing selection debited buyer")
			}
			id, state := build1LatestAdmission(t, db)
			if rejectRevocation {
				if id != originalID || state != "settlement_capable" {
					t.Fatal("revocation fault did not preserve positive event")
				}
			} else if state != "revoked" {
				t.Fatalf("route did not attempt revocation: %s", state)
			}
			// The deferred close has not removed this exact session as an accidental aid.
			alive := build1PoolProvider(t, s)
			if alive["assigned_id"] != before["assigned_id"] || alive["state"] != "ready" {
				t.Fatal("eventual cleanup or reversible readiness hid route assertion")
			}
			t.Log("S2-T11 real HTTP: scheduled blacklist, ready revival, first buyer selection rejected before status; no dispatch/payable artifact record; fixture only")
		})
	}
}
func build1AwaitSignal(t *testing.T, ch <-chan struct{}) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(5 * time.Second):
		t.Fatal("fixture transport barrier timeout")
	}
}
func build1LatestAdmission(t *testing.T, db *sql.DB) (string, string) {
	t.Helper()
	var id, state string
	if err := db.QueryRow(`SELECT coordinator_event_id,state FROM model_admission_events ORDER BY id DESC LIMIT 1`).Scan(&id, &state); err != nil {
		t.Fatal(err)
	}
	return id, state
}
func build1PoolProvider(t *testing.T, s *scenario) map[string]any {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, s.coordProvURL+"/poolz", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+s.operatorKey)
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var doc struct {
		Pool []map[string]any `json:"pool"`
	}
	if err = json.NewDecoder(response.Body).Decode(&doc); err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != 200 || len(doc.Pool) != 1 || doc.Pool[0]["provider_id"] != s.providerID {
		t.Fatal("expected sole fixture provider in registry")
	}
	return doc.Pool[0]
}
