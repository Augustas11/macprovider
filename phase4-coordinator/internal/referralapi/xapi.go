package referralapi

import (
	"context"
	"crypto/sha256"
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
		u.Port() != "" || u.User != nil || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" {
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

func NewXAPIClient(bearer, joinBaseURL string) (*XAPIClient, error) {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.ResponseHeaderTimeout = 4 * time.Second
	joinBase, err := parseJoinBaseURL(joinBaseURL)
	if err != nil {
		return nil, err
	}
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
	}, nil
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
		body, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		switch response.StatusCode {
		case http.StatusNotFound, http.StatusGone:
			return payload, fmt.Errorf("x lookup status %d: %w", response.StatusCode, ErrXPostTerminal)
		case http.StatusForbidden:
			if describesProtectedOrPrivatePost(body) {
				return payload, fmt.Errorf("x post is protected or private: %w", ErrXPostTerminal)
			}
			return payload, fmt.Errorf("x lookup status %d: %w", response.StatusCode, ErrXPostTransient)
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

// RecheckPost proves that the same public post still contains the exact
// canonical invite URL accepted during submission. The digest keeps the
// challenge and invite code bound without retaining or logging the URL.
func (c *XAPIClient) RecheckPost(ctx context.Context, postID, expectedURLHash string) (string, error) {
	if !socialChallengePattern.MatchString(strings.TrimSpace(expectedURLHash)) {
		return "", fmt.Errorf("invalid expected share URL digest: %w", ErrXPostTerminal)
	}
	payload, err := c.fetchPost(ctx, postID)
	if err != nil {
		return "", err
	}
	for _, entity := range payload.Data.Entities.URLs {
		for _, candidate := range []string{entity.Expanded, entity.Unwound} {
			canonical, err := canonicalShareURL(candidate, c.joinBase)
			if err != nil {
				continue
			}
			digest := sha256.Sum256([]byte(canonical))
			if fmt.Sprintf("%x", digest[:]) == expectedURLHash {
				return payload.Data.AuthorID, nil
			}
		}
	}
	return "", fmt.Errorf("exact invite URL no longer present: %w", ErrXPostTerminal)
}

func ShareURLDigest(raw, joinBaseURL string) (string, error) {
	joinBase, err := parseJoinBaseURL(joinBaseURL)
	if err != nil {
		return "", err
	}
	canonical, err := canonicalShareURL(raw, joinBase)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256([]byte(canonical))
	return fmt.Sprintf("%x", digest[:]), nil
}

func parseJoinBaseURL(raw string) (*url.URL, error) {
	joinBase, err := url.Parse(strings.TrimRight(strings.TrimSpace(raw), "/"))
	if err != nil || joinBase.Scheme != "https" || joinBase.Host == "" || joinBase.User != nil ||
		joinBase.RawQuery != "" || joinBase.ForceQuery || joinBase.Fragment != "" || !strings.HasSuffix(strings.TrimRight(joinBase.Path, "/"), "/j") {
		return nil, errors.New("join base URL must be a credential-free absolute https URL ending in /j")
	}
	return joinBase, nil
}

func describesProtectedOrPrivatePost(body []byte) bool {
	var problem struct {
		Type   string `json:"type"`
		Errors []struct {
			Type string `json:"type"`
			Code int    `json:"code"`
		} `json:"errors"`
	}
	if json.Unmarshal(body, &problem) != nil {
		return false
	}
	if strings.HasSuffix(problem.Type, "/not-authorized-for-resource") {
		return true
	}
	for _, item := range problem.Errors {
		if strings.HasSuffix(item.Type, "/not-authorized-for-resource") || item.Code == 179 {
			return true
		}
	}
	return false
}

func canonicalShareURL(raw string, joinBase *url.URL) (string, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || joinBase == nil || joinBase.Scheme != "https" || joinBase.Host == "" ||
		u.Scheme != joinBase.Scheme || !strings.EqualFold(u.Host, joinBase.Host) || u.User != nil || u.ForceQuery || u.Fragment != "" {
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
