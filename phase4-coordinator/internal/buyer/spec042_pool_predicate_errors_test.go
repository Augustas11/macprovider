package buyer

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
	"github.com/rs/zerolog"
)

func TestPoolPredicateErrors_EncryptedLegUnsatisfied(t *testing.T) {
	registry := pool.NewRegistry(nil)
	tp := trustpool.NewRegistry()
	plain := poolProvider("member-plain")
	plain.EncryptedLeg = false
	registry.Register(&plain, nil)
	tp.AddMember("P", "member-plain")
	s := NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		WithPoolMembership(tp),
		WithTier2Config(config.Tier2Config{RequireEncryptedLeg: true}),
	)

	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.code != "pool_encrypted_leg_unsatisfied" {
		t.Fatalf("encrypted-leg pool predicate: want pool_encrypted_leg_unsatisfied, got %+v", routeErr)
	}
	if spec018RetryableByCode[routeErr.code] {
		t.Fatal("pool_encrypted_leg_unsatisfied must be non-retryable")
	}
}

func TestPoolPredicateErrors_AttestationUnsatisfied(t *testing.T) {
	registry := pool.NewRegistry(nil)
	tp := trustpool.NewRegistry()
	unsupported := poolProvider("member-unsupported")
	unsupported.EncryptedLeg = true
	unsupported.AttestationStatus = pool.AttestationStatusUnsupported
	registry.Register(&unsupported, nil)
	tp.AddMember("P", "member-unsupported")
	s := NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		WithPoolMembership(tp),
		WithTier2Config(config.Tier2Config{RequireAttestation: true}),
	)

	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.code != "pool_attestation_unsatisfied" {
		t.Fatalf("attestation pool predicate: want pool_attestation_unsatisfied, got %+v", routeErr)
	}
	if spec018RetryableByCode[routeErr.code] {
		t.Fatal("pool_attestation_unsatisfied must be non-retryable")
	}
}

func TestPoolPredicateErrors_SettlementModeUnsatisfied(t *testing.T) {
	s, registry := enforceReceiptServer(t)
	tp := trustpool.NewRegistry()
	s.trustPools = tp
	noKey := receiptGateProvider("member-no-key", nil)
	noKey.TrustedPoolV1 = true
	registry.Register(&noKey, nil)
	tp.AddMember("P", "member-no-key")

	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.code != "pool_settlement_mode_unsatisfied" {
		t.Fatalf("settlement pool predicate: want pool_settlement_mode_unsatisfied, got %+v", routeErr)
	}
	if spec018RetryableByCode[routeErr.code] {
		t.Fatal("pool_settlement_mode_unsatisfied must be non-retryable")
	}
}

func TestPoolPredicateErrors_ProviderCapabilityUnsatisfied(t *testing.T) {
	registry := pool.NewRegistry(nil)
	tp := trustpool.NewRegistry()
	legacy := poolProvider("member-legacy")
	legacy.TrustedPoolV1 = false
	registry.Register(&legacy, nil)
	tp.AddMember("P", "member-legacy")
	s := NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		WithPoolMembership(tp),
	)

	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.code != "pool_provider_capability_unsatisfied" {
		t.Fatalf("provider capability pool predicate: want pool_provider_capability_unsatisfied, got %+v", routeErr)
	}
	if spec018RetryableByCode[routeErr.code] {
		t.Fatal("pool_provider_capability_unsatisfied must be non-retryable")
	}
}

func TestPoolPredicateErrors_CapableMemberLaterPredicateWinsOverLegacyCapability(t *testing.T) {
	registry := pool.NewRegistry(nil)
	tp := trustpool.NewRegistry()
	legacy := poolProvider("member-legacy")
	legacy.TrustedPoolV1 = false
	registry.Register(&legacy, nil)
	tp.AddMember("P", "member-legacy")

	capablePlain := poolProvider("member-capable-plain")
	capablePlain.EncryptedLeg = false
	registry.Register(&capablePlain, nil)
	tp.AddMember("P", "member-capable-plain")

	s := NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		WithPoolMembership(tp),
		WithTier2Config(config.Tier2Config{RequireEncryptedLeg: true}),
	)

	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.code != "pool_encrypted_leg_unsatisfied" {
		t.Fatalf("mixed capability/predicate failure: want pool_encrypted_leg_unsatisfied, got %+v", routeErr)
	}
}
