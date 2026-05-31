package tier2

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

const testHash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
const otherHash = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

func TestLoadCatalogVerifiesKnownGoodFixture(t *testing.T) {
	defer ResetForTest()
	raw, publicKey := signedCatalogFixture(t, time.Now().UTC().Add(time.Hour), testHash)
	path := writeTempCatalog(t, raw)

	catalog, err := LoadCatalog(path, publicKey, zerolog.Nop())
	if err != nil {
		t.Fatalf("LoadCatalog: %v", err)
	}
	if catalog.CatalogID != "test-catalog" {
		t.Fatalf("catalog_id=%q", catalog.CatalogID)
	}
	if got := catalog.Models["model-a"].SHA256; got != testHash {
		t.Fatalf("sha=%q", got)
	}
}

func TestLoadCatalogLogsSuccessfulActivation(t *testing.T) {
	defer ResetForTest()
	raw, publicKey := signedCatalogFixture(t, time.Now().UTC().Add(time.Hour), testHash)
	path := writeTempCatalog(t, raw)
	var logs bytes.Buffer

	if _, err := LoadCatalog(path, publicKey, zerolog.New(&logs)); err != nil {
		t.Fatalf("LoadCatalog: %v", err)
	}

	rawLog := logs.String()
	for _, want := range []string{
		`"event":"catalog_loaded"`,
		`"category":"T2.A"`,
		`"severity":"INFO"`,
		`"catalog_id":"test-catalog"`,
		`"model_count":1`,
		`"message":"tier2 catalog loaded"`,
	} {
		if !strings.Contains(rawLog, want) {
			t.Fatalf("catalog load log missing %s: %s", want, rawLog)
		}
	}
}

func TestLoadCatalogRejectsCorruptedBodyAndLogsSignatureInvalid(t *testing.T) {
	defer ResetForTest()
	raw, publicKey := signedCatalogFixture(t, time.Now().UTC().Add(time.Hour), testHash)
	corrupted := bytes.Replace(raw, []byte("model-a"), []byte("model-b"), 1)
	path := writeTempCatalog(t, corrupted)
	var logs bytes.Buffer
	logger := zerolog.New(&logs)

	_, err := LoadCatalog(path, publicKey, logger)
	if err == nil {
		t.Fatal("LoadCatalog succeeded, want signature failure")
	}
	if !strings.Contains(logs.String(), `"event":"catalog_signature_invalid"`) {
		t.Fatalf("logs did not include catalog_signature_invalid: %s", logs.String())
	}
}

func TestLoadCatalogRejectsExpiredCatalog(t *testing.T) {
	defer ResetForTest()
	raw, publicKey := signedCatalogFixture(t, time.Now().UTC().Add(-time.Hour), testHash)
	path := writeTempCatalog(t, raw)

	_, err := LoadCatalog(path, publicKey, zerolog.Nop())
	if err == nil || !strings.Contains(err.Error(), "catalog expired") {
		t.Fatalf("LoadCatalog err=%v, want expired", err)
	}
}

func TestActiveCatalogExpiresAtUseTime(t *testing.T) {
	defer ResetForTest()
	base := time.Now().UTC()
	nowUTC = func() time.Time { return base }
	raw, publicKey := signedCatalogFixture(t, base.Add(time.Hour), testHash)
	path := writeTempCatalog(t, raw)
	cfg := config.Default()
	cfg.Tier2.CatalogPath = path
	cfg.Tier2.CatalogPublicKey = publicKey
	if err := Configure(cfg.Tier2, zerolog.Nop()); err != nil {
		t.Fatalf("Configure: %v", err)
	}
	if !Active() {
		t.Fatal("catalog should be active before expiry")
	}

	nowUTC = func() time.Time { return base.Add(2 * time.Hour) }

	if Active() {
		t.Fatal("expired catalog should not remain active")
	}
	if !CatalogUnavailable() {
		t.Fatal("expired configured catalog should be unavailable")
	}
	if Catalogued("model-a") {
		t.Fatal("expired catalog should not mark model catalogued")
	}
	if got := VerifyProviderHash("model-a", testHash); got != pool.HashStatusCatalogUnavailable {
		t.Fatalf("VerifyProviderHash after expiry=%q want %q", got, pool.HashStatusCatalogUnavailable)
	}
}

func TestVerifyProviderHashStatuses(t *testing.T) {
	defer ResetForTest()
	raw, publicKey := signedCatalogFixture(t, time.Now().UTC().Add(time.Hour), testHash)
	path := writeTempCatalog(t, raw)
	cfg := config.Default()
	cfg.Tier2.CatalogPath = path
	cfg.Tier2.CatalogPublicKey = publicKey
	if err := Configure(cfg.Tier2, zerolog.Nop()); err != nil {
		t.Fatalf("Configure: %v", err)
	}

	tests := []struct {
		name         string
		modelID      string
		reportedHash string
		want         pool.HashStatus
	}{
		{name: "match", modelID: "model-a", reportedHash: testHash, want: pool.HashStatusVerified},
		{name: "mismatch", modelID: "model-a", reportedHash: otherHash, want: pool.HashStatusMismatch},
		{name: "empty", modelID: "model-a", reportedHash: "", want: pool.HashStatusUncatalogued},
		{name: "invalid", modelID: "model-a", reportedHash: "not-a-sha", want: pool.HashStatusInvalid},
		{name: "unknown", modelID: "unknown-model", reportedHash: testHash, want: pool.HashStatusUncatalogued},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := VerifyProviderHash(tc.modelID, tc.reportedHash); got != tc.want {
				t.Fatalf("VerifyProviderHash=%q want %q", got, tc.want)
			}
		})
	}
}

func TestVerifyProviderHashUsesCaseInsensitiveModelIDLookup(t *testing.T) {
	defer ResetForTest()
	raw, publicKey := signedCatalogFixture(t, time.Now().UTC().Add(time.Hour), testHash)
	path := writeTempCatalog(t, raw)
	cfg := config.Default()
	cfg.Tier2.CatalogPath = path
	cfg.Tier2.CatalogPublicKey = publicKey
	if err := Configure(cfg.Tier2, zerolog.Nop()); err != nil {
		t.Fatalf("Configure: %v", err)
	}

	if got := VerifyProviderHash("MODEL-A", otherHash); got != pool.HashStatusMismatch {
		t.Fatalf("VerifyProviderHash case-only model drift=%q want %q", got, pool.HashStatusMismatch)
	}
	if got := VerifyProviderHash("MODEL-A", testHash); got != pool.HashStatusVerified {
		t.Fatalf("VerifyProviderHash uppercase match=%q want %q", got, pool.HashStatusVerified)
	}
}

func TestConfigurePreservesPreviousCatalogOnReloadFailure(t *testing.T) {
	defer ResetForTest()
	raw, publicKey := signedCatalogFixture(t, time.Now().UTC().Add(time.Hour), testHash)
	path := writeTempCatalog(t, raw)
	cfg := config.Default()
	cfg.Tier2.CatalogPath = path
	cfg.Tier2.CatalogPublicKey = publicKey
	if err := Configure(cfg.Tier2, zerolog.Nop()); err != nil {
		t.Fatalf("initial Configure: %v", err)
	}

	cfg.Tier2.CatalogPath = writeTempCatalog(t, bytes.Replace(raw, []byte("model-a"), []byte("model-b"), 1))
	if err := Configure(cfg.Tier2, zerolog.Nop()); err != nil {
		t.Fatalf("reload Configure should preserve previous catalog when enforcement is off: %v", err)
	}
	if !Active() || CatalogID() != "test-catalog" {
		t.Fatalf("active catalog not preserved: active=%v catalog_id=%q", Active(), CatalogID())
	}
	if CatalogUnavailable() {
		t.Fatal("preserved active catalog should not be unavailable")
	}
	if got := VerifyProviderHash("model-a", testHash); got != pool.HashStatusVerified {
		t.Fatalf("VerifyProviderHash after failed reload=%q want %q", got, pool.HashStatusVerified)
	}
}

func TestParseCatalogRejectsUnknownFieldsDuplicateModelsAndBadSemantics(t *testing.T) {
	t.Run("unknown top-level field", func(t *testing.T) {
		raw, publicKey := signedCatalogFixture(t, time.Now().UTC().Add(time.Hour), testHash)
		var file map[string]any
		if err := json.Unmarshal(raw, &file); err != nil {
			t.Fatalf("unmarshal fixture: %v", err)
		}
		file["unexpected"] = true
		withUnknown, err := json.Marshal(file)
		if err != nil {
			t.Fatalf("marshal unknown fixture: %v", err)
		}
		if _, err := ParseCatalog(withUnknown, publicKey); err == nil || !strings.Contains(err.Error(), "unknown field") {
			t.Fatalf("ParseCatalog err=%v, want unknown field rejection", err)
		}
	})

	t.Run("duplicate model id", func(t *testing.T) {
		raw, publicKey := signedCatalogFixtureWithModels(t, time.Now().UTC().Add(time.Hour), []ModelEntry{
			validModelEntry("model-a", testHash),
			validModelEntry("model-a", otherHash),
		})
		if _, err := ParseCatalog(raw, publicKey); err == nil || !strings.Contains(err.Error(), "duplicate catalog model_id") {
			t.Fatalf("ParseCatalog err=%v, want duplicate model rejection", err)
		}
	})

	t.Run("case-insensitive duplicate model id", func(t *testing.T) {
		raw, publicKey := signedCatalogFixtureWithModels(t, time.Now().UTC().Add(time.Hour), []ModelEntry{
			validModelEntry("model-a", testHash),
			validModelEntry("MODEL-A", otherHash),
		})
		if _, err := ParseCatalog(raw, publicKey); err == nil || !strings.Contains(err.Error(), "duplicate catalog model_id") {
			t.Fatalf("ParseCatalog err=%v, want case-insensitive duplicate model rejection", err)
		}
	})

	t.Run("unsupported hash scope", func(t *testing.T) {
		model := validModelEntry("model-a", testHash)
		model.HashScope = "whole_directory"
		raw, publicKey := signedCatalogFixtureWithModels(t, time.Now().UTC().Add(time.Hour), []ModelEntry{model})
		if _, err := ParseCatalog(raw, publicKey); err == nil || !strings.Contains(err.Error(), "hash_scope") {
			t.Fatalf("ParseCatalog err=%v, want hash_scope rejection", err)
		}
	})
}

func TestTier2AuditEventsIncludeCommonFields(t *testing.T) {
	var logs bytes.Buffer
	LogProviderHashStatus(zerolog.New(&logs), "provider-a", "session-a", "model-a", otherHash, pool.HashStatusMismatch)
	raw := logs.String()
	for _, want := range []string{
		`"event":"model_hash_mismatch"`,
		`"category":"T2.A"`,
		`"request_id":""`,
		`"tier2_phase":1`,
		`"pillar":"A"`,
		`"decision":"exclude"`,
		`"config_flag":"tier2.catalog_path"`,
	} {
		if !strings.Contains(raw, want) {
			t.Fatalf("audit log missing %s: %s", want, raw)
		}
	}
}

func TestUncataloguedHashLogsWarnWhenCatalogActive(t *testing.T) {
	defer ResetForTest()
	raw, publicKey := signedCatalogFixture(t, time.Now().UTC().Add(time.Hour), testHash)
	path := writeTempCatalog(t, raw)
	cfg := config.Default()
	cfg.Tier2.CatalogPath = path
	cfg.Tier2.CatalogPublicKey = publicKey
	if err := Configure(cfg.Tier2, zerolog.Nop()); err != nil {
		t.Fatalf("Configure: %v", err)
	}
	var logs bytes.Buffer

	LogProviderHashStatus(zerolog.New(&logs), "provider-a", "session-a", "unknown-model", testHash, pool.HashStatusUncatalogued)

	rawLog := logs.String()
	for _, want := range []string{
		`"event":"model_hash_uncatalogued"`,
		`"severity":"WARN"`,
		`"decision":"allow"`,
		`"reason":"not_catalogued"`,
	} {
		if !strings.Contains(rawLog, want) {
			t.Fatalf("audit log missing %s: %s", want, rawLog)
		}
	}
}

func signedCatalogFixture(t *testing.T, expiresAt time.Time, sha string) ([]byte, string) {
	t.Helper()
	return signedCatalogFixtureWithModels(t, expiresAt, []ModelEntry{validModelEntry("model-a", sha)})
}

func validModelEntry(modelID, sha string) ModelEntry {
	return ModelEntry{
		ArtifactKind: "mlx_weight_file",
		HashScope:    "primary_weight_file",
		ModelID:      modelID,
		SHA256:       sha,
		Source:       "operator-curated",
	}
}

func signedCatalogFixtureWithModels(t *testing.T, expiresAt time.Time, models []ModelEntry) ([]byte, string) {
	t.Helper()
	seed := bytes.Repeat([]byte{7}, ed25519.SeedSize)
	privateKey := ed25519.NewKeyFromSeed(seed)
	publicKey := privateKey.Public().(ed25519.PublicKey)
	issuedAt := time.Now().UTC().Add(-time.Hour)
	if !issuedAt.Before(expiresAt) {
		issuedAt = expiresAt.Add(-time.Hour)
	}
	body := canonicalBody{
		CatalogID: "test-catalog",
		ExpiresAt: expiresAt.UTC().Format(time.RFC3339),
		IssuedAt:  issuedAt.Format(time.RFC3339),
		Models:    models,
		Version:   1,
	}
	canonical, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("canonical marshal: %v", err)
	}
	sig := ed25519.Sign(privateKey, canonical)
	file := catalogFile{
		CatalogID: body.CatalogID,
		ExpiresAt: body.ExpiresAt,
		IssuedAt:  body.IssuedAt,
		Models:    body.Models,
		Signature: Signature{Alg: "Ed25519", KeyID: "test-key", Sig: base64.RawURLEncoding.EncodeToString(sig)},
		Version:   body.Version,
	}
	raw, err := json.Marshal(file)
	if err != nil {
		t.Fatalf("catalog marshal: %v", err)
	}
	return raw, base64.RawURLEncoding.EncodeToString(publicKey)
}

func writeTempCatalog(t *testing.T, raw []byte) string {
	t.Helper()
	f, err := os.CreateTemp(t.TempDir(), "catalog-*.json")
	if err != nil {
		t.Fatalf("CreateTemp: %v", err)
	}
	if _, err := f.Write(raw); err != nil {
		t.Fatalf("write catalog: %v", err)
	}
	if err := f.Close(); err != nil {
		t.Fatalf("close catalog: %v", err)
	}
	return f.Name()
}
