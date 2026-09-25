package buyer_test

import (
	"net/http"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/billing"
)

// SPEC-042-R014 / SPEC-006-R016 (#1690 M7): buyer engine selection through
// the coordinator buyer handler, on the #1690 M4 external-runtime harness (a
// llama-server GGUF member of a pool whose v2 allowlist is llamacpp_loopback).

func withEngine(h http.Header, values ...string) http.Header {
	h["X-MacProvider-Internal-Engine"] = values
	return h
}

// engine=llamacpp on an allowlisting pool is served by the llama.cpp member,
// discloses the class, records it in the route snapshot, and settles
// pool_operator_attested exactly as an unselected pool request does.
func TestSPEC042R014LlamacppOnAllowlistingPoolServedAndDisclosed(t *testing.T) {
	h := newExternalRuntimeHarness(t, defaultExternalRuntimeFixture())
	rec := postChat(t, h.server, externalRuntimeBody, withEngine(externalRuntimePoolHeaders(h.poolID), "llamacpp_loopback"))
	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	if got := rec.Header().Get("X-MacProvider-Engine"); got != "llamacpp_loopback" {
		t.Fatalf("X-MacProvider-Engine=%q", got)
	}
	if got := queryRouteSnapshotBYOMBinding(t, h.dbPath)["runtime_source"]; got != "llamacpp_loopback" {
		t.Fatalf("route snapshot runtime_source=%v", got)
	}
	ledger := externalRuntimeLedger(t, h.dbPath)
	if ledger.usageSource != billing.UsageSourcePoolOperatorAttested || ledger.provider == 0 {
		t.Fatalf("ledger=%+v", ledger)
	}
}

// No selection: routing is unchanged, and the served class is still disclosed.
func TestSPEC042R014AbsentSelectionUnchangedAndDisclosed(t *testing.T) {
	h := newExternalRuntimeHarness(t, defaultExternalRuntimeFixture())
	rec := postChat(t, h.server, externalRuntimeBody, externalRuntimePoolHeaders(h.poolID))
	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	if got := rec.Header().Get("X-MacProvider-Engine"); got != "llamacpp_loopback" {
		t.Fatalf("X-MacProvider-Engine=%q", got)
	}
}

// A pool with a native member and a llama.cpp member honours each selection
// with the member of that class.
func TestSPEC042R014MixedPoolHonoursEachSelection(t *testing.T) {
	for class, want := range map[string]string{"mlx_cache": "p2", "llamacpp_loopback": "p1"} {
		fx := defaultExternalRuntimeFixture()
		fx.nativeMember = true
		h := newExternalRuntimeHarness(t, fx)
		rec := postChat(t, h.server, externalRuntimeBody, withEngine(externalRuntimePoolHeaders(h.poolID), class))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: status=%d body=%s", class, rec.Code, rec.Body.String())
		}
		if got := rec.Header().Get("X-MacProvider-Provider"); got != want {
			t.Fatalf("%s: served by %q want %q", class, got, want)
		}
		if got := rec.Header().Get("X-MacProvider-Engine"); got != class {
			t.Fatalf("%s: X-MacProvider-Engine=%q", class, got)
		}
	}
}

// SPEC-042-R014 fail-closed set through the handler: no route snapshot, no
// provider call, and nothing billable.
func TestSPEC042R014EngineFailClosedSet(t *testing.T) {
	cases := map[string]struct {
		headers func(poolID string) http.Header
		status  int
		code    string
	}{
		"native on a pool whose only member is llama.cpp": {
			headers: func(p string) http.Header {
				return withEngine(externalRuntimePoolHeaders(p), "mlx_cache")
			},
			status: http.StatusServiceUnavailable, code: "engine_unavailable",
		},
		"ollama on a pool that allowlists only llamacpp": {
			headers: func(p string) http.Header {
				return withEngine(externalRuntimePoolHeaders(p), "ollama_loopback")
			},
			status: http.StatusServiceUnavailable, code: "engine_unavailable",
		},
		"llamacpp on a global route": {
			headers: func(string) http.Header { return withEngine(globalRouteHeaders(), "llamacpp_loopback") },
			status:  http.StatusServiceUnavailable, code: "engine_unavailable",
		},
		"selector name instead of a runtime class": {
			headers: func(p string) http.Header {
				return withEngine(externalRuntimePoolHeaders(p), "llamacpp")
			},
			status: http.StatusBadRequest, code: "invalid_engine_selection",
		},
		"conflicting internal values": {
			headers: func(p string) http.Header {
				return withEngine(externalRuntimePoolHeaders(p), "llamacpp_loopback", "mlx_cache")
			},
			status: http.StatusBadRequest, code: "invalid_engine_selection",
		},
		"internal engine header without the gateway bearer": {
			headers: func(string) http.Header { return withEngine(http.Header{}, "llamacpp_loopback") },
		},
	}
	for name, tc := range cases {
		tc := tc
		t.Run(name, func(t *testing.T) {
			h := newExternalRuntimeHarness(t, defaultExternalRuntimeFixture())
			rec := postChat(t, h.server, externalRuntimeBody, tc.headers(h.poolID))
			if rec.Code == http.StatusOK || (tc.status != 0 && rec.Code != tc.status) {
				t.Fatalf("status=%d body=%s, want %d", rec.Code, rec.Body.String(), tc.status)
			}
			if tc.code != "" && !strings.Contains(rec.Body.String(), `"code":"`+tc.code+`"`) {
				t.Fatalf("body=%s, want code %s", rec.Body.String(), tc.code)
			}
			if rows := queryRouteSnapshotBYOMBindings(t, h.dbPath); len(rows) != 0 {
				t.Fatalf("route snapshot written: %#v", rows)
			}
			if got := len(h.settlementMetadata()); got != 0 {
				t.Fatalf("provider called %d times", got)
			}
			if got := ledgerCreditCount(t, h.dbPath); got != 0 {
				t.Fatalf("ledger credits=%d want 0", got)
			}
		})
	}
}
