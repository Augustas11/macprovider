package mdm

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"
)

func openTestMDAStore(t *testing.T) *MDAStore {
	t.Helper()
	s, err := OpenMDAStore(filepath.Join(t.TempDir(), "mda.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func TestOpenMDAStoreRequiresPath(t *testing.T) {
	if _, err := OpenMDAStore("  "); err == nil {
		t.Fatal("expected error for blank path")
	}
	s, err := OpenMDAStoreWithManualWALCheckpoint(filepath.Join(t.TempDir(), "sub", "x.db"))
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	var nilStore *MDAStore
	if err := nilStore.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestMDAStoreProofRoundTripUpsertDelete(t *testing.T) {
	s := openTestMDAStore(t)
	ctx := context.Background()
	if _, ok, err := s.LoadProof(ctx, "p1"); err != nil || ok {
		t.Fatalf("missing proof: ok=%v err=%v", ok, err)
	}
	at := time.Date(2026, 1, 2, 3, 4, 5, 6, time.UTC)
	rec := MDAProofRecord{ProviderID: " p1 ", Serial: " abc123 ", MDACertChain: [][]byte{{1, 2}, {3}}, BoundSEKeyHash: []byte{9, 9}, VerifiedAt: at}
	if err := s.SaveProof(ctx, rec); err != nil {
		t.Fatal(err)
	}
	got, ok, err := s.LoadProof(ctx, "p1")
	if err != nil || !ok {
		t.Fatalf("load: ok=%v err=%v", ok, err)
	}
	if got.Serial != "ABC123" || got.ProviderID != "p1" || !got.VerifiedAt.Equal(at) ||
		len(got.MDACertChain) != 2 || !bytes.Equal(got.MDACertChain[0], []byte{1, 2}) || !bytes.Equal(got.BoundSEKeyHash, []byte{9, 9}) {
		t.Fatalf("unexpected record: %+v", got)
	}
	rec.Serial = "zzz"
	if err := s.SaveProof(ctx, rec); err != nil {
		t.Fatal(err)
	}
	got, _, _ = s.LoadProof(ctx, "p1")
	if got.Serial != "ZZZ" {
		t.Fatalf("upsert did not replace serial: %q", got.Serial)
	}
	if err := s.DeleteProof(ctx, "p1"); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := s.LoadProof(ctx, "p1"); ok {
		t.Fatal("proof still present after delete")
	}
}

func TestMDAStoreLoadProofCorruptRows(t *testing.T) {
	s := openTestMDAStore(t)
	ctx := context.Background()
	exec := func(q string) {
		t.Helper()
		if _, err := s.db.ExecContext(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	exec(`INSERT INTO mda_proofs VALUES('badjson','S','not-json',x'01','2026-01-01T00:00:00Z')`)
	exec(`INSERT INTO mda_proofs VALUES('badts','S','[]',x'01','yesterday')`)
	exec(`INSERT INTO mda_proofs VALUES('badb64','S','["!!"]',x'01','2026-01-01T00:00:00Z')`)
	exec(`INSERT INTO mda_proofs VALUES('rfc','S','[]',x'01','2026-01-01T00:00:00Z')`)
	for _, id := range []string{"badjson", "badts", "badb64"} {
		if _, ok, err := s.LoadProof(ctx, id); err == nil || ok {
			t.Fatalf("%s: expected error, ok=%v err=%v", id, ok, err)
		}
	}
	got, ok, err := s.LoadProof(ctx, "rfc")
	if err != nil || !ok || !got.VerifiedAt.Equal(time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("RFC3339 fallback: %+v ok=%v err=%v", got, ok, err)
	}
}

func TestMDAStoreEnqueueLedger(t *testing.T) {
	s := openTestMDAStore(t)
	ctx := context.Background()
	if _, ok, err := s.LoadEnqueueLedger(ctx, "k"); err != nil || ok {
		t.Fatalf("missing: ok=%v err=%v", ok, err)
	}
	at := time.Date(2026, 5, 6, 7, 8, 9, 0, time.UTC)
	rec := EnqueueLedgerRecord{LedgerKey: "k", ProviderID: " p ", Serial: "sn", SEKeyHash: []byte{1}, LastEnqueueAt: at, PendingCommandUUID: " c1 ", TerminalOutcome: " success "}
	if err := s.SaveEnqueueLedger(ctx, rec); err != nil {
		t.Fatal(err)
	}
	rec.PendingCommandUUID = "c2"
	rec.TerminalOutcome = "failed"
	if err := s.SaveEnqueueLedger(ctx, rec); err != nil {
		t.Fatal(err)
	}
	got, ok, err := s.LoadEnqueueLedger(ctx, "k")
	if err != nil || !ok {
		t.Fatalf("load: ok=%v err=%v", ok, err)
	}
	if got.ProviderID != "p" || got.Serial != "SN" || got.PendingCommandUUID != "c2" || got.TerminalOutcome != "failed" || !got.LastEnqueueAt.Equal(at) {
		t.Fatalf("unexpected: %+v", got)
	}
	if _, err := s.db.ExecContext(ctx, `UPDATE mda_enqueue_ledger SET last_enqueue_at='bad'`); err != nil {
		t.Fatal(err)
	}
	if _, ok, err := s.LoadEnqueueLedger(ctx, "k"); err == nil || ok {
		t.Fatalf("bad timestamp should error: ok=%v err=%v", ok, err)
	}
	if err := s.DeleteEnqueueLedger(ctx, "k"); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := s.LoadEnqueueLedger(ctx, "k"); ok {
		t.Fatal("ledger row survived delete")
	}
}

func TestMDAStorePending(t *testing.T) {
	s := openTestMDAStore(t)
	ctx := context.Background()
	if err := s.SavePending(ctx, PendingMDARecord{UDID: "u"}); err == nil {
		t.Fatal("expected error for missing command uuid")
	}
	at := time.Date(2026, 3, 3, 3, 3, 3, 0, time.UTC)
	save := func(cmd, udid string) {
		t.Helper()
		if err := s.SavePending(ctx, PendingMDARecord{ProviderID: "p", AssignedID: "a", Serial: "sn", UDID: udid, SEKeyHash: []byte{7}, CommandUUID: cmd, EnqueuedAt: at}); err != nil {
			t.Fatal(err)
		}
	}
	save("c1", "u1")
	save("c2", "u2")
	save("c3", "u3")
	got, ok, err := s.LoadPendingByCommandUUID(ctx, " c1 ")
	if err != nil || !ok || got.UDID != "u1" || got.Serial != "SN" || !got.EnqueuedAt.Equal(at) || !bytes.Equal(got.SEKeyHash, []byte{7}) {
		t.Fatalf("by command: %+v ok=%v err=%v", got, ok, err)
	}
	got, ok, err = s.LoadPendingByUDID(ctx, "u2")
	if err != nil || !ok || got.CommandUUID != "c2" {
		t.Fatalf("by udid: %+v ok=%v err=%v", got, ok, err)
	}
	if _, ok, _ := s.LoadPendingByUDID(ctx, "nope"); ok {
		t.Fatal("unexpected match")
	}
	// DeletePending: both empty is a no-op; command only; udid only; either.
	if err := s.DeletePending(ctx, "", " "); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := s.LoadPendingByCommandUUID(ctx, "c1"); !ok {
		t.Fatal("no-op delete removed a row")
	}
	if err := s.DeletePending(ctx, "c1", ""); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := s.LoadPendingByCommandUUID(ctx, "c1"); ok {
		t.Fatal("c1 not deleted")
	}
	if err := s.DeletePending(ctx, "", "u2"); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := s.LoadPendingByCommandUUID(ctx, "c2"); ok {
		t.Fatal("c2 not deleted by udid")
	}
	if _, ok, _ := s.LoadPendingByCommandUUID(ctx, "c3"); !ok {
		t.Fatal("c3 should remain")
	}
	if err := s.DeletePending(ctx, "zzz", "u3"); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := s.LoadPendingByCommandUUID(ctx, "c3"); ok {
		t.Fatal("c3 not deleted by udid with mismatched command")
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO mda_pending VALUES('bad','p','a','S','u9',x'01','nonsense')`); err != nil {
		t.Fatal(err)
	}
	if _, ok, err := s.LoadPendingByCommandUUID(ctx, "bad"); err == nil || ok {
		t.Fatalf("bad timestamp should error: ok=%v err=%v", ok, err)
	}
}

func TestMDAStoreBindings(t *testing.T) {
	s := openTestMDAStore(t)
	ctx := context.Background()
	if err := s.SaveBinding(ctx, DeviceBindingRecord{ProviderID: "p", Serial: " "}); err == nil {
		t.Fatal("expected error for blank serial")
	}
	if err := s.SaveBinding(ctx, DeviceBindingRecord{ProviderID: " ", Serial: "S"}); err == nil {
		t.Fatal("expected error for blank provider")
	}
	at := time.Date(2026, 4, 4, 4, 4, 4, 0, time.UTC)
	for _, r := range []DeviceBindingRecord{
		{ProviderID: "p1", Serial: "s1", UDID: " u1 ", ClaimedAt: at},
		{ProviderID: "p2", Serial: "s2", ClaimedAt: at},
		{ProviderID: "p1", Serial: "s1b", UDID: "u1b", ClaimedAt: at},
	} {
		if err := s.SaveBinding(ctx, r); err != nil {
			t.Fatal(err)
		}
	}
	all, err := s.LoadAllBindings(ctx)
	if err != nil || len(all) != 2 {
		t.Fatalf("all=%+v err=%v", all, err)
	}
	by := map[string]DeviceBindingRecord{}
	for _, r := range all {
		by[r.ProviderID] = r
	}
	if by["p1"].Serial != "S1B" || by["p1"].UDID != "u1b" || !by["p1"].ClaimedAt.Equal(at) {
		t.Fatalf("p1 not upserted: %+v", by["p1"])
	}
	if err := s.DeleteBinding(ctx, "p1"); err != nil {
		t.Fatal(err)
	}
	if err := s.DeleteBindingBySerial(ctx, " s2 "); err != nil {
		t.Fatal(err)
	}
	if all, _ := s.LoadAllBindings(ctx); len(all) != 0 {
		t.Fatalf("bindings remain: %+v", all)
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO mda_device_bindings VALUES('p','S','','junk')`); err != nil {
		t.Fatal(err)
	}
	if _, err := s.LoadAllBindings(ctx); err == nil {
		t.Fatal("expected timestamp parse error")
	}
}

func TestNilMDAStoreIsNoop(t *testing.T) {
	var s *MDAStore
	ctx := context.Background()
	if err := s.SaveProof(ctx, MDAProofRecord{}); err != nil {
		t.Fatal(err)
	}
	if _, ok, err := s.LoadProof(ctx, "p"); ok || err != nil {
		t.Fatal("nil store LoadProof")
	}
	if _, ok, err := s.LoadPendingByUDID(ctx, "u"); ok || err != nil {
		t.Fatal("nil store LoadPendingByUDID")
	}
	if all, err := s.LoadAllBindings(ctx); all != nil || err != nil {
		t.Fatal("nil store LoadAllBindings")
	}
	if err := s.SaveBinding(ctx, DeviceBindingRecord{}); err != nil {
		t.Fatal("nil store SaveBinding")
	}
}

func TestExtractWebhookUDID(t *testing.T) {
	cases := map[string]string{
		`{"udid":" A "}`:                                       "A",
		`{"UDID":"B"}`:                                         "B",
		`{"udid":"  ","UDID":"B2"}`:                            "B2",
		`{"payload":{"UDID":"C"}}`:                             "C",
		`{"payload":{"udid":"C2"}}`:                            "C2",
		`{"acknowledge_event":{"udid":"D"}}`:                   "D",
		`{"acknowledge_event":{"UDID":"D2"}}`:                  "D2",
		`{"payload":{"x":1},"acknowledge_event":{"udid":"E"}}`: "E",
		`{"udid":5}`:                                           "",
		`not json`:                                             "",
		`{}`:                                                   "",
	}
	for in, want := range cases {
		if got := extractWebhookUDID([]byte(in)); got != want {
			t.Errorf("%s: got %q want %q", in, got, want)
		}
	}
}

func TestParseAcknowledgeEventTopicAndPayload(t *testing.T) {
	if _, err := ParseAcknowledgeEvent([]byte(`{"topic":"mdm.CheckIn","acknowledge_event":{"udid":"u"}}`)); err == nil {
		t.Fatal("non-Connect topic must be rejected")
	}
	// Empty raw payload: parse reports no attestation but keeps identifiers.
	out, err := ParseAcknowledgeEvent([]byte(`{"topic":"mdm.Connect","acknowledge_event":{"udid":" u ","command_uuid":"c","status":"Acknowledged"}}`))
	if !errors.Is(err, ErrNoDeviceAttestation) || out == nil || out.UDID != "u" || out.CommandUUID != "c" || out.Status != "Acknowledged" {
		t.Fatalf("out=%+v err=%v", out, err)
	}
	// Raw (non-base64) XML plist with a DeviceAttestation array.
	cert := base64.StdEncoding.EncodeToString([]byte{0x30, 0x03, 0x02, 0x01, 0x01})
	xml := `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>DeviceAttestation</key><array><string>` + cert + `</string></array></dict></plist>`
	body, _ := json.Marshal(map[string]any{"acknowledge_event": map[string]any{"udid": "u", "raw_payload": xml}})
	out, err = ParseAcknowledgeEvent(body)
	if err != nil || out.Result == nil || len(out.Result.CertificateChain) != 1 {
		t.Fatalf("out=%+v err=%v", out, err)
	}
	// Garbage payload surfaces a plist decode error.
	body, _ = json.Marshal(map[string]any{"acknowledge_event": map[string]any{"raw_payload": "<<<"}})
	if _, err = ParseAcknowledgeEvent(body); err == nil {
		t.Fatal("expected plist decode error")
	}
	// Plist without attestation.
	nope := `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>X</key><string>y</string></dict></plist>`
	body, _ = json.Marshal(map[string]any{"acknowledge_event": map[string]any{"raw_payload": nope}})
	if _, err = ParseAcknowledgeEvent(body); !errors.Is(err, ErrNoDeviceAttestation) {
		t.Fatalf("err=%v", err)
	}
	// Legacy flat JSON fallback carries the UDID.
	out, err = ParseAcknowledgeEvent([]byte(`{"udid":"legacy","DeviceAttestation":["` + cert + `"]}`))
	if err != nil || out.UDID != "legacy" || len(out.Result.CertificateChain) != 1 {
		t.Fatalf("legacy out=%+v err=%v", out, err)
	}
}

func TestExtractDeviceAttestationCertsErrorsAndEncodings(t *testing.T) {
	if _, err := extractDeviceAttestationCerts([]interface{}{1.0}); err == nil {
		t.Fatal("non-string element must error")
	}
	if _, err := extractDeviceAttestationCerts([]interface{}{"***"}); err == nil {
		t.Fatal("bad base64 element must error")
	}
	if _, err := extractDeviceAttestationCerts("***"); err == nil {
		t.Fatal("bad base64 string must error")
	}
	if _, err := extractDeviceAttestationCerts(42); err == nil {
		t.Fatal("unexpected type must error")
	}
	// 1- and 2-byte payloads need padding in the padded encodings, so the
	// unpadded raw variants are only decodable by the raw decoders.
	for _, der := range [][]byte{{0xfb}, {0xfb, 0xff}} {
		for name, enc := range map[string]*base64.Encoding{"std": base64.StdEncoding, "url": base64.URLEncoding, "rawstd": base64.RawStdEncoding, "rawurl": base64.RawURLEncoding} {
			got, err := decodeBase64Cert(" " + enc.EncodeToString(der) + " ")
			if err != nil || !bytes.Equal(got, der) {
				t.Errorf("%s %x: got %x err=%v", name, der, got, err)
			}
		}
	}
	// Opaque non-cert DER passes through as a single-element chain.
	res, err := extractDeviceAttestationCerts(base64.StdEncoding.EncodeToString([]byte("opaque")))
	if err != nil || len(res.CertificateChain) != 1 || string(res.CertificateChain[0]) != "opaque" {
		t.Fatalf("res=%+v err=%v", res, err)
	}
	// plist []byte values are re-encoded to base64 strings.
	if got := plistValueToJSONCompat([]interface{}{[]byte("ab"), "s", 3}); got.([]interface{})[0] != base64.StdEncoding.EncodeToString([]byte("ab")) {
		t.Fatalf("got %v", got)
	}
	if _, ok := mapAttestationValue(nil); ok {
		t.Fatal("nil map must not match")
	}
	v, ok := mapAttestationValue(map[string]interface{}{"DevicePropertiesAttestation": "a", "DeviceAttestation": "b"})
	if !ok || v != "a" {
		t.Fatalf("Apple key must win: %v", v)
	}
}

func TestClientHTTPErrorPaths(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, pass, ok := r.BasicAuth(); !ok || pass != "tok" {
			t.Errorf("missing basic auth")
		}
		if r.URL.Path == "/bad" {
			http.Error(w, "boom", http.StatusTeapot)
			return
		}
		_, _ = w.Write([]byte("not json"))
	}))
	defer srv.Close()
	c, err := NewClient(ClientConfig{BaseURL: srv.URL + "/", APIToken: "tok"})
	if err != nil {
		t.Fatal(err)
	}
	req, err := c.newRequest(context.Background(), http.MethodGet, "/bad", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.doJSON(req, &struct{}{}); err == nil || !bytes.Contains([]byte(err.Error()), []byte("status 418: boom")) {
		t.Fatalf("err=%v", err)
	}
	req, _ = c.newRequest(context.Background(), http.MethodGet, "/ok", nil)
	if err := c.doJSON(req, &struct{}{}); err == nil {
		t.Fatal("expected JSON decode error")
	}
	if _, err := c.newRequest(context.Background(), "BAD METHOD", "/x", nil); err == nil {
		t.Fatal("expected build error")
	}
	srv.Close()
	req, _ = c.newRequest(context.Background(), http.MethodGet, "/ok", nil)
	if err := c.doJSON(req, &struct{}{}); err == nil {
		t.Fatal("expected transport error")
	}
}
