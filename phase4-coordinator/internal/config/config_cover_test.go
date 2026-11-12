package config

import (
	"math"
	"strings"
	"testing"
	"time"
)

func TestCompatibilitySetIDAccessors(t *testing.T) {
	repo, ok := CompatibilitySetIDRepository(compatibilitySetTarget)
	if !ok || repo != "Augustas11/macprovider" {
		t.Fatalf("repo = %q, %v", repo, ok)
	}
	ver, ok := CompatibilitySetIDVersion(compatibilitySetTarget)
	if !ok || ver != "1.8.4" {
		t.Fatalf("version = %q, %v", ver, ok)
	}
	for _, bad := range []string{"", "garbage", "a/b:v01.2.3@" + strings.Repeat("a", 40), "a/b:v1.2.3@" + strings.Repeat("A", 40)} {
		if r, ok := CompatibilitySetIDRepository(bad); ok || r != "" {
			t.Errorf("repo(%q) = %q, %v; want rejected", bad, r, ok)
		}
		if v, ok := CompatibilitySetIDVersion(bad); ok || v != "" {
			t.Errorf("version(%q) = %q, %v; want rejected", bad, v, ok)
		}
	}
}

func TestSplitCompatibilitySetIDMalformed(t *testing.T) {
	for _, id := range []string{"noat", "a/b@" + strings.Repeat("a", 40), "a/b:x1.2.3@abc", "a/b:v@abc"} {
		if _, _, ok := splitCompatibilitySetID(id); ok {
			t.Errorf("split(%q) ok, want false", id)
		}
	}
	repo, ver, ok := splitCompatibilitySetID("o/r:v1.2.3@abc")
	if !ok || repo != "o/r" || ver != "1.2.3" {
		t.Fatalf("split = %q %q %v", repo, ver, ok)
	}
}

func TestValidCompatibilitySetVersion(t *testing.T) {
	for v, want := range map[string]bool{
		"1.2.3": true, "0.0.0": true, "01.2.3": false, "1.2": false, "1.2.3.4": false, "": false, "v1.2.3": false,
		"99999999999999999999.0.0": false,
	} {
		if got := ValidCompatibilitySetVersion(v); got != want {
			t.Errorf("ValidCompatibilitySetVersion(%q) = %v, want %v", v, got, want)
		}
	}
}

func TestNativeMTPCanaryInterval(t *testing.T) {
	for _, tc := range []struct {
		s    int
		want time.Duration
	}{
		{0, time.Hour}, {-5, time.Hour}, {60, 15 * time.Minute}, {899, 15 * time.Minute},
		{900, 15 * time.Minute}, {1800, 30 * time.Minute},
	} {
		if got := (NativeMTPCanaryConfig{IntervalS: tc.s}).Interval(); got != tc.want {
			t.Errorf("Interval(%d) = %v, want %v", tc.s, got, tc.want)
		}
	}
}

func TestValidateCanaryChallengeList(t *testing.T) {
	ok := CanaryChallengeConfig{Prompt: "say {nonce}", Expected: "{nonce}"}
	if err := validateCanaryChallengeList("p", []CanaryChallengeConfig{ok}); err != nil {
		t.Fatalf("valid challenge rejected: %v", err)
	}
	cases := map[string]CanaryChallengeConfig{
		"must not be empty":  {Prompt: "  ", Expected: "{nonce}"},
		"must contain {non":  {Prompt: "x", Expected: "{nonce}"},
		"max_ttft_ms":        {Prompt: "{nonce}", Expected: "{nonce}", MaxTTFTMS: -1},
		"min_sustained_tps ": {Prompt: "{nonce}", Expected: "{nonce}", MinSustainedTPS: math.NaN()},
		"min_sustained_tps":  {Prompt: "{nonce}", Expected: "{nonce}", MinSustainedTPS: math.Inf(1)},
	}
	for want, c := range cases {
		err := validateCanaryChallengeList("p", []CanaryChallengeConfig{ok, c})
		if err == nil || !strings.Contains(err.Error(), "p[1]") || !strings.Contains(err.Error(), strings.TrimSpace(want)) {
			t.Errorf("challenge %+v: err=%v, want index 1 and %q", c, err, want)
		}
	}
	neg := ok
	neg.MinSustainedTPS = -0.5
	if err := validateCanaryChallengeList("p", []CanaryChallengeConfig{neg}); err == nil {
		t.Error("negative tps accepted")
	}
}

func TestCanaryChallengesForModel(t *testing.T) {
	def := []CanaryChallengeConfig{{Prompt: "d", Expected: "d"}}
	exact := []CanaryChallengeConfig{{Prompt: "e", Expected: "e"}}
	fold := []CanaryChallengeConfig{{Prompt: "f", Expected: "f"}}
	p := PoolConfig{
		CanaryChallenges: def,
		ModelClassChallenges: map[string][]CanaryChallengeConfig{
			"Org/Exact": exact,
			" Org/Fold": fold,
			"org/empty": nil,
		},
	}
	if got, ok := p.CanaryChallengesForModel(""); ok || got[0].Prompt != "d" {
		t.Errorf("empty model = %v, %v", got, ok)
	}
	if got, ok := p.CanaryChallengesForModel("  "); ok || got[0].Prompt != "d" {
		t.Errorf("blank model = %v, %v", got, ok)
	}
	if got, ok := p.CanaryChallengesForModel("Org/Exact"); !ok || got[0].Prompt != "e" {
		t.Errorf("exact = %v, %v", got, ok)
	}
	if got, ok := p.CanaryChallengesForModel("org/fold"); !ok || got[0].Prompt != "f" {
		t.Errorf("case-insensitive = %v, %v", got, ok)
	}
	if got, ok := p.CanaryChallengesForModel("org/empty"); ok || got[0].Prompt != "d" {
		t.Errorf("empty bank should fall back = %v, %v", got, ok)
	}
	if got, ok := p.CanaryChallengesForModel("other"); ok || got[0].Prompt != "d" {
		t.Errorf("unknown = %v, %v", got, ok)
	}
}

func TestConfigDurationAccessorsOverrideAndFallToDefault(t *testing.T) {
	def := Default()
	var zero Config
	if got, want := zero.HeartbeatInterval(), time.Duration(def.Pool.HeartbeatIntervalS)*time.Second; got != want || got == 0 {
		t.Errorf("HeartbeatInterval default = %v, want %v", got, want)
	}
	if got, want := zero.FailoverTimeout(), time.Duration(def.Routing.FailoverTimeoutS)*time.Second; got != want || got == 0 {
		t.Errorf("FailoverTimeout default = %v", got)
	}
	if got, want := zero.HeartbeatMissThreshold(), time.Duration(def.Pool.HeartbeatMissThresholdS)*time.Second; got != want || got == 0 {
		t.Errorf("HeartbeatMissThreshold default = %v", got)
	}
	if got, want := zero.ProviderWSHandshakeTimeout(), time.Duration(def.WS.HandshakeTimeoutS)*time.Second; got != want || got == 0 {
		t.Errorf("handshake default = %v", got)
	}
	if got, want := zero.ProviderWSWriteTimeout(), time.Duration(def.WS.WriteTimeoutS)*time.Second; got != want || got == 0 {
		t.Errorf("write default = %v", got)
	}
	if got := zero.ProviderWSMaxFrameBytes(); got != def.WS.MaxFrameBytes || got <= 0 {
		t.Errorf("frame default = %v", got)
	}
	if got := zero.ProviderWSMaxUnauthenticatedConn(); got != def.WS.MaxUnauthenticatedConn || got <= 0 {
		t.Errorf("unauth default = %v", got)
	}
	if got := zero.ProviderWSMaxUnauthenticatedConnPerIP(); got != def.WS.MaxUnauthenticatedConnPerIP || got <= 0 {
		t.Errorf("unauth per-ip default = %v", got)
	}
	if got := zero.RelayMaxRequestBufferBytes(); got != def.Relay.MaxRequestBufferBytes || got <= 0 {
		t.Errorf("relay buffer default = %v", got)
	}

	var c Config
	c.Pool.HeartbeatIntervalS = 7
	c.Routing.FailoverTimeoutS = 8
	c.Pool.HeartbeatMissThresholdS = 9
	c.WS.HandshakeTimeoutS = 11
	c.WS.WriteTimeoutS = 12
	c.WS.MaxFrameBytes = 1234
	c.WS.MaxUnauthenticatedConn = 5
	c.WS.MaxUnauthenticatedConnPerIP = 2
	c.Relay.MaxRequestBufferBytes = 777
	if c.HeartbeatInterval() != 7*time.Second || c.FailoverTimeout() != 8*time.Second ||
		c.HeartbeatMissThreshold() != 9*time.Second || c.ProviderWSHandshakeTimeout() != 11*time.Second ||
		c.ProviderWSWriteTimeout() != 12*time.Second {
		t.Error("duration overrides not honoured")
	}
	if c.ProviderWSMaxFrameBytes() != 1234 || c.ProviderWSMaxUnauthenticatedConn() != 5 ||
		c.ProviderWSMaxUnauthenticatedConnPerIP() != 2 || c.RelayMaxRequestBufferBytes() != 777 {
		t.Error("size/count overrides not honoured")
	}
	c.Pool.HeartbeatIntervalS = -1
	if c.HeartbeatInterval() != time.Duration(def.Pool.HeartbeatIntervalS)*time.Second {
		t.Error("negative heartbeat should fall back to default")
	}
}

func TestProviderByIDAndValidateEndpointURL(t *testing.T) {
	c := Config{Providers: []ProviderConfig{{ProviderID: "a", EndpointURL: "x"}, {ProviderID: "b"}}}
	m := c.ProviderByID()
	if len(m) != 2 || m["a"].EndpointURL != "x" {
		t.Fatalf("ProviderByID = %+v", m)
	}
	if _, ok := m["zz"]; ok {
		t.Error("unexpected provider")
	}
	for u, wantErr := range map[string]bool{
		"https://example.com":   false,
		"http://localhost:8080": false,
		"http://127.0.0.1:1":    false,
		"http://example.com":    true,
		"ftp://localhost":       true,
		"https://":              true,
		"example.com":           true,
		"":                      true,
		"http://%zz":            true,
	} {
		if err := ValidateEndpointURL(u); (err != nil) != wantErr {
			t.Errorf("ValidateEndpointURL(%q) err=%v, wantErr=%v", u, err, wantErr)
		}
	}
}
