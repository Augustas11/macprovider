package referralapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

var xPostIDPattern = regexp.MustCompile(`^[0-9]{1,24}$`)

// FIX-570 M3: promotion-time re-checks classify their failure so the promotion
// reconciler can tell a CONFIRMED terminal state (post deleted / protected) from
// a TRANSIENT one (timeout / 429 / 5xx / transport error). Only terminal
// failures may permanently deny the social bonus; transient failures leave the
// verification pending for a later retry.
var (
	// ErrXPostTerminal means the post is confirmed gone or inaccessible in a way
	// that will not recover (404 not found, 410 gone, 403 protected/suspended).
	ErrXPostTerminal = errors.New("x post terminally unavailable")
	// ErrXPostTransient means the lookup could not be completed for a reason that
	// may succeed on retry (timeout, 429 rate limit, 5xx, transport/parse error).
	ErrXPostTransient = errors.New("x post lookup transient failure")
)

// forbiddenProvesPostUnavailable parses a bounded X API v2 error body and reports
// whether a 403 CONFIRMS the POST itself is unavailable (suspended/protected/
// deleted author or tweet) rather than an issue with our own API credentials,
// project, subscription, access level, or permissions. FIX-570 M2(adv): only a
// proven post-unavailable 403 is terminal; everything else (client-not-enrolled,
// insufficient access, generic Forbidden) is transient. Unparseable bodies are
// treated as ambiguous → transient (fail safe: never permanently deny a bonus on
// an unproven signal).
func forbiddenProvesPostUnavailable(body []byte) bool {
	if len(body) == 0 {
		return false
	}
	var parsed struct {
		Title  string `json:"title"`
		Detail string `json:"detail"`
		Reason string `json:"reason"`
		Type   string `json:"type"`
		Errors []struct {
			Title   string `json:"title"`
			Detail  string `json:"detail"`
			Message string `json:"message"`
			Reason  string `json:"reason"`
		} `json:"errors"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return false
	}
	fields := []string{parsed.Title, parsed.Detail, parsed.Reason, parsed.Type}
	for _, e := range parsed.Errors {
		fields = append(fields, e.Title, e.Detail, e.Message, e.Reason)
	}
	// Markers that prove the POST/author is the reason (terminal).
	postUnavailable := []string{"suspended", "protected", "deleted", "not-found", "not found", "unavailable"}
	// Markers that prove OUR credentials/project are the reason (transient) — these
	// veto a terminal classification even if an ambiguous word co-occurs.
	credentialIssue := []string{"client-not-enrolled", "not enrolled", "access level", "insufficient", "unauthorized client", "product", "subscription", "usage cap", "consumer key"}
	joined := strings.ToLower(strings.Join(fields, " \x00 "))
	for _, m := range credentialIssue {
		if strings.Contains(joined, m) {
			return false
		}
	}
	for _, m := range postUnavailable {
		if strings.Contains(joined, m) {
			return true
		}
	}
	return false
}

func ParseXPostID(raw string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Scheme != "https" || !strings.EqualFold(u.Hostname(), "x.com") || u.Port() != "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", errors.New("invalid x post url")
	}
	parts := strings.Split(strings.Trim(u.EscapedPath(), "/"), "/")
	if len(parts) != 3 || parts[0] == "" || parts[1] != "status" || !xPostIDPattern.MatchString(parts[2]) {
		return "", errors.New("invalid x post path")
	}
	return parts[2], nil
}

type XAPIClient struct {
	bearer   string
	client   *http.Client
	joinBase *url.URL
}

func NewXAPIClient(bearer, joinBaseURL string) *XAPIClient {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.ResponseHeaderTimeout = 4 * time.Second
	joinBase, _ := url.Parse(strings.TrimRight(strings.TrimSpace(joinBaseURL), "/"))
	return &XAPIClient{
		bearer:   strings.TrimSpace(bearer),
		joinBase: joinBase,
		client: &http.Client{
			Timeout:   6 * time.Second,
			Transport: transport,
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}
}

type xPostPayload struct {
	Data struct {
		ID       string `json:"id"`
		AuthorID string `json:"author_id"`
		Entities struct {
			URLs []struct {
				Expanded string `json:"expanded_url"`
				Unwound  string `json:"unwound_url"`
			} `json:"urls"`
		} `json:"entities"`
	} `json:"data"`
}

func (c *XAPIClient) fetchPost(ctx context.Context, postID string) (xPostPayload, error) {
	var payload xPostPayload
	if c == nil || c.bearer == "" || !xPostIDPattern.MatchString(postID) {
		return payload, errors.New("x verifier unavailable")
	}
	endpoint := "https://api.x.com/2/tweets/" + postID + "?tweet.fields=entities,author_id"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return payload, err
	}
	req.Header.Set("Authorization", "Bearer "+c.bearer)
	req.Header.Set("Accept", "application/json")
	resp, err := c.client.Do(req)
	if err != nil {
		// Transport errors (timeout, connection reset, DNS) are always transient.
		return payload, fmt.Errorf("x lookup transport error: %w", ErrXPostTransient)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		errBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		// FIX-570 M3/M2(adv): only a CONFIRMED gone/inaccessible post is terminal.
		// 404/410 prove the post is gone. A 403 is ambiguous — it may be the post
		// (protected/suspended author) OR our own credential/project/permission/
		// access-level failure. Parse the structured X error body and treat a 403 as
		// terminal ONLY when it proves post deletion/protection; a credential/project
		// 403 (and every other status, e.g. 429/5xx) is transient and must be
		// retried, never used to permanently deny the bonus.
		switch resp.StatusCode {
		case http.StatusNotFound, http.StatusGone:
			return payload, fmt.Errorf("x lookup status %d: %w", resp.StatusCode, ErrXPostTerminal)
		case http.StatusForbidden:
			if forbiddenProvesPostUnavailable(errBody) {
				return payload, fmt.Errorf("x lookup status 403 (post unavailable): %w", ErrXPostTerminal)
			}
			return payload, fmt.Errorf("x lookup status 403 (ambiguous/credential): %w", ErrXPostTransient)
		default:
			return payload, fmt.Errorf("x lookup status %d: %w", resp.StatusCode, ErrXPostTransient)
		}
	}
	mediaType, _, err := mime.ParseMediaType(resp.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		return payload, fmt.Errorf("x lookup content type invalid: %w", ErrXPostTransient)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024+1))
	if err != nil || len(body) > 64*1024 {
		return payload, fmt.Errorf("x lookup response invalid: %w", ErrXPostTransient)
	}
	if err := json.Unmarshal(body, &payload); err != nil || payload.Data.ID != postID {
		return payload, fmt.Errorf("x lookup response mismatch: %w", ErrXPostTransient)
	}
	return payload, nil
}

// VerifyPost confirms the post is public and contains the expected invite URL,
// returning the bound X author id (may be empty if the API omits it). FIX-570 H3
// binds this author id so a later re-check can detect a swapped/deleted post.
func (c *XAPIClient) VerifyPost(ctx context.Context, postID, expectedURL string) (string, error) {
	payload, err := c.fetchPost(ctx, postID)
	if err != nil {
		return "", err
	}
	want, err := canonicalShareURL(expectedURL, c.joinBase)
	if err != nil {
		return "", err
	}
	for _, entity := range payload.Data.Entities.URLs {
		for _, candidate := range []string{entity.Expanded, entity.Unwound} {
			got, err := canonicalShareURL(candidate, c.joinBase)
			if err == nil && got == want {
				return payload.Data.AuthorID, nil
			}
		}
	}
	return "", errors.New("expected invite URL missing")
}

// LookupPostAuthor re-checks, at promotion time, that the post is STILL public
// (a non-200/gone post errors) and returns its current author id so the caller
// can confirm it still matches the author bound at verify time. FIX-570 H3.
func (c *XAPIClient) LookupPostAuthor(ctx context.Context, postID string) (string, error) {
	payload, err := c.fetchPost(ctx, postID)
	if err != nil {
		return "", err
	}
	return payload.Data.AuthorID, nil
}

func canonicalShareURL(raw string, joinBase *url.URL) (string, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || joinBase == nil || joinBase.Scheme != "https" || joinBase.Host == "" ||
		u.Scheme != joinBase.Scheme || !strings.EqualFold(u.Host, joinBase.Host) || u.User != nil || u.Fragment != "" {
		return "", errors.New("invalid share url")
	}
	wantPrefix := strings.TrimRight(joinBase.EscapedPath(), "/") + "/MAL1-"
	if !strings.HasPrefix(u.EscapedPath(), wantPrefix) || strings.TrimSpace(u.Query().Get("c")) == "" {
		return "", errors.New("invalid share url")
	}
	u.Scheme = joinBase.Scheme
	u.Host = joinBase.Host
	u.RawQuery = u.Query().Encode()
	return u.String(), nil
}
