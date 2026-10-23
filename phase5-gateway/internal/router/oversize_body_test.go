package router

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// TestOversizeChatBodyStreamedReturns413NotReset reproduces #2107. nginx
// streams /v1/ bodies to the gateway (proxy_request_buffering off) and reads
// the response only after the whole body is written. Without the bounded drain
// the gateway answers 413 with most of the body unread, net/http closes the
// connection, the kernel resets it, and the streaming client hits a reset or
// broken pipe instead of the 413 (nginx turns that into a 502).
func TestOversizeChatBodyStreamedReturns413NotReset(t *testing.T) {
	_, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Limits.RequestBodyBytes = 64 << 10
	}, WithHTTPClient(noopClient()))
	fullKey := createAccountAndKey(t, store, cfg, "acct_oversize_drain")
	h := New(cfg, store, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(noopClient())).Handler()
	ts := httptest.NewServer(h)
	defer ts.Close()

	// Well over the chat read limit, under nginx's 8 MiB client_max_body_size.
	const bodyBytes = 6 << 20
	for attempt := range 3 {
		status, respBody, err := streamOversizeRequest(ts.Listener.Addr().String(), "/v1/chat/completions", fullKey, bodyBytes)
		if err != nil {
			t.Fatalf("attempt %d: streaming client saw %v before the 413; the gateway closed with the body unread", attempt, err)
		}
		if status != http.StatusRequestEntityTooLarge {
			t.Fatalf("attempt %d: status=%d body=%s", attempt, status, respBody)
		}
		assertErrorCode(t, respBody, "request_too_large")
	}
}

// streamOversizeRequest behaves like nginx with request buffering off: it
// writes the headers and the whole body in chunks, then reads the response.
func streamOversizeRequest(addr, path, bearer string, bodyBytes int) (int, string, error) {
	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return 0, "", err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))

	head := fmt.Sprintf("POST %s HTTP/1.1\r\nHost: %s\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n", path, addr, bearer, bodyBytes)
	if _, err := io.WriteString(conn, head); err != nil {
		return 0, "", fmt.Errorf("write headers: %w", err)
	}
	chunk := bytes.Repeat([]byte{'x'}, 64<<10)
	for sent := 0; sent < bodyBytes; {
		n := min(len(chunk), bodyBytes-sent)
		if _, err := conn.Write(chunk[:n]); err != nil {
			return 0, "", fmt.Errorf("write body after %d bytes: %w", sent, err)
		}
		sent += n
	}
	resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		return 0, "", fmt.Errorf("read response: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return 0, "", fmt.Errorf("read response body: %w", err)
	}
	return resp.StatusCode, strings.TrimSpace(string(raw)), nil
}
