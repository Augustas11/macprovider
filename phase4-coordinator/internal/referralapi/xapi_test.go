package referralapi

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
)

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
	client := NewXAPIClient("secret", "https://malibu.tech/j")
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
}

func TestXAPIClassifiesOnlyConfirmedGoneAsTerminal(t *testing.T) {
	client := NewXAPIClient("secret", "https://malibu.tech/j")
	for _, test := range []struct {
		status int
		want   error
	}{
		{status: http.StatusNotFound, want: ErrXPostTerminal},
		{status: http.StatusGone, want: ErrXPostTerminal},
		{status: http.StatusForbidden, want: ErrXPostTransient},
		{status: http.StatusTooManyRequests, want: ErrXPostTransient},
		{status: http.StatusInternalServerError, want: ErrXPostTransient},
	} {
		client.client = &http.Client{Transport: xRoundTripFunc(func(*http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: test.status, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(`{"title":"error"}`))}, nil
		})}
		if _, err := client.LookupPostAuthor(context.Background(), "123"); !errors.Is(err, test.want) {
			t.Fatalf("status=%d err=%v want=%v", test.status, err, test.want)
		}
	}
}
