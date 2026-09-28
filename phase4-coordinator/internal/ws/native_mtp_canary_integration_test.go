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
	wireResult := NativeMTPCanaryResult{
		Type:                        "native_mtp_canary_result_v1",
		Version:                     1,
		RequestID:                   req.RequestID,
		ProviderID:                  req.ProviderID,
		AssignedID:                  req.AssignedID,
		RequestDigest:               req.RequestDigest,
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
	wireResult.ResultDigest = nativeMTPCanaryResultDigest(wireResult)
	server.handleNativeMTPCanaryResult(provider.ProviderID, provider.AssignedID, mustMarshalNativeMTP(t, wireResult))
	updated := mustResolveProvider(t, registry, provider.ProviderID, provider.AssignedID)
	if updated.NativeMTPCanary == nil || updated.NativeMTPCanary.Status != string(NativeMTPCanaryTupleFresh) || updated.CanaryFailCount != 0 || updated.State != pool.StateReady {
		t.Fatalf("unexpected native MTP tuple result state: provider=%+v native=%+v", updated, updated.NativeMTPCanary)
	}
}

func TestNativeMTPCanaryFailureSendsTupleDisableOnlyOnce(t *testing.T) {
	h := newNativeMTPCanaryIntegrationHarness(t)
	req := h.dispatchRequest(t)
	wireResult := h.wireResult(req, "ordinary")

	h.server.handleNativeMTPCanaryResult(h.provider.ProviderID, h.provider.AssignedID, mustMarshalNativeMTP(t, wireResult))
	disable := h.readDisable(t)
	if disable.Reason != "fallback" ||
		disable.ProviderID != h.provider.ProviderID ||
		disable.AssignedID != h.provider.AssignedID ||
		disable.TargetGeneration != h.offer.TargetGeneration ||
		disable.NativeMTPAdmissionTupleSHA256 != h.offer.NativeMTPAdmissionTupleSHA256 ||
		disable.NativeMTPRuntimeTupleSHA256 != h.offer.NativeMTPRuntimeTupleSHA256 {
		t.Fatalf("unexpected disable: %+v", disable)
	}
	updated := mustResolveProvider(t, h.registry, h.provider.ProviderID, h.provider.AssignedID)
	if updated.State != pool.StateReady || updated.CanaryFailCount != 0 || updated.NativeMTPCanary.Status != string(NativeMTPCanaryTupleDisabled) {
		t.Fatalf("tuple disable must not degrade ordinary/classic readiness: provider=%+v native=%+v", updated, updated.NativeMTPCanary)
	}

	if h.server.maybeDispatchNativeMTPCanary(mustResolveProvider(t, h.registry, h.provider.ProviderID, h.provider.AssignedID), *h.now) {
		t.Fatal("disabled tuple must not dispatch again")
	}
	h.assertNoServerFrame(t)
}

func TestNativeMTPCanaryTimeoutSweepSendsTupleDisableOnce(t *testing.T) {
	h := newNativeMTPCanaryIntegrationHarness(t)
	req := h.dispatchRequest(t)
	expiresAt, err := time.Parse(time.RFC3339, req.ExpiresAt)
	if err != nil {
		t.Fatal(err)
	}
	*h.now = expiresAt.Add(time.Nanosecond)

	if h.server.maybeDispatchNativeMTPCanary(mustResolveProvider(t, h.registry, h.provider.ProviderID, h.provider.AssignedID), *h.now) {
		t.Fatal("timeout expiry must not dispatch a replacement request")
	}
	disable := h.readDisable(t)
	if disable.Reason != "timeout" || disable.NativeMTPRuntimeTupleSHA256 != h.offer.NativeMTPRuntimeTupleSHA256 {
		t.Fatalf("unexpected timeout disable: %+v", disable)
	}

	if h.server.maybeDispatchNativeMTPCanary(mustResolveProvider(t, h.registry, h.provider.ProviderID, h.provider.AssignedID), *h.now) {
		t.Fatal("disabled timeout tuple must not dispatch again")
	}
	h.assertNoServerFrame(t)
}

func TestNativeMTPCanaryBankMismatchSendsTupleDisable(t *testing.T) {
	h := newNativeMTPCanaryIntegrationHarness(t)
	badOffer := h.offer
	badOffer.ChallengeBankSHA256 = strings.Repeat("1", 64)
	h.server.handleNativeMTPTupleOffer(h.provider.ProviderID, h.provider.AssignedID, mustMarshalNativeMTP(t, badOffer))

	disable := h.readDisable(t)
	if disable.Reason != "bank_mismatch" || disable.NativeMTPRuntimeTupleSHA256 != badOffer.NativeMTPRuntimeTupleSHA256 {
		t.Fatalf("unexpected bank mismatch disable: %+v", disable)
	}
	updated := mustResolveProvider(t, h.registry, h.provider.ProviderID, h.provider.AssignedID)
	if updated.State != pool.StateReady || updated.CanaryFailCount != 0 {
		t.Fatalf("bank mismatch tuple disable must not degrade provider: %+v", updated)
	}
}

type nativeMTPCanaryIntegrationHarness struct {
	server     *Server
	registry   *pool.Registry
	provider   *pool.Provider
	clientConn net.Conn
	serverConn net.Conn
	bank       NativeMTPChallengeBank
	record     NativeMTPChallengeRecord
	runtime    NativeMTPRuntimeTuple
	offer      NativeMTPTupleOffer
	now        *time.Time
}

func newNativeMTPCanaryIntegrationHarness(t *testing.T) *nativeMTPCanaryIntegrationHarness {
	t.Helper()
	raw, binding := nativeMTPValidBankFixture(t)
	bank, err := ParseNativeMTPChallengeBank(raw, binding)
	if err != nil {
		t.Fatal(err)
	}
	bank.Entries[0].ExpectedTerminalReason = "passed"
	record := bank.Entries[0]
	now := time.Date(2026, 9, 28, 2, 0, 0, 0, time.UTC)
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
	t.Cleanup(func() {
		_ = clientConn.Close()
		_ = serverConn.Close()
	})
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
	runtimeTupleSHA256 := nativeMTPRuntimeTupleIdentitySHA256(provider.ProviderID, provider.AssignedID, 7, admissionTupleSHA256, servedSnapshotID)
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
	return &nativeMTPCanaryIntegrationHarness{
		server:     server,
		registry:   registry,
		provider:   provider,
		clientConn: clientConn,
		serverConn: serverConn,
		bank:       bank,
		record:     record,
		runtime:    runtimeTuple,
		offer:      offer,
		now:        &now,
	}
}

func (h *nativeMTPCanaryIntegrationHarness) dispatchRequest(t *testing.T) NativeMTPCanaryRequest {
	t.Helper()
	if !h.server.maybeDispatchNativeMTPCanary(mustResolveProvider(t, h.registry, h.provider.ProviderID, h.provider.AssignedID), *h.now) {
		t.Fatal("expected dispatch")
	}
	rawReq, err := wsutil.ReadServerText(h.clientConn)
	if err != nil {
		t.Fatal(err)
	}
	req, _, err := ParseNativeMTPCanaryRequest(rawReq)
	if err != nil {
		t.Fatalf("parse request: %v", err)
	}
	return req
}

func (h *nativeMTPCanaryIntegrationHarness) wireResult(req NativeMTPCanaryRequest, decodePath string) NativeMTPCanaryResult {
	wireResult := NativeMTPCanaryResult{
		Type:                        "native_mtp_canary_result_v1",
		Version:                     1,
		RequestID:                   req.RequestID,
		ProviderID:                  req.ProviderID,
		AssignedID:                  req.AssignedID,
		RequestDigest:               req.RequestDigest,
		TargetGeneration:            req.TargetGeneration,
		ProviderRevision:            h.runtime.ProviderRevision,
		RuntimeRevision:             h.runtime.RuntimeRevision,
		ChallengeID:                 req.ChallengeID,
		ChallengeBankSHA256:         req.ChallengeBankSHA256,
		Nonce:                       req.Nonce,
		NativeMTPRuntimeTupleSHA256: req.NativeMTPRuntimeTupleSHA256,
		ExpectedTokenIDSHA256:       req.ExpectedTokenIDSHA256,
		ActualTokenIDSHA256:         h.record.ExpectedTokenIDSHA256,
		TerminalReason:              h.record.ExpectedTerminalReason,
		Counters:                    nativeMTPCountersFromCore(h.record.ExpectedCounters),
		CommittedStateSHA256:        h.record.ExpectedCommittedStateSHA256,
		ActualDecodePath:            decodePath,
		RuntimeTuple:                h.runtime,
	}
	wireResult.ResultDigest = nativeMTPCanaryResultDigest(wireResult)
	return wireResult
}

func (h *nativeMTPCanaryIntegrationHarness) readDisable(t *testing.T) NativeMTPTupleDisable {
	t.Helper()
	raw, err := wsutil.ReadServerText(h.clientConn)
	if err != nil {
		t.Fatal(err)
	}
	disable, _, err := ParseNativeMTPTupleDisable(raw)
	if err != nil {
		t.Fatalf("parse disable: %v raw=%s", err, string(raw))
	}
	return disable
}

func (h *nativeMTPCanaryIntegrationHarness) assertNoServerFrame(t *testing.T) {
	t.Helper()
	if err := h.clientConn.SetReadDeadline(time.Now().Add(50 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	defer h.clientConn.SetReadDeadline(time.Time{})
	if raw, err := wsutil.ReadServerText(h.clientConn); err == nil {
		t.Fatalf("unexpected server frame: %s", string(raw))
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
