package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-gateway/internal/auth"
	"github.com/augstar/macprovider-gateway/internal/relayblind"
)

const requestScope = "request_content_hidden_from_relays; provider_reads_request; responses_visible_to_relays"

type options struct {
	baseURL, identityPin, model, input, apiKeyEnv, walletSessionID, walletSessionKeyEnv string
	maxOutputTokens, inputTokenUpperBound                                               int64
	stream                                                                              bool
	timeout                                                                             time.Duration
}

func main() {
	var opts options
	flag.StringVar(&opts.baseURL, "base-url", "", "gateway base URL (HTTPS, or HTTP loopback for local testing)")
	flag.StringVar(&opts.identityPin, "identity-pin", "", "absolute path to operator-provisioned relay-blind identity pin")
	flag.StringVar(&opts.model, "model", "", "canonical model ID")
	flag.StringVar(&opts.input, "input", "-", "OpenAI-compatible chat request JSON file, or - for stdin")
	flag.Int64Var(&opts.maxOutputTokens, "max-output-tokens", 0, "maximum output token cap")
	flag.Int64Var(&opts.inputTokenUpperBound, "input-token-upper-bound", 0, "declared input token upper bound")
	flag.BoolVar(&opts.stream, "stream", false, "request streaming response")
	flag.StringVar(&opts.apiKeyEnv, "api-key-env", "MACPROVIDER_API_KEY", "environment variable containing the bearer credential")
	flag.StringVar(&opts.walletSessionID, "wallet-session-id", "", "optional SPEC-040 wallet session ID")
	flag.StringVar(&opts.walletSessionKeyEnv, "wallet-session-key-env", "MACPROVIDER_WALLET_SESSION_PRIVATE_KEY", "environment variable containing an optional Ed25519 wallet-session private key")
	flag.DurationVar(&opts.timeout, "timeout", 5*time.Minute, "whole-command timeout")
	flag.Parse()

	ctx, cancel := context.WithTimeout(context.Background(), opts.timeout)
	defer cancel()
	if err := run(ctx, opts, os.Stdin, os.Stdout, os.Stderr, os.Getenv); err != nil {
		fmt.Fprintf(os.Stderr, "relay-blind-client: %v\n", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, opts options, stdin io.Reader, stdout, stderr io.Writer, getenv func(string) string) error {
	base, err := validateBaseURL(opts.baseURL)
	if err != nil {
		return err
	}
	if opts.identityPin == "" || !filepath.IsAbs(opts.identityPin) {
		return errors.New("--identity-pin must name an absolute local file")
	}
	pin, err := relayblind.ReadIdentityPin(opts.identityPin)
	if err != nil {
		return fmt.Errorf("identity pin rejected: %w", err)
	}
	if err := pin.Verify(time.Now().UTC()); err != nil {
		return fmt.Errorf("identity pin rejected: %w", err)
	}
	if !contains(pin.Models, opts.model) || !contains(pin.EndpointFamilies, relayblind.EndpointChatCompletions) {
		return errors.New("identity pin does not authorize the requested model and endpoint")
	}
	if opts.maxOutputTokens <= 0 || opts.inputTokenUpperBound <= 0 {
		return errors.New("positive --max-output-tokens and --input-token-upper-bound are required")
	}
	bearer := strings.TrimSpace(getenv(opts.apiKeyEnv))
	if bearer == "" {
		return fmt.Errorf("bearer credential environment variable %s is empty", opts.apiKeyEnv)
	}
	sessionKey, err := walletSessionKey(opts, getenv)
	if err != nil {
		return err
	}

	inner, err := readInnerRequest(opts.input, stdin)
	if err != nil {
		return err
	}
	if err := validateInnerRequest(inner, opts); err != nil {
		return err
	}
	reservationRequest := relayblind.ReservationRequest{
		EndpointFamily: relayblind.EndpointChatCompletions, Model: opts.model, Stream: opts.stream,
		MaxOutputTokens: opts.maxOutputTokens, InputTokenUpperBound: opts.inputTokenUpperBound,
		EncryptedRequestBytes: int64(len(inner)),
	}
	if err := reservationRequest.Validate(); err != nil {
		return err
	}
	reservationBody, _ := json.Marshal(reservationRequest)
	reservationRequestID, err := newRequestID()
	if err != nil {
		return err
	}
	reservationRaw, err := doJSON(ctx, base, "/v1/relay-blind/route-reservations", bearer, opts.walletSessionID, sessionKey, reservationRequestID, reservationBody)
	if err != nil {
		return fmt.Errorf("route reservation failed: %w", err)
	}
	reservation, err := relayblind.ParseReservationResponse(reservationRaw)
	if err != nil {
		return fmt.Errorf("route reservation rejected: %w", err)
	}
	if err := reservation.MatchesRequest(reservationRequest); err != nil {
		return fmt.Errorf("route reservation mismatch: %w", err)
	}
	verificationTime := time.Now().UTC()
	if reservation.ExpiresAtUnix <= verificationTime.Unix() {
		return errors.New("route reservation is expired")
	}
	if err := pin.VerifyRecord(reservation.KeyRecord, verificationTime); err != nil {
		return fmt.Errorf("provider key record rejected: %w", err)
	}

	providerPublicKey, err := reservation.KeyRecord.EncryptionPublicKey()
	if err != nil {
		return err
	}
	buyerPrivateKey, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return fmt.Errorf("generate buyer ephemeral key: %w", err)
	}
	replayNonce := make([]byte, 32)
	if _, err := io.ReadFull(rand.Reader, replayNonce); err != nil {
		return fmt.Errorf("generate replay nonce: %w", err)
	}
	inferenceRequestID, err := newRequestID()
	if err != nil {
		return err
	}
	envelope, err := reservation.NewEnvelope(inferenceRequestID, time.Now().UTC(), replayNonce)
	if err != nil {
		return err
	}
	envelope, err = envelope.Encrypt(inner, providerPublicKey, buyerPrivateKey.Bytes())
	if err != nil {
		return fmt.Errorf("encrypt request: %w", err)
	}
	envelopeBody, err := json.Marshal(envelope)
	if err != nil {
		return err
	}

	request, err := newSignedRequest(ctx, base, "/v1/chat/completions", bearer, opts.walletSessionID, sessionKey, inferenceRequestID, envelopeBody)
	if err != nil {
		return err
	}
	response, err := httpClient().Do(request)
	if err != nil {
		return fmt.Errorf("encrypted request failed: %w", err)
	}
	defer response.Body.Close()
	if err := copyVerifiedResponse(response, opts.stream, stdout); err != nil {
		return err
	}
	fmt.Fprintf(stderr, "relay-blind satisfied; identity fingerprint=%s\nscope: %s\nverified_model_settlement: unavailable_for_relay_blind_request\nusage_settlement: standard_usage_settlement_and_clear_cap_enforcement_still_apply\n", pin.Fingerprint, requestScope)
	return nil
}

// Responses are relay-visible. This checks the gateway's reported outcome and
// protocol completion; it does not turn that report into provider attestation.
func copyVerifiedResponse(response *http.Response, stream bool, stdout io.Writer) error {
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("encrypted request returned HTTP %d", response.StatusCode)
	}
	if response.Header.Get("X-MacProvider-Requested-Privacy-Mode") != "relay_blind_required" || response.Header.Get("X-MacProvider-Effective-Privacy-Outcome") != "relay_blind_satisfied" {
		return errors.New("response did not report satisfied request encryption; do not resubmit")
	}
	check := func(raw []byte) (bool, error) {
		var root map[string]json.RawMessage
		if json.Unmarshal(raw, &root) != nil || root == nil {
			return false, errors.New("invalid response metadata; do not resubmit")
		}
		if e, ok := root["error"]; ok && !bytes.Equal(e, []byte("null")) {
			return false, errors.New("provider response failed; do not resubmit")
		}
		var usage struct {
			Macprovider struct {
				Requested  string `json:"requested_privacy_mode"`
				Effective  string `json:"effective_privacy_outcome"`
				Scope      string `json:"scope"`
				Settlement struct {
					Verified string `json:"verified_model_settlement"`
					Usage    string `json:"usage_settlement"`
				} `json:"settlement"`
			} `json:"macprovider"`
		}
		if json.Unmarshal(root["usage"], &usage) != nil {
			return false, nil
		}
		return usage.Macprovider.Requested == "relay_blind_required" && usage.Macprovider.Effective == "relay_blind_satisfied" && usage.Macprovider.Scope == requestScope && usage.Macprovider.Settlement.Verified == "unavailable_for_relay_blind_request" && usage.Macprovider.Settlement.Usage == "standard_usage_settlement_and_clear_cap_enforcement_still_apply", nil
	}
	if !stream {
		raw, err := io.ReadAll(io.LimitReader(response.Body, 16<<20+1))
		if err != nil {
			return errors.New("incomplete response; do not resubmit")
		}
		if len(raw) > 16<<20 {
			return errors.New("response exceeds local verification limit; do not resubmit")
		}
		valid, err := check(raw)
		if err != nil {
			return err
		}
		if !valid {
			return errors.New("missing successful privacy usage metadata; do not resubmit")
		}
		_, err = stdout.Write(raw)
		return err
	}
	scanner := bufio.NewScanner(response.Body)
	scanner.Buffer(make([]byte, 4096), 1<<20)
	validated, done := false, false
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "data:") {
			data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
			if data == "[DONE]" {
				if !validated {
					return errors.New("stream ended without privacy usage metadata; do not resubmit")
				}
				done = true
			} else if data != "" {
				if done {
					return errors.New("data after stream completion; do not resubmit")
				}
				valid, err := check([]byte(data))
				if err != nil {
					return err
				}
				validated = validated || valid
			}
		}
		if _, err := fmt.Fprintln(stdout, line); err != nil {
			return err
		}
	}
	if scanner.Err() != nil || !done {
		return errors.New("incomplete stream; do not resubmit")
	}
	return nil
}

func doJSON(ctx context.Context, base *url.URL, path, bearer, sessionID string, sessionKey ed25519.PrivateKey, requestID string, body []byte) ([]byte, error) {
	request, err := newSignedRequest(ctx, base, path, bearer, sessionID, sessionKey, requestID, body)
	if err != nil {
		return nil, err
	}
	response, err := httpClient().Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, relayblind.MaxEncryptedRequestBytes+1))
	if err != nil {
		return nil, err
	}
	if len(raw) > relayblind.MaxEncryptedRequestBytes {
		return nil, errors.New("response body too large")
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("HTTP %d", response.StatusCode)
	}
	return raw, nil
}

func newSignedRequest(ctx context.Context, base *url.URL, path, bearer, sessionID string, sessionKey ed25519.PrivateKey, requestID string, body []byte) (*http.Request, error) {
	target := *base
	target.Path = strings.TrimRight(target.Path, "/") + path
	target.RawPath = ""
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, target.String(), bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	request.Header.Set("Authorization", "Bearer "+bearer)
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json")
	request.Header.Set("X-Request-ID", requestID)
	if len(sessionKey) == 0 {
		return request, nil
	}
	timestamp := time.Now().UTC().Unix()
	request.Header.Set("X-MacProvider-Session-Timestamp", strconv.FormatInt(timestamp, 10))
	signatureObject, err := auth.NewWalletRequestSignatureObject(sessionID, http.MethodPost, path, requestID, body, request.Header, timestamp)
	if err != nil {
		return nil, err
	}
	canonical, err := auth.CanonicalWalletRequestBytes(signatureObject)
	if err != nil {
		return nil, err
	}
	request.Header.Set("X-MacProvider-Session-Signature", base64.RawURLEncoding.EncodeToString(ed25519.Sign(sessionKey, canonical)))
	return request, nil
}

func walletSessionKey(opts options, getenv func(string) string) (ed25519.PrivateKey, error) {
	encoded := strings.TrimSpace(getenv(opts.walletSessionKeyEnv))
	if opts.walletSessionID == "" {
		if encoded != "" {
			return nil, errors.New("--wallet-session-id is required when wallet-session key environment variable is set")
		}
		return nil, nil
	}
	if encoded == "" {
		return nil, fmt.Errorf("wallet-session key environment variable %s is empty", opts.walletSessionKeyEnv)
	}
	raw, err := base64.RawURLEncoding.Strict().DecodeString(encoded)
	if err != nil || base64.RawURLEncoding.EncodeToString(raw) != encoded {
		return nil, errors.New("wallet-session private key is not canonical base64url")
	}
	switch len(raw) {
	case ed25519.SeedSize:
		return ed25519.NewKeyFromSeed(raw), nil
	case ed25519.PrivateKeySize:
		return ed25519.PrivateKey(raw), nil
	default:
		return nil, errors.New("wallet-session private key must be a 32-byte Ed25519 seed or 64-byte private key")
	}
}

func validateBaseURL(raw string) (*url.URL, error) {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return nil, errors.New("--base-url must be an absolute gateway URL without user info, query, or fragment")
	}
	if parsed.Scheme != "https" {
		host := parsed.Hostname()
		ip := net.ParseIP(host)
		if parsed.Scheme != "http" || (host != "localhost" && (ip == nil || !ip.IsLoopback())) {
			return nil, errors.New("--base-url requires HTTPS except for loopback testing")
		}
	}
	return parsed, nil
}

func readInnerRequest(path string, stdin io.Reader) ([]byte, error) {
	reader := stdin
	var file *os.File
	var err error
	if path != "-" {
		file, err = os.Open(path)
		if err != nil {
			return nil, fmt.Errorf("open input: %w", err)
		}
		defer file.Close()
		reader = file
	}
	raw, err := io.ReadAll(io.LimitReader(reader, relayblind.MaxEncryptedRequestBytes+1))
	if err != nil {
		return nil, err
	}
	if len(raw) == 0 || len(raw) > relayblind.MaxEncryptedRequestBytes {
		return nil, errors.New("input must contain 1..1048576 bytes")
	}
	return raw, nil
}

func validateInnerRequest(raw []byte, opts options) error {
	if err := rejectDuplicateKeys(raw); err != nil {
		return fmt.Errorf("inner chat request rejected: %w", err)
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var object map[string]json.RawMessage
	if err := decoder.Decode(&object); err != nil {
		return fmt.Errorf("inner chat request rejected: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return errors.New("inner chat request has trailing JSON")
	}
	var model string
	if err := json.Unmarshal(object["model"], &model); err != nil || model != opts.model {
		return errors.New("inner chat request model does not match reservation")
	}
	if messages, ok := object["messages"]; !ok || len(messages) == 0 || bytes.Equal(bytes.TrimSpace(messages), []byte("null")) {
		return errors.New("inner chat request messages are required")
	}
	stream := false
	if rawStream, ok := object["stream"]; ok {
		if err := json.Unmarshal(rawStream, &stream); err != nil {
			return errors.New("inner chat request stream must be boolean")
		}
	}
	if stream != opts.stream {
		return errors.New("inner chat request stream does not match reservation")
	}
	var maxTokens int64
	if err := json.Unmarshal(object["max_tokens"], &maxTokens); err != nil || maxTokens != opts.maxOutputTokens {
		return errors.New("inner chat request max_tokens does not match reservation")
	}
	return nil
}

func rejectDuplicateKeys(raw []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := scanJSON(decoder); err != nil {
		return err
	}
	if token, err := decoder.Token(); err != io.EOF || token != nil {
		return errors.New("trailing JSON")
	}
	return nil
}

func scanJSON(decoder *json.Decoder) error {
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	delim, ok := token.(json.Delim)
	if !ok {
		return nil
	}
	switch delim {
	case '{':
		seen := make(map[string]struct{})
		for decoder.More() {
			nameToken, err := decoder.Token()
			if err != nil {
				return err
			}
			name, ok := nameToken.(string)
			if !ok {
				return errors.New("invalid object key")
			}
			if _, duplicate := seen[name]; duplicate {
				return fmt.Errorf("duplicate field %q", name)
			}
			seen[name] = struct{}{}
			if err := scanJSON(decoder); err != nil {
				return err
			}
		}
		end, err := decoder.Token()
		if err != nil || end != json.Delim('}') {
			return errors.New("invalid object")
		}
	case '[':
		for decoder.More() {
			if err := scanJSON(decoder); err != nil {
				return err
			}
		}
		end, err := decoder.Token()
		if err != nil || end != json.Delim(']') {
			return errors.New("invalid array")
		}
	default:
		return errors.New("invalid JSON delimiter")
	}
	return nil
}

func newRequestID() (string, error) {
	raw := make([]byte, 16)
	if _, err := io.ReadFull(rand.Reader, raw); err != nil {
		return "", err
	}
	raw[6] = (raw[6] & 0x0f) | 0x40
	raw[8] = (raw[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", raw[0:4], raw[4:6], raw[6:8], raw[8:10], raw[10:16]), nil
}

func contains(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func httpClient() *http.Client {
	return &http.Client{
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		Transport: &http.Transport{
			Proxy:                 http.ProxyFromEnvironment,
			DialContext:           (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
			TLSHandshakeTimeout:   10 * time.Second,
			ResponseHeaderTimeout: 2 * time.Minute,
		},
	}
}
