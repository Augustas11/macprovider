package auth

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"strings"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

type KeyManager struct {
	prefix string
	mode   string
	secret []byte
}

func NewKeyManager(prefix, mode, secret string) KeyManager {
	return KeyManager{prefix: prefix, mode: mode, secret: []byte(secret)}
}

func (m KeyManager) Issue(ctx context.Context, store storage.KeyStore, accountID string) (fullKey string, summary storage.APIKey, err error) {
	fullKey, summary, err = m.Generate(accountID)
	if err != nil {
		return "", storage.APIKey{}, err
	}
	if err := store.CreateAPIKey(ctx, summary); err != nil {
		return "", storage.APIKey{}, err
	}
	return fullKey, summary, nil
}

func (m KeyManager) Generate(accountID string) (fullKey string, summary storage.APIKey, err error) {
	random, err := randomBytes(32)
	if err != nil {
		return "", storage.APIKey{}, err
	}
	fullKey = m.prefix + base64.RawURLEncoding.EncodeToString(random)
	hash := m.Hash(fullKey)
	keyID, err := RandomID("key")
	if err != nil {
		return "", storage.APIKey{}, err
	}
	summary = storage.APIKey{
		KeyID: keyID, AccountID: accountID, KeyHash: hash, KeyHashPrefix: keyPrefix(fullKey),
		Status: "active", CreatedAt: time.Now().UTC(),
	}
	return fullKey, summary, nil
}

func (m KeyManager) Validate(ctx context.Context, store storage.KeyStore, fullKey string) (storage.KeyValidation, error) {
	if !strings.HasPrefix(fullKey, m.prefix) {
		return storage.KeyValidation{}, storage.ErrNotFound
	}
	return store.ValidateAPIKeyHash(ctx, m.Hash(fullKey))
}

func (m KeyManager) Hash(fullKey string) []byte {
	if m.mode == "hmac_sha256" {
		mac := hmac.New(sha256.New, m.secret)
		_, _ = mac.Write([]byte(fullKey))
		return mac.Sum(nil)
	}
	sum := sha256.Sum256([]byte(fullKey))
	return sum[:]
}

func RandomID(prefix string) (string, error) {
	b, err := randomBytes(16)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%s_%s", prefix, hex.EncodeToString(b)), nil
}

func StateToken() (string, error) {
	b, err := randomBytes(32)
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

func StateHash(state string) []byte {
	sum := sha256.Sum256([]byte(state))
	return sum[:]
}

func randomBytes(n int) ([]byte, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return nil, err
	}
	return b, nil
}

func keyPrefix(fullKey string) string {
	if len(fullKey) <= 12 {
		return fullKey
	}
	return fullKey[:12]
}
