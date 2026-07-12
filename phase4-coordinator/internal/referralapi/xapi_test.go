package referralapi

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
)

func TestParseXPostIDAcceptsOnlyCanonicalPublicStatusURLs(t *testing.T) {
	id, err := ParseXPostID("https://x.com/malibu/status/123456789")
	if err != nil || id != "123456789" {
		t.Fatalf("id=%q err=%v", id, err)
	}
	for _, raw := range []string{
		"http://x.com/malibu/status/1",
		"https://twitter.com/malibu/status/1",
		"https://x.com:443/malibu/status/1",
		"https://user@x.com/malibu/status/1",
		"https://x.com/malibu/status/1?next=http://127.0.0.1",
		"https://x.com/malibu/status/not-numeric",
		"https://127.0.0.1/malibu/status/1",
	} {
		if _, err := ParseXPostID(raw); err == nil {
			t.Errorf("accepted %q", raw)
		}
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestXVerifierUsesFixedAPIOriginAndExpandedInviteEntity(t *testing.T) {
	var requested string
	client := &XAPIClient{
		bearer:   "x-token",
		joinBase: mustURL(t, "https://coordinator.streamvc.live/j"),
		client: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			requested = r.URL.String()
			if r.Header.Get("Authorization") != "Bearer x-token" {
				t.Fatalf("missing X bearer")
			}
			body := `{"data":{"id":"123","author_id":"author-9","entities":{"urls":[{"expanded_url":"https://coordinator.streamvc.live/j/MAL1-P-k1-issuer-AAAAAAAAAAAAAAAAAAAAAAAAAA?c=abc"}]}}}`
			header := make(http.Header)
			header.Set("Content-Type", "application/json")
			return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(body)), Header: header}, nil
		})},
	}
	authorID, err := client.VerifyPost(context.Background(), "123", "https://coordinator.streamvc.live/j/MAL1-P-k1-issuer-AAAAAAAAAAAAAAAAAAAAAAAAAA?c=abc")
	if err != nil {
		t.Fatal(err)
	}
	if authorID != "author-9" {
		t.Fatalf("author id=%q", authorID)
	}
	if requested != "https://api.x.com/2/tweets/123?tweet.fields=entities,author_id" {
		t.Fatalf("requested=%q", requested)
	}
	if _, err := client.VerifyPost(context.Background(), "123", "https://malibu.tech/j/MAL1-P-k1-issuer-AAAAAAAAAAAAAAAAAAAAAAAAAA?c=abc"); err == nil {
		t.Fatal("accepted invite URL outside configured join origin")
	}
	if _, err := client.VerifyPost(context.Background(), "https://127.0.0.1", "https://coordinator.streamvc.live/j/MAL1-P-k1-issuer-AAAAAAAAAAAAAAAAAAAAAAAAAA?c=abc"); err == nil {
		t.Fatal("accepted non-numeric post ID")
	}
	// LookupPostAuthor returns the current author for the promotion re-check.
	if got, err := client.LookupPostAuthor(context.Background(), "123"); err != nil || got != "author-9" {
		t.Fatalf("lookup author got=%q err=%v", got, err)
	}
}

func mustURL(t *testing.T, raw string) *url.URL {
	t.Helper()
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	return u
}

// TestXLookupClassifiesTransientVsTerminal is the FIX-570 M3 regression: only a
// confirmed gone/protected post (404/410/403) is terminal; rate limits, server
// errors, and transport failures are transient so promotion retries instead of
// permanently denying the bonus.
func TestXLookupClassifiesTransientVsTerminal(t *testing.T) {
	newClient := func(status int, transportErr error) *XAPIClient {
		return &XAPIClient{
			bearer:   "x-token",
			joinBase: mustURL(t, "https://coordinator.streamvc.live/j"),
			client: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
				if transportErr != nil {
					return nil, transportErr
				}
				header := make(http.Header)
				header.Set("Content-Type", "application/json")
				return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader("{}")), Header: header}, nil
			})},
		}
	}
	terminalStatuses := []int{http.StatusNotFound, http.StatusGone, http.StatusForbidden}
	for _, st := range terminalStatuses {
		_, err := newClient(st, nil).LookupPostAuthor(context.Background(), "123")
		if !errors.Is(err, ErrXPostTerminal) {
			t.Fatalf("status %d: want terminal, got %v", st, err)
		}
	}
	transientStatuses := []int{http.StatusTooManyRequests, http.StatusInternalServerError, http.StatusBadGateway, http.StatusServiceUnavailable}
	for _, st := range transientStatuses {
		_, err := newClient(st, nil).LookupPostAuthor(context.Background(), "123")
		if !errors.Is(err, ErrXPostTransient) {
			t.Fatalf("status %d: want transient, got %v", st, err)
		}
	}
	// Transport error is transient.
	if _, err := newClient(0, io.ErrUnexpectedEOF).LookupPostAuthor(context.Background(), "123"); !errors.Is(err, ErrXPostTransient) {
		t.Fatalf("transport error: want transient, got %v", err)
	}
}
