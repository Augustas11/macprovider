package computeintegrity

import "strings"

// FR-15 disclosure. Each buyer, provider, public, and auditor surface must publish
// the approved copy for the policy's bound disclosure_copy_version and record the
// version/digest it serves. Enforce activation refuses while any required surface is
// missing or stale, and approved copy must not make honest-computation, cryptographic-
// proof, hardware-integrity, or binary-integrity claims.

// DisclosureSurfaceKind enumerates the required disclosure surfaces (FR-15).
type DisclosureSurfaceKind string

const (
	SurfaceBuyer    DisclosureSurfaceKind = "buyer"
	SurfaceProvider DisclosureSurfaceKind = "provider"
	SurfacePublic   DisclosureSurfaceKind = "public"
	SurfaceAuditor  DisclosureSurfaceKind = "auditor"
)

// requiredSurfaces are the four surfaces enforce activation requires (FR-15).
var requiredSurfaces = []DisclosureSurfaceKind{SurfaceBuyer, SurfaceProvider, SurfacePublic, SurfaceAuditor}

// DisclosureSurface is a published disclosure surface and the copy version/digest it
// is currently serving (FR-15).
type DisclosureSurface struct {
	Kind        DisclosureSurfaceKind
	CopyVersion string
	CopyDigest  string
	CopyText    string
}

// forbiddenClaimPhrases are buyer-facing claims SPEC-036 v0.1 disclosure MUST NOT make
// (FR-15). Matching is case-insensitive and substring-based.
var forbiddenClaimPhrases = []string{
	"proved honest computation",
	"proves honest computation",
	"guaranteed model integrity",
	"cryptographic compute proof",
	"cryptographic proof of honest computation",
	"hardware integrity",
	"binary integrity",
	"covert canary attestation",
}

// ContainsForbiddenClaim reports whether disclosure copy makes a forbidden v0.1 claim.
func ContainsForbiddenClaim(copyText string) bool {
	lc := strings.ToLower(copyText)
	for _, p := range forbiddenClaimPhrases {
		if strings.Contains(lc, p) {
			return true
		}
	}
	return false
}

// DisclosureRefusals returns the FR-15 refusal reasons for enforce activation given
// the active policy's bound copy version/digest and the published surfaces. An empty
// result means disclosure is enforce-ready.
func DisclosureRefusals(policy Policy, surfaces []DisclosureSurface) []string {
	var reasons []string
	byKind := map[DisclosureSurfaceKind]DisclosureSurface{}
	for _, s := range surfaces {
		byKind[s.Kind] = s
	}
	if policy.DisclosureCopyVersion == "" || policy.DisclosureCopyDigest == "" {
		reasons = append(reasons, "policy does not bind a disclosure copy version/digest")
	}
	for _, kind := range requiredSurfaces {
		s, ok := byKind[kind]
		if !ok {
			reasons = append(reasons, "required disclosure surface missing: "+string(kind))
			continue
		}
		if s.CopyVersion != policy.DisclosureCopyVersion || s.CopyDigest != policy.DisclosureCopyDigest {
			reasons = append(reasons, "disclosure surface stale: "+string(kind))
		}
		if ContainsForbiddenClaim(s.CopyText) {
			reasons = append(reasons, "disclosure surface makes a forbidden v0.1 claim: "+string(kind))
		}
	}
	return reasons
}
