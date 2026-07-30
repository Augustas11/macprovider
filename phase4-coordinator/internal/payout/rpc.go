package payout

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// SPEC-016 §4.4 — minimal Base mainnet JSON-RPC client.
//
// The IMPL avoids the go-ethereum rpc package because the §4.3
// hot path only needs ~five methods (eth_chainId,
// eth_getTransactionCount, eth_sendRawTransaction,
// eth_getTransactionReceipt, eth_getTransactionByHash) plus
// optional eth_blockNumber. A purpose-built client keeps the
// dependency surface narrow and the request shapes auditable
// against the SPEC line-by-line.
//
// The interface is mockable: tests inject a stub RPC client
// that returns canned responses without hitting the network.
// Production wiring uses *HTTPRPCClient against the operator's
// pinned RPC URLs.

// RPCClient is the runner-facing RPC surface. Two instances are
// wired (primary + secondary) per §4.4 two-RPC discipline.
type RPCClient interface {
	// ChainID returns the chain id advertised by the RPC. The
	// runner asserts this equals 8453 at startup to fail-loud
	// on a misconfigured RPC URL (e.g. an Ethereum mainnet RPC
	// instead of a Base mainnet RPC).
	ChainID(ctx context.Context) (uint64, error)

	// TransactionCount returns getTransactionCount(address,
	// "pending") — the next-nonce-to-use for the wallet.
	// SPEC §4.6 nonce cold-start uses this on both RPCs and
	// asserts ±1 agreement.
	TransactionCount(ctx context.Context, address string) (uint64, error)

	// SendRawTransaction submits a signed EIP-1559 envelope.
	// Returns the tx hash on success; the RPC error class is
	// preserved verbatim in the returned error so the runner can
	// distinguish nonce-too-low from network errors.
	SendRawTransaction(ctx context.Context, rawSignedTx []byte) (string, error)

	// TransactionReceipt returns the receipt for the given tx
	// hash, or nil receipt + nil error if the RPC reports "not
	// found" (the SPEC §4.7 reorg signal).
	TransactionReceipt(ctx context.Context, txHash string) (*Receipt, error)

	// TransactionByHash returns the full tx envelope. §4.3 step
	// 7 (a) uses this to verify tx.input byte-equality. Returns
	// nil tx + nil error on "not found".
	TransactionByHash(ctx context.Context, txHash string) (*Transaction, error)

	// BlockNumber returns the current best-block number. Used
	// by §4.3 step 7 to compute receipt depth.
	BlockNumber(ctx context.Context) (uint64, error)

	// CallContract issues an eth_call to the named contract
	// address with the supplied ABI-encoded calldata. Returns
	// the raw response bytes (caller decodes per ABI). Used by
	// §7.4 chain-balance worker for USDC balanceOf(hot_wallet).
	// Step 4 wiring.
	CallContract(ctx context.Context, to string, data []byte) ([]byte, error)

	// NativeBalance returns the native ETH balance of the
	// address in wei. Used by §6.2 low-native-balance alert.
	// Step 4 wiring.
	NativeBalance(ctx context.Context, address string) (uint64, error)

	// Label is an operator-readable name for log emissions
	// (e.g. "primary" / "secondary"). Required because both RPC
	// URLs are secret-bearing and MUST NOT be logged.
	Label() string
}

// Receipt is the minimal subset of eth_getTransactionReceipt the
// runner consumes. All fields are normalized to lowercase
// 0x-prefixed hex (where applicable).
type Receipt struct {
	TxHash      string
	BlockHash   string
	BlockNumber uint64
	Status      uint64 // 1 = success, 0 = failed
	From        string
	To          string
	GasUsed     uint64
	Logs        []ReceiptLog
}

// ReceiptLog is the minimal log subset.
type ReceiptLog struct {
	Address string   // 0x-prefixed lowercase 20-byte hex
	Topics  []string // each 0x-prefixed 32-byte hex
	Data    []byte
}

// Transaction is the minimal eth_getTransactionByHash subset.
type Transaction struct {
	Hash    string
	From    string
	To      string
	Input   []byte
	Value   string // raw hex 0x...
	Nonce   uint64
	ChainID uint64
}

// HTTPRPCClient is the production RPC client.
type HTTPRPCClient struct {
	URL        string
	HTTPClient *http.Client
	transport  *http.Transport // retained so CloseIdleConnections is callable
	label      string
}

// NewHTTPRPCClient constructs a client against the given URL.
// label is a non-secret operator-readable name. pinFn returns the
// current 64-hex-char SHA-256 SPKI pin to enforce; it is called on
// EVERY TLS handshake so SIGHUP cert-rotation changes land on the
// next connection without client rebuild. Return "" to disable
// pinning (test/no-pin paths). SPEC §4.4 / §6.5.
//
// Step 4 r2 [arch:r2-4.2] MAJOR closure: the previous version took
// a plain string and closed over the startup pin inside the TLS
// verifier, making SIGHUP cert-rotation a no-op. Using func() string
// lets TuningProvider.Snapshot() be called at handshake time so the
// live value is always enforced.
func NewHTTPRPCClient(url, label string, pinFn func() string, timeout time.Duration) *HTTPRPCClient {
	if timeout == 0 {
		timeout = 20 * time.Second
	}
	transport := &http.Transport{
		ForceAttemptHTTP2:   true,
		IdleConnTimeout:     90 * time.Second,
		TLSHandshakeTimeout: 10 * time.Second,
	}
	if pinFn != nil {
		transport.TLSClientConfig = &tls.Config{
			VerifyPeerCertificate: makeSPKIPinVerifier(pinFn),
		}
	}
	return &HTTPRPCClient{
		URL: url,
		HTTPClient: &http.Client{
			Timeout:   timeout,
			Transport: transport,
		},
		transport: transport, // retained for CloseIdleConnections
		label:     label,
	}
}

// CloseIdleConnections drains the transport's idle connection pool so
// the next RPC forces a fresh TLS handshake. Called by the SIGHUP
// handler when an SPKI pin change is accepted — ensures the new pin
// is enforced immediately rather than waiting for the 90s idle-conn
// TTL to expire.
//
// Step 4 r3 [sec:r3-1]/[arch:r3-4.2] CONVERGENT HIGH/MEDIUM closure:
// SPKI live-read at handshake time is correct, but pooled TLS
// connections bypass future handshakes. CloseIdleConnections + SIGHUP
// wiring closes that window.
func (c *HTTPRPCClient) CloseIdleConnections() {
	if c != nil && c.transport != nil {
		c.transport.CloseIdleConnections()
	}
}

// makeSPKIPinVerifier returns a TLS VerifyPeerCertificate callback
// that asserts the leaf cert's SubjectPublicKeyInfo SHA-256
// hash matches the pin returned by pinFn at handshake time.
// pinFn returning "" disables pinning for that handshake (empty
// pin = no verification). The pin must be 64 hex chars when non-empty;
// config parse-time bounds enforce this for non-empty values.
//
// Closes codex round-1 [arch:3.3] MEDIUM (original SPKI wiring).
// Step 4 r2 [arch:r2-4.2] MAJOR closure: live read via pinFn so
// SIGHUP SPKI rotations take effect on the next TLS handshake.
func makeSPKIPinVerifier(pinFn func() string) func(rawCerts [][]byte, verifiedChains [][]*x509.Certificate) error {
	return func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
		pin := pinFn()
		if pin == "" {
			// Empty pin = no pinning enforced for this handshake.
			return nil
		}
		wantLower := strings.ToLower(pin)
		if len(rawCerts) == 0 {
			return errors.New("SPKI pin: peer sent no certs")
		}
		cert, err := x509.ParseCertificate(rawCerts[0])
		if err != nil {
			return fmt.Errorf("SPKI pin: parse leaf cert: %w", err)
		}
		hash := sha256.Sum256(cert.RawSubjectPublicKeyInfo)
		got := hex.EncodeToString(hash[:])
		if got != wantLower {
			return fmt.Errorf("SPKI pin mismatch: want %s got %s", wantLower, got)
		}
		return nil
	}
}

func (c *HTTPRPCClient) Label() string { return c.label }

type rpcReq struct {
	JSONRPC string        `json:"jsonrpc"`
	ID      int           `json:"id"`
	Method  string        `json:"method"`
	Params  []interface{} `json:"params"`
}

type rpcResp struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      int             `json:"id"`
	Result  json.RawMessage `json:"result"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (e *rpcError) Error() string {
	return fmt.Sprintf("rpc error %d: %s", e.Code, e.Message)
}

// RPCError surfaces the RPC's typed error so the runner can
// distinguish nonce-too-low / already-known from transient
// network errors. errors.As() unwraps this.
type RPCError struct {
	Code    int
	Message string
}

func (e *RPCError) Error() string { return fmt.Sprintf("rpc error %d: %s", e.Code, e.Message) }

func (c *HTTPRPCClient) call(ctx context.Context, method string, params []interface{}, out interface{}) error {
	body := rpcReq{JSONRPC: "2.0", ID: 1, Method: method, Params: params}
	buf, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("rpc encode: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.URL, bytes.NewReader(buf))
	if err != nil {
		return fmt.Errorf("rpc new request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return fmt.Errorf("rpc post: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		bodyBytes, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("rpc http %d: %s", resp.StatusCode, string(bodyBytes))
	}
	var r rpcResp
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return fmt.Errorf("rpc decode: %w", err)
	}
	if r.Error != nil {
		return &RPCError{Code: r.Error.Code, Message: r.Error.Message}
	}
	if out != nil && len(r.Result) > 0 {
		if err := json.Unmarshal(r.Result, out); err != nil {
			return fmt.Errorf("rpc result decode: %w", err)
		}
	}
	return nil
}

func (c *HTTPRPCClient) ChainID(ctx context.Context) (uint64, error) {
	var hexStr string
	if err := c.call(ctx, "eth_chainId", []interface{}{}, &hexStr); err != nil {
		return 0, err
	}
	return parseHexUint(hexStr)
}

func (c *HTTPRPCClient) TransactionCount(ctx context.Context, address string) (uint64, error) {
	var hexStr string
	if err := c.call(ctx, "eth_getTransactionCount", []interface{}{strings.ToLower(address), "pending"}, &hexStr); err != nil {
		return 0, err
	}
	return parseHexUint(hexStr)
}

func (c *HTTPRPCClient) SendRawTransaction(ctx context.Context, rawSignedTx []byte) (string, error) {
	var hashStr string
	hexInput := "0x" + hex.EncodeToString(rawSignedTx)
	if err := c.call(ctx, "eth_sendRawTransaction", []interface{}{hexInput}, &hashStr); err != nil {
		return "", err
	}
	return strings.ToLower(hashStr), nil
}

type rpcReceiptRaw struct {
	TransactionHash string             `json:"transactionHash"`
	BlockHash       string             `json:"blockHash"`
	BlockNumber     string             `json:"blockNumber"`
	Status          string             `json:"status"`
	From            string             `json:"from"`
	To              string             `json:"to"`
	GasUsed         string             `json:"gasUsed"`
	Logs            []rpcReceiptLogRaw `json:"logs"`
}

type rpcReceiptLogRaw struct {
	Address string   `json:"address"`
	Topics  []string `json:"topics"`
	Data    string   `json:"data"`
}

func (c *HTTPRPCClient) TransactionReceipt(ctx context.Context, txHash string) (*Receipt, error) {
	var raw *rpcReceiptRaw
	if err := c.call(ctx, "eth_getTransactionReceipt", []interface{}{strings.ToLower(txHash)}, &raw); err != nil {
		return nil, err
	}
	if raw == nil || raw.TransactionHash == "" {
		return nil, nil
	}
	blockNumber, err := parseHexUint(raw.BlockNumber)
	if err != nil {
		return nil, fmt.Errorf("blockNumber: %w", err)
	}
	status, err := parseHexUint(raw.Status)
	if err != nil {
		return nil, fmt.Errorf("status: %w", err)
	}
	gasUsed, err := parseHexUint(raw.GasUsed)
	if err != nil {
		return nil, fmt.Errorf("gasUsed: %w", err)
	}
	logs := make([]ReceiptLog, 0, len(raw.Logs))
	for _, l := range raw.Logs {
		data, err := hex.DecodeString(strings.TrimPrefix(strings.ToLower(l.Data), "0x"))
		if err != nil {
			return nil, fmt.Errorf("log.data: %w", err)
		}
		topics := make([]string, len(l.Topics))
		for i, t := range l.Topics {
			topics[i] = strings.ToLower(t)
		}
		logs = append(logs, ReceiptLog{
			Address: strings.ToLower(l.Address),
			Topics:  topics,
			Data:    data,
		})
	}
	return &Receipt{
		TxHash:      strings.ToLower(raw.TransactionHash),
		BlockHash:   strings.ToLower(raw.BlockHash),
		BlockNumber: blockNumber,
		Status:      status,
		From:        strings.ToLower(raw.From),
		To:          strings.ToLower(raw.To),
		GasUsed:     gasUsed,
		Logs:        logs,
	}, nil
}

type rpcTxRaw struct {
	Hash    string `json:"hash"`
	From    string `json:"from"`
	To      string `json:"to"`
	Input   string `json:"input"`
	Value   string `json:"value"`
	Nonce   string `json:"nonce"`
	ChainID string `json:"chainId"`
}

func (c *HTTPRPCClient) TransactionByHash(ctx context.Context, txHash string) (*Transaction, error) {
	var raw *rpcTxRaw
	if err := c.call(ctx, "eth_getTransactionByHash", []interface{}{strings.ToLower(txHash)}, &raw); err != nil {
		return nil, err
	}
	if raw == nil || raw.Hash == "" {
		return nil, nil
	}
	input, err := hex.DecodeString(strings.TrimPrefix(strings.ToLower(raw.Input), "0x"))
	if err != nil {
		return nil, fmt.Errorf("input: %w", err)
	}
	nonce, err := parseHexUint(raw.Nonce)
	if err != nil {
		return nil, fmt.Errorf("nonce: %w", err)
	}
	chainID, err := parseHexUint(raw.ChainID)
	if err != nil {
		return nil, fmt.Errorf("chainId: %w", err)
	}
	return &Transaction{
		Hash:    strings.ToLower(raw.Hash),
		From:    strings.ToLower(raw.From),
		To:      strings.ToLower(raw.To),
		Input:   input,
		Value:   strings.ToLower(raw.Value),
		Nonce:   nonce,
		ChainID: chainID,
	}, nil
}

func (c *HTTPRPCClient) BlockNumber(ctx context.Context) (uint64, error) {
	var hexStr string
	if err := c.call(ctx, "eth_blockNumber", []interface{}{}, &hexStr); err != nil {
		return 0, err
	}
	return parseHexUint(hexStr)
}

// CallContract issues eth_call against the given contract
// address with the provided ABI-encoded calldata. Used by §7.4
// chain-balance worker for USDC balanceOf(hot_wallet). Step 4
// wiring.
func (c *HTTPRPCClient) CallContract(ctx context.Context, to string, data []byte) ([]byte, error) {
	params := []interface{}{
		map[string]string{
			"to":   to,
			"data": "0x" + hex.EncodeToString(data),
		},
		"latest",
	}
	var hexStr string
	if err := c.call(ctx, "eth_call", params, &hexStr); err != nil {
		return nil, err
	}
	hexStr = strings.TrimPrefix(strings.ToLower(hexStr), "0x")
	if hexStr == "" {
		return nil, nil
	}
	out, err := hex.DecodeString(hexStr)
	if err != nil {
		return nil, fmt.Errorf("CallContract: decode result: %w", err)
	}
	return out, nil
}

// NativeBalance returns eth_getBalance(address, "latest") in wei.
// Used by §6.2 low-native-balance alert. Step 4 wiring.
func (c *HTTPRPCClient) NativeBalance(ctx context.Context, address string) (uint64, error) {
	var hexStr string
	if err := c.call(ctx, "eth_getBalance", []interface{}{address, "latest"}, &hexStr); err != nil {
		return 0, err
	}
	return parseHexUint(hexStr)
}

// ---- Two-RPC discipline helpers ------------------------------------------

// TwoRPCs bundles the primary + secondary clients with helpers
// that satisfy SPEC §4.4 two-RPC discipline (cold-start nonce
// sync ±1 agreement, receipt agreement, etc.).
type TwoRPCs struct {
	Primary   RPCClient
	Secondary RPCClient
}

// AssertChainID asserts both RPCs advertise the expected chain id
// at startup. Used by main.go to fail-loud on a misconfigured RPC
// URL.
func (p TwoRPCs) AssertChainID(ctx context.Context, expected uint64) error {
	prim, err := p.Primary.ChainID(ctx)
	if err != nil {
		return fmt.Errorf("primary chain id: %w", err)
	}
	if prim != expected {
		return fmt.Errorf("primary chain id %d != expected %d", prim, expected)
	}
	sec, err := p.Secondary.ChainID(ctx)
	if err != nil {
		return fmt.Errorf("secondary chain id: %w", err)
	}
	if sec != expected {
		return fmt.Errorf("secondary chain id %d != expected %d", sec, expected)
	}
	return nil
}

// ColdStartNonceSync queries both RPCs' pending nonce for the
// hot wallet address, asserts ±1 agreement, and returns the
// chosen cursor value (max of the two). Per §4.6:
//   - difference > 1: HALT — emit payout_rpc_disagreement
//     reason=nonce_cold_start_mismatch
//   - any disagreement within tolerance: emit
//     payout_nonce_cold_start_within_tolerance with both values
//
// Returns: (chosen, rpcA, rpcB, withinTolerance, error). The
// withinTolerance flag signals to the caller that the WARN event
// should fire even on success.
func (p TwoRPCs) ColdStartNonceSync(ctx context.Context, address string) (uint64, uint64, uint64, bool, error) {
	a, err := p.Primary.TransactionCount(ctx, address)
	if err != nil {
		return 0, 0, 0, false, fmt.Errorf("primary getTransactionCount: %w", err)
	}
	b, err := p.Secondary.TransactionCount(ctx, address)
	if err != nil {
		return 0, 0, 0, false, fmt.Errorf("secondary getTransactionCount: %w", err)
	}
	diff := int64(a) - int64(b)
	if diff < 0 {
		diff = -diff
	}
	if diff > 1 {
		return 0, a, b, false, fmt.Errorf("nonce_cold_start_mismatch: primary=%d secondary=%d", a, b)
	}
	chosen := a
	if b > chosen {
		chosen = b
	}
	return chosen, a, b, diff > 0, nil
}

// BroadcastBoth submits the same signed envelope to both RPCs.
// Returns (acceptedAny, primaryHash, secondaryHash,
// primaryErr, secondaryErr). The runner decides what to do with
// the outcome based on SPEC §4.4 "at least one accepts → broadcast
// successful".
func (p TwoRPCs) BroadcastBoth(ctx context.Context, rawSignedTx []byte) (acceptedAny bool, primaryHash, secondaryHash string, primaryErr, secondaryErr error) {
	primaryHash, primaryErr = p.Primary.SendRawTransaction(ctx, rawSignedTx)
	secondaryHash, secondaryErr = p.Secondary.SendRawTransaction(ctx, rawSignedTx)
	acceptedAny = primaryErr == nil || secondaryErr == nil
	return acceptedAny, primaryHash, secondaryHash, primaryErr, secondaryErr
}

// IsNonceTooLow returns true if the error is the canonical
// "nonce too low" / "already known" RPC error class. Used by the
// §4.8b post-CAS broadcast race (M4 test) to distinguish a
// chain-serialized race from a real failure.
func IsNonceTooLow(err error) bool {
	if err == nil {
		return false
	}
	var rpcErr *RPCError
	if !errors.As(err, &rpcErr) {
		return false
	}
	msg := strings.ToLower(rpcErr.Message)
	return strings.Contains(msg, "nonce too low") ||
		strings.Contains(msg, "already known") ||
		strings.Contains(msg, "replacement transaction underpriced")
}

// ReceiptsAgree returns whether two receipts agree on the SPEC
// §4.3 step 7 minimum set: tx_hash, block_hash, block_number,
// status, to. Nil-handling: any nil receipt → disagreement.
func ReceiptsAgree(a, b *Receipt) bool {
	if a == nil || b == nil {
		return false
	}
	return a.TxHash == b.TxHash &&
		a.BlockHash == b.BlockHash &&
		a.BlockNumber == b.BlockNumber &&
		a.Status == b.Status &&
		a.To == b.To
}

func parseHexUint(s string) (uint64, error) {
	if s == "" {
		return 0, errors.New("empty hex string")
	}
	s = strings.TrimPrefix(strings.ToLower(s), "0x")
	if s == "" {
		return 0, nil
	}
	return strconv.ParseUint(s, 16, 64)
}
