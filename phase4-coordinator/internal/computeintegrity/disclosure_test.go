package computeintegrity

import "testing"

func discPolicy() Policy {
	p := goodEnforcePolicy()
	p.DisclosureCopyVersion = "disc-v1"
	p.DisclosureCopyDigest = "sha256:disc"
	return p
}

func discSurfaces(version, digest, copyText string) []DisclosureSurface {
	var out []DisclosureSurface
	for _, k := range requiredSurfaces {
		out = append(out, DisclosureSurface{Kind: k, CopyVersion: version, CopyDigest: digest, CopyText: copyText})
	}
	return out
}

const approvedCopy = "SPEC-036 is an overt distribution-drift detector against approved references. " +
	"It is not cryptographic proof; drift means measured divergence from an approved reference distribution."

// AC-12: disclosure.
func TestAC12_Disclosure(t *testing.T) {
	t.Run("every required surface with approved matching copy is enforce-ready", func(t *testing.T) {
		if r := DisclosureRefusals(discPolicy(), discSurfaces("disc-v1", "sha256:disc", approvedCopy)); len(r) != 0 {
			t.Fatalf("approved disclosure should be ready, got %v", r)
		}
	})

	t.Run("activation refuses when a required surface is missing", func(t *testing.T) {
		surfaces := discSurfaces("disc-v1", "sha256:disc", approvedCopy)[:3] // drop auditor
		if len(DisclosureRefusals(discPolicy(), surfaces)) == 0 {
			t.Fatal("missing surface must refuse enforce")
		}
	})

	t.Run("activation refuses a stale surface", func(t *testing.T) {
		surfaces := discSurfaces("disc-OLD", "sha256:old", approvedCopy)
		if len(DisclosureRefusals(discPolicy(), surfaces)) == 0 {
			t.Fatal("stale surface must refuse enforce")
		}
	})

	t.Run("forbidden claims are rejected", func(t *testing.T) {
		for _, bad := range []string{
			"This proves honest computation.",
			"guaranteed model integrity",
			"cryptographic compute proof of the model",
			"hardware integrity attestation",
			"binary integrity guarantee",
		} {
			if !ContainsForbiddenClaim(bad) {
				t.Fatalf("should reject forbidden claim: %q", bad)
			}
		}
		surfaces := discSurfaces("disc-v1", "sha256:disc", "SPEC-036 proves honest computation")
		if len(DisclosureRefusals(discPolicy(), surfaces)) == 0 {
			t.Fatal("forbidden claim in copy must refuse enforce")
		}
	})

	t.Run("approved drift-neutral copy contains no forbidden claim", func(t *testing.T) {
		if ContainsForbiddenClaim(approvedCopy) {
			t.Fatal("approved copy must not trip the forbidden-claim check")
		}
	})
}
