package config

import (
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/base64"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"gopkg.in/yaml.v3"
)

func TestPrivacyClassDefaultOff(t *testing.T) {
	cfg := Default()
	if cfg.PrivacyClass.Enabled {
		t.Fatal("privacy class enabled by default")
	}
	if cfg.PrivacyClass.PostureChallengeIntervalSeconds != 60 || cfg.PrivacyClass.PostureMaxAgeSeconds != 150 || cfg.PrivacyClass.PostureResponseTimeoutSeconds != 10 || cfg.PrivacyClass.QuarantineSeconds != 86400 {
		t.Fatalf("defaults = %+v", cfg.PrivacyClass)
	}
	if len(cfg.PrivacyClass.AllowedSEKeyBackends) != 2 || cfg.PrivacyClass.AllowedSEKeyBackends[0] != "file" || cfg.PrivacyClass.AllowedSEKeyBackends[1] != "keychain" {
		t.Fatalf("backends = %#v", cfg.PrivacyClass.AllowedSEKeyBackends)
	}
	if len(cfg.PrivacyClass.ProviderSEPublicKeys) != 0 || len(cfg.PrivacyClass.ApprovedCodeIdentities) != 0 {
		t.Fatal("default pins or identities are not empty")
	}

	merged := Default()
	if err := yaml.Unmarshal([]byte("privacy_class:\n  enabled: false\n"), &merged); err != nil {
		t.Fatal(err)
	}
	if merged.PrivacyClass.Enabled || merged.PrivacyClass.PostureChallengeIntervalSeconds != 60 || merged.PrivacyClass.PostureMaxAgeSeconds != 150 || merged.PrivacyClass.PostureResponseTimeoutSeconds != 10 || merged.PrivacyClass.QuarantineSeconds != 86400 {
		t.Fatalf("partial yaml cleared defaults: %+v", merged.PrivacyClass)
	}

	pin := testPrivacySEPin(t)
	expiry := time.Date(2027, 1, 2, 3, 4, 5, 0, time.UTC)
	block := PrivacyClassConfig{
		Enabled:                         false,
		ProviderSEPublicKeys:            map[string]string{"provider-a": pin},
		ApprovedCodeIdentities:          []ApprovedCodeIdentity{testApprovedIdentity(expiry)},
		AllowedSEKeyBackends:            []string{"file", "keychain"},
		PostureChallengeIntervalSeconds: 60,
		PostureMaxAgeSeconds:            150,
		PostureResponseTimeoutSeconds:   10,
		QuarantineSeconds:               86400,
	}
	raw, err := yaml.Marshal(block)
	if err != nil {
		t.Fatal(err)
	}
	var decoded PrivacyClassConfig
	if err := yaml.Unmarshal(raw, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.ProviderSEPublicKeys["provider-a"] != pin {
		t.Fatal("SE pin did not round-trip as standard base64")
	}
	if len(decoded.ApprovedCodeIdentities) != 1 || !decoded.ApprovedCodeIdentities[0].ExpiresAt.Equal(expiry) {
		t.Fatalf("expires_at = %s", decoded.ApprovedCodeIdentities[0].ExpiresAt)
	}
}

func TestPrivacyClassValidation(t *testing.T) {
	disabled := validTestConfig()
	disabled.PrivacyClass.AllowedSEKeyBackends = nil
	if err := disabled.Validate(); err != nil {
		t.Fatal(err)
	}
	disabled.PrivacyClass.PostureChallengeIntervalSeconds = 0
	if err := disabled.Validate(); err == nil || !strings.Contains(err.Error(), "posture_challenge_interval_seconds") {
		t.Fatalf("interval 0 = %v", err)
	}
	disabled = validTestConfig()
	disabled.PrivacyClass.AllowedSEKeyBackends = []string{"software"}
	if err := disabled.Validate(); err == nil || !strings.Contains(err.Error(), "unknown backend") {
		t.Fatalf("software backend = %v", err)
	}
	badPin := testPrivacySEPin(t)
	disabled = validTestConfig()
	disabled.PrivacyClass.ProviderSEPublicKeys = map[string]string{"provider-a": badPin[:len(badPin)-2]}
	if err := disabled.Validate(); err == nil || strings.Contains(err.Error(), badPin) {
		t.Fatalf("malformed disabled pin = %v", err)
	}

	base := privacyReadyConfig(t)
	if err := base.Validate(); err != nil {
		t.Fatal(err)
	}
	enabled := base
	enabled.PrivacyClass.Enabled = true
	if err := enabled.Validate(); err != nil {
		t.Fatal(err)
	}

	cases := []struct {
		name    string
		mutate  func(*Config)
		want    string
		secret  string
		enabled bool
	}{
		{name: "requires relay blind", want: "relay_blind.enabled", enabled: true, mutate: func(cfg *Config) { cfg.RelayBlind.Enabled = false }},
		{name: "interval low", want: "posture_challenge_interval_seconds", mutate: func(cfg *Config) { cfg.PrivacyClass.PostureChallengeIntervalSeconds = 14 }},
		{name: "interval high", want: "posture_challenge_interval_seconds", mutate: func(cfg *Config) { cfg.PrivacyClass.PostureChallengeIntervalSeconds = 301 }},
		{name: "max age below window", want: "posture_max_age_seconds", mutate: func(cfg *Config) { cfg.PrivacyClass.PostureMaxAgeSeconds = 69 }},
		{name: "max age above cap", want: "posture_max_age_seconds", mutate: func(cfg *Config) {
			cfg.PrivacyClass.PostureMaxAgeSeconds = 601
		}},
		{name: "timeout", want: "posture_response_timeout_seconds", mutate: func(cfg *Config) { cfg.PrivacyClass.PostureResponseTimeoutSeconds = 0 }},
		{name: "quarantine", want: "quarantine_seconds", mutate: func(cfg *Config) { cfg.PrivacyClass.QuarantineSeconds = 0 }},
		{name: "empty backends", want: "allowed_se_key_backends", enabled: true, mutate: func(cfg *Config) { cfg.PrivacyClass.AllowedSEKeyBackends = nil }},
		{name: "duplicate backends", want: "duplicate backend", mutate: func(cfg *Config) { cfg.PrivacyClass.AllowedSEKeyBackends = []string{"file", "file"} }},
		{name: "se pin without identity pin", want: "requires relay_blind.identity_public_keys", mutate: func(cfg *Config) {
			cfg.PrivacyClass.ProviderSEPublicKeys = map[string]string{"provider-b": testPrivacySEPin(t)}
		}},
		{name: "expired identity", want: "unexpired", enabled: true, mutate: func(cfg *Config) {
			cfg.PrivacyClass.ApprovedCodeIdentities[0].ExpiresAt = time.Date(2020, 1, 2, 3, 4, 5, 0, time.UTC)
		}},
		{name: "directory key required", want: "directory.signing_key_path", enabled: true, mutate: func(cfg *Config) { cfg.PrivacyClass.Directory.SigningKeyPath = "" }},
		{name: "directory key relative", want: "directory.signing_key_path", mutate: func(cfg *Config) { cfg.PrivacyClass.Directory.SigningKeyPath = "relative.key" }},
		{name: "directory ttl low", want: "directory.ttl_seconds", mutate: func(cfg *Config) { cfg.PrivacyClass.Directory.TTLSeconds = 59 }},
		{name: "directory ttl high", want: "directory.ttl_seconds", mutate: func(cfg *Config) { cfg.PrivacyClass.Directory.TTLSeconds = 3601 }},
		{name: "denied cdhash format", want: "denied_code_cdhashes", mutate: func(cfg *Config) { cfg.PrivacyClass.DeniedCodeCDHashes = []string{"ABC"} }},
		{name: "denied cdhash duplicate", want: "duplicate", mutate: func(cfg *Config) {
			cfg.PrivacyClass.DeniedCodeCDHashes = []string{strings.Repeat("a", 40), strings.Repeat("a", 40)}
		}},
		{name: "release half configured", want: "release_code_identities", mutate: func(cfg *Config) {
			cfg.PrivacyClass.ReleaseCodeIdentities.MetadataDir = "/opt/macprovider/privacy-release-identities"
		}},
		{name: "team id", want: "team_id", mutate: func(cfg *Config) { cfg.PrivacyClass.ApprovedCodeIdentities[0].TeamID = "ab12cd34ef" }},
		{name: "cdhash", want: "code_cdhash", mutate: func(cfg *Config) {
			cfg.PrivacyClass.ApprovedCodeIdentities[0].CDHash = strings.ToUpper(cfg.PrivacyClass.ApprovedCodeIdentities[0].CDHash)
		}},
		{name: "signing identifier", want: "signing_identifier", mutate: func(cfg *Config) {
			cfg.PrivacyClass.ApprovedCodeIdentities[0].SigningIdentifier = "has space"
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg := privacyReadyConfig(t)
			if tc.enabled {
				cfg.PrivacyClass.Enabled = true
			}
			tc.mutate(&cfg)
			err := cfg.Validate()
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("Validate = %v, want %q", err, tc.want)
			}
		})
	}

	t.Run("off curve", func(t *testing.T) {
		raw := make([]byte, 64)
		for i := range raw {
			raw[i] = 0x02
		}
		encoded := base64.StdEncoding.EncodeToString(raw)
		cfg := privacyReadyConfig(t)
		cfg.PrivacyClass.ProviderSEPublicKeys = map[string]string{"provider-a": encoded}
		err := cfg.Validate()
		if err == nil || !strings.Contains(err.Error(), "P-256") || strings.Contains(err.Error(), encoded) {
			t.Fatalf("Validate = %v", err)
		}
	})
	t.Run("base64url pin", func(t *testing.T) {
		priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		raw := privacySEPoint(priv)
		encoded := base64.RawURLEncoding.EncodeToString(raw)
		cfg := privacyReadyConfig(t)
		cfg.PrivacyClass.ProviderSEPublicKeys = map[string]string{"provider-a": encoded}
		err = cfg.Validate()
		if err == nil || !strings.Contains(err.Error(), "standard base64") || strings.Contains(err.Error(), encoded) {
			t.Fatalf("Validate = %v", err)
		}
	})
}

func privacyReadyConfig(t *testing.T) Config {
	t.Helper()
	cfg := validTestConfig()
	cfg.RelayBlind.Enabled = true
	cfg.RelayBlind.SQLitePath = filepath.Join(t.TempDir(), "relay-blind.sqlite")
	public, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	cfg.RelayBlind.IdentityPublicKeys = map[string]string{"provider-a": base64.RawURLEncoding.EncodeToString(public)}
	cfg.PrivacyClass.ProviderSEPublicKeys = map[string]string{"provider-a": testPrivacySEPin(t)}
	cfg.PrivacyClass.ApprovedCodeIdentities = []ApprovedCodeIdentity{testApprovedIdentity(time.Date(2027, 1, 2, 3, 4, 5, 0, time.UTC))}
	cfg.PrivacyClass.Directory.SigningKeyPath = "/etc/macprovider/privacy-directory.key"
	return cfg
}

// SPEC-049-R025/R027: automatic enrollment needs no operator pins, and
// signed release metadata alone can supply approved identities.
func TestPrivacyClassAutomaticEnrollmentConfig(t *testing.T) {
	cfg := privacyReadyConfig(t)
	cfg.PrivacyClass.Enabled = true
	cfg.PrivacyClass.ProviderSEPublicKeys = map[string]string{}
	cfg.RelayBlind.IdentityPublicKeys = map[string]string{}
	cfg.PrivacyClass.ApprovedCodeIdentities = nil
	cfg.PrivacyClass.ReleaseCodeIdentities = PrivacyReleaseCodeIdentitiesConfig{
		MetadataDir:   "/opt/macprovider/privacy-release-identities",
		PublicKeyPath: "/opt/macprovider/release-signing-public.pem",
	}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("pinless release-derived config rejected: %v", err)
	}
	cfg.PrivacyClass.ReleaseCodeIdentities = PrivacyReleaseCodeIdentitiesConfig{}
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "release_code_identities or an unexpired") {
		t.Fatalf("no approval source = %v", err)
	}
	relayOnly := privacyReadyConfig(t)
	relayOnly.PrivacyClass.ProviderSEPublicKeys = map[string]string{}
	relayOnly.RelayBlind.IdentityPublicKeys = map[string]string{}
	if err := relayOnly.Validate(); err == nil || !strings.Contains(err.Error(), "identity_public_keys") {
		t.Fatalf("relay-blind without privacy class still requires pins: %v", err)
	}
	if Default().PrivacyClass.Directory.TTLSeconds != 300 {
		t.Fatal("directory ttl default is not 300")
	}
}

func testApprovedIdentity(expiry time.Time) ApprovedCodeIdentity {
	return ApprovedCodeIdentity{
		TeamID:            "AB12CD34EF",
		SigningIdentifier: "live.malibu.provider.cli",
		CDHash:            "0123456789abcdef0123456789abcdef01234567",
		BinaryVersion:     "0.0.0-fixture",
		ExpiresAt:         expiry,
	}
}

func testPrivacySEPin(t *testing.T) string {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(privacySEPoint(priv))
}

func privacySEPoint(priv *ecdsa.PrivateKey) []byte {
	raw := make([]byte, 64)
	priv.X.FillBytes(raw[:32])
	priv.Y.FillBytes(raw[32:])
	return raw
}

// An approval without expires_at is valid and counts as live.
func TestPrivacyClassApprovalWithoutExpiry(t *testing.T) {
	cfg := privacyReadyConfig(t)
	cfg.PrivacyClass.Enabled = true
	cfg.PrivacyClass.ApprovedCodeIdentities = []ApprovedCodeIdentity{testApprovedIdentity(time.Time{})}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("approval without expiry rejected: %v", err)
	}
}
