package github

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

const (
	DefaultAuthorizeURL = "https://github.com/login/oauth/authorize"
	DefaultTokenURL     = "https://github.com/login/oauth/access_token"
	DefaultUserURL      = "https://api.github.com/user"
)

type User struct {
	ID    int64  `json:"id"`
	Login string `json:"login"`
}

type Client struct {
	HTTPClient *http.Client
	TokenURL   string
	UserURL    string
}

func (c Client) ExchangeCode(ctx context.Context, clientID, clientSecret, redirectURI, code string) (string, error) {
	endpoint := c.TokenURL
	if endpoint == "" {
		endpoint = DefaultTokenURL
	}
	body, _ := json.Marshal(map[string]string{
		"client_id":     clientID,
		"client_secret": clientSecret,
		"redirect_uri":  redirectURI,
		"code":          code,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.httpClient().Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, resp.Body)
		return "", fmt.Errorf("github token exchange status %d", resp.StatusCode)
	}
	var out struct {
		AccessToken string `json:"access_token"`
		Error       string `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", err
	}
	if out.Error != "" || out.AccessToken == "" {
		if out.Error == "" {
			out.Error = "missing_access_token"
		}
		return "", fmt.Errorf("github token exchange failed: %s", out.Error)
	}
	return out.AccessToken, nil
}

func (c Client) User(ctx context.Context, accessToken string) (User, error) {
	endpoint := c.UserURL
	if endpoint == "" {
		endpoint = DefaultUserURL
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return User{}, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Authorization", "Bearer "+accessToken)
	resp, err := c.httpClient().Do(req)
	if err != nil {
		return User{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, resp.Body)
		return User{}, fmt.Errorf("github user lookup status %d", resp.StatusCode)
	}
	var user User
	if err := json.NewDecoder(resp.Body).Decode(&user); err != nil {
		return User{}, err
	}
	if user.ID <= 0 || user.Login == "" {
		return User{}, fmt.Errorf("github user response missing id/login")
	}
	return user, nil
}

func AuthorizeURL(clientID, redirectURI, state string) string {
	q := url.Values{}
	q.Set("client_id", clientID)
	q.Set("redirect_uri", redirectURI)
	q.Set("scope", "read:user")
	q.Set("state", state)
	return DefaultAuthorizeURL + "?" + q.Encode()
}

func (c Client) httpClient() *http.Client {
	if c.HTTPClient != nil {
		return c.HTTPClient
	}
	return &http.Client{Timeout: 10 * time.Second}
}
