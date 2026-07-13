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

var xIDPattern = regexp.MustCompile(`^[0-9]{1,24}$`)
var socialChallengePattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

var (
	ErrXPostTerminal  = errors.New("x post terminally unavailable")
	ErrXPostTransient = errors.New("x post lookup transient failure")
)

func ParseXPostID(raw string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Scheme != "https" || !strings.EqualFold(u.Hostname(), "x.com") ||
		u.Port() != "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", errors.New("invalid x post url")
	}
	parts := strings.Split(strings.Trim(u.EscapedPath(), "/"), "/")
	if len(parts) != 3 || parts[0] == "" || parts[1] != "status" || !xIDPattern.MatchString(parts[2]) {
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
	if c == nil || c.bearer == "" || !xIDPattern.MatchString(postID) {
		return payload, fmt.Errorf("x verifier unavailable: %w", ErrXPostTransient)
	}
	endpoint := "https://api.x.com/2/tweets/" + postID + "?tweet.fields=entities,author_id"
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return payload, fmt.Errorf("build x lookup: %w", ErrXPostTransient)
	}
	request.Header.Set("Authorization", "Bearer "+c.bearer)
	request.Header.Set("Accept", "application/json")
	response, err := c.client.Do(request)
	if err != nil {
		return payload, fmt.Errorf("x lookup transport: %w", ErrXPostTransient)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
		switch response.StatusCode {
		case http.StatusNotFound, http.StatusGone:
			return payload, fmt.Errorf("x lookup status %d: %w", response.StatusCode, ErrXPostTerminal)
		default:
			return payload, fmt.Errorf("x lookup status %d: %w", response.StatusCode, ErrXPostTransient)
		}
	}
	mediaType, _, err := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		return payload, fmt.Errorf("x lookup content type: %w", ErrXPostTransient)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 64*1024+1))
	if err != nil || len(body) > 64*1024 {
		return payload, fmt.Errorf("x lookup response size: %w", ErrXPostTransient)
	}
	if err := json.Unmarshal(body, &payload); err != nil || payload.Data.ID != postID || !xIDPattern.MatchString(payload.Data.AuthorID) {
		return payload, fmt.Errorf("x lookup response mismatch: %w", ErrXPostTransient)
	}
	return payload, nil
}

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
	if !strings.HasPrefix(u.EscapedPath(), wantPrefix) {
		return "", errors.New("invalid share url")
	}
	query := u.Query()
	challenges, ok := query["c"]
	if !ok || len(query) != 1 || len(challenges) != 1 || !socialChallengePattern.MatchString(challenges[0]) {
		return "", errors.New("invalid share url")
	}
	u.Scheme = joinBase.Scheme
	u.Host = joinBase.Host
	u.RawQuery = query.Encode()
	return u.String(), nil
}
