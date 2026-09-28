package ws

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
)

func TestNativeMTPCanaryBankRequiresValidDetachedSignature(t *testing.T) {
	raw, binding := nativeMTPValidBankFixture(t)
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	bankPath := root + "/bank.json"
	sigPath := root + "/bank.json.sig"
	if err := os.WriteFile(bankPath, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	sig := nativeMTPCanaryDetachedSignature{
		Alg:       "Ed25519",
		KeyID:     binding.SignerKeyID,
		Signature: base64.StdEncoding.EncodeToString(ed25519.Sign(priv, raw)),
	}
	if err := writeNativeMTPSignatureSidecar(sigPath, sig); err != nil {
		t.Fatal(err)
	}
	cfg := config.NativeMTPCanaryConfig{
		Enabled:           true,
		ChallengeBankPath: bankPath,
		SignaturePath:     sigPath,
		SignerKeyID:       binding.SignerKeyID,
		PublicKeys:        map[string]string{binding.SignerKeyID: base64.StdEncoding.EncodeToString(pub)},
		IntervalS:         900,
	}
	if _, err := loadVerifiedNativeMTPChallengeBank(cfg); err != nil {
		t.Fatalf("valid signed bank: %v", err)
	}

	if err := os.WriteFile(sigPath, []byte(`{"alg":"Ed25519","key_id":"`+binding.SignerKeyID+`","signature":"`+sig.Signature+`","extra":"nope"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadVerifiedNativeMTPChallengeBank(cfg); err == nil || !strings.Contains(err.Error(), "wrong field count") {
		t.Fatalf("unknown sidecar field err=%v", err)
	}
	if err := os.WriteFile(sigPath, []byte(`{"alg":"Ed25519","alg":"Ed25519","key_id":"`+binding.SignerKeyID+`","signature":"`+sig.Signature+`"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadVerifiedNativeMTPChallengeBank(cfg); err == nil || !strings.Contains(err.Error(), "duplicate") {
		t.Fatalf("duplicate sidecar field err=%v", err)
	}

	if err := writeNativeMTPSignatureSidecar(sigPath, nativeMTPCanaryDetachedSignature{
		Alg:       "Ed25519",
		KeyID:     binding.SignerKeyID,
		Signature: base64.StdEncoding.EncodeToString(ed25519.Sign(priv, append([]byte("tamper"), raw...))),
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := loadVerifiedNativeMTPChallengeBank(cfg); err == nil || !strings.Contains(err.Error(), "signature verification failed") {
		t.Fatalf("forged signature err=%v", err)
	}
}

func TestNativeMTPCanaryTupleOfferDispatchAndResultAreTupleScoped(t *testing.T) {
	raw, binding := nativeMTPValidBankFixture(t)
	bank, err := ParseNativeMTPChallengeBank(raw, binding)
	if err != nil {
		t.Fatal(err)
	}
	bank.Entries[0].ExpectedTerminalReason = "passed"
	record := bank.Entries[0]
	now := time.Date(2026, 9, 28, 1, 0, 0, 0, time.UTC)
	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{
		ProviderID:       "provider-a",
		AssignedID:       "assigned-a",
		ModelID:          record.ModelID,
		ModelHash:        record.ModelHash,
		State:            pool.StateReady,
		SlotsFree:        1,
		SlotsTotal:       1,
		MaxContextTokens: 4096,
	}
	clientConn, serverConn := net.Pipe()
	defer clientConn.Close()
	defer serverConn.Close()
	registry.Register(provider, serverConn)
	cfg := config.Default()
	cfg.Pool.NativeMTPCanary.IntervalS = 900
	server := NewServer(cfg, registry, zerolog.Nop(),
		WithNow(func() time.Time { return now }),
		WithNativeMTPCanaryJitter(func(base time.Duration) time.Duration { return base }),
	)
	server.cfg.Pool.NativeMTPCanary.Enabled = true
	server.nativeMTPCanaryBank = &bank
	session := newProviderSession(provider.ProviderID, provider.AssignedID, serverConn, 16, time.Second)
	server.sessions.Store(sessionKey(provider.ProviderID, provider.AssignedID), session)
	go session.runWriter()

	runtimeTuple := NativeMTPRuntimeTuple{
		ModelID:              record.ModelID,
		ModelHash:            record.ModelHash,
		ModelHashAlgorithm:   "sha256",
		ProviderRevision:     "1.8.123",
		RuntimeRevision:      "mlx-swift-lm-e874140",
		TokenizerDigest:      record.TokenizerSHA256,
		ArtifactDigest:       record.ArtifactSHA256,
		ManifestDigest:       record.MTPManifestSHA256,
		SidecarDigest:        strings.Repeat("8", 64),
		ProviderBinarySHA256: strings.Repeat("9", 64),
		RuntimeCDHash:        strings.Repeat("a", 64),
		CacheNamespace:       "native-mtp-test",
		StateDigest:          record.ExpectedCommittedStateSHA256,
		ProposalDepth:        int(record.FixedProposalDepth),
	}
	admissionTupleSHA256 := strings.Repeat("8", 64)
	servedSnapshotID := "snapshot-a"
	runtimeTupleSHA256 := nativeMTPRuntimeTupleIdentitySHA256(
		provider.ProviderID,
		provider.AssignedID,
		7,
		admissionTupleSHA256,
		servedSnapshotID,
	)
	offer := NativeMTPTupleOffer{
		Type:                          "native_mtp_tuple_offer_v1",
		Version:                       1,
		ProviderID:                    provider.ProviderID,
		AssignedID:                    provider.AssignedID,
		TargetGeneration:              7,
		ProviderRevision:              runtimeTuple.ProviderRevision,
		RuntimeRevision:               runtimeTuple.RuntimeRevision,
		RuntimeTuple:                  runtimeTuple,
		NativeMTPAdmissionTupleSHA256: admissionTupleSHA256,
		ServedSnapshotID:              servedSnapshotID,
		NativeMTPRuntimeTupleSHA256:   runtimeTupleSHA256,
		SidecarDigest:                 runtimeTuple.SidecarDigest,
		ChallengeBankReleaseID:        bank.ReleaseID,
		ChallengeBankSHA256:           bank.RawSHA256,
		ChallengeCorpusSHA256:         strings.Repeat("b", 64),
		SelftestProfile:               "native_mtp_selftest_v1",
		SelftestPassDigest:            strings.Repeat("c", 64),
		SelftestObservedAt:            now.Format(time.RFC3339),
	}
	server.handleNativeMTPTupleOffer(provider.ProviderID, provider.AssignedID, mustMarshalNativeMTP(t, offer))
	if snap, _ := registry.Resolve(provider.ProviderID, provider.AssignedID); snap.NativeMTPCanary == nil || snap.NativeMTPCanary.Status != "unknown" {
		t.Fatalf("tuple offer not recorded: %+v", snap.NativeMTPCanary)
	}
	if !server.maybeDispatchNativeMTPCanary(mustResolveProvider(t, registry, provider.ProviderID, provider.AssignedID), now) {
		t.Fatal("expected dispatch")
	}
	rawReq, err := wsutil.ReadServerText(clientConn)
	if err != nil {
		t.Fatal(err)
	}
	req, _, err := ParseNativeMTPCanaryRequest(rawReq)
	if err != nil {
		t.Fatalf("parse request: %v", err)
	}
	result := NativeMTPCanaryCoreResult{
		Profile:                    nativeMTPCanaryProfile,
		ProviderID:                 req.ProviderID,
		AssignedID:                 req.AssignedID,
		TargetGeneration:           req.TargetGeneration,
		RuntimeTupleSHA256:         req.NativeMTPRuntimeTupleSHA256,
		ChallengeBankSHA256:        req.ChallengeBankSHA256,
		ChallengeID:                req.ChallengeID,
		Nonce:                      req.Nonce,
		RequestDigestSHA256:        req.RequestDigest,
		ActualDecodePath:           "native_mtp",
		ActualTokenIDSHA256:        record.ExpectedTokenIDSHA256,
		ActualTerminalReason:       record.ExpectedTerminalReason,
		ActualCounters:             record.ExpectedCounters,
		ActualCommittedStateSHA256: record.ExpectedCommittedStateSHA256,
	}
	result.ResultDigestSHA256 = digestCanonicalJSON(result.digestObject())
	wireResult := NativeMTPCanaryResult{
		Type:                        "native_mtp_canary_result_v1",
		Version:                     1,
		RequestID:                   req.RequestID,
		ProviderID:                  req.ProviderID,
		AssignedID:                  req.AssignedID,
		RequestDigest:               req.RequestDigest,
		ResultDigest:                result.ResultDigestSHA256,
		TargetGeneration:            req.TargetGeneration,
		ProviderRevision:            runtimeTuple.ProviderRevision,
		RuntimeRevision:             runtimeTuple.RuntimeRevision,
		ChallengeID:                 req.ChallengeID,
		ChallengeBankSHA256:         req.ChallengeBankSHA256,
		Nonce:                       req.Nonce,
		NativeMTPRuntimeTupleSHA256: req.NativeMTPRuntimeTupleSHA256,
		ExpectedTokenIDSHA256:       req.ExpectedTokenIDSHA256,
		ActualTokenIDSHA256:         record.ExpectedTokenIDSHA256,
		TerminalReason:              record.ExpectedTerminalReason,
		Counters:                    nativeMTPCountersFromCore(record.ExpectedCounters),
		CommittedStateSHA256:        record.ExpectedCommittedStateSHA256,
		ActualDecodePath:            "native_mtp",
		RuntimeTuple:                runtimeTuple,
	}
	server.handleNativeMTPCanaryResult(provider.ProviderID, provider.AssignedID, mustMarshalNativeMTP(t, wireResult))
	updated := mustResolveProvider(t, registry, provider.ProviderID, provider.AssignedID)
	if updated.NativeMTPCanary == nil || updated.NativeMTPCanary.Status != string(NativeMTPCanaryTupleFresh) || updated.CanaryFailCount != 0 || updated.State != pool.StateReady {
		t.Fatalf("unexpected native MTP tuple result state: provider=%+v native=%+v", updated, updated.NativeMTPCanary)
	}
}

func mustResolveProvider(t *testing.T, registry *pool.Registry, providerID, assignedID string) pool.Provider {
	t.Helper()
	provider, ok := registry.Resolve(providerID, assignedID)
	if !ok {
		t.Fatalf("missing provider %s/%s", providerID, assignedID)
	}
	return provider
}

func writeNativeMTPSignatureSidecar(path string, sig nativeMTPCanaryDetachedSignature) error {
	raw, err := json.Marshal(sig)
	if err != nil {
		return err
	}
	return os.WriteFile(path, raw, 0o600)
}
