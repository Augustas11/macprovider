package router

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/relayblind"
)

func privacyClosedFrame(t *testing.T, seq uint64, final bool) string {
	t.Helper()
	raw, err := json.Marshal(relayblind.PrivacyFrame{
		Object: relayblind.PrivacyFrameObject, Version: relayblind.PrivacyResponseVersion, Seq: seq, Final: final,
		Ciphertext: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{byte(0x40 + seq)}, 48)),
	})
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// privacyClosedResponseBody is a SPEC-049 §4.8 non-stream privacy response.
func privacyClosedResponseBody(t *testing.T) string {
	t.Helper()
	return `{"object":"` + relayblind.PrivacyResponseObject + `","version":"` + relayblind.PrivacyResponseVersion + `","frames":[` +
		privacyClosedFrame(t, 0, false) + `,` + privacyClosedFrame(t, 1, true) + `],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}`
}

func TestPrivacyGatewayRefusesClearNonStreamBody(t *testing.T) {
	res := privacyReservationFixture(t, false)
	raw := pilotEnvelopeFixture(t, res)
	digest := sha256.Sum256(raw)
	digestText := base64.RawURLEncoding.EncodeToString(digest[:])
	upstream, _ := privacyCoordinator(t, res, raw, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set(relayBlindValidatedHeader, digestText)
		setPrivacyChatEcho(w, privacyCoordinatorVerifiedAt)
		w.Header().Set(settlementModeHeader, "observe")
		io.WriteString(w, `{"object":"chat.completion","choices":[{"message":{"content":"CANARY_PRIVACY_BODY","tool_calls":[]}}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}`)
	})
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
		enablePrivacy(c)
		c.Coordinator.BuyerURL = upstream.URL
	})
	key := createAccountAndKey(t, store, cfg, "privacy-clear-json")
	chat := postPrivacy(h, key, "/v1/chat/completions", raw, privacyChatHeaders())
	if chat.Code != http.StatusInternalServerError {
		t.Fatalf("status %d %s", chat.Code, chat.Body.String())
	}
	assertPrivacyError(t, chat.Body.String(), http.StatusInternalServerError, privacyClassUnconfirmed, "do_not_resubmit", "Privacy class completion was not confirmed")
	if strings.Contains(chat.Body.String(), "CANARY_PRIVACY_BODY") {
		t.Fatalf("clear body forwarded: %s", chat.Body.String())
	}
	if chat.Header().Get(privacyClassHeader) != "" || chat.Header().Get(privacyAssuranceHeader) != "" || chat.Header().Get(privacyResponseEncryptionHeader) != "" {
		t.Fatalf("success headers on refusal: %v", chat.Header())
	}
	if _, held, err := store.DailyUsage(context.Background(), "privacy-clear-json", fixedNow().Format("2006-01-02")); err != nil || held != 0 {
		t.Fatalf("held=%d err=%v", held, err)
	}
}

func TestPrivacyGatewayRefusesClearStreamContent(t *testing.T) {
	frame0 := "data: " + privacyClosedFrame(t, 0, false) + "\n\n"
	frame1 := "data: " + privacyClosedFrame(t, 1, true) + "\n\n"
	usage := "data: {\"object\":\"chat.completion.chunk\",\"model\":\"test-model\",\"choices\":[],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":2,\"total_tokens\":6}}\n\n"
	for _, tc := range []struct {
		name, account, upstream, forwarded string
	}{
		{name: "clear content chunk", account: "privacy-clear-delta", upstream: frame0 + "data: {\"choices\":[{\"delta\":{\"content\":\"CANARY_PRIVACY_BODY\"}}]}\n\n" + frame1 + usage + "data: [DONE]\n\n", forwarded: frame0},
		{name: "content bearing usage chunk", account: "privacy-clear-usage", upstream: frame0 + frame1 + "data: {\"object\":\"chat.completion.chunk\",\"model\":\"test-model\",\"choices\":[{\"delta\":{\"content\":\"CANARY_PRIVACY_BODY\"}}],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":2,\"total_tokens\":6}}\n\ndata: [DONE]\n\n", forwarded: frame0 + frame1},
		{name: "usage model not reserved model", account: "privacy-usage-model", upstream: frame0 + frame1 + strings.Replace(usage, `"model":"test-model"`, `"model":"other-model"`, 1) + "data: [DONE]\n\n", forwarded: frame0 + frame1},
		{name: "done before final frame", account: "privacy-early-done", upstream: frame0 + "data: [DONE]\n\n", forwarded: frame0},
		{name: "eof without usage or done", account: "privacy-eof", upstream: frame0 + frame1, forwarded: frame0 + frame1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			res := privacyReservationFixture(t, true)
			raw := pilotEnvelopeFixture(t, res)
			digest := sha256.Sum256(raw)
			digestText := base64.RawURLEncoding.EncodeToString(digest[:])
			upstream, _ := privacyCoordinator(t, res, raw, func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set(relayBlindValidatedHeader, digestText)
				setPrivacyChatEcho(w, privacyCoordinatorVerifiedAt)
				w.Header().Set(settlementModeHeader, "observe")
				w.Header().Set("Content-Type", "text/event-stream")
				io.WriteString(w, tc.upstream)
			})
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
				enablePrivacy(c)
				c.Coordinator.BuyerURL = upstream.URL
			})
			key := createAccountAndKey(t, store, cfg, tc.account)
			chat := postPrivacy(h, key, "/v1/chat/completions", raw, privacyChatHeaders())
			body := chat.Body.String()
			if chat.Code != http.StatusOK {
				t.Fatalf("status %d %s", chat.Code, body)
			}
			if strings.Contains(body, "CANARY_PRIVACY_BODY") {
				t.Fatalf("clear content forwarded: %s", body)
			}
			if !strings.HasPrefix(body, tc.forwarded) {
				t.Fatalf("opaque frames not forwarded verbatim: %q", body)
			}
			tail := strings.TrimPrefix(body, tc.forwarded)
			if !strings.HasPrefix(tail, "data: ") || !strings.HasSuffix(tail, "\n\ndata: [DONE]\n\n") {
				t.Fatalf("refusal tail %q", tail)
			}
			assertPrivacyError(t, strings.TrimSuffix(strings.TrimPrefix(tail, "data: "), "\n\ndata: [DONE]\n\n"), http.StatusInternalServerError, privacyClassUnconfirmed, "do_not_resubmit", "Privacy class completion was not confirmed")
			if _, held, err := store.DailyUsage(context.Background(), tc.account, fixedNow().Format("2006-01-02")); err != nil || held != 0 {
				t.Fatalf("held=%d err=%v", held, err)
			}
		})
	}
}
