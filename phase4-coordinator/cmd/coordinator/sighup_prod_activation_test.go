package main

import (
	"bytes"
	"os"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/rs/zerolog"
)

// Freeze audit R1 (#1690) SECURITY M4: the trust-pool production gate is built
// once at startup, so a SIGHUP that changes trusted_pools.production_activation
// must be rejected, never recorded as applied.
func TestSIGHUPRejectsProductionActivationChange(t *testing.T) {
	defer tier2.ResetForTest()
	statePath := useAppliedConfigStatePath(t)
	startup, _, wsServer, buyerServer := reloadTestServers(config.Default())
	reloadTier2Config(writeReloadConfig(t, startup), startup.Tier2, zerolog.Nop(), wsServer, buyerServer, nil)
	before, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatalf("baseline record: %v", err)
	}

	// The running coordinator booted with a production gate; the file on disk
	// no longer carries it.
	booted := config.TrustedPoolsProductionActivationConfig{
		AllowedLaunchEnvironments: []string{"production"},
		EvidenceSHA256:            strings.Repeat("a", 64),
		RootCustodyHashes:         []string{strings.Repeat("b", 64)},
		RootCustodyClasses:        map[string]string{strings.Repeat("b", 64): "hsm"},
	}
	reloadStartupTrustedPoolsProductionActivation.Store(&booted)
	t.Cleanup(func() { reloadStartupTrustedPoolsProductionActivation.Store(nil) })

	var logs bytes.Buffer
	reloadTier2Config(writeReloadConfig(t, startup), startup.Tier2, zerolog.New(&logs), wsServer, buyerServer, nil)
	if !strings.Contains(logs.String(), "trusted_pools.production_activation is startup-only") {
		t.Fatalf("expected a rejected reload, logs=%s", logs.String())
	}
	if after, _ := os.ReadFile(statePath); !bytes.Equal(before, after) {
		t.Fatalf("rejected production_activation reload rewrote the applied record: %s", after)
	}

	// An equal gate (modulo whitespace and ordering) is not a change.
	same := startup
	same.TrustedPools.ProductionActivation = booted
	if trustedPoolsProductionActivationChanged(booted, config.TrustedPoolsProductionActivationConfig{
		AllowedLaunchEnvironments: []string{" production "},
		EvidenceSHA256:            strings.Repeat("a", 64) + " ",
		RootCustodyHashes:         []string{strings.Repeat("b", 64)},
		RootCustodyClasses:        map[string]string{strings.Repeat("b", 64): " hsm"},
	}) {
		t.Fatal("normalized-equal production activation reported as changed")
	}
	if trustedPoolsProductionActivationChanged(booted, same.TrustedPools.ProductionActivation) {
		t.Fatal("identical production activation reported as changed")
	}
}
