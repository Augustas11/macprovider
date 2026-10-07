package buyer

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
)

func TestPoolModelDisclosureHeadersRequireCurrentAttemptSnapshot(t *testing.T) {
	const modelID = "pool/pool-a/creator-model"
	base := &billingRecorder{
		requestID:                     "req-1",
		model:                         modelID,
		dispatchedThisAttempt:         true,
		settlementAttemptN:            3,
		hasSettlementAttemptN:         true,
		settlementRouteSnapshot:       poolModelDisclosureSnapshot("req-1", "pool-a", modelID, "provider-a", 3),
		settlementRouteSnapshotDigest: strings.Repeat("a", 64),
		state: &forwardState{
			poolID: "pool-a",
			provider: pool.Provider{
				ProviderID: "provider-a",
				AssignedID: "session-a",
			},
		},
	}
	for name, mutate := range map[string]func(*billingRecorder){
		"current attempt": nil,
		"stale request": func(r *billingRecorder) {
			r.settlementRouteSnapshot.RequestID = "req-2"
		},
		"wrong pool": func(r *billingRecorder) {
			r.settlementRouteSnapshot.PoolID = "pool-b"
		},
		"wrong route model": func(r *billingRecorder) {
			r.settlementRouteSnapshot.ModelID = "pool/pool-a/other"
		},
		"wrong pool model": func(r *billingRecorder) {
			r.settlementRouteSnapshot.PoolModelID = "pool/pool-a/other"
		},
		"wrong provider": func(r *billingRecorder) {
			r.settlementRouteSnapshot.ProviderID = "provider-b"
		},
		"wrong provider session": func(r *billingRecorder) {
			r.settlementRouteSnapshot.ProviderSessionID = stringPtrOrNil("session-b")
		},
		"missing provider session": func(r *billingRecorder) {
			r.settlementRouteSnapshot.ProviderSessionID = nil
		},
		"current provider session changed": func(r *billingRecorder) {
			r.state.provider.AssignedID = "session-b"
		},
		"not dispatched": func(r *billingRecorder) {
			r.dispatchedThisAttempt = false
		},
		"stale attempt": func(r *billingRecorder) {
			r.settlementRouteSnapshot.AttemptN = 2
		},
		"error status": nil,
	} {
		t.Run(name, func(t *testing.T) {
			rec := clonePoolModelDisclosureRecorder(base)
			if mutate != nil {
				mutate(rec)
			}
			status := http.StatusOK
			if name == "error status" {
				status = http.StatusServiceUnavailable
			}
			h := http.Header{}
			publishPoolModelDisclosureHeaders(h, rec, status)
			gotDisclosure := h.Get(poolModelDisclosureHeader)
			gotDigest := h.Get(poolManifestCoreDigestHeader)
			if name == "current attempt" {
				if gotDisclosure != "pool_attested_unverified" || gotDigest != strings.Repeat("d", 64) {
					t.Fatalf("headers=(%q,%q), want disclosure and digest", gotDisclosure, gotDigest)
				}
				return
			}
			if gotDisclosure != "" || gotDigest != "" {
				t.Fatalf("headers=(%q,%q), want stripped", gotDisclosure, gotDigest)
			}
		})
	}
}

func TestPoolModelDisclosureHeadersPublishAtFirstCommitOnly(t *testing.T) {
	const modelID = "pool/pool-a/creator-model"
	newRecorder := func() *billingRecorder {
		return &billingRecorder{
			requestID:                     "req-1",
			model:                         modelID,
			dispatchedThisAttempt:         true,
			settlementAttemptN:            3,
			hasSettlementAttemptN:         true,
			settlementRouteSnapshot:       poolModelDisclosureSnapshot("req-1", "pool-a", modelID, "provider-a", 3),
			settlementRouteSnapshotDigest: strings.Repeat("a", 64),
			state: &forwardState{
				poolID: "pool-a",
				provider: pool.Provider{
					ProviderID: "provider-a",
					AssignedID: "session-a",
				},
			},
		}
	}

	t.Run("implicit write publishes actual snapshot digest over stale candidate", func(t *testing.T) {
		inner := httptest.NewRecorder()
		inner.Header().Set(poolModelDisclosureHeader, poolmanifest.PoolModelDisclosureClass)
		inner.Header().Set(poolManifestCoreDigestHeader, strings.Repeat("c", 64))
		w := &noPriorDispatchResponseWriter{ResponseWriter: inner, rec: newRecorder()}
		if _, err := w.Write([]byte("data: {}\n\n")); err != nil {
			t.Fatalf("write: %v", err)
		}
		if got := inner.Header().Get(poolManifestCoreDigestHeader); got != strings.Repeat("d", 64) {
			t.Fatalf("digest = %q, want actual route snapshot digest", got)
		}
	})

	t.Run("flush publishes disclosure on first commit", func(t *testing.T) {
		inner := httptest.NewRecorder()
		w := &noPriorDispatchResponseWriter{ResponseWriter: inner, rec: newRecorder()}
		w.Flush()
		if got := inner.Header().Get(poolModelDisclosureHeader); got != poolmanifest.PoolModelDisclosureClass {
			t.Fatalf("disclosure = %q, want pool disclosure", got)
		}
		if got := inner.Header().Get(poolManifestCoreDigestHeader); got != strings.Repeat("d", 64) {
			t.Fatalf("digest = %q, want actual route snapshot digest", got)
		}
	})

	t.Run("later terminal after committed stream cannot strip disclosure", func(t *testing.T) {
		inner := httptest.NewRecorder()
		w := &noPriorDispatchResponseWriter{ResponseWriter: inner, rec: newRecorder()}
		if _, err := w.Write([]byte("data: {}\n\n")); err != nil {
			t.Fatalf("write: %v", err)
		}
		w.WriteHeader(http.StatusBadGateway)
		if got := inner.Header().Get(poolModelDisclosureHeader); got != poolmanifest.PoolModelDisclosureClass {
			t.Fatalf("disclosure after late error = %q, want preserved", got)
		}
		if got := inner.Header().Get(poolManifestCoreDigestHeader); got != strings.Repeat("d", 64) {
			t.Fatalf("digest after late error = %q, want preserved", got)
		}
	})
}

func poolModelDisclosureSnapshot(requestID, poolID, modelID, providerID string, attemptN int64) *billing.RouteSnapshot {
	return &billing.RouteSnapshot{
		RequestID:               requestID,
		PoolID:                  poolID,
		ModelID:                 modelID,
		PoolModelID:             modelID,
		ProviderID:              providerID,
		ProviderSessionID:       stringPtrOrNil("session-a"),
		AttemptN:                attemptN,
		ExpectedModelHashSource: billing.ExpectedModelHashSourcePoolManifest,
		ManifestCoreDigest:      strings.Repeat("d", 64),
	}
}

func clonePoolModelDisclosureRecorder(in *billingRecorder) *billingRecorder {
	out := *in
	snap := *in.settlementRouteSnapshot
	out.settlementRouteSnapshot = &snap
	state := *in.state
	out.state = &state
	return &out
}
