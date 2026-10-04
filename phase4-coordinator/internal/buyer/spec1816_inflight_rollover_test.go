package buyer_test

import (
	"database/sql"
	"fmt"
	"net/http"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// SPEC-042-R015 (last paragraph) / SPEC-047-R011 / SPEC-022-R013 (#1816 F2):
// an in-flight attempt settles from its immutable route snapshot across an
// ordinary manifest rotation and across removing or changing its entry; it
// falls back to zero only when the durable route fence reports a revocation
// between routing and settlement (membership, provider, attestation, pool).
// The fence's per-event semantics are tested on the durable store in
// internal/trustpool (TestPoolRouteFenceAcrossRotationAndRevocation).

var errRevokedSinceRouting = fmt.Errorf("%w: revoked since routing", billing.ErrPoolOperatorAttestationRejected)

// rotated returns snap advanced one accepted generation, with entries as the
// new active core's entries and the old core recorded as the prior one.
func rotated(snap trustpool.RouteableSnapshot, entries []poolmanifest.PoolModelEntry) trustpool.RouteableSnapshot {
	next := snap
	next.PriorManifestVersion, next.PriorManifestCoreDigest = snap.ManifestVersion, snap.ManifestCoreDigest
	next.PriorModelEntries = poolmanifest.ClonePoolModelEntries(snap.ModelEntries)
	next.ManifestVersion = snap.ManifestVersion + 1
	next.ManifestCoreDigest = strings.Repeat("9", 64)
	next.ModelEntries = entries
	return next
}

type ledgerCredit struct {
	gross, provider, quarantined int64
	reason                       string
}

func queryLedgerCredit(t *testing.T, dbPath string) ledgerCredit {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var row ledgerCredit
	var reason sql.NullString
	if err := db.QueryRow(`SELECT gross_credits, provider_credits, quarantined, quarantine_reason FROM ledger_request_credits`).
		Scan(&row.gross, &row.provider, &row.quarantined, &reason); err != nil {
		t.Fatalf("query ledger: %v", err)
	}
	row.reason = reason.String
	return row
}

func TestSPEC1816PoolModelInFlightAcrossRollover(t *testing.T) {
	members := map[string]poolModelFixture{
		"native mlx_cache":         {},
		"creator-owned llama.cpp":  {runtime: "llamacpp_loopback"},
		"R016-attested delegation": {runtime: "llamacpp_loopback", delegated: true, attested: true},
	}
	for memberName, base := range members {
		for name, tc := range map[string]struct {
			midFlight func(*poolModelHarness)
			wantPaid  bool
		}{
			"rotation keeps the entry": {func(h *poolModelHarness) {
				loadTrustedPoolLayer2Snapshot(t, h.trustPools, 1, rotated(h.routeable, h.routeable.ModelEntries))
			}, true},
			"rotation removes the entry": {func(h *poolModelHarness) {
				loadTrustedPoolLayer2Snapshot(t, h.trustPools, 1, rotated(h.routeable, nil))
			}, true},
			"rotation changes the entry's price": {func(h *poolModelHarness) {
				changed := poolmanifest.ClonePoolModelEntries(h.routeable.ModelEntries)
				changed[0].Pricing.CompletionRatePerMtok++
				loadTrustedPoolLayer2Snapshot(t, h.trustPools, 1, rotated(h.routeable, changed))
			}, true},
			"membership or provider revoked": {func(h *poolModelHarness) {
				h.authority.mu.Lock()
				h.authority.fenceErr = errRevokedSinceRouting
				h.authority.mu.Unlock()
			}, false},
			"rotation that also revokes": {func(h *poolModelHarness) {
				loadTrustedPoolLayer2Snapshot(t, h.trustPools, 1, rotated(h.routeable, h.routeable.ModelEntries))
				h.authority.mu.Lock()
				h.authority.fenceErr = errRevokedSinceRouting
				h.authority.mu.Unlock()
			}, false},
		} {
			t.Run(memberName+"/"+name, func(t *testing.T) {
				fx := base
				fx.midFlight = tc.midFlight
				h := newPoolModelHarness(t, fx)
				rec := postChat(t, h.server, h.body(), externalRuntimePoolHeaders(h.poolID))
				if rec.Code != http.StatusOK {
					t.Fatalf("pool-model route status=%d body=%s", rec.Code, rec.Body.String())
				}
				ledger := queryLedgerCredit(t, h.dbPath)
				if tc.wantPaid {
					// Priced from the route snapshot's entry: 1 * 3e6 + 1 * 7e6 per million.
					if ledger.quarantined != 0 || ledger.gross != 10 || ledger.provider == 0 {
						t.Fatalf("in-flight attempt across the rollover ledger=%+v, want 10 from the snapshot", ledger)
					}
					return
				}
				if ledger.gross != 0 || ledger.provider != 0 || ledger.quarantined != 1 {
					t.Fatalf("revoked in-flight attempt ledger=%+v, want zero and quarantined", ledger)
				}
			})
		}
	}
}

// The #1690 catalog-pool member path follows the same rule.
func TestSPEC042ExternalRuntimeInFlightAcrossRollover(t *testing.T) {
	for name, tc := range map[string]struct {
		midFlight func(*externalRuntimeHarness)
		wantPaid  bool
	}{
		"rotation": {func(h *externalRuntimeHarness) {
			next := h.routeable
			next.PriorManifestVersion, next.PriorManifestCoreDigest = next.ManifestVersion, next.ManifestCoreDigest
			next.ManifestVersion++
			next.ManifestCoreDigest = strings.Repeat("9", 64)
			loadTrustedPoolLayer2Snapshot(t, h.trustPools, 1, next)
		}, true},
		"membership, provider, or attestation revoked": {func(h *externalRuntimeHarness) {
			h.authority.mu.Lock()
			h.authority.fenceErr = errRevokedSinceRouting
			h.authority.mu.Unlock()
		}, false},
	} {
		t.Run(name, func(t *testing.T) {
			fx := defaultExternalRuntimeFixture()
			fx.midFlight = tc.midFlight
			h := newExternalRuntimeHarness(t, fx)
			rec := postChat(t, h.server, externalRuntimeBody, externalRuntimePoolHeaders(h.poolID))
			if rec.Code != http.StatusOK {
				t.Fatalf("pool route status=%d body=%s", rec.Code, rec.Body.String())
			}
			ledger := externalRuntimeLedger(t, h.dbPath)
			if tc.wantPaid {
				if ledger.usageSource != billing.UsageSourcePoolOperatorAttested || ledger.quarantined != 0 || ledger.gross == 0 || ledger.provider == 0 {
					t.Fatalf("attested attempt across the rollover ledger=%+v", ledger)
				}
				return
			}
			if ledger.usageSource != billing.UsageSourceByteEstimated || ledger.gross != 0 || ledger.provider != 0 || ledger.quarantined != 1 {
				t.Fatalf("revoked in-flight attempt ledger=%+v", ledger)
			}
		})
	}
}

// #1816 F3: a rotation that keeps the entry byte-identical never gaps
// routing. Before the sweep records the rebind, a binding to the prior
// generation still routes; a changed entry does not.
func TestSPEC1816PoolModelRotationNeverGapsRouting(t *testing.T) {
	for name, fx := range map[string]poolModelFixture{
		"native mlx_cache":        {},
		"creator-owned llama.cpp": {runtime: "llamacpp_loopback"},
	} {
		t.Run(name, func(t *testing.T) {
			h := newPoolModelHarness(t, fx)
			loadTrustedPoolLayer2Snapshot(t, h.trustPools, 0, rotated(h.routeable, h.routeable.ModelEntries))
			for i := 0; i < 5; i++ {
				if rec := postChat(t, h.server, h.body(), externalRuntimePoolHeaders(h.poolID)); rec.Code != http.StatusOK {
					t.Fatalf("request %d after a rotation keeping the entry: status=%d body=%s", i, rec.Code, rec.Body.String())
				}
			}
			snapshot := queryRouteSnapshotBYOMBinding(t, h.dbPath)
			if snapshot["manifest_version"] != float64(h.routeable.ManifestVersion+1) {
				t.Fatalf("route snapshot names manifest_version=%v, want the active generation", snapshot["manifest_version"])
			}

			changed := newPoolModelHarness(t, fx)
			entries := poolmanifest.ClonePoolModelEntries(changed.routeable.ModelEntries)
			entries[0].MaxContextTokens++
			loadTrustedPoolLayer2Snapshot(t, changed.trustPools, 0, rotated(changed.routeable, entries))
			if rec := postChat(t, changed.server, changed.body(), externalRuntimePoolHeaders(changed.poolID)); rec.Code == http.StatusOK {
				t.Fatal("a binding to the prior generation routed after its entry changed")
			}
			skipped := newPoolModelHarness(t, fx)
			twice := rotated(rotated(skipped.routeable, skipped.routeable.ModelEntries), skipped.routeable.ModelEntries)
			twice.ManifestCoreDigest = strings.Repeat("8", 64)
			loadTrustedPoolLayer2Snapshot(t, skipped.trustPools, 0, twice)
			if rec := postChat(t, skipped.server, skipped.body(), externalRuntimePoolHeaders(skipped.poolID)); rec.Code == http.StatusOK {
				t.Fatal("a binding two generations behind routed")
			}
		})
	}
}
