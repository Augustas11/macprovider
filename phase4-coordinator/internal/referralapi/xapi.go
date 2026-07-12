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
		return payload, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		return payload, fmt.Errorf("x lookup status %d", resp.StatusCode)
	}
	mediaType, _, err := mime.ParseMediaType(resp.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		return payload, errors.New("x lookup content type invalid")
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024+1))
	if err != nil || len(body) > 64*1024 {
		return payload, errors.New("x lookup response invalid")
	}
	if err := json.Unmarshal(body, &payload); err != nil || payload.Data.ID != postID {
		return payload, errors.New("x lookup response mismatch")
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
