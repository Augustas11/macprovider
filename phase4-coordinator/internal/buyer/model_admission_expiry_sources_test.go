package buyer_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/rs/zerolog"
)

// Preserve the actual independently verified feed fixture and extend only the
// reference lifetime, using a newly signed reference and the real strict loader.
func configureLongLivedExpiryReference(t *testing.T, p pool.Provider, generated time.Time) {
	t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	body := map[string]any{
		"catalog_id": "expiry-independent-tier2", "issued_at": generated.Format(time.RFC3339),
		"expires_at": generated.Add(30 * 24 * time.Hour).Format(time.RFC3339), "version": 1,
		"models": []map[string]any{{"model_id": p.ModelID, "sha256": p.ModelHash, "artifact_kind": "mlx_weight_file", "hash_scope": "primary_weight_file", "source": "operator-curated"}},
	}
	canonical, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	body["signature"] = map[string]any{"alg": "Ed25519", "key_id": "expiry-independent-key", "sig": base64.RawURLEncoding.EncodeToString(ed25519.Sign(private, canonical))}
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	if err := tier2.ConfigureStrict(config.Tier2Config{ObserveEnabled: true, CatalogPath: writeRouteSnapshotCatalog(t, raw), CatalogPublicKey: base64.RawURLEncoding.EncodeToString(public), RequireHashVerified: true}, zerolog.Nop()); err != nil {
		t.Fatal(err)
	}
}

func TestPrimaryAdmissionSignedSourceExpiryBoundaries(t *testing.T) {
	for _, source := range []string{"reference", "feed_14_days"} {
		t.Run(source, func(t *testing.T) {
			for _, boundary := range []string{"minus_1ms", "exact"} {
				t.Run(boundary, func(t *testing.T) {
					server, p, event, feeds, _, _ := primaryAdmissionFixture(t)
					generated := feeds.CatalogArtifactsVerification.GeneratedAt
					for _, proof := range []buyer.AutotuneFeedVerification{feeds.AutotuneCandidatesVerification, feeds.RateCardVerification} {
						if !proof.GeneratedAt.Equal(generated) {
							t.Fatal("fixture feed generation differs; boundary would not isolate shared feed lifetime")
						}
					}
					if source == "feed_14_days" {
						configureLongLivedExpiryReference(t, p, generated)
					}
					material, ok := tier2.SnapshotMaterial(p.ModelID, p.ModelHash)
					if !ok {
						t.Fatal("actual verified reference material absent")
					}
					feedExpiry := generated.Add(14 * 24 * time.Hour)
					expiry := material.CatalogExpiresAt
					reason := "settlement_reference_unavailable"
					if source == "reference" {
						if !expiry.Before(feedExpiry) {
							t.Fatal("reference expiry not isolated before signed feed expiry")
						}
					} else {
						expiry = feedExpiry
						reason = "feed_stale_or_changed"
						if !material.CatalogExpiresAt.Equal(generated.Add(30*24*time.Hour)) || !expiry.Before(material.CatalogExpiresAt) {
							t.Fatal("independent reference does not outlive feed boundary")
						}
					}
					// Source timestamps, rather than caller-built evidence, determine the real
					// expiry. Every leaf starts with valid preparation and its actual owner pin.
					buyer.SetModelAdmissionClockForTest(server, expiry.Add(-time.Millisecond))
					prepared, err := server.PrepareModelAdmissionAuthority(context.Background(), p, event)
					if err != nil {
						t.Fatalf("signed source expiry minus 1ms: %v", err)
					}
					if prepared.Event.ArtifactAdmissionEvidence == nil || prepared.Event.ArtifactAdmissionEvidence.AuthorityExpiresAtUnixMS != expiry.UnixMilli() {
						t.Fatalf("resolved expiry differs from signed source: %+v", prepared.Event.ArtifactAdmissionEvidence)
					}
					if prepared.Event.ArtifactAdmissionEvidence.ProbeExpiresAtUnixMS <= expiry.UnixMilli() {
						t.Fatal("probe expiry masks tested source boundary")
					}
					unlock, err := prepared.TryPin()
					if err != nil || unlock == nil {
						t.Fatalf("before-expiry actual owner pin: %v", err)
					}
					unlock()
					if boundary == "minus_1ms" {
						if _, err := server.ResolveModelAdmissionAuthority(context.Background(), p, event); err != nil {
							t.Fatalf("before-expiry resolver: %v", err)
						}
						return
					}
					// No feed/config/provider publication occurs between these observations.
					// The exact boundary must fail for its source reason, not another exclusion.
					buyer.SetModelAdmissionClockForTest(server, expiry)
					if _, err := server.ResolveModelAdmissionAuthority(context.Background(), p, event); err == nil || !strings.Contains(err.Error(), reason) {
						t.Fatalf("exact signed source expiry resolver: %v; want %s", err, reason)
					}
					expired, err := server.PrepareModelAdmissionAuthority(context.Background(), p, event)
					if err == nil || !strings.Contains(err.Error(), reason) || expired.TryPin != nil || expired.Event.ArtifactAdmissionEvidence != nil {
						t.Fatalf("exact expiry exposed newly prepared authority: %+v %v", expired, err)
					}
				})
			}
		})
	}
}
