package ws

import (
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

func TestBootstrapMintLimiterEnforcesIPAndProviderBucketsAtomically(t *testing.T) {
	cfg := config.AuthConfig{
		CredentialBootstrapMintsPerIPHour: 1,
		CredentialBootstrapMintsPerIDHour: 1,
	}
	limiter := newBootstrapMintLimiter(cfg)
	now := time.Date(2026, 7, 10, 12, 0, 0, 0, time.UTC)

	if !limiter.allow("203.0.113.1", "provider-a", now) {
		t.Fatal("first mint was rejected")
	}
	if limiter.allow("203.0.113.1", "provider-b", now) {
		t.Fatal("same-IP mint exceeded bucket")
	}
	if limiter.allow("203.0.113.2", "provider-a", now) {
		t.Fatal("same-provider mint exceeded bucket")
	}
	// The rejected cross-product requests must not consume the independent side.
	if !limiter.allow("203.0.113.2", "provider-b", now) {
		t.Fatal("rejected requests consumed only one side of the paired quota")
	}
	if !limiter.allow("203.0.113.1", "provider-a", now.Add(time.Hour)) {
		t.Fatal("hourly refill did not restore capacity")
	}
}

func TestBootstrapMintLimiterPrunesIdleBuckets(t *testing.T) {
	cfg := config.AuthConfig{
		CredentialBootstrapMintsPerIPHour: 1,
		CredentialBootstrapMintsPerIDHour: 1,
	}
	limiter := newBootstrapMintLimiter(cfg)
	now := time.Date(2026, 7, 10, 12, 0, 0, 0, time.UTC)
	if !limiter.allow("203.0.113.1", "provider-a", now) {
		t.Fatal("first mint was rejected")
	}
	if !limiter.allow("203.0.113.2", "provider-b", now.Add(bootstrapBucketRetention+time.Second)) {
		t.Fatal("later independent mint was rejected")
	}
	if _, ok := limiter.ipBuckets["203.0.113.1"]; ok {
		t.Fatal("idle IP bucket was not pruned")
	}
	if _, ok := limiter.providerBuckets["provider-a"]; ok {
		t.Fatal("idle provider bucket was not pruned")
	}
}
