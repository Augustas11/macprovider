package ws

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

// nativeMTPLogLevels returns the level of every log line whose message is msg.
func nativeMTPLogLevels(t *testing.T, logs *bytes.Buffer, msg string) []string {
	t.Helper()
	var levels []string
	for _, line := range strings.Split(strings.TrimSpace(logs.String()), "\n") {
		if line == "" {
			continue
		}
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Fatalf("log line is not JSON: %q", line)
		}
		if entry["message"] == msg {
			level, _ := entry["level"].(string)
			levels = append(levels, level)
		}
	}
	return levels
}

// The tuple offer and the canary outcome must show at the production log
// level (info): an accepted offer and a passing canary were both silent, so an
// operator could not tell a working canary from one that never ran.
func TestNativeMTPTupleOfferAcceptAndCanaryResultLogAtInfo(t *testing.T) {
	h := newNativeMTPCanaryIntegrationHarness(t)
	var logs bytes.Buffer
	h.server.log = zerolog.New(&logs)

	h.server.handleNativeMTPTupleOffer(h.provider.ProviderID, h.provider.AssignedID, mustMarshalNativeMTP(t, h.offer))
	if got := nativeMTPLogLevels(t, &logs, "native MTP tuple offer accepted"); len(got) != 1 || got[0] != "info" {
		t.Fatalf("offer accepted log levels = %v, want [info]; logs=%s", got, logs.String())
	}

	req := h.dispatchRequest(t)
	h.server.handleNativeMTPCanaryResult(h.provider.ProviderID, h.provider.AssignedID, mustMarshalNativeMTP(t, h.wireResult(req, "native_mtp")))
	if got := nativeMTPLogLevels(t, &logs, "native MTP canary result recorded"); len(got) != 1 || got[0] != "info" {
		t.Fatalf("canary result log levels = %v, want [info]; logs=%s", got, logs.String())
	}
	if !strings.Contains(logs.String(), `"outcome":"pass"`) {
		t.Fatalf("canary result log does not name the outcome: %s", logs.String())
	}
}

func TestNativeMTPTupleOfferIgnoredWhileCanaryDisabledLogsAtInfo(t *testing.T) {
	h := newNativeMTPCanaryIntegrationHarness(t)
	var logs bytes.Buffer
	h.server.log = zerolog.New(&logs)
	h.server.cfg.Pool.NativeMTPCanary.Enabled = false

	h.server.handleNativeMTPTupleOffer(h.provider.ProviderID, h.provider.AssignedID, mustMarshalNativeMTP(t, h.offer))
	if got := nativeMTPLogLevels(t, &logs, "native MTP tuple offer ignored: canary disabled"); len(got) != 1 || got[0] != "info" {
		t.Fatalf("canary-disabled log levels = %v, want [info]; logs=%s", got, logs.String())
	}
}

// /admin/providers is the operator view; it must carry the canary state the
// live pool holds, or an offered and passing tuple looks absent there.
func TestAdminProviderViewProjectsNativeMTPCanary(t *testing.T) {
	h := newNativeMTPCanaryIntegrationHarness(t)
	view := adminViewFromLive(mustResolveProvider(t, h.registry, h.provider.ProviderID, h.provider.AssignedID))
	raw, err := json.Marshal(view)
	if err != nil {
		t.Fatal(err)
	}
	var decoded struct {
		NativeMTPCanary *struct {
			Offered                     bool   `json:"offered"`
			NativeMTPRuntimeTupleSHA256 string `json:"native_mtp_runtime_tuple_sha256"`
		} `json:"native_mtp_canary"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.NativeMTPCanary == nil || !decoded.NativeMTPCanary.Offered ||
		decoded.NativeMTPCanary.NativeMTPRuntimeTupleSHA256 != h.offer.NativeMTPRuntimeTupleSHA256 {
		t.Fatalf("admin view native_mtp_canary = %s", raw)
	}

	plain, err := json.Marshal(adminViewFromLive(pool.Provider{ProviderID: "provider-without-offer"}))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(plain), "native_mtp_canary") {
		t.Fatalf("provider without an offer carries native_mtp_canary: %s", plain)
	}
}
