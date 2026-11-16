package ws

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"

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

// nativeMTPLogEvents returns every JSON log line whose "event" is event.
func nativeMTPLogEvents(t *testing.T, logs *bytes.Buffer, event string) []map[string]any {
	t.Helper()
	var out []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(logs.String()), "\n") {
		if line == "" {
			continue
		}
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Fatalf("log line is not JSON: %q", line)
		}
		if entry["event"] == event {
			out = append(out, entry)
		}
	}
	return out
}

// Issue #2404: a canary that times out switched native MTP off with no line on
// the coordinator. The challenge, the timeout and the disable each log once.
func TestNativeMTPCanaryTimeoutLogsChallengeTimeoutAndDisable(t *testing.T) {
	h := newNativeMTPCanaryIntegrationHarness(t)
	var logs bytes.Buffer
	h.server.log = zerolog.New(&logs)

	req := h.dispatchRequest(t)
	sent := nativeMTPLogEvents(t, &logs, "native_mtp_canary_challenge_sent")
	if len(sent) != 1 || sent[0]["level"] != "info" ||
		sent[0]["challenge_id"] != req.ChallengeID ||
		sent[0]["request_id"] != req.RequestID ||
		sent[0]["deadline"] != req.ExpiresAt ||
		sent[0]["challenge_bank_release_id"] != h.bank.ReleaseID {
		t.Fatalf("challenge sent log = %v; logs=%s", sent, logs.String())
	}

	expiresAt, err := time.Parse(time.RFC3339, req.ExpiresAt)
	if err != nil {
		t.Fatal(err)
	}
	*h.now = expiresAt.Add(time.Second)
	h.server.maybeDispatchNativeMTPCanary(mustResolveProvider(t, h.registry, h.provider.ProviderID, h.provider.AssignedID), *h.now)
	if disable := h.readDisable(t); disable.Reason != "timeout" {
		t.Fatalf("disable reason = %q, want timeout", disable.Reason)
	}
	timeouts := nativeMTPLogEvents(t, &logs, "native_mtp_canary_timeout")
	if len(timeouts) != 1 || timeouts[0]["challenge_id"] != req.ChallengeID || timeouts[0]["request_id"] != req.RequestID {
		t.Fatalf("timeout log = %v; logs=%s", timeouts, logs.String())
	}
	disables := nativeMTPLogEvents(t, &logs, "native_mtp_tuple_disable_sent")
	if len(disables) != 1 || disables[0]["reason"] != "timeout" || disables[0]["sent"] != true {
		t.Fatalf("disable sent log = %v; logs=%s", disables, logs.String())
	}

	// A later sweep of the disabled tuple neither times out again nor resends.
	h.server.maybeDispatchNativeMTPCanary(mustResolveProvider(t, h.registry, h.provider.ProviderID, h.provider.AssignedID), *h.now)
	h.assertNoServerFrame(t)
	if got := len(nativeMTPLogEvents(t, &logs, "native_mtp_canary_timeout")); got != 1 {
		t.Fatalf("timeout logged %d times, want 1", got)
	}
	for _, line := range strings.Split(logs.String(), "\n") {
		if strings.Contains(line, "prompt_token_ids") || strings.Contains(line, "expected_token_id") {
			t.Fatalf("canary log carries challenge content: %s", line)
		}
	}
}

func TestNativeMTPCanaryResultLogNamesChallengeAndOutcome(t *testing.T) {
	h := newNativeMTPCanaryIntegrationHarness(t)
	var logs bytes.Buffer
	h.server.log = zerolog.New(&logs)

	req := h.dispatchRequest(t)
	result := h.wireResult(req, "ordinary")
	result.Diagnostic = "ordinary path"
	result.ResultDigest = nativeMTPCanaryResultDigest(result)
	h.server.handleNativeMTPCanaryResult(h.provider.ProviderID, h.provider.AssignedID, mustMarshalNativeMTP(t, result))
	if disable := h.readDisable(t); disable.Reason != "fallback" {
		t.Fatalf("disable reason = %q, want fallback", disable.Reason)
	}
	got := nativeMTPLogEvents(t, &logs, "native_mtp_canary_result_received")
	if len(got) != 1 || got[0]["challenge_id"] != req.ChallengeID || got[0]["request_id"] != req.RequestID ||
		got[0]["outcome"] != "fail" || got[0]["reason"] != "unsupported_path_fallback" ||
		got[0]["actual_decode_path"] != "ordinary" || got[0]["diagnostic"] != "ordinary path" {
		t.Fatalf("result log = %v; logs=%s", got, logs.String())
	}
	disables := nativeMTPLogEvents(t, &logs, "native_mtp_tuple_disable_sent")
	if len(disables) != 1 || disables[0]["reason"] != "fallback" {
		t.Fatalf("disable sent log = %v; logs=%s", disables, logs.String())
	}
}

func TestNativeMTPCanaryChallengeSendFailureLogsAndReschedules(t *testing.T) {
	h := newNativeMTPCanaryIntegrationHarness(t)
	var logs bytes.Buffer
	h.server.log = zerolog.New(&logs)
	session, ok := h.server.storedSessionFor(h.provider.ProviderID, h.provider.AssignedID)
	if !ok {
		t.Fatal("missing provider session")
	}
	session.close()

	if h.server.maybeDispatchNativeMTPCanary(mustResolveProvider(t, h.registry, h.provider.ProviderID, h.provider.AssignedID), *h.now) {
		t.Fatal("dispatch on a closed session reported success")
	}
	if got := nativeMTPLogEvents(t, &logs, "native_mtp_canary_challenge_send_failed"); len(got) != 1 || got[0]["level"] != "warn" {
		t.Fatalf("send failure log = %v; logs=%s", got, logs.String())
	}
	if got := nativeMTPLogEvents(t, &logs, "native_mtp_canary_challenge_sent"); len(got) != 0 {
		t.Fatalf("send failure logged as sent: %v", got)
	}
}
