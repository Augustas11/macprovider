package integration

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
)

// SPEC-022 R-14 / SPEC-001-R005 / SPEC-015 §N.13 across the real
// coordinator, gateway, relay-blind client, and Swift InferenceRelay: an
// enforce coordinator with relay_blind.enforce_settlement_profile, a Swift
// fixture that pins the catalog model hash, completes the SPEC-008 key
// agreement, and signs relay-blind-settlement-v1 receipts.

const relayBlindSettlementEntrypoint = "coordinator_buyer_v1_relay_blind_chat_completions"

type relayBlindSettlementStack struct {
	s          *scenario
	fixture    *swiftRelayFixture
	stateDir   string
	providerID string
	// snapshotsAtDispatch records, for each dispatch in order, how many
	// relay-blind route snapshots the coordinator journal held when the
	// provider received the inference_request.
	snapshotsMu         sync.Mutex
	snapshotsAtDispatch []int
}

type relayBlindSettlementOpts struct {
	privacy        bool
	omitCapability bool
}

func newRelayBlindSettlementStack(t *testing.T, opts relayBlindSettlementOpts) *relayBlindSettlementStack {
	t.Helper()
	requirePrivacyDarwin(t)
	stateDir := t.TempDir()
	if err := os.Chmod(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	resolved, err := filepath.EvalSymlinks(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	stateDir = resolved
	providerID := "prov-swift-settle-" + randHex(t, 4)
	// The catalog fixture is deterministic, so its model hash is known
	// before the scenario boots; a probe scenario is not needed.
	fixture := &swiftRelayFixture{
		t:                    t,
		stateDir:             stateDir,
		model:                settlementFixtureModelID,
		settlementModelHash:  settlementCatalogModelHash(t),
		settlementProviderID: providerID,
		stdoutLog:            newLogBuffer(),
		stderrLog:            newLogBuffer(),
	}
	if opts.privacy {
		fixture.privacyClass = true
		fixture.privacyProviderID = providerID
		fixture.privacyCompletion = privacyCanaryCompletion
		fixture.postureReady = make(chan struct{})
	}
	fixture.start("")
	t.Cleanup(fixture.stop)
	if fixture.descriptor.ProviderECDHPublicKey == "" || fixture.descriptor.ReceiptPublicKey == "" ||
		fixture.descriptor.ModelHash != fixture.settlementModelHash || fixture.descriptor.ProviderID != providerID {
		t.Fatal("Swift settlement fixture descriptor lacks its SPEC-008 key, receipt key, or pinned model hash")
	}
	scenarioOptions := scenarioOpts{
		seedAccount:                        true,
		providerID:                         providerID,
		externalWebSocketProvider:          true,
		settlementReceiptProvider:          true,
		settlementEnforceMode:              true,
		settlementReconcileIntervalSeconds: 1,
		pendingDeadlineSeconds:             1,
		gatewayRelayBlindEnabled:           true,
		coordinatorRelayBlindEnabled:       true,
		relayBlindIdentityPublicKeys:       map[string]string{providerID: fixture.descriptor.IdentityPublicKey},
		captureCoordLogs:                   true,
		captureGatewayLogs:                 true,
	}
	if opts.privacy {
		scenarioOptions.coordinatorPrivacyClass = &coordinatorPrivacyClassOpts{
			SEPublicKey:       fixture.descriptor.SEPublicKey,
			TeamID:            fixture.descriptor.TeamID,
			SigningIdentifier: fixture.descriptor.SigningIdentifier,
			CDHash:            fixture.descriptor.CodeCDHash,
		}
		scenarioOptions.gatewayPrivacyClass = true
	}
	s := newScenario(t, scenarioOptions)
	if s.modelHash != fixture.settlementModelHash {
		t.Fatalf("catalog model hash %s differs from the fixture pin %s", s.modelHash, fixture.settlementModelHash)
	}
	stack := &relayBlindSettlementStack{s: s, fixture: fixture, stateDir: stateDir, providerID: providerID}
	fixture.onDispatch = func([]byte) {
		count := stack.relayBlindSnapshotCount()
		stack.snapshotsMu.Lock()
		stack.snapshotsAtDispatch = append(stack.snapshotsAtDispatch, count)
		stack.snapshotsMu.Unlock()
	}
	connectSwiftSettlementProvider(t, s.rootCtx, s, fixture, opts.omitCapability)
	s.waitForProviderReady(providerID)
	if opts.privacy {
		fixture.waitPosture(25 * time.Second)
	}
	return stack
}

// settlementCatalogModelHash boots nothing: it reads the hash the
// deterministic settlement catalog fixture assigns.
func settlementCatalogModelHash(t *testing.T) string {
	t.Helper()
	probe := &scenario{t: t, tempDir: t.TempDir()}
	return probe.writeSettlementCatalogFixture().modelHash
}

func (st *relayBlindSettlementStack) relayBlindSnapshotCount() int {
	db, err := sql.Open("sqlite", "file:"+st.s.coordinatorDB+".route-snapshots?_pragma=busy_timeout(10000)")
	if err != nil {
		return -1
	}
	defer db.Close()
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM settlement_route_snapshot_journal WHERE paid_entrypoint = ? AND prompt_hash_basis = 'relay_blind_envelope_digest_v1'`,
		relayBlindSettlementEntrypoint).Scan(&count); err != nil {
		return -1
	}
	return count
}

func (st *relayBlindSettlementStack) pinPath(t *testing.T) string {
	t.Helper()
	path := filepath.Join(st.stateDir, "buyer-pin.json")
	pin := map[string]any{
		"version":             "relay-blind-pilot-pin-v1",
		"identity_public_key": st.fixture.descriptor.IdentityPublicKey,
		"fingerprint":         st.fixture.descriptor.KeyRecord["identity_fingerprint"],
		"models":              []string{settlementFixtureModelID},
		"endpoint_families":   []string{"chat_completions"},
		"not_before_unix":     st.fixture.descriptor.KeyRecord["not_before_unix"],
		"expires_at_unix":     st.fixture.descriptor.KeyRecord["expires_at_unix"],
		"revoked":             false,
	}
	raw, err := json.Marshal(pin)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func (st *relayBlindSettlementStack) runClient(t *testing.T, prompt string, stream, privacy bool) (string, string) {
	t.Helper()
	stdout, stderr, err := st.tryClient(t, prompt, stream, privacy)
	if err != nil {
		t.Fatalf("relay-blind client stream=%v privacy=%v: %v (%s)", stream, privacy, err, privacyClientDetail(stderr))
	}
	return stdout, stderr
}

func (st *relayBlindSettlementStack) tryClient(t *testing.T, prompt string, stream, privacy bool) (string, string, error) {
	t.Helper()
	args := []string{
		"--base-url", st.s.gatewayBaseURL,
		"--identity-pin", st.pinPath(t),
		"--model", settlementFixtureModelID,
		"--max-output-tokens", "32",
		"--input-token-upper-bound", "64",
		"--input", "-",
	}
	if stream {
		args = append(args, "--stream")
	}
	if privacy {
		args = append(args, "--privacy-class")
	}
	cmd := exec.Command(relayBlindClientBin, args...)
	cmd.Env = append(os.Environ(), "MACPROVIDER_API_KEY="+st.s.apiKey)
	cmd.Stdin = strings.NewReader(fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":%q}],"stream":%t,"max_tokens":32}`, settlementFixtureModelID, prompt, stream))
	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	return stdout.String(), stderr.String(), err
}

// latestGatewayReservation waits for the n-th gateway quota reservation and
// returns its request id.
func (st *relayBlindSettlementStack) latestGatewayReservation(t *testing.T, n int) string {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if st.s.countGatewayRows("quota_reservations") >= n {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	db, err := sql.Open("sqlite", st.s.gatewayDB)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var count int
	var requestID string
	if err := db.QueryRow(`SELECT COUNT(*) FROM quota_reservations WHERE account_id = ?`, st.s.accountID).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != n {
		t.Fatalf("gateway quota_reservations=%d, want %d", count, n)
	}
	if err := db.QueryRow(`SELECT request_id FROM quota_reservations WHERE account_id = ? ORDER BY rowid DESC LIMIT 1`, st.s.accountID).Scan(&requestID); err != nil {
		t.Fatal(err)
	}
	return requestID
}

// waitForNthClosedVerdict returns the n-th settlement verdict once it is
// closed. The coordinator keys verdicts by its own settlement request id,
// not the gateway's, and these scenarios run requests one at a time.
func waitForNthClosedVerdict(t *testing.T, s *scenario, n int) settlementReceiptVerdictRow {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	var latest []settlementReceiptVerdictRow
	for time.Now().Before(deadline) {
		latest = s.readSettlementReceiptVerdicts()
		if len(latest) > n {
			t.Fatalf("settlement verdicts=%d, want %d: %+v", len(latest), n, latest)
		}
		if len(latest) == n && latest[n-1].Closed == 1 {
			return latest[n-1]
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("no closed settlement verdict #%d; verdicts=%+v", n, latest)
	return settlementReceiptVerdictRow{}
}

func ledgerCreditFor(t *testing.T, s *scenario, requestID string) ledgerCreditRow {
	t.Helper()
	for _, row := range s.readLedgerCredits() {
		if row.RequestID == requestID {
			return row
		}
	}
	t.Fatalf("no ledger credit for request %s", requestID)
	return ledgerCreditRow{}
}

func verifiedWorkCount(t *testing.T, s *scenario) int {
	t.Helper()
	db, err := sql.Open("sqlite", "file:"+s.coordinatorDB+"?_pragma=busy_timeout(10000)")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var count int
	// The predicate every verified-work consumer uses (rewards unlock,
	// referral serving, provider receipt summaries).
	if err := db.QueryRow(`SELECT COUNT(*) FROM settlement_receipt_verdicts WHERE closed = 1 AND settlement_outcome = 'verified' AND receipt_result = 'valid'`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	return count
}

// assertRelayBlindSettled runs one request and proves the full R-14 money
// path: snapshot before dispatch, a closed relay_blind_settled verdict, a
// payable provider credit, and gateway debit usage equal to credit usage.
func (st *relayBlindSettlementStack) assertRelayBlindSettled(t *testing.T, n int, stream, privacy bool) {
	t.Helper()
	label := fmt.Sprintf("stream=%v privacy=%v", stream, privacy)
	prompt := "relay-blind settlement " + label
	if privacy {
		prompt = privacyCanaryPrompt
	}
	stdout, stderr := st.runClient(t, prompt, stream, privacy)
	if privacy {
		if !privacyPlaintextHas(stdout, privacyCanaryCompletion) || !strings.Contains(stderr, "privacy class satisfied") {
			t.Fatalf("%s: privacy client did not decrypt or confirm the response (stdout_len=%d)", label, len(stdout))
		}
	} else if !strings.Contains(stdout, "fixture response") || !strings.Contains(stderr, "relay-blind satisfied") {
		t.Fatalf("%s: relay-blind client output=%q stderr=%q", label, stdout, stderr)
	}
	if got := st.fixture.dispatches.Load(); got != int32(n) {
		t.Fatalf("%s: fixture dispatches=%d, want %d", label, got, n)
	}
	st.snapshotsMu.Lock()
	observed := append([]int(nil), st.snapshotsAtDispatch...)
	st.snapshotsMu.Unlock()
	if len(observed) != n || observed[n-1] != n {
		t.Fatalf("%s: relay-blind route snapshots at dispatch=%v, want the %d-th committed before dispatch", label, observed, n)
	}
	requestID := st.latestGatewayReservation(t, n)
	verdict := waitForNthClosedVerdict(t, st.s, n)
	if verdict.SettlementOutcome != "relay_blind_settled" || verdict.ReceiptResult != "valid" || verdict.Closed != 1 ||
		!verdict.ReceiptVersion.Valid || verdict.ReceiptVersion.String != "relay-blind-settlement-v1" || verdict.RouteSnapshotMode != "enforce" {
		t.Fatalf("%s: verdict=%+v, want closed valid relay_blind_settled relay-blind-settlement-v1 under enforce", label, verdict)
	}
	if !verdict.ModelHash.Valid || verdict.ModelHash.String != st.fixture.settlementModelHash {
		t.Fatalf("%s: verdict model hash=%v, want the pinned catalog hash", label, verdict.ModelHash)
	}
	if got := st.s.payableCreditCount(verdict.RequestID); got != 1 {
		t.Fatalf("%s: payable provider credits=%d, want 1", label, got)
	}
	credit := ledgerCreditFor(t, st.s, verdict.RequestID)
	// Nine tokens round to zero credits at fixture rates; payability is the
	// spec022_payable_request_credits row above.
	if credit.SettlementPolicyMode != "enforce" || credit.Status != http.StatusOK || credit.ProviderID != st.providerID {
		t.Fatalf("%s: provider credit=%+v, want an enforce credit for %s", label, credit, st.providerID)
	}
	usage, reservation := waitForSpec022GatewaySettlement(t, st.s, requestID)
	if usage.Outcome != "spec022_relay_blind_settled" {
		t.Fatalf("%s: gateway usage outcome=%q, want spec022_relay_blind_settled", label, usage.Outcome)
	}
	creditPrompt := credit.PromptTokens.Int64
	creditCompletion := credit.CompletionTokens.Int64
	if usage.PromptTokens != creditPrompt || usage.CompletionTokens != creditCompletion ||
		reservation.SettledTokens != creditPrompt+creditCompletion || creditPrompt != 5 || creditCompletion != 4 {
		t.Fatalf("%s: gateway debit usage=%d+%d settled=%d, provider credit usage=%d+%d; want equal 5+4",
			label, usage.PromptTokens, usage.CompletionTokens, reservation.SettledTokens, creditPrompt, creditCompletion)
	}
	if got := verifiedWorkCount(t, st.s); got != 0 {
		t.Fatalf("%s: verified-work rows=%d, want 0 (relay_blind_settled is never verified)", label, got)
	}
}

func TestRelayBlindEnforceSettlesSwiftReceipts(t *testing.T) {
	st := newRelayBlindSettlementStack(t, relayBlindSettlementOpts{})
	st.assertRelayBlindSettled(t, 1, false, false)
	st.assertRelayBlindSettled(t, 2, true, false)

	// A validly signed receipt whose tuple was tampered (the handle pins a
	// model hash other than the snapshot's catalog hash) is a trust failure:
	// quarantined, buyer refunded, no provider credit.
	st.fixture.tamperReceipts(t)
	// The buyer response may fail closed once the receipt is quarantined;
	// either way the hold is refunded below.
	_, _, _ = st.tryClient(t, "relay-blind settlement tampered", false, false)
	requestID := st.latestGatewayReservation(t, 3)
	verdict := waitForNthClosedVerdict(t, st.s, 3)
	if verdict.SettlementOutcome != "quarantined" || verdict.ReceiptResult == "valid" {
		t.Fatalf("tampered receipt verdict=%+v, want quarantined", verdict)
	}
	refund, ok := waitForQuotaStatus(t, st.s, requestID, "refunded")
	if !ok || refund.SettledTokens != 0 {
		t.Fatalf("tampered receipt quota=%+v ok=%v, want refunded with no debit", refund, ok)
	}
	if got := st.s.payableCreditCount(verdict.RequestID); got != 0 {
		t.Fatalf("tampered receipt payable credits=%d, want 0", got)
	}
	if got := verifiedWorkCount(t, st.s); got != 0 {
		t.Fatalf("verified-work rows=%d, want 0", got)
	}
}

func TestPrivacyClassEnforceSettlesSwiftReceipts(t *testing.T) {
	st := newRelayBlindSettlementStack(t, relayBlindSettlementOpts{privacy: true})
	st.assertRelayBlindSettled(t, 1, false, true)
	st.assertRelayBlindSettled(t, 2, true, true)
	// SPEC-049-R021: the receipt-derived rows carry no canary and no SHA-256
	// of the canary prompt, the canary completion, or the decrypted request.
	needles := []string{privacyCanaryPrompt, privacyCanaryCompletion}
	for _, plaintext := range []string{
		privacyCanaryPrompt,
		privacyCanaryCompletion,
		fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":%q}],"stream":%t,"max_tokens":32}`, settlementFixtureModelID, privacyCanaryPrompt, false),
		fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":%q}],"stream":%t,"max_tokens":32}`, settlementFixtureModelID, privacyCanaryPrompt, true),
	} {
		sum := sha256.Sum256([]byte(plaintext))
		needles = append(needles, hex.EncodeToString(sum[:]))
	}
	for _, source := range []struct{ path, table string }{
		{st.s.coordinatorDB, "settlement_receipt_verdicts"},
		{st.s.coordinatorDB, "settlement_route_snapshots"},
		{st.s.coordinatorDB, "ledger_request_credits"},
		{st.s.coordinatorDB + ".route-snapshots", "settlement_route_snapshot_journal"},
	} {
		assertSQLiteTableLacks(t, source.path, source.table, needles)
	}
}

func assertSQLiteTableLacks(t *testing.T, path, table string, needles []string) {
	t.Helper()
	db, err := sql.Open("sqlite", "file:"+path+"?_pragma=busy_timeout(10000)")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	rows, err := db.Query(`SELECT * FROM ` + table)
	if err != nil {
		t.Fatalf("scan %s: %v", table, err)
	}
	defer rows.Close()
	columns, _ := rows.Columns()
	scanned := 0
	for rows.Next() {
		values := make([]any, len(columns))
		pointers := make([]any, len(columns))
		for i := range values {
			pointers[i] = &values[i]
		}
		if err := rows.Scan(pointers...); err != nil {
			t.Fatal(err)
		}
		scanned++
		for i, value := range values {
			text := fmt.Sprint(value)
			if raw, ok := value.([]byte); ok {
				text = string(raw)
			}
			for _, needle := range needles {
				if strings.Contains(text, needle) {
					t.Fatalf("%s.%s carries plaintext-derived material", table, columns[i])
				}
			}
		}
	}
	if scanned == 0 {
		t.Fatalf("%s has no rows to scan", table)
	}
}

// R-14.2 with a real Swift provider over auth_request: a session that did
// not advertise relay_blind_settlement_receipt_v1 is never reserved.
func TestRelayBlindEnforceExcludesSwiftProviderWithoutCapability(t *testing.T) {
	st := newRelayBlindSettlementStack(t, relayBlindSettlementOpts{omitCapability: true})
	status, _, body := st.s.jsonRequest(http.MethodPost, "/v1/relay-blind/route-reservations", nil,
		strings.Replace(relayBlindReservationBody, defaultFakeModelID, settlementFixtureModelID, 1))
	if status != http.StatusServiceUnavailable || relayBlindErrorCode(t, body) != "relay_blind_provider_unsupported" {
		t.Fatalf("status=%d body=%s, want 503 relay_blind_provider_unsupported", status, body)
	}
	if got := st.s.countGatewayRows("quota_reservations"); got != 0 {
		t.Fatalf("quota_reservations=%d, want 0", got)
	}
	if got := st.fixture.dispatches.Load(); got != 0 {
		t.Fatalf("fixture dispatches=%d, want 0", got)
	}
}

// tamperReceipts makes later fixture receipts sign a substituted model hash.
func (f *swiftRelayFixture) tamperReceipts(t *testing.T) {
	t.Helper()
	line, err := f.exchangeLine([]byte(`{"type":"relay_fixture_tamper_receipts"}`))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(line), "relay_fixture_tamper_receipts_ack") {
		t.Fatalf("tamper control rejected: %s", line)
	}
}

// connectSwiftSettlementProvider runs the auth_request v2 handshake the
// production CLI runs, with the Swift fixture's SPEC-008 key, receipt key,
// pinned catalog hash, and relay-blind or privacy key records. The fixture
// completes the key agreement, so every dispatch is SPEC-008 sealed end to
// end and this bridge relays ciphertext only.
func connectSwiftSettlementProvider(t *testing.T, ctx context.Context, s *scenario, fixture *swiftRelayFixture, omitCapability bool) {
	t.Helper()
	u, err := url.Parse(s.coordProvURL)
	if err != nil {
		t.Fatal(err)
	}
	header := http.Header{}
	header.Set("Authorization", "Bearer "+s.providerToken)
	dialer := gobwas.Dialer{Timeout: 5 * time.Second, Header: gobwas.HandshakeHeaderHTTP(header)}
	var conn net.Conn
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		conn, _, _, err = dialer.Dial(ctx, "ws://"+u.Host+"/ws/provider")
		if err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if conn == nil {
		t.Fatalf("connect Swift settlement provider: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	var writeMu sync.Mutex
	send := func(raw []byte) error {
		writeMu.Lock()
		defer writeMu.Unlock()
		return wsutil.WriteClientText(conn, raw)
	}
	keyRecords := func(msg map[string]any) {
		if records := fixture.privacyKeyRecords(); len(records) > 0 {
			msg["privacy_key_records"] = records
		} else {
			msg["relay_blind_key_records"] = []any{fixture.descriptor.KeyRecord}
		}
	}
	capabilities := map[string]any{"encrypted_leg": true, "attestation": false, "aead_suites": []string{"A256GCM"}}
	if !omitCapability {
		capabilities["relay_blind_settlement_receipt_v1"] = true
	}
	initial := map[string]any{
		"type":                        "auth_request",
		"version":                     2,
		"stage":                       "initial",
		"provider_id":                 s.providerID,
		"hostname":                    "swift-settlement-fixture",
		"model_id":                    settlementFixtureModelID,
		"model_params_b":              3.0,
		"ram_gb":                      16,
		"max_context_tokens":          8192,
		"max_concurrency":             1,
		"throughput_tps_estimate":     20.0,
		"binary_version":              "relay-blind-local-fixture",
		"provider_ecdh_public_key":    fixture.descriptor.ProviderECDHPublicKey,
		"provider_receipt_public_key": fixture.descriptor.ReceiptPublicKey,
		"supported_models":            []string{settlementFixtureModelID},
		"publishes_supported_models":  true,
		"tier2_capabilities":          capabilities,
		"catalog_release_id":          s.autotuneCatalogVersion,
		"catalog_policy_version":      s.autotunePolicyVersion,
		"catalog_candidate_sha256":    s.autotuneCatalogSHA256,
		"catalog_signer_key_id":       staticAutotuneSignerKeyID,
		"catalog_row_identity":        staticLlama32CandidateRowID,
	}
	addCanonicalModelIdentity(initial, fixture.settlementModelHash)
	keyRecords(initial)
	rawInitial, _ := json.Marshal(initial)
	if err := send(rawInitial); err != nil {
		t.Fatalf("send auth_request initial: %v", err)
	}
	challengeRaw, _, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read auth_challenge: %v", err)
	}
	var challenge map[string]any
	if err := json.Unmarshal(challengeRaw, &challenge); err != nil || challenge["type"] != "auth_challenge" {
		t.Fatalf("decode auth_challenge: %v (%s)", err, challengeRaw)
	}
	control, _ := json.Marshal(map[string]any{"type": "relay_fixture_tier2_challenge", "challenge": challenge})
	ackLine, err := fixture.exchangeLine(control)
	if err != nil || !strings.Contains(string(ackLine), "relay_fixture_tier2_session_ack") {
		t.Fatalf("Swift fixture SPEC-008 session: %v (%s)", err, ackLine)
	}
	proof := map[string]any{
		"type":                       "auth_request",
		"version":                    2,
		"stage":                      "proof",
		"auth_attempt_id":            challenge["auth_attempt_id"],
		"provider_id":                s.providerID,
		"attestation_token":          nil,
		"supported_models":           []string{settlementFixtureModelID},
		"publishes_supported_models": true,
	}
	rawProof, _ := json.Marshal(proof)
	if err := send(rawProof); err != nil {
		t.Fatalf("send auth_request proof: %v", err)
	}
	var challenges [][]byte
	for {
		_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))
		raw, _, err := wsutil.ReadServerData(conn)
		_ = conn.SetReadDeadline(time.Time{})
		if err != nil {
			t.Fatalf("read auth_response: %v", err)
		}
		var frame struct {
			Type   string `json:"type"`
			Status string `json:"status"`
		}
		if json.Unmarshal(raw, &frame) != nil {
			t.Fatal("decode frame before auth_response")
		}
		if frame.Type == "privacy_posture_challenge" && fixture.privacyClass {
			challenges = append(challenges, append([]byte(nil), raw...))
			continue
		}
		if frame.Type != "auth_response" || frame.Status != "accepted" {
			t.Fatalf("auth_response=%s", raw)
		}
		break
	}
	for _, challenge := range challenges {
		if err := answerSwiftPrivacyChallenge(fixture, challenge, send); err != nil {
			t.Fatalf("Swift privacy posture exchange: %v", err)
		}
	}
	ready := readyStateUpdate(settlementFixtureModelID, fixture.settlementModelHash)
	keyRecords(ready)
	rawReady, _ := json.Marshal(ready)
	if err := send(rawReady); err != nil {
		t.Fatalf("send ready state_update: %v", err)
	}
	var closed atomic.Bool
	go func() {
		for {
			raw, _, err := wsutil.ReadServerData(conn)
			if err != nil {
				closed.Store(true)
				return
			}
			var frame struct {
				Type string `json:"type"`
			}
			if json.Unmarshal(raw, &frame) != nil {
				continue
			}
			switch frame.Type {
			case "privacy_posture_challenge":
				if fixture.privacyClass {
					if err := answerSwiftPrivacyChallenge(fixture, raw, send); err != nil && ctx.Err() == nil {
						t.Errorf("Swift privacy posture exchange: %v", err)
						return
					}
				}
			case "inference_request":
				fixture.dispatches.Add(1)
				if fixture.onDispatch != nil {
					fixture.onDispatch(raw)
				}
				if err := fixture.serveFrame(raw, send); err != nil && ctx.Err() == nil && !errors.Is(err, net.ErrClosed) {
					t.Errorf("Swift settlement fixture dispatch: %v", err)
					return
				}
			}
		}
	}()
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if closed.Load() {
					return
				}
				hb := map[string]any{
					"type": "heartbeat", "status": "ready", "model_id": settlementFixtureModelID,
					"model_params_b": 3.0, "ram_gb": 16, "max_context_tokens": 8192,
					"max_concurrency": 1, "slots_free": 1, "slots_total": 1,
					"throughput_tps_estimate": 20.0, "requests_served_since_last": 0,
					"avg_latency_ms_since_last": 0.0, "throughput_tps_since_last": 0.0,
				}
				addCanonicalModelIdentity(hb, fixture.settlementModelHash)
				keyRecords(hb)
				raw, _ := json.Marshal(hb)
				if send(raw) != nil {
					return
				}
			}
		}
	}()
}
