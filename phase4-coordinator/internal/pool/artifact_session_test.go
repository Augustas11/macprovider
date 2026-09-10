package pool

import (
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/artifactidentity"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
)

// SPEC-010 v1.7 R007(b): the matched member is SESSION authority. Once a
// session bound a member, a later heartbeat that resolves to a different
// member — or to the row's own primary pair — is a mismatch for the same
// model id; a model change starts a new binding.
func TestArtifactSessionMemberIsPinnedAcrossHeartbeats(t *testing.T) {
	const rowHash = "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a"
	ggufA, ggufB := strings.Repeat("c", 64), strings.Repeat("d", 64)
	member := func(id, hash string) artifactidentity.Member {
		return artifactidentity.Member{ModelKey: "small", ModelID: "model-a", ArtifactID: id, HashAlgorithm: modelidentity.GGUFFileV1, Hash: hash, RuntimeStatus: "recommendable"}
	}
	resolver := func(req ModelIdentityRequest) ModelIdentityVerdict {
		switch {
		case req.ReportedAlgorithm == modelidentity.SnapshotManifestV1 && req.ReportedHash == rowHash:
			return ModelIdentityVerdict{Status: HashStatusVerified}
		case req.ReportedHash == ggufA:
			return ModelIdentityVerdict{Status: HashStatusVerified, Artifact: &artifactidentity.Binding{Member: member("gguf-q4", ggufA)}}
		case req.ReportedHash == ggufB:
			return ModelIdentityVerdict{Status: HashStatusVerified, Artifact: &artifactidentity.Binding{Member: member("gguf-q8", ggufB)}}
		}
		return ModelIdentityVerdict{Status: HashStatusMismatch}
	}
	registry := NewRegistry(nil, WithModelIdentityResolver(resolver))
	start := time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC)
	registerHeartbeatProvider(t, registry, "model-a", "", HashStatusUncatalogued, start)
	beat := func(modelID, hash, algorithm string, at time.Time) Provider {
		t.Helper()
		provider, _, ok := registry.ApplyHeartbeat("p1", "current", HeartbeatUpdate{
			Status: StateReady, ModelID: modelID, ModelHash: hash, ModelHashPresent: true,
			ModelHashAlgorithm: algorithm, ModelHashAlgorithmPresent: true, ExpectedModelHash: rowHash,
			MaxContextTokens: 8192, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1, At: at,
		})
		if !ok {
			t.Fatal("heartbeat not applied")
		}
		return *provider
	}
	first := beat("model-a", ggufA, modelidentity.GGUFFileV1, start.Add(time.Minute))
	if first.HashStatus != HashStatusVerified || first.ArtifactIdentity == nil || first.ArtifactIdentity.Member.ArtifactID != "gguf-q4" {
		t.Fatalf("first binding: %+v", first)
	}
	same := beat("model-a", ggufA, modelidentity.GGUFFileV1, start.Add(2*time.Minute))
	if same.HashStatus != HashStatusVerified || same.ArtifactIdentity == nil {
		t.Fatalf("same member stays verified: %+v", same)
	}
	swapped := beat("model-a", ggufB, modelidentity.GGUFFileV1, start.Add(3*time.Minute))
	if swapped.HashStatus != HashStatusMismatch || swapped.ArtifactIdentity != nil {
		t.Fatalf("another member of the same key is a mismatch for the session: %+v", swapped)
	}
	// The pin OUTLIVES the mismatch: repeating the other member, a report
	// with no hash at all, and a refresh all leave the session bound to the
	// member it first verified; only that member verifies again.
	if again := beat("model-a", ggufB, modelidentity.GGUFFileV1, start.Add(4*time.Minute)); again.HashStatus != HashStatusMismatch || again.ArtifactIdentity != nil {
		t.Fatalf("a second report of the other member must still mismatch: %+v", again)
	}
	if _, _, ok := registry.ApplyHeartbeat("p1", "current", HeartbeatUpdate{
		Status: StateReady, ModelID: "model-a", ModelHashPresent: false, ExpectedModelHash: rowHash,
		MaxContextTokens: 8192, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1, At: start.Add(5 * time.Minute),
	}); !ok {
		t.Fatal("hash-less heartbeat not applied")
	}
	if after := beat("model-a", ggufB, modelidentity.GGUFFileV1, start.Add(6*time.Minute)); after.HashStatus != HashStatusMismatch || after.ArtifactIdentity != nil {
		t.Fatalf("a hash-less report must not clear the pin: %+v", after)
	}
	if n := registry.UpdateModelIdentities(func(Provider) ModelIdentityVerdict {
		return ModelIdentityVerdict{Status: HashStatusVerified, Artifact: &artifactidentity.Binding{Member: member("gguf-q8", ggufB)}}
	}); n != 0 {
		t.Fatalf("refresh to another member after a mismatch must stay a mismatch, updated=%d", n)
	}
	if back := beat("model-a", ggufA, modelidentity.GGUFFileV1, start.Add(7*time.Minute)); back.HashStatus != HashStatusVerified || back.ArtifactIdentity == nil || back.ArtifactIdentity.Member.ArtifactID != "gguf-q4" {
		t.Fatalf("the pinned member verifies again: %+v", back)
	}
	// A session that first verified the row's PRIMARY pair is pinned to it:
	// a later member report for the same model is a mismatch too.
	registerHeartbeatProvider(t, registry, "model-a", "", HashStatusUncatalogued, start)
	if p := beat("model-a", rowHash, modelidentity.SnapshotManifestV1, start.Add(8*time.Minute)); p.HashStatus != HashStatusVerified || p.ArtifactIdentity != nil {
		t.Fatalf("primary verifies: %+v", p)
	}
	if p := beat("model-a", ggufA, modelidentity.GGUFFileV1, start.Add(9*time.Minute)); p.HashStatus != HashStatusMismatch || p.ArtifactIdentity != nil {
		t.Fatalf("a member after the primary is a different identity for the session: %+v", p)
	}
	// Re-register a fresh session bound to gguf-q4, then report the primary pair.
	registerHeartbeatProvider(t, registry, "model-a", "", HashStatusUncatalogued, start)
	beat("model-a", ggufA, modelidentity.GGUFFileV1, start.Add(10*time.Minute))
	toPrimary := beat("model-a", rowHash, modelidentity.SnapshotManifestV1, start.Add(11*time.Minute))
	if toPrimary.HashStatus != HashStatusMismatch || toPrimary.ArtifactIdentity != nil {
		t.Fatalf("the row's own pair is a different member for a session bound elsewhere: %+v", toPrimary)
	}
	// A model change (warm swap, R006) starts a new binding instead.
	registerHeartbeatProvider(t, registry, "model-a", "", HashStatusUncatalogued, start)
	beat("model-a", ggufA, modelidentity.GGUFFileV1, start.Add(12*time.Minute))
	changed := beat("model-b", ggufB, modelidentity.GGUFFileV1, start.Add(13*time.Minute))
	if changed.HashStatus != HashStatusVerified || changed.ArtifactIdentity == nil || changed.ArtifactIdentity.Member.ArtifactID != "gguf-q8" {
		t.Fatalf("model change rebinds: %+v", changed)
	}
	// The refresh path pins the same way (session now pinned to gguf-q8).
	if n := registry.UpdateModelIdentities(func(Provider) ModelIdentityVerdict {
		return ModelIdentityVerdict{Status: HashStatusVerified, Artifact: &artifactidentity.Binding{Member: member("gguf-q4", ggufA)}}
	}); n != 1 {
		t.Fatalf("refresh to another member must flip status, updated=%d", n)
	}
	if p := registry.Snapshot()[0]; p.HashStatus != HashStatusMismatch || p.ArtifactIdentity != nil || p.IdentityPin == nil || p.IdentityPin.Member.ArtifactID != "gguf-q8" {
		t.Fatalf("refresh path pin: %+v pin=%+v", p, p.IdentityPin)
	}
}
