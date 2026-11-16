package ws

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// Issue #2404: provider CLI 1.8.289 answered every canary for the
// GLM-5.3-Flash uncensored variant with `invalid_message`. These tests feed
// the request this coordinator builds into a faithful copy of the 1.8.289
// decoder (CoordinatorClient.swift `decodeNativeMTPCanaryRequest` and
// `decodeNativeMTPRuntimeTuple` at tag v1.8.289), using the bank entries as
// published and as regenerated.

var (
	v289Hex64  = regexp.MustCompile(`^[0-9a-f]{64}$`)
	v289Nonce  = regexp.MustCompile(`^[0-9a-f]{32}$`)
	v289HexAny = regexp.MustCompile(`^[0-9a-f]+$`)
)

var v289RequestKeys = map[string]bool{
	"type": true, "version": true, "request_id": true, "provider_id": true, "assigned_id": true,
	"model_id": true, "model_hash": true, "model_hash_algorithm": true, "target_generation": true,
	"provider_revision": true, "runtime_revision": true,
	"tokenizer_digest": true, "artifact_digest": true, "manifest_digest": true, "sidecar_digest": true,
	"provider_binary_sha256": true, "runtime_cdhash": true, "cache_namespace": true, "state_digest": true,
	"runtime_tuple": true, "challenge_id": true, "challenge_corpus_sha256": true, "challenge_bank_sha256": true,
	"native_mtp_admission_tuple_sha256": true, "served_snapshot_id": true,
	"native_mtp_runtime_tuple_sha256": true, "expected_token_id_sha256": true, "expected_terminal_reason": true,
	"expected_counters": true, "expected_committed_state_sha256": true, "nonce": true, "request_digest": true,
	"issued_at": true, "expires_at": true, "prompt_token_ids": true, "max_completion_tokens": true, "proposal_depth": true,
}

var v289TupleKeys = map[string]bool{
	"model_id": true, "model_hash": true, "model_hash_algorithm": true, "tokenizer_digest": true,
	"provider_revision": true, "runtime_revision": true,
	"artifact_digest": true, "manifest_digest": true, "sidecar_digest": true, "provider_binary_sha256": true,
	"runtime_cdhash": true, "cache_namespace": true, "state_digest": true, "proposal_depth": true,
}

var v289TerminalReasons = map[string]bool{
	"passed": true, "failed": true, "inconclusive": true, "expired": true, "runtime_unavailable": true,
	"stop": true, "length": true, "cancelled": true, "request_failed": true, "batch_failed": true, "rejected": true,
}

type v289Decoder struct{ obj map[string]any }

func (d v289Decoder) str(field string, maxBytes int) (string, error) {
	v, ok := d.obj[field].(string)
	if !ok || v == "" || containsControlChar(v) {
		return "", fmt.Errorf("%s: invalid string field", field)
	}
	if len(v) > maxBytes {
		return "", fmt.Errorf("%s: exceeds %d bytes", field, maxBytes)
	}
	return v, nil
}

func (d v289Decoder) sha(field string) (string, error) {
	v, err := d.str(field, 64)
	if err != nil {
		return "", err
	}
	if !v289Hex64.MatchString(v) {
		return "", fmt.Errorf("%s: must be lowercase sha256", field)
	}
	return v, nil
}

func (d v289Decoder) hex(field string, lengths ...int) error {
	v, err := d.str(field, 64)
	if err != nil {
		return err
	}
	for _, n := range lengths {
		if len(v) == n && v289HexAny.MatchString(v) {
			return nil
		}
	}
	return fmt.Errorf("%s: must be lowercase hex", field)
}

func (d v289Decoder) num(field string) (float64, bool) {
	v, ok := d.obj[field].(float64)
	return v, ok
}

func (d v289Decoder) uint64(field string) (uint64, error) {
	v, ok := d.num(field)
	if !ok || v < 0 || v != float64(uint64(v)) {
		return 0, fmt.Errorf("%s: invalid uint64", field)
	}
	return uint64(v), nil
}

func v289UnknownKey(obj map[string]any, allowed map[string]bool) error {
	for key := range obj {
		if !allowed[key] {
			return fmt.Errorf("%s: unknown field", key)
		}
	}
	return nil
}

// decodeV289CanaryRequest returns nil when CLI 1.8.289 accepts the request
// and the first rejected field otherwise, in the decoder's own order.
func decodeV289CanaryRequest(raw []byte, now time.Time) error {
	var obj map[string]any
	if err := json.Unmarshal(raw, &obj); err != nil {
		return err
	}
	if err := v289UnknownKey(obj, v289RequestKeys); err != nil {
		return err
	}
	d := v289Decoder{obj}
	if v, _ := obj["type"].(string); v != "native_mtp_canary_request_v1" {
		return fmt.Errorf("type")
	}
	if v, ok := d.num("version"); !ok || v != 1 {
		return fmt.Errorf("version")
	}
	providerID, err := d.str("request_id", 128)
	if err != nil {
		return err
	}
	if providerID, err = d.str("provider_id", 128); err != nil {
		return err
	}
	assignedID, err := d.str("assigned_id", 128)
	if err != nil {
		return err
	}
	if _, err := d.str("model_id", 256); err != nil {
		return err
	}
	if _, err := d.sha("model_hash"); err != nil {
		return err
	}
	for _, f := range []string{"model_hash_algorithm", "provider_revision", "runtime_revision"} {
		if _, err := d.str(f, 128); err != nil {
			return err
		}
	}
	generation, err := d.uint64("target_generation")
	if err != nil {
		return err
	}
	for _, f := range []string{"tokenizer_digest", "artifact_digest", "manifest_digest", "sidecar_digest", "provider_binary_sha256"} {
		if _, err := d.sha(f); err != nil {
			return err
		}
	}
	if err := d.hex("runtime_cdhash", 40, 64); err != nil {
		return err
	}
	if _, err := d.str("cache_namespace", 128); err != nil {
		return err
	}
	if _, err := d.sha("state_digest"); err != nil {
		return err
	}
	if _, err := d.str("challenge_id", 128); err != nil {
		return err
	}
	for _, f := range []string{"challenge_corpus_sha256", "challenge_bank_sha256"} {
		if _, err := d.sha(f); err != nil {
			return err
		}
	}
	admission, err := d.sha("native_mtp_admission_tuple_sha256")
	if err != nil {
		return err
	}
	snapshot, err := d.str("served_snapshot_id", 128)
	if err != nil {
		return err
	}
	tupleSHA, err := d.sha("native_mtp_runtime_tuple_sha256")
	if err != nil {
		return err
	}
	if tupleSHA != nativeMTPRuntimeTupleIdentitySHA256(providerID, assignedID, generation, admission, snapshot) {
		return fmt.Errorf("native_mtp_runtime_tuple_sha256: identity mismatch")
	}
	if _, err := d.sha("expected_token_id_sha256"); err != nil {
		return err
	}
	reason, err := d.str("expected_terminal_reason", 64)
	if err != nil || !v289TerminalReasons[reason] {
		return fmt.Errorf("expected_terminal_reason")
	}
	counters, ok := obj["expected_counters"].(map[string]any)
	if !ok {
		return fmt.Errorf("expected_counters")
	}
	if err := v289UnknownKey(counters, map[string]bool{"accepted": true, "rejected": true, "bonus": true, "committed": true}); err != nil {
		return err
	}
	for _, f := range []string{"accepted", "rejected", "bonus", "committed"} {
		if _, err := (v289Decoder{counters}).uint64(f); err != nil {
			return err
		}
	}
	if _, err := d.sha("expected_committed_state_sha256"); err != nil {
		return err
	}
	nonce, err := d.str("nonce", 32)
	if err != nil || !v289Nonce.MatchString(nonce) {
		return fmt.Errorf("nonce")
	}
	if _, err := d.sha("request_digest"); err != nil {
		return err
	}
	issued, err := d.str("issued_at", 64)
	if err != nil {
		return err
	}
	expires, err := d.str("expires_at", 64)
	if err != nil {
		return err
	}
	if _, err := time.Parse(time.RFC3339, issued); err != nil {
		return fmt.Errorf("issued_at")
	}
	expiry, err := time.Parse(time.RFC3339, expires)
	if err != nil || !expiry.After(now) {
		return fmt.Errorf("expires_at")
	}
	prompt, ok := obj["prompt_token_ids"].([]any)
	if !ok || len(prompt) == 0 || len(prompt) > 2048 {
		return fmt.Errorf("prompt_token_ids")
	}
	for _, token := range prompt {
		if v, ok := token.(float64); !ok || v < 0 {
			return fmt.Errorf("prompt_token_ids")
		}
	}
	if v, ok := d.num("max_completion_tokens"); !ok || v < 1 || v > 64 {
		return fmt.Errorf("max_completion_tokens")
	}
	depth, ok := d.num("proposal_depth")
	if !ok || depth < 1 || depth > 16 {
		return fmt.Errorf("proposal_depth")
	}
	tuple, ok := obj["runtime_tuple"].(map[string]any)
	if !ok {
		return fmt.Errorf("runtime_tuple")
	}
	if err := v289UnknownKey(tuple, v289TupleKeys); err != nil {
		return fmt.Errorf("runtime_tuple.%w", err)
	}
	t := v289Decoder{tuple}
	if v, ok := t.num("proposal_depth"); !ok || v != depth {
		return fmt.Errorf("runtime_tuple.proposal_depth")
	}
	if _, err := t.str("model_id", 256); err != nil {
		return fmt.Errorf("runtime_tuple.%w", err)
	}
	if _, err := t.sha("model_hash"); err != nil {
		return fmt.Errorf("runtime_tuple.%w", err)
	}
	for _, f := range []string{"model_hash_algorithm", "provider_revision", "runtime_revision"} {
		if _, err := t.str(f, 128); err != nil {
			return fmt.Errorf("runtime_tuple.%w", err)
		}
	}
	for _, f := range []string{"tokenizer_digest", "artifact_digest", "manifest_digest", "sidecar_digest", "provider_binary_sha256"} {
		if _, err := t.sha(f); err != nil {
			return fmt.Errorf("runtime_tuple.%w", err)
		}
	}
	if err := t.hex("runtime_cdhash", 40, 64); err != nil {
		return fmt.Errorf("runtime_tuple.%w", err)
	}
	if _, err := t.str("cache_namespace", 128); err != nil {
		return fmt.Errorf("runtime_tuple.%w", err)
	}
	if _, err := t.sha("state_digest"); err != nil {
		return fmt.Errorf("runtime_tuple.%w", err)
	}
	return nil
}

func v289BankRecords(t *testing.T, path string) []NativeMTPChallengeRecord {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var bank struct {
		Entries []json.RawMessage `json:"entries"`
	}
	if err := json.Unmarshal(data, &bank); err != nil {
		t.Fatal(err)
	}
	records := make([]NativeMTPChallengeRecord, 0, len(bank.Entries))
	for _, raw := range bank.Entries {
		record, err := parseNativeMTPChallengeRecord(raw, NativeMTPChallengeBankBinding{})
		if err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		records = append(records, record)
	}
	return records
}

// v289WireRequest is the request this coordinator sends a 1.8.289 provider
// that offered the tuple for record: every tuple field is the provider's own
// offer, built as 1.8.289 builds it (cache namespace
// `native_mtp:<admission tuple>:<challenge id>`, a 40-hex cdhash).
func v289WireRequest(t *testing.T, record NativeMTPChallengeRecord, now time.Time) []byte {
	t.Helper()
	const providerID, assignedID = "prov-v289", "assigned-v289"
	admission := strings.Repeat("7", 64)
	snapshot := "snapshot-v289"
	diag := &pool.NativeMTPCanaryDiagnostics{
		Offered:                       true,
		TargetGeneration:              1,
		ProviderRevision:              strings.Repeat("e", 40),
		RuntimeRevision:               "mlx-swift-lm@" + strings.Repeat("d", 40),
		NativeMTPAdmissionTupleSHA256: admission,
		ServedSnapshotID:              snapshot,
		NativeMTPRuntimeTupleSHA256:   nativeMTPRuntimeTupleIdentitySHA256(providerID, assignedID, 1, admission, snapshot),
		ChallengeBankSHA256:           strings.Repeat("4", 64),
		ChallengeCorpusSHA256:         strings.Repeat("3", 64),
		ModelID:                       record.ModelID,
		ModelHash:                     record.ModelHash,
		ModelHashAlgorithm:            "macprovider.snapshot-manifest.v1",
		TokenizerDigest:               record.TokenizerSHA256,
		ArtifactDigest:                record.ArtifactSHA256,
		ManifestDigest:                record.MTPManifestSHA256,
		SidecarDigest:                 strings.Repeat("5", 64),
		ProviderBinarySHA256:          strings.Repeat("6", 64),
		RuntimeCDHash:                 strings.Repeat("a", 40),
		CacheNamespace:                "native_mtp:" + admission + ":" + record.ChallengeID,
		StateDigest:                   strings.Repeat("8", 64),
		ProposalDepth:                 int(record.FixedProposalDepth),
	}
	provider := pool.Provider{ProviderID: providerID, AssignedID: assignedID, NativeMTPCanary: diag}
	key := nativeMTPTupleKeyFromProvider(provider)
	req, err := NewNativeMTPCanaryCoreRequest(key, record, now)
	if err != nil {
		t.Fatalf("%s: %v", record.ChallengeID, err)
	}
	raw, err := json.Marshal(nativeMTPCanaryWireRequest(provider, record, req))
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestNativeMTPCanaryV289RefusesThePublishedVariantEntryOnItsCacheNamespace(t *testing.T) {
	now := time.Now().UTC()
	published := filepath.Join("..", "..", "..", "phase3-binary", "dist", "static", "native-mtp-selftest-bank.json")
	var variants int
	for _, record := range v289BankRecords(t, published) {
		err := decodeV289CanaryRequest(v289WireRequest(t, record, now), now)
		if strings.Contains(record.ChallengeID, "-variant-") {
			variants++
			if err == nil || !strings.HasPrefix(err.Error(), "cache_namespace: exceeds 128 bytes") {
				t.Fatalf("%s: 1.8.289 should refuse on cache_namespace, got %v", record.ChallengeID, err)
			}
			continue
		}
		if err != nil {
			t.Fatalf("%s: a base entry must be accepted by 1.8.289: %v", record.ChallengeID, err)
		}
	}
	if variants == 0 {
		t.Fatal("published bank has no variant entry; update this test")
	}
}

// The catalog fix renames a variant to `<donor id>-v<12 hex>` and bounds a
// challenge id at 52 bytes: 128 - len("native_mtp:") - 64 - 1. Every published
// entry renamed that way, and any 52-byte id, must pass 1.8.289; 53 bytes must not.
func TestNativeMTPCanaryV289AcceptsShortVariantIDsUpToFiftyTwoBytes(t *testing.T) {
	now := time.Now().UTC()
	published := filepath.Join("..", "..", "..", "phase3-binary", "dist", "static", "native-mtp-selftest-bank.json")
	records := v289BankRecords(t, published)
	if len(records) == 0 {
		t.Fatal("empty bank")
	}
	for _, record := range records {
		if donor, suffix, ok := strings.Cut(record.ChallengeID, "-variant-"); ok {
			record.ChallengeID = donor + "-v" + suffix
		}
		if err := decodeV289CanaryRequest(v289WireRequest(t, record, now), now); err != nil {
			t.Fatalf("%s: 1.8.289 refuses the short-named entry: %v", record.ChallengeID, err)
		}
	}
	record := records[0]
	record.ChallengeID = strings.Repeat("c", 52)
	if err := decodeV289CanaryRequest(v289WireRequest(t, record, now), now); err != nil {
		t.Fatalf("a 52-byte challenge id must pass 1.8.289: %v", err)
	}
	record.ChallengeID = strings.Repeat("c", 53)
	if err := decodeV289CanaryRequest(v289WireRequest(t, record, now), now); err == nil || !strings.HasPrefix(err.Error(), "cache_namespace: exceeds 128 bytes") {
		t.Fatalf("a 53-byte challenge id must be refused on cache_namespace, got %v", err)
	}
}
