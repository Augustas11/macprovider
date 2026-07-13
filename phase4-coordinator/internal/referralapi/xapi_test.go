package referralapi

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
)

func mustXClient(t *testing.T, bearer, joinBaseURL string) *XAPIClient {
	t.Helper()
	client, err := NewXAPIClient(bearer, joinBaseURL)
	if err != nil {
		t.Fatal(err)
	}
	return client
}

type xRoundTripFunc func(*http.Request) (*http.Response, error)

func (f xRoundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}

func TestParseXPostIDAcceptsOnlyCanonicalStatusURLs(t *testing.T) {
	accepted := "https://x.com/malibu/status/123456789"
	if got, err := ParseXPostID(accepted); err != nil || got != "123456789" {
		t.Fatalf("ParseXPostID=%q err=%v", got, err)
	}
	for _, rejected := range []string{
		"http://x.com/malibu/status/123",
		"https://www.x.com/malibu/status/123",
		"https://x.com/malibu/status/123?ref=share",
		"https://x.com.evil.test/malibu/status/123",
		"https://x.com/malibu/status/not-numeric",
		"https://x.com/status/123",
	} {
		if _, err := ParseXPostID(rejected); err == nil {
			t.Fatalf("accepted %q", rejected)
		}
	}
}

func TestXAPIUsesFixedOriginAndRequiresAuthorAndExactInviteEntity(t *testing.T) {
	challenge := strings.Repeat("a", 64)
	wantShare := "https://malibu.tech/j/MAL1-P-k1-issuer-TAG?c=" + challenge
	client := mustXClient(t, "secret", "https://malibu.tech/j")
	client.client = &http.Client{Transport: xRoundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.URL.String() != "https://api.x.com/2/tweets/123?tweet.fields=entities,author_id" {
			t.Fatalf("request URL=%s", request.URL)
		}
		if request.Header.Get("Authorization") != "Bearer secret" {
			t.Fatalf("authorization=%q", request.Header.Get("Authorization"))
		}
		body := `{"data":{"id":"123","author_id":"456","entities":{"urls":[{"expanded_url":"` + wantShare + `"}]}}}`
		return &http.Response{StatusCode: http.StatusOK, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(body))}, nil
	})}
	authorID, err := client.VerifyPost(context.Background(), "123", wantShare)
	if err != nil || authorID != "456" {
		t.Fatalf("author=%q err=%v", authorID, err)
	}

	client.client = &http.Client{Transport: xRoundTripFunc(func(*http.Request) (*http.Response, error) {
		body := `{"data":{"id":"123","author_id":"","entities":{"urls":[{"expanded_url":"` + wantShare + `"}]}}}`
		return &http.Response{StatusCode: http.StatusOK, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(body))}, nil
	})}
	if _, err := client.VerifyPost(context.Background(), "123", wantShare); !errors.Is(err, ErrXPostTransient) {
		t.Fatalf("missing author error=%v", err)
	}
	if _, err := canonicalShareURL(wantShare+"&utm_source=x", client.joinBase); err == nil {
		t.Fatal("canonical share URL accepted an extra query parameter")
	}
	digest, err := ShareURLDigest(wantShare, "https://malibu.tech/j")
	if err != nil || len(digest) != 64 {
		t.Fatalf("share URL digest=%q err=%v", digest, err)
	}
}

func TestXAPIClassifiesOnlyConfirmedUnavailablePostsAsTerminal(t *testing.T) {
	client := mustXClient(t, "secret", "https://malibu.tech/j")
	for _, test := range []struct {
		status int
		body   string
		want   error
	}{
		{status: http.StatusNotFound, body: `{"title":"not found"}`, want: ErrXPostTerminal},
		{status: http.StatusGone, body: `{"title":"gone"}`, want: ErrXPostTerminal},
		{status: http.StatusForbidden, body: `{"type":"https://api.x.com/2/problems/not-authorized-for-resource","detail":"This post is unavailable"}`, want: ErrXPostTerminal},
		{status: http.StatusForbidden, body: `{"errors":[{"code":179,"message":"not visible"}]}`, want: ErrXPostTerminal},
		{status: http.StatusForbidden, body: `{"detail":"client cannot access private metrics"}`, want: ErrXPostTransient},
		{status: http.StatusForbidden, body: `{"title":"client forbidden"}`, want: ErrXPostTransient},
		{status: http.StatusTooManyRequests, body: `{"title":"limited"}`, want: ErrXPostTransient},
		{status: http.StatusInternalServerError, body: `{"title":"error"}`, want: ErrXPostTransient},
	} {
		client.client = &http.Client{Transport: xRoundTripFunc(func(*http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: test.status, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(test.body))}, nil
		})}
		if _, err := client.RecheckPost(context.Background(), "123", strings.Repeat("a", 64)); !errors.Is(err, test.want) {
			t.Fatalf("status=%d err=%v want=%v", test.status, err, test.want)
		}
	}
}

func TestXAPIRecheckRequiresOriginalExactInviteURL(t *testing.T) {
	challenge := strings.Repeat("a", 64)
	original := "https://malibu.tech/j/MAL1-P-k1-issuer-TAG?c=" + challenge
	digest, err := ShareURLDigest(original, "https://malibu.tech/j")
	if err != nil {
		t.Fatal(err)
	}
	client := mustXClient(t, "secret", "https://malibu.tech/j")
	postURL := original
	client.client = &http.Client{Transport: xRoundTripFunc(func(*http.Request) (*http.Response, error) {
		body := `{"data":{"id":"123","author_id":"456","entities":{"urls":[{"expanded_url":"` + postURL + `"}]}}}`
		return &http.Response{StatusCode: http.StatusOK, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(body))}, nil
	})}
	if author, err := client.RecheckPost(context.Background(), "123", digest); err != nil || author != "456" {
		t.Fatalf("unchanged author=%q err=%v", author, err)
	}
	postURL = "https://malibu.tech/j/MAL1-P-k1-other-TAG?c=" + challenge
	if _, err := client.RecheckPost(context.Background(), "123", digest); !errors.Is(err, ErrXPostTerminal) {
		t.Fatalf("changed invite error=%v", err)
	}
	postURL = "https://example.test/no-malibu-link"
	if _, err := client.RecheckPost(context.Background(), "123", digest); !errors.Is(err, ErrXPostTerminal) {
		t.Fatalf("removed invite error=%v", err)
	}
}

func TestNewXAPIClientRejectsUnsafeJoinBase(t *testing.T) {
	for _, raw := range []string{
		"http://malibu.tech/j",
		"https://user:secret@malibu.tech/j",
		"https://malibu.tech/j?next=evil",
		"https://malibu.tech/invite",
	} {
		if _, err := NewXAPIClient("secret", raw); err == nil {
			t.Fatalf("accepted unsafe join base %q", raw)
		}
	}
}
