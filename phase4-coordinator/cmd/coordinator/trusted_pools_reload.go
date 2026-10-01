package main

import (
	"fmt"
	"sync/atomic"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// livePoolModelPricingBounds is the one SPEC-005-R015 bounds snapshot that
// manifest acceptance, the SPEC-047-R011 binding sweep, buyer routing, the
// pool /v1/models view, and provider status all read. Boot and every applied
// SIGHUP reload replace it atomically. A route snapshot already inserted
// keeps the bounds digest it recorded, so a reload never re-prices it; a
// binding whose rates fall outside new bounds is unroutable until the
// creator publishes conforming rates.
var livePoolModelPricingBounds atomic.Pointer[poolmanifest.PoolModelPricingBounds]

func currentPoolModelPricingBounds() *poolmanifest.PoolModelPricingBounds {
	return livePoolModelPricingBounds.Load()
}

// trustPoolOwnerAuthority holds the two SPEC-042-R016 owner-authority
// surfaces a reload must update together: the store's provider owner keys
// (delegation grant/revoke checks) and the registry's provider owner
// accounts (attestation match, which advances the routing generation).
type trustPoolOwnerAuthority struct {
	store    *trustpool.Store
	registry *trustpool.Registry
}

// liveTrustPoolOwnerAuthority is set once trusted pools load at boot. Nil
// (pools disabled or not ready) leaves only the bounds to reload.
var liveTrustPoolOwnerAuthority atomic.Pointer[trustPoolOwnerAuthority]

// prepareTrustedPoolsReload validates the reloadable trusted-pool fields of a
// candidate config and returns the step that applies them. The reload runs
// the step only after every other fallible step succeeded, so a rejected
// reload leaves bounds and owner authority untouched and a recorded applied
// config is the one in force.
func prepareTrustedPoolsReload(cfg config.TrustedPoolsConfig) (func(), error) {
	keys, err := trustpool.ParseProviderOwnerPublicKeys(cfg.ProviderOwnerPublicKeys)
	if err != nil {
		return nil, fmt.Errorf("trusted_pools.provider_owner_public_keys: %w", err)
	}
	// ParseProviderOwnerPublicKeys enforces what SetProviderOwnerPublicKeys
	// checks, so the apply step cannot fail.
	authority := liveTrustPoolOwnerAuthority.Load()
	bounds := poolModelPricingBounds(cfg.PoolModelPricingBounds)
	accounts := cfg.ProviderOwnerAccountIDs
	return func() {
		livePoolModelPricingBounds.Store(bounds)
		if authority != nil {
			_ = authority.store.SetProviderOwnerPublicKeys(keys)
			authority.registry.SetProviderOwnerAccounts(accounts)
		}
	}, nil
}
