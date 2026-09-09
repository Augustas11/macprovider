package buyer_test

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
)

// The shared SPEC-023 §3.7 conformance corpus is read by the Python generator,
// this coordinator validator, and the Swift CLI, so the three cannot drift on
// the closed schema, identity matrix, release binding, or primary consistency.
type artifactCorpus struct {
	Candidate map[string]any `json:"candidate"`
	Feed      map[string]any `json:"feed"`
	Cases     []struct {
		Name   string `json:"name"`
		Expect string `json:"expect"`
		Ops    []struct {
			Op    string   `json:"op"`
			Path  []string `json:"path"`
			Value any      `json:"value"`
		} `json:"ops"`
	} `json:"cases"`
}

func applyCorpusOps(feed map[string]any, ops []struct {
	Op    string   `json:"op"`
	Path  []string `json:"path"`
	Value any      `json:"value"`
}) {
	for _, op := range ops {
		target := feed
		for _, key := range op.Path[:len(op.Path)-1] {
			target = target[key].(map[string]any)
		}
		leaf := op.Path[len(op.Path)-1]
		switch op.Op {
		case "set":
			target[leaf] = op.Value
		case "delete":
			delete(target, leaf)
		default:
			panic("unknown corpus op " + op.Op)
		}
	}
}

func deepCopyJSON(t *testing.T, value map[string]any) map[string]any {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func TestCatalogArtifactsSharedConformanceCorpus(t *testing.T) {
	t.Parallel()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "scripts", "tests", "fixtures", "artifact_feed_conformance.json"))
	if err != nil {
		t.Fatalf("read corpus: %v", err)
	}
	var corpus artifactCorpus
	if err := json.Unmarshal(raw, &corpus); err != nil {
		t.Fatalf("decode corpus: %v", err)
	}
	if len(corpus.Cases) < 25 {
		t.Fatalf("corpus has %d cases", len(corpus.Cases))
	}
	// json.Marshal sorts object keys and emits compact JSON: the same canonical
	// form the generator signs.
	candidate, err := json.Marshal(corpus.Candidate)
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(candidate)
	candidateSHA := hex.EncodeToString(digest[:])
	version := corpus.Candidate["version"].(string)
	generatedAt := corpus.Candidate["generated_at"].(string)
	policyVersion := corpus.Candidate["policy_version"].(string)

	for _, tc := range corpus.Cases {
		tc := tc
		t.Run(tc.Name, func(t *testing.T) {
			t.Parallel()
			publicKey, privateKey := testSigningKey(t)
			dir := t.TempDir()
			feed := deepCopyJSON(t, corpus.Feed)
			feed["candidate_catalog_sha256"] = candidateSHA
			applyCorpusOps(feed, tc.Ops)
			artifacts, err := json.Marshal(feed)
			if err != nil {
				t.Fatal(err)
			}
			candidateJSONPath, candidateSigPath := writeSignedFeedPair(t, dir, "autotune-candidates", candidate, "test-key", privateKey)
			demandJSONPath, demandSigPath := writeSignedFeedPair(t, dir, "demand-rank", validDemandFeedWith(version, generatedAt, policyVersion), "test-key", privateKey)
			rateCardJSONPath, rateCardSigPath := writeSignedFeedPair(t, dir, "rate-card", validRateCardFeed(generatedAt, policyVersion), "test-key", privateKey)
			artifactsJSONPath, artifactsSigPath := writeSignedFeedPair(t, dir, "autotune-artifacts", artifacts, "test-key", privateKey)
			_, loadErr := buyer.LoadAutotuneFeeds(config.AutotuneFeedsConfig{
				RateCardPath:              rateCardJSONPath,
				RateCardSigPath:           rateCardSigPath,
				DemandRankPath:            demandJSONPath,
				DemandRankSigPath:         demandSigPath,
				AutotuneCandidatesPath:    candidateJSONPath,
				AutotuneCandidatesSigPath: candidateSigPath,
				CatalogArtifactsPath:      artifactsJSONPath,
				CatalogArtifactsSigPath:   artifactsSigPath,
				PublicKeys:                map[string]string{"test-key": base64.StdEncoding.EncodeToString(ed25519.PublicKey(publicKey))},
			})
			switch tc.Expect {
			case "accept":
				if loadErr != nil {
					t.Fatalf("corpus case %q must be accepted: %v", tc.Name, loadErr)
				}
			case "reject":
				if loadErr == nil {
					t.Fatalf("corpus case %q must be rejected", tc.Name)
				}
			default:
				t.Fatalf("corpus case %q has unknown expectation %q", tc.Name, tc.Expect)
			}
		})
	}
}
