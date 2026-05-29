package auth

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
)

var ErrForbiddenScope = errors.New("oauth scope forbidden")

type OAuthIdentity struct {
	ProviderUserID string
	Email          string
	Scopes         []string
}

type OAuthProvider interface {
	Exchange(ctx context.Context, code, redirectURI string) (OAuthIdentity, error)
}

type GitHubProvider struct {
	cfg    config.GitHubOAuthConfig
	client *http.Client
}

func NewGitHubProvider(cfg config.GitHubOAuthConfig, client *http.Client) GitHubProvider {
	if client == nil {
		client = http.DefaultClient
	}
	return GitHubProvider{cfg: cfg, client: client}
}

func (p GitHubProvider) AuthURL(redirectURI, state string) string {
	values := url.Values{}
	values.Set("client_id", p.cfg.ClientID)
	values.Set("redirect_uri", redirectURI)
	values.Set("state", state)
	values.Set("scope", "read:user")
	return p.cfg.AuthorizeURL + "?" + values.Encode()
}

func (p GitHubProvider) Exchange(ctx context.Context, code, redirectURI string) (OAuthIdentity, error) {
	form := url.Values{}
	form.Set("client_id", p.cfg.ClientID)
	form.Set("client_secret", p.cfg.ClientSecret)
	form.Set("code", code)
	form.Set("redirect_uri", redirectURI)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.cfg.TokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return OAuthIdentity{}, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := p.client.Do(req)
	if err != nil {
		return OAuthIdentity{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return OAuthIdentity{}, fmt.Errorf("github token exchange status %d", resp.StatusCode)
	}
	var tokenResp struct {
		AccessToken string `json:"access_token"`
		Scope       string `json:"scope"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&tokenResp); err != nil {
		return OAuthIdentity{}, err
	}
	scopes := splitScopes(tokenResp.Scope)
	if !ScopesAllowed(scopes) {
		return OAuthIdentity{}, ErrForbiddenScope
	}
	userReq, err := http.NewRequestWithContext(ctx, http.MethodGet, p.cfg.UserURL, nil)
	if err != nil {
		return OAuthIdentity{}, err
	}
	userReq.Header.Set("Accept", "application/json")
	userReq.Header.Set("Authorization", "Bearer "+tokenResp.AccessToken)
	userResp, err := p.client.Do(userReq)
	if err != nil {
		return OAuthIdentity{}, err
	}
	defer userResp.Body.Close()
	if userResp.StatusCode < 200 || userResp.StatusCode > 299 {
		return OAuthIdentity{}, fmt.Errorf("github user status %d", userResp.StatusCode)
	}
	var user struct {
		ID    int64  `json:"id"`
		Email string `json:"email"`
	}
	if err := json.NewDecoder(userResp.Body).Decode(&user); err != nil {
		return OAuthIdentity{}, err
	}
	if user.ID == 0 {
		return OAuthIdentity{}, errors.New("github user id missing")
	}
	return OAuthIdentity{ProviderUserID: fmt.Sprintf("%d", user.ID), Email: user.Email, Scopes: scopes}, nil
}

func ScopesAllowed(scopes []string) bool {
	if len(scopes) == 0 {
		return false
	}
	allowed := map[string]bool{"read:user": true, "user:email": true}
	for _, scope := range scopes {
		if !allowed[scope] {
			return false
		}
	}
	return true
}

func splitScopes(raw string) []string {
	fields := strings.FieldsFunc(raw, func(r rune) bool { return r == ' ' || r == ',' })
	out := make([]string, 0, len(fields))
	for _, field := range fields {
		field = strings.TrimSpace(field)
		if field != "" {
			out = append(out, field)
		}
	}
	sort.Strings(out)
	return out
}

func OAuthStateExpiry(now time.Time) time.Time {
	return now.UTC().Add(10 * time.Minute)
}
