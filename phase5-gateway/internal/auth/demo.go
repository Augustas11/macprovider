package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/netip"
	"strings"
	"time"
)

var ErrInvalidDemoToken = errors.New("invalid demo token")

type DemoManager struct {
	secret []byte
}

type DemoPayload struct {
	Version int    `json:"v"`
	IP      string `json:"ip"`
	Issued  int64  `json:"iat"`
	Expires int64  `json:"exp"`
}

func NewDemoManager(secret string) DemoManager {
	return DemoManager{secret: []byte(secret)}
}

func (m DemoManager) Issue(clientIP string, now time.Time, ttl time.Duration) (string, time.Time, error) {
	if ttl <= 0 || ttl > 24*time.Hour {
		ttl = 24 * time.Hour
	}
	expires := now.UTC().Add(ttl)
	payload := DemoPayload{Version: 1, IP: normalizeDemoIP(clientIP), Issued: now.UTC().Unix(), Expires: expires.Unix()}
	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		return "", time.Time{}, err
	}
	encodedPayload := base64.RawURLEncoding.EncodeToString(payloadBytes)
	sig := m.sign([]byte(encodedPayload))
	return encodedPayload + "." + base64.RawURLEncoding.EncodeToString(sig), expires, nil
}

func (m DemoManager) Validate(token, clientIP string, now time.Time) (DemoPayload, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		return DemoPayload{}, ErrInvalidDemoToken
	}
	expected := m.sign([]byte(parts[0]))
	got, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || !hmac.Equal(expected, got) {
		return DemoPayload{}, ErrInvalidDemoToken
	}
	payloadBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return DemoPayload{}, ErrInvalidDemoToken
	}
	var payload DemoPayload
	if err := json.Unmarshal(payloadBytes, &payload); err != nil {
		return DemoPayload{}, ErrInvalidDemoToken
	}
	if payload.Version != 1 || now.UTC().Unix() >= payload.Expires {
		return DemoPayload{}, ErrInvalidDemoToken
	}
	if payload.IP != normalizeDemoIP(clientIP) {
		return DemoPayload{}, ErrInvalidDemoToken
	}
	return payload, nil
}

func (m DemoManager) sign(payload []byte) []byte {
	mac := hmac.New(sha256.New, m.secret)
	_, _ = mac.Write(payload)
	return mac.Sum(nil)
}

func normalizeDemoIP(raw string) string {
	addr, err := netip.ParseAddr(strings.TrimSpace(raw))
	if err != nil {
		return raw
	}
	if addr.Is4() {
		return addr.String()
	}
	return netip.PrefixFrom(addr, 64).Masked().String()
}
