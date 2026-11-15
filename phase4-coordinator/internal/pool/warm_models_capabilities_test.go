package pool

import (
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/artifactidentity"
)

// SPEC-002-R011: a further member's entry view carries its own tool and
// vision declarations and its own artifact binding; it never inherits the
// primary's.
func TestWarmEntryCarriesItsOwnCapabilitiesAndArtifactBinding(t *testing.T) {
	const memberHash = "3333333333333333333333333333333333333333333333333333333333333333"
	artifact := &artifactidentity.Binding{Member: artifactidentity.Member{ArtifactID: "artifact-b", Hash: memberHash}}
	registry := NewRegistry(nil, WithModelIdentityResolver(func(req ModelIdentityRequest) ModelIdentityVerdict {
		if req.ModelID == "model-b" && req.ReportedHash == memberHash {
			return ModelIdentityVerdict{Status: HashStatusVerified, Artifact: artifact}
		}
		return ModelIdentityVerdict{Status: HashStatusUncatalogued}
	}))
	at := time.Now()
	registerWarmHeartbeatProvider(t, registry, at)
	primaryTool := ToolSelectionCapability{ModelID: "model-a", Runtime: "mlx_cache", Modes: []string{"auto", "required"}, Validation: "schema-holdback-v1"}
	memberTool := ToolSelectionCapability{ModelID: "model-b", Runtime: "mlx_cache", Modes: []string{"auto", "none", "required", "named"}, Validation: "schema-holdback-v1"}
	memberVision := VisionRuntimeCapability{ModelID: "model-b", ModelHash: memberHash, MediaProfile: "profile"}
	capable := warmTestMember("model-b", WarmModelWarm, 2, 2)
	capable.ModelHash = memberHash
	capable.ToolSelectionCapabilities = []ToolSelectionCapability{memberTool}
	capable.VisionRuntimeCapabilities = []VisionRuntimeCapability{memberVision}
	update := warmHeartbeatUpdate(at.Add(time.Second), warmTestMembers("model-a", capable, warmTestMember("model-d", WarmModelWarm, 1, 1)))
	update.ModelHash, update.ModelHashPresent = memberHash, true
	update.ToolSelectionCapabilities = []ToolSelectionCapability{primaryTool}
	if _, _, ok := registry.ApplyHeartbeat("p1", "current", update); !ok {
		t.Fatal("heartbeat failed")
	}
	if primary := warmEntry(t, registry, "model-a"); len(primary.ToolSelectionCapabilities) != 1 || primary.ToolSelectionCapabilities[0].ModelID != "model-a" {
		t.Fatalf("primary tool declarations = %+v", primary.ToolSelectionCapabilities)
	}
	member := warmEntry(t, registry, "model-b")
	if len(member.ToolSelectionCapabilities) != 1 || member.ToolSelectionCapabilities[0].ModelID != "model-b" ||
		len(member.VisionRuntimeCapabilities) != 1 || member.VisionRuntimeCapabilities[0] != memberVision {
		t.Fatalf("member declarations = %+v / %+v", member.ToolSelectionCapabilities, member.VisionRuntimeCapabilities)
	}
	if member.HashStatus != HashStatusVerified || member.ArtifactIdentity != artifact {
		t.Fatalf("member verdict = %s artifact=%v, want its own verified artifact binding", member.HashStatus, member.ArtifactIdentity)
	}
	if bare := warmEntry(t, registry, "model-d"); bare.ToolSelectionCapabilities != nil || bare.VisionRuntimeCapabilities != nil || bare.ArtifactIdentity != nil {
		t.Fatalf("a member without declarations inherited some: %+v", bare)
	}
}

// A release publication re-verifies each further member against its own
// model id and hash, as it does the session's model.
func TestWarmEntryIdentityRefreshIsPerMember(t *testing.T) {
	const memberHash = "4444444444444444444444444444444444444444444444444444444444444444"
	revoked := false
	registry := NewRegistry(nil, WithModelIdentityResolver(func(req ModelIdentityRequest) ModelIdentityVerdict {
		if req.ModelID == "model-b" && !revoked {
			return ModelIdentityVerdict{Status: HashStatusVerified}
		}
		return ModelIdentityVerdict{Status: HashStatusMismatch}
	}))
	at := time.Now()
	registerWarmHeartbeatProvider(t, registry, at)
	member := warmTestMember("model-b", WarmModelWarm, 2, 2)
	member.ModelHash = memberHash
	update := warmHeartbeatUpdate(at.Add(time.Second), warmTestMembers("model-a", member))
	update.ModelHash, update.ModelHashPresent = memberHash, true
	if _, _, ok := registry.ApplyHeartbeat("p1", "current", update); !ok {
		t.Fatal("heartbeat failed")
	}
	if got := warmEntry(t, registry, "model-b").HashStatus; got != HashStatusVerified {
		t.Fatalf("member before refresh = %s", got)
	}
	revoked = true
	var seen []string
	registry.UpdateModelIdentities(func(p Provider) ModelIdentityVerdict {
		seen = append(seen, p.ModelID)
		if p.ModelID == "model-b" && !revoked {
			return ModelIdentityVerdict{Status: HashStatusVerified}
		}
		return ModelIdentityVerdict{Status: HashStatusMismatch}
	})
	if got := warmEntry(t, registry, "model-b").HashStatus; got != HashStatusMismatch {
		t.Fatalf("member after refresh = %s, want mismatch", got)
	}
	if len(seen) != 2 || seen[0] != "model-a" || seen[1] != "model-b" {
		t.Fatalf("refresh evaluated %v, want the session then its member", seen)
	}
}
