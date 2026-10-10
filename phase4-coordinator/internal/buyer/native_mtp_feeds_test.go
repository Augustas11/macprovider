package buyer_test

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

type nativeMTPFixture struct {
	dir        string
	keyID      string
	privateKey ed25519.PrivateKey
	cfg        config.AutotuneFeedsConfig
	admission  []byte
	manifest   []byte
	bank       []byte
}

func sha256HexForTest(raw []byte) string {
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

func signedSidecar(t *testing.T, keyID string, privateKey ed25519.PrivateKey, raw []byte) []byte {
	t.Helper()
	sidecar, err := json.Marshal(map[string]string{
		"key_id":    keyID,
		"alg":       "ed25519",
		"signature": base64.StdEncoding.EncodeToString(ed25519.Sign(privateKey, raw)),
	})
	if err != nil {
		t.Fatal(err)
	}
	return sidecar
}

func nativeMTPAdmissionBody(releaseID, keyID, manifestSHA, bankSHA string) []byte {
	return []byte(fmt.Sprintf(
		`{"schema_version":"macprovider.native-mtp-admission.v1","release_id":%q,"issued_at":"2026-10-01T00:00:00Z","expires_at":"2026-12-25T00:00:00Z","signer_key_id":%q,"challenge_bank_signer_key_id":%q,"revocation_signer_key_id":%q,"entries":[{"artifact_manifest_sha256":%q,"challenge_bank_sha256":%q,"model_key":"test-model"}]}`,
		releaseID, keyID, keyID, keyID, manifestSHA, bankSHA,
	))
}

// newNativeMTPFixture writes a complete signed release (three base feeds
// plus the native-MTP admission set) and an empty revocation slot directory.
func newNativeMTPFixture(t *testing.T) nativeMTPFixture {
	t.Helper()
	dir := t.TempDir()
	publicKey, privateKey := testSigningKey(t)
	keyID := "streamvc-autotune-static-test"
	candidateJSON, candidateSig := writeSignedFeedPair(t, dir, "autotune-candidates", validCandidateFeed("release-native-1"), keyID, privateKey)
	cfg := completeCandidateFeedConfig(t, dir, candidateJSON, candidateSig, keyID, publicKey, privateKey)

	manifest := []byte(`{"schema_version":"macprovider.native-mtp-artifact-manifest.v1"}`)
	bank := []byte(`{"schema_version":"macprovider.native-mtp-challenge-bank.v1","challenges":[]}`)
	admission := nativeMTPAdmissionBody("release-native-1", keyID, sha256HexForTest(manifest), sha256HexForTest(bank))
	write := func(name string, raw []byte) string {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, raw, 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	cfg.NativeMTPAdmissionPath = write("native-mtp-admission.json", admission)
	cfg.NativeMTPAdmissionSigPath = write("native-mtp-admission.json.sig", signedSidecar(t, keyID, privateKey, admission))
	cfg.NativeMTPArtifactManifestPath = write("native-mtp-artifact-manifest.json", manifest)
	cfg.NativeMTPSelftestBankPath = write("native-mtp-selftest-bank.json", bank)
	cfg.NativeMTPSelftestBankSigPath = write("native-mtp-selftest-bank.json.sig", signedSidecar(t, keyID, privateKey, bank))
	revocations := filepath.Join(dir, "revocations")
	if err := os.Mkdir(revocations, 0o700); err != nil {
		t.Fatal(err)
	}
	cfg.NativeMTPRevocationsDir = revocations
	return nativeMTPFixture{dir: dir, keyID: keyID, privateKey: privateKey, cfg: cfg, admission: admission, manifest: manifest, bank: bank}
}

func (f nativeMTPFixture) writeRevocationSlot(t *testing.T, generation uint64, issuedAt time.Time, window time.Duration) []byte {
	t.Helper()
	body := []byte(fmt.Sprintf(
		`{"schema_version":"macprovider.native-mtp-revocations.v1","generation":%d,"issued_at":%q,"expires_at":%q,"signer_key_id":%q,"revoked_admission_tuple_sha256":[]}`,
		generation, issuedAt.UTC().Format(time.RFC3339), issuedAt.Add(window).UTC().Format(time.RFC3339), f.keyID,
	))
	name := filepath.Join(f.cfg.NativeMTPRevocationsDir, fmt.Sprintf("%d.json", generation))
	if err := os.WriteFile(name, body, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(name+".sig", signedSidecar(t, f.keyID, f.privateKey, body), 0o600); err != nil {
		t.Fatal(err)
	}
	return body
}

func nativeMTPHandler(t *testing.T, cfg config.AutotuneFeedsConfig) http.Handler {
	t.Helper()
	feeds, err := buyer.LoadAutotuneFeeds(cfg)
	if err != nil {
		t.Fatalf("LoadAutotuneFeeds: %v", err)
	}
	return buyer.NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithAutotuneFeeds(feeds)).Handler()
}

func getForTest(handler http.Handler, path string) *httptest.ResponseRecorder {
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, path, nil))
	return rr
}

func TestNativeMTPAdmissionSetServesLiteralBytes(t *testing.T) {
	t.Parallel()
	fixture := newNativeMTPFixture(t)
	handler := nativeMTPHandler(t, fixture.cfg)
	for path, want := range map[string][]byte{
		"/v1/native-mtp-admission":         fixture.admission,
		"/v1/native-mtp-artifact-manifest": fixture.manifest,
		"/v1/native-mtp-selftest-bank":     fixture.bank,
	} {
		rr := getForTest(handler, path)
		if rr.Code != http.StatusOK || !bytes.Equal(rr.Body.Bytes(), want) {
			t.Fatalf("%s status=%d body=%s", path, rr.Code, rr.Body.String())
		}
	}
	for _, path := range []string{"/v1/native-mtp-admission.sig", "/v1/native-mtp-selftest-bank.sig"} {
		if rr := getForTest(handler, path); rr.Code != http.StatusOK || !strings.Contains(rr.Body.String(), `"key_id"`) {
			t.Fatalf("%s status=%d body=%s", path, rr.Code, rr.Body.String())
		}
	}
}

func TestNativeMTPAdmissionSetFailsClosedOnMisbinding(t *testing.T) {
	t.Parallel()
	cases := map[string]func(t *testing.T, f *nativeMTPFixture){
		"partial set": func(t *testing.T, f *nativeMTPFixture) { f.cfg.NativeMTPRevocationsDir = "" },
		"wrong release": func(t *testing.T, f *nativeMTPFixture) {
			body := nativeMTPAdmissionBody("release-other", f.keyID, sha256HexForTest(f.manifest), sha256HexForTest(f.bank))
			rewriteSigned(t, f, f.cfg.NativeMTPAdmissionPath, f.cfg.NativeMTPAdmissionSigPath, body)
		},
		"manifest drift": func(t *testing.T, f *nativeMTPFixture) {
			if err := os.WriteFile(f.cfg.NativeMTPArtifactManifestPath, []byte(`{"drift":true}`), 0o600); err != nil {
				t.Fatal(err)
			}
		},
		"bank drift": func(t *testing.T, f *nativeMTPFixture) {
			rewriteSigned(t, f, f.cfg.NativeMTPSelftestBankPath, f.cfg.NativeMTPSelftestBankSigPath, []byte(`{"drift":true}`))
		},
		"unsigned bank": func(t *testing.T, f *nativeMTPFixture) {
			_, other := testSigningKey(t)
			if err := os.WriteFile(f.cfg.NativeMTPSelftestBankSigPath, signedSidecar(t, f.keyID, other, f.bank), 0o600); err != nil {
				t.Fatal(err)
			}
		},
		"tampered admission": func(t *testing.T, f *nativeMTPFixture) {
			if err := os.WriteFile(f.cfg.NativeMTPAdmissionPath, bytes.Replace(f.admission, []byte("test-model"), []byte("evil-model"), 1), 0o600); err != nil {
				t.Fatal(err)
			}
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			fixture := newNativeMTPFixture(t)
			mutate(t, &fixture)
			if _, err := buyer.LoadAutotuneFeeds(fixture.cfg); err == nil {
				t.Fatal("LoadAutotuneFeeds accepted a misbound native-MTP admission set")
			}
		})
	}
}

func rewriteSigned(t *testing.T, f *nativeMTPFixture, jsonPath, sigPath string, raw []byte) {
	t.Helper()
	if err := os.WriteFile(jsonPath, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(sigPath, signedSidecar(t, f.keyID, f.privateKey, raw), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestNativeMTPRevocationFeedServesTheNewestIssuedSlot(t *testing.T) {
	t.Parallel()
	fixture := newNativeMTPFixture(t)
	now := time.Now().UTC().Truncate(time.Second)
	fixture.writeRevocationSlot(t, 1, now.Add(-30*time.Minute), time.Hour)
	current := fixture.writeRevocationSlot(t, 2, now.Add(-5*time.Minute), time.Hour)
	fixture.writeRevocationSlot(t, 3, now.Add(10*time.Minute), time.Hour) // not yet issued
	// A slot whose signature does not verify is never served, even if newest.
	forged := []byte(fmt.Sprintf(
		`{"schema_version":"macprovider.native-mtp-revocations.v1","generation":4,"issued_at":%q,"expires_at":%q,"signer_key_id":%q,"revoked_admission_tuple_sha256":[]}`,
		now.Add(-time.Minute).Format(time.RFC3339), now.Add(59*time.Minute).Format(time.RFC3339), fixture.keyID,
	))
	_, other := testSigningKey(t)
	forgedPath := filepath.Join(fixture.cfg.NativeMTPRevocationsDir, "4.json")
	if err := os.WriteFile(forgedPath, forged, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(forgedPath+".sig", signedSidecar(t, fixture.keyID, other, forged), 0o600); err != nil {
		t.Fatal(err)
	}
	handler := nativeMTPHandler(t, fixture.cfg)

	path := "/v1/native-mtp-revocations." + fixture.keyID + ".json"
	rr := getForTest(handler, path)
	if rr.Code != http.StatusOK || !bytes.Equal(rr.Body.Bytes(), current) {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("Cache-Control=%q", rr.Header().Get("Cache-Control"))
	}
	sig := getForTest(handler, path+".sig")
	if sig.Code != http.StatusOK || !strings.Contains(sig.Body.String(), fixture.keyID) {
		t.Fatalf("sig status=%d body=%s", sig.Code, sig.Body.String())
	}
	for _, wrong := range []string{
		"/v1/native-mtp-revocations.other-key.json",
		"/v1/native-mtp-revocations." + fixture.keyID + ".txt",
	} {
		if rr := getForTest(handler, wrong); rr.Code != http.StatusNotFound {
			t.Fatalf("%s status=%d want 404", wrong, rr.Code)
		}
	}
}

func TestNativeMTPRevocationFeedAnswers404WithoutAnIssuedSlot(t *testing.T) {
	t.Parallel()
	fixture := newNativeMTPFixture(t)
	now := time.Now().UTC().Truncate(time.Second)
	fixture.writeRevocationSlot(t, 2, now.Add(time.Hour), time.Hour) // future
	handler := nativeMTPHandler(t, fixture.cfg)
	if rr := getForTest(handler, "/v1/native-mtp-revocations."+fixture.keyID+".json"); rr.Code != http.StatusNotFound {
		t.Fatalf("status=%d want 404", rr.Code)
	}
}

// #1938: once every pre-signed slot has passed expires_at, the newest issued
// slot keeps being served; a future slot is still withheld.
func TestNativeMTPRevocationFeedServesNewestIssuedSlotPastExpiry(t *testing.T) {
	t.Parallel()
	fixture := newNativeMTPFixture(t)
	now := time.Now().UTC().Truncate(time.Second)
	fixture.writeRevocationSlot(t, 1, now.Add(-3*time.Hour), time.Hour)
	fixture.writeRevocationSlot(t, 2, now.Add(-2*time.Hour), time.Hour)
	fixture.writeRevocationSlot(t, 3, now.Add(time.Hour), time.Hour)
	handler := nativeMTPHandler(t, fixture.cfg)
	rr := getForTest(handler, "/v1/native-mtp-revocations."+fixture.keyID+".json")
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d want 200", rr.Code)
	}
	if !strings.Contains(rr.Body.String(), `"generation":2`) {
		t.Fatalf("served %s, want generation 2", rr.Body.String())
	}
}

func TestNativeMTPFeedsDisabledWhenUnset(t *testing.T) {
	t.Parallel()
	handler := buyer.NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Unix(1716768000, 0)).Handler()
	for _, path := range []string{
		"/v1/native-mtp-admission",
		"/v1/native-mtp-admission.sig",
		"/v1/native-mtp-artifact-manifest",
		"/v1/native-mtp-selftest-bank",
		"/v1/native-mtp-selftest-bank.sig",
		"/v1/native-mtp-revocations.streamvc-autotune-static-v4.json",
	} {
		if rr := getForTest(handler, path); rr.Code != http.StatusNotFound {
			t.Fatalf("%s status=%d want 404", path, rr.Code)
		}
	}
}
