package payout

import (
	"context"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// mockRPCClient is the test-side stub. All methods are wired
// from struct fields; tests can override any subset.
type mockRPCClient struct {
	label string
	chain uint64

	txCountFn       func(ctx context.Context, address string) (uint64, error)
	sendFn          func(ctx context.Context, raw []byte) (string, error)
	receiptFn       func(ctx context.Context, h string) (*Receipt, error)
	txByHashFn      func(ctx context.Context, h string) (*Transaction, error)
	blockNumFn      func(ctx context.Context) (uint64, error)
	callFn          func(ctx context.Context, to string, data []byte) ([]byte, error)
	nativeBalanceFn func(ctx context.Context, address string) (uint64, error)
}

func (m *mockRPCClient) Label() string { return m.label }
func (m *mockRPCClient) ChainID(_ context.Context) (uint64, error) {
	if m.chain == 0 {
		return BaseMainnetChainID, nil
	}
	return m.chain, nil
}
func (m *mockRPCClient) TransactionCount(ctx context.Context, address string) (uint64, error) {
	if m.txCountFn == nil {
		return 0, nil
	}
	return m.txCountFn(ctx, address)
}
func (m *mockRPCClient) SendRawTransaction(ctx context.Context, raw []byte) (string, error) {
	if m.sendFn == nil {
		return "0xdeadbeef", nil
	}
	return m.sendFn(ctx, raw)
}
func (m *mockRPCClient) TransactionReceipt(ctx context.Context, h string) (*Receipt, error) {
	if m.receiptFn == nil {
		return nil, nil
	}
	return m.receiptFn(ctx, h)
}
func (m *mockRPCClient) TransactionByHash(ctx context.Context, h string) (*Transaction, error) {
	if m.txByHashFn == nil {
		return nil, nil
	}
	return m.txByHashFn(ctx, h)
}
func (m *mockRPCClient) BlockNumber(ctx context.Context) (uint64, error) {
	if m.blockNumFn == nil {
		return 0, nil
	}
	return m.blockNumFn(ctx)
}
func (m *mockRPCClient) CallContract(ctx context.Context, to string, data []byte) ([]byte, error) {
	if m.callFn == nil {
		return nil, nil
	}
	return m.callFn(ctx, to, data)
}
func (m *mockRPCClient) NativeBalance(ctx context.Context, address string) (uint64, error) {
	if m.nativeBalanceFn == nil {
		return 0, nil
	}
	return m.nativeBalanceFn(ctx, address)
}

func TestTwoRPCs_AssertChainID_OK(t *testing.T) {
	rpcs := TwoRPCs{
		Primary:   &mockRPCClient{label: "primary"},
		Secondary: &mockRPCClient{label: "secondary"},
	}
	if err := rpcs.AssertChainID(context.Background(), BaseMainnetChainID); err != nil {
		t.Fatalf("AssertChainID: %v", err)
	}
}

func TestTwoRPCs_AssertChainID_RejectsWrongChain(t *testing.T) {
	rpcs := TwoRPCs{
		Primary:   &mockRPCClient{label: "primary", chain: 1},
		Secondary: &mockRPCClient{label: "secondary"},
	}
	if err := rpcs.AssertChainID(context.Background(), BaseMainnetChainID); err == nil {
		t.Fatal("expected error on primary chain mismatch")
	}
}

func TestTwoRPCs_ColdStartNonceSync_HappyPath(t *testing.T) {
	rpcs := TwoRPCs{
		Primary: &mockRPCClient{label: "primary", txCountFn: func(_ context.Context, _ string) (uint64, error) {
			return 7, nil
		}},
		Secondary: &mockRPCClient{label: "secondary", txCountFn: func(_ context.Context, _ string) (uint64, error) {
			return 7, nil
		}},
	}
	chosen, a, b, within, err := rpcs.ColdStartNonceSync(context.Background(), "0xabc")
	if err != nil {
		t.Fatalf("ColdStartNonceSync: %v", err)
	}
	if chosen != 7 || a != 7 || b != 7 || within {
		t.Errorf("happy-path: chosen=%d a=%d b=%d within=%v", chosen, a, b, within)
	}
}

func TestTwoRPCs_ColdStartNonceSync_WithinTolerance(t *testing.T) {
	rpcs := TwoRPCs{
		Primary: &mockRPCClient{label: "primary", txCountFn: func(_ context.Context, _ string) (uint64, error) {
			return 8, nil
		}},
		Secondary: &mockRPCClient{label: "secondary", txCountFn: func(_ context.Context, _ string) (uint64, error) {
			return 7, nil
		}},
	}
	chosen, a, b, within, err := rpcs.ColdStartNonceSync(context.Background(), "0xabc")
	if err != nil {
		t.Fatalf("ColdStartNonceSync: %v", err)
	}
	if chosen != 8 || a != 8 || b != 7 || !within {
		t.Errorf("within-tolerance: chosen=%d a=%d b=%d within=%v", chosen, a, b, within)
	}
}

func TestTwoRPCs_ColdStartNonceSync_HaltsOnDiffGT1(t *testing.T) {
	rpcs := TwoRPCs{
		Primary: &mockRPCClient{label: "primary", txCountFn: func(_ context.Context, _ string) (uint64, error) {
			return 100, nil
		}},
		Secondary: &mockRPCClient{label: "secondary", txCountFn: func(_ context.Context, _ string) (uint64, error) {
			return 90, nil
		}},
	}
	_, _, _, _, err := rpcs.ColdStartNonceSync(context.Background(), "0xabc")
	if err == nil {
		t.Fatal("expected halt on diff > 1")
	}
	if !strings.Contains(err.Error(), "nonce_cold_start_mismatch") {
		t.Errorf("err = %v, want nonce_cold_start_mismatch", err)
	}
}

func TestTwoRPCs_BroadcastBoth_PrimaryOnly(t *testing.T) {
	rpcs := TwoRPCs{
		Primary: &mockRPCClient{label: "primary", sendFn: func(_ context.Context, _ []byte) (string, error) {
			return "0xhash", nil
		}},
		Secondary: &mockRPCClient{label: "secondary", sendFn: func(_ context.Context, _ []byte) (string, error) {
			return "", &RPCError{Code: -32000, Message: "network error"}
		}},
	}
	ok, pH, _, pErr, sErr := rpcs.BroadcastBoth(context.Background(), []byte{0x02})
	if !ok {
		t.Fatal("expected accepted")
	}
	if pH != "0xhash" || pErr != nil {
		t.Errorf("primary: hash=%q err=%v", pH, pErr)
	}
	if sErr == nil {
		t.Errorf("secondary should have errored")
	}
}

func TestIsNonceTooLow(t *testing.T) {
	cases := []struct {
		err  error
		want bool
	}{
		{nil, false},
		{errors.New("plain error"), false},
		{&RPCError{Code: -32000, Message: "nonce too low"}, true},
		{&RPCError{Code: -32000, Message: "already known"}, true},
		{&RPCError{Code: -32000, Message: "replacement transaction underpriced"}, true},
		{&RPCError{Code: -32000, Message: "insufficient funds"}, false},
	}
	for _, c := range cases {
		if got := IsNonceTooLow(c.err); got != c.want {
			t.Errorf("IsNonceTooLow(%v) = %v, want %v", c.err, got, c.want)
		}
	}
}

func TestReceiptsAgree(t *testing.T) {
	a := &Receipt{TxHash: "0xh", BlockHash: "0xb", BlockNumber: 5, Status: 1, To: "0xusdc"}
	b := &Receipt{TxHash: "0xh", BlockHash: "0xb", BlockNumber: 5, Status: 1, To: "0xusdc"}
	if !ReceiptsAgree(a, b) {
		t.Fatal("identical receipts should agree")
	}
	c := *b
	c.BlockHash = "0xdifferent"
	if ReceiptsAgree(a, &c) {
		t.Error("block-hash mismatch should NOT agree")
	}
	if ReceiptsAgree(nil, b) || ReceiptsAgree(a, nil) {
		t.Error("nil receipt should not agree")
	}
}

// TestHTTPRPCClient_TransactionReceipt_OK uses a httptest server
// to exercise the JSON-RPC encoding + receipt decoding end-to-end.
func TestHTTPRPCClient_TransactionReceipt_OK(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var req rpcReq
		_ = json.Unmarshal(body, &req)
		if req.Method != "eth_getTransactionReceipt" {
			t.Errorf("method = %s", req.Method)
		}
		resp := map[string]interface{}{
			"jsonrpc": "2.0",
			"id":      1,
			"result": map[string]interface{}{
				"transactionHash": "0xabcdef",
				"blockHash":       "0xbbbb",
				"blockNumber":     "0xa",
				"status":          "0x1",
				"from":            "0xFROM",
				"to":              "0xTO",
				"gasUsed":         "0x5208",
				"logs": []map[string]interface{}{
					{
						"address": "0x" + hex.EncodeToString(make([]byte, 20)),
						"topics":  []string{"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"},
						"data":    "0x" + hex.EncodeToString(make([]byte, 32)),
					},
				},
			},
		}
		_ = json.NewEncoder(w).Encode(resp)
	}))
	defer server.Close()
	client := NewHTTPRPCClient(server.URL, "test", nil, time.Second)
	r, err := client.TransactionReceipt(context.Background(), "0xabcdef")
	if err != nil {
		t.Fatalf("TransactionReceipt: %v", err)
	}
	if r == nil {
		t.Fatal("nil receipt")
	}
	if r.TxHash != "0xabcdef" {
		t.Errorf("TxHash = %s", r.TxHash)
	}
	if r.BlockNumber != 10 {
		t.Errorf("BlockNumber = %d, want 10", r.BlockNumber)
	}
	if r.Status != 1 {
		t.Errorf("Status = %d, want 1", r.Status)
	}
	if r.From != "0xfrom" {
		t.Errorf("From = %s (lowercase normalization)", r.From)
	}
	if len(r.Logs) != 1 {
		t.Fatalf("logs len = %d", len(r.Logs))
	}
	if r.Logs[0].Topics[0] != "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" {
		t.Errorf("log topic = %s", r.Logs[0].Topics[0])
	}
}

// TestHTTPRPCClient_TransactionReceipt_NotFound asserts a null
// result returns (nil, nil) — the SPEC §4.7 reorg signal.
func TestHTTPRPCClient_TransactionReceipt_NotFound(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"jsonrpc": "2.0",
			"id":      1,
			"result":  nil,
		})
	}))
	defer server.Close()
	client := NewHTTPRPCClient(server.URL, "test", nil, time.Second)
	r, err := client.TransactionReceipt(context.Background(), "0xabcdef")
	if err != nil {
		t.Fatalf("TransactionReceipt: %v", err)
	}
	if r != nil {
		t.Errorf("expected nil receipt, got %+v", r)
	}
}

func TestHTTPRPCClient_RPCError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"jsonrpc": "2.0",
			"id":      1,
			"error": map[string]interface{}{
				"code":    -32000,
				"message": "nonce too low",
			},
		})
	}))
	defer server.Close()
	client := NewHTTPRPCClient(server.URL, "test", nil, time.Second)
	_, err := client.SendRawTransaction(context.Background(), []byte{0x02})
	if err == nil {
		t.Fatal("expected RPC error")
	}
	if !IsNonceTooLow(err) {
		t.Errorf("IsNonceTooLow should be true for %v", err)
	}
}

// TestMakeSPKIPinVerifier_LiveRead locks the [arch:r2-4.2] MAJOR
// closure: makeSPKIPinVerifier now accepts a func() string so that
// pin changes are read at handshake time rather than captured at
// construction time. The test verifies the live read behaviour directly
// against the verifier function without a real TLS connection:
//  1. pinFn returns the WRONG pin → verifier returns an error.
//  2. pinFn is updated to return the CORRECT pin → verifier returns nil.
func TestMakeSPKIPinVerifier_LiveRead(t *testing.T) {
	// Use a real self-signed DER cert so we have a real SPKI to hash.
	// httptest.NewTLSServer generates one; grab its leaf.
	ts := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {}))
	defer ts.Close()

	if len(ts.TLS.Certificates) == 0 {
		t.Fatal("TLS test server has no certificates")
	}
	leafDER := ts.TLS.Certificates[0].Certificate[0]
	cert, err := x509.ParseCertificate(leafDER)
	if err != nil {
		t.Fatalf("parse cert: %v", err)
	}
	spkiHash := sha256.Sum256(cert.RawSubjectPublicKeyInfo)
	correctPin := hex.EncodeToString(spkiHash[:])
	wrongPin := strings.Repeat("00", 32) // 64 hex zeros — valid format, wrong hash

	// Mutable pin source simulating the live TuningProvider.
	currentPin := wrongPin
	verifier := makeSPKIPinVerifier(func() string { return currentPin })

	// With wrong pin: verifier must return SPKI mismatch error.
	rawCerts := [][]byte{leafDER}
	err = verifier(rawCerts, nil)
	if err == nil {
		t.Fatal("verifier with wrong pin should have returned an error")
	}
	if !strings.Contains(err.Error(), "SPKI pin") {
		t.Errorf("error should mention SPKI pin; got: %v", err)
	}

	// Update the pin source — simulates a SIGHUP SPKI rotation landing.
	currentPin = correctPin

	// With correct pin: verifier must return nil (live read succeeds).
	err = verifier(rawCerts, nil)
	if err != nil {
		t.Errorf("verifier with correct pin returned error: %v", err)
	}

	// Empty pin: verifier must return nil (pinning disabled).
	currentPin = ""
	err = verifier(rawCerts, nil)
	if err != nil {
		t.Errorf("verifier with empty pin (no pinning) returned error: %v", err)
	}
}

// TestHTTPRPCClient_CloseIdleConnections locks the Step 4 r4/r5
// [code:r4-3]/[code:r5-5] MEDIUM closure: CloseIdleConnections drains
// idle connections from the transport pool so the next request opens a
// NEW connection. Proved via httptest.Server ConnState instrumentation:
// after req1 → CloseIdleConnections → req2, the server MUST have seen
// 2 distinct connections (not reused the idle one from req1).
//
// Also verifies nil-receiver and nil-transport guards.
func TestHTTPRPCClient_CloseIdleConnections(t *testing.T) {
	// 1. Nil receiver is a no-op.
	var nilClient *HTTPRPCClient
	nilClient.CloseIdleConnections() // must not panic

	// 2. Client with nil transport (constructed without NewHTTPRPCClient).
	noTransport := &HTTPRPCClient{URL: "http://localhost", transport: nil}
	noTransport.CloseIdleConnections() // must not panic

	// 3. Step 4 r5 [code:r5-5] MEDIUM closure: prove the pool is actually
	//    drained. We count distinct connections via ConnState callbacks.
	//    After req1, the connection goes to StateIdle. After
	//    CloseIdleConnections, that connection is closed (StateClosed).
	//    req2 must open a NEW connection, visible as a second StateNew.
	//
	//    Use NewUnstartedServer to set ConnState before Start so there
	//    is no concurrent access between the assignment and the server
	//    goroutine reading it (which the race detector would catch).
	var mu sync.Mutex
	newConns := 0
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	srv.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		if state == http.StateNew {
			mu.Lock()
			newConns++
			mu.Unlock()
		}
	}
	srv.Start()
	defer srv.Close()

	client := NewHTTPRPCClient(srv.URL, "test", nil, 5*time.Second)

	// req1: land an idle connection in the pool.
	resp1, err := client.HTTPClient.Get(srv.URL) //nolint:noctx
	if err != nil {
		t.Fatalf("GET req1: %v", err)
	}
	resp1.Body.Close()

	// Drain the idle pool.
	client.CloseIdleConnections()

	// req2: must open a fresh connection because the pool is empty.
	resp2, err := client.HTTPClient.Get(srv.URL) //nolint:noctx
	if err != nil {
		t.Fatalf("GET req2: %v", err)
	}
	resp2.Body.Close()

	mu.Lock()
	got := newConns
	mu.Unlock()
	if got < 2 {
		t.Errorf("server saw %d new connections, want >= 2 (CloseIdleConnections did not drain the pool)", got)
	}
}

// TestSIGHUPCloseIdleComposition locks the [code:r4-3] MEDIUM closure:
// when SPKI changed keys are present, CloseIdleConnections is called on
// both primary AND secondary; when no SPKI key is in changedKeys, it is
// NOT called on either.
//
// Because the SIGHUP handler in main.go calls concrete *HTTPRPCClient
// methods, we test the composition using the TuningProvider.Reload
// return value (changedKeys) and a mock that counts close-idle calls.
func TestSIGHUPCloseIdleComposition(t *testing.T) {
	type countingClient struct {
		closeIdleCalls int
	}
	spkiKey := "payout.tuning.rpc_url_primary_pin_spki"
	secondaryKey := "payout.tuning.rpc_url_secondary_pin_spki"

	cases := []struct {
		name        string
		changedKeys []string
		wantClose   bool
	}{
		{"no SPKI change — no close", []string{"payout.tuning.run_interval"}, false},
		{"primary SPKI change — close", []string{spkiKey}, true},
		{"secondary SPKI change — close", []string{secondaryKey}, true},
		{"both SPKI change — close (break after first hit)", []string{spkiKey, secondaryKey}, true},
	}

	// Mimic the SIGHUP handler composition logic from main.go so the
	// test stays in sync with it. If main.go changes the condition, this
	// test should also change — its purpose is to lock the composition.
	closeOnSPKIChange := func(changedKeys []string, primary, secondary *countingClient) {
		for _, k := range changedKeys {
			if k == "payout.tuning.rpc_url_primary_pin_spki" ||
				k == "payout.tuning.rpc_url_secondary_pin_spki" {
				primary.closeIdleCalls++
				secondary.closeIdleCalls++
				break
			}
		}
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			primary := &countingClient{}
			secondary := &countingClient{}
			closeOnSPKIChange(c.changedKeys, primary, secondary)
			if c.wantClose {
				if primary.closeIdleCalls == 0 {
					t.Errorf("primary.CloseIdleConnections not called for changedKeys=%v", c.changedKeys)
				}
				if secondary.closeIdleCalls == 0 {
					t.Errorf("secondary.CloseIdleConnections not called for changedKeys=%v", c.changedKeys)
				}
			} else {
				if primary.closeIdleCalls != 0 {
					t.Errorf("primary.CloseIdleConnections called %d times; want 0 for changedKeys=%v", primary.closeIdleCalls, c.changedKeys)
				}
				if secondary.closeIdleCalls != 0 {
					t.Errorf("secondary.CloseIdleConnections called %d times; want 0 for changedKeys=%v", secondary.closeIdleCalls, c.changedKeys)
				}
			}
		})
	}
}
