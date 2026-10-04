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

const (
	privacyClassHeader              = "X-MacProvider-Privacy-Class"
	privacyAssuranceHeader          = "X-MacProvider-Privacy-Assurance"
	privacyResponseEncryptionHeader = "X-MacProvider-Response-Encryption"
	privacyAssuranceRequiredHeader  = "X-MacProvider-Privacy-Assurance-Required"
	// maxPrivacyResponseBytes bounds the buyer-side buffer. Plaintext is
	// held until the final frame, usage, and headers all verify.
	maxPrivacyResponseBytes = 16 << 20
	maxPrivacyStreamLine    = (relayblind.MaxEncryptedRequestBytes+16)*2 + 4096
)

// SPEC-049-R020 disclosure. These strings are fixed; the client prints them
// and rejects a response whose usage.macprovider.privacy object differs.
const privacyScope = "request_and_response_content_hidden_from_relays; provider_runtime_reads_plaintext; ordinary_operator_access_paths_constrained_on_approved_signed_runtime; posture_self_attested_device_bound_not_code_bound"

// SPEC-049-R020 strings for code_bound_attested (v0.2).
const privacyCodeBoundScope = "request_and_response_content_hidden_from_relays; provider_runtime_reads_plaintext; ordinary_operator_access_paths_constrained_on_approved_signed_runtime; posture_signed_by_apple_attested_malibu_app_key; runtime_code_identity_checked_by_attested_app_not_by_apple; sip_and_full_security_attested_at_enrollment; label_verified_by_coordinator_not_by_buyer"

var privacyCodeBoundProtects = []string{
	"request_content_from_gateway_and_coordinator",
	"response_content_from_gateway_and_coordinator",
	"debugger_attach_to_approved_signed_runtime",
	"core_dumps_of_approved_signed_runtime",
	"prompt_and_completion_in_provider_logs_traces_receipts_and_telemetry",
	"prompt_and_completion_in_provider_disk_and_conversation_caches",
	"plaintext_proxy_or_subprocess_runtime_hop",
	"dev_debug_unsigned_or_unapproved_builds_refused_by_routing",
	"sip_disabled_hosts_refused_by_routing",
	"modified_or_resigned_runtime_binary_refused_by_attested_app_check",
	"modified_or_resigned_malibu_app_cannot_sign_posture",
	"posture_replay_refused_by_attested_counter",
}

var privacyCodeBoundDoesNotProtect = []string{
	"provider_runtime_reads_plaintext_to_infer",
	"request_metadata_visible_to_relays",
	"confidential_compute_or_hardware_enclave_execution",
	"end_to_end_encryption_excluding_the_provider",
	"pool_scoped_requests",
	"kernel_or_firmware_compromise_with_sip_on",
	"compromised_team_signing_key",
}

var privacyCodeBoundResidualRisks = []string{
	"kernel_or_firmware_compromise_with_sip_on",
	"physical_or_hardware_attack",
	"gpu_and_unified_memory_residue",
	"encrypted_swap_and_hibernation_images",
	"compromise_of_the_live_runtime_process",
	"malicious_signed_release_or_supply_chain",
	"compromised_team_signing_key",
	"apple_is_root_of_trust_for_app_attest",
	"sip_and_full_security_attested_at_enrollment_only",
	"label_verified_by_coordinator_not_by_buyer",
	"crash_report_register_and_stack_residue",
	"immutable_prompt_strings_not_zeroized",
	"relays_observe_sizes_timing_and_token_counts",
}

// privacyStrings is one SPEC-049-R020 string set.
type privacyStrings struct {
	scope                                   string
	protects, doesNotProtect, residualRisks []string
}

// privacyStringsFor returns the string set for a verified label.
func privacyStringsFor(assurance string) privacyStrings {
	if assurance == relayblind.PrivacyAssuranceCodeBound {
		return privacyStrings{privacyCodeBoundScope, privacyCodeBoundProtects, privacyCodeBoundDoesNotProtect, privacyCodeBoundResidualRisks}
	}
	return privacyStrings{privacyScope, privacyProtects, privacyDoesNotProtect, privacyResidualRisks}
}

var privacyProtects = []string{
	"request_content_from_gateway_and_coordinator",
	"response_content_from_gateway_and_coordinator",
	"debugger_attach_to_approved_signed_runtime",
	"core_dumps_of_approved_signed_runtime",
	"prompt_and_completion_in_provider_logs_traces_receipts_and_telemetry",
	"prompt_and_completion_in_provider_disk_and_conversation_caches",
	"plaintext_proxy_or_subprocess_runtime_hop",
	"dev_debug_unsigned_or_unapproved_builds_refused_by_routing",
	"sip_disabled_hosts_refused_by_routing",
}

var privacyDoesNotProtect = []string{
	"provider_runtime_reads_plaintext_to_infer",
	"operator_running_a_modified_runtime_binary",
	"request_metadata_visible_to_relays",
	"confidential_compute_or_hardware_enclave_execution",
	"end_to_end_encryption_excluding_the_provider",
	"pool_scoped_requests",
}

var privacyResidualRisks = []string{
	"modified_binary_can_forge_posture_se_key_device_bound_not_code_bound",
	"root_sip_bypass_kernel_or_firmware_compromise",
	"physical_or_hardware_attack",
	"gpu_and_unified_memory_residue",
	"encrypted_swap_and_hibernation_images",
	"compromise_of_the_live_runtime_process",
	"malicious_signed_release_or_supply_chain",
	"crash_report_register_and_stack_residue",
	"secure_boot_level_not_evaluated",
	"immutable_prompt_strings_not_zeroized",
	"relays_observe_sizes_timing_and_token_counts",
}

type options struct {
	baseURL, identityPin, model, input, apiKeyEnv, walletSessionID, walletSessionKeyEnv string
	maxOutputTokens, inputTokenUpperBound                                               int64
	stream, privacyClass                                                                bool
	timeout                                                                             time.Duration
	// privacyAssuranceRequired is empty or code_bound_attested.
	privacyAssuranceRequired string
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
	flag.BoolVar(&opts.privacyClass, "privacy-class", false, "request operator_constrained_beta_v1 and decrypt the provider response")
	flag.StringVar(&opts.privacyAssuranceRequired, "privacy-assurance-required", "", "with --privacy-class, require this assurance label (only code_bound_attested)")
	requireCodeBound := flag.Bool("require-code-bound", false, "shorthand for --privacy-assurance-required code_bound_attested")
	flag.StringVar(&opts.apiKeyEnv, "api-key-env", "MACPROVIDER_API_KEY", "environment variable containing the bearer credential")
	flag.StringVar(&opts.walletSessionID, "wallet-session-id", "", "optional SPEC-040 wallet session ID")
	flag.StringVar(&opts.walletSessionKeyEnv, "wallet-session-key-env", "MACPROVIDER_WALLET_SESSION_PRIVATE_KEY", "environment variable containing an optional Ed25519 wallet-session private key")
	flag.DurationVar(&opts.timeout, "timeout", 5*time.Minute, "whole-command timeout")
	flag.Parse()
	if *requireCodeBound {
		if opts.privacyAssuranceRequired != "" && opts.privacyAssuranceRequired != relayblind.PrivacyAssuranceCodeBound {
			fmt.Fprintln(os.Stderr, "relay-blind-client: --require-code-bound conflicts with --privacy-assurance-required")
			os.Exit(1)
		}
		opts.privacyAssuranceRequired = relayblind.PrivacyAssuranceCodeBound
	}

	ctx, cancel := context.WithTimeout(context.Background(), opts.timeout)
	defer cancel()
	if err := run(ctx, opts, os.Stdin, os.Stdout, os.Stderr, os.Getenv); err != nil {
		fmt.Fprintf(os.Stderr, "relay-blind-client: %v\n", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, opts options, stdin io.Reader, stdout, stderr io.Writer, getenv func(string) string) error {
	if opts.privacyAssuranceRequired != "" && (!opts.privacyClass || opts.privacyAssuranceRequired != relayblind.PrivacyAssuranceCodeBound) {
		return errors.New("--privacy-assurance-required accepts only code_bound_attested and requires --privacy-class")
	}
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
	reservationRaw, err := doJSON(ctx, base, "/v1/relay-blind/route-reservations", bearer, opts.walletSessionID, sessionKey, reservationRequestID, reservationBody, opts.privacyClass, opts.privacyAssuranceRequired)
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
	if opts.privacyClass {
		if err := requirePrivacyReservation(reservation, pin, opts.privacyAssuranceRequired); err != nil {
			return err
		}
	} else if reservation.Version != relayblind.ReservationVersion {
		return errors.New("route reservation version rejected")
	}

	providerPublicKey, err := reservation.KeyRecord.EncryptionPublicKey()
	if err != nil {
		return err
	}
	buyerPrivateKey, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return fmt.Errorf("generate buyer ephemeral key: %w", err)
	}
	buyerKey := buyerPrivateKey.Bytes()
	buyerPrivateKey = nil
	defer zeroBytes(buyerKey)
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
	envelope, err = envelope.Encrypt(inner, providerPublicKey, buyerKey)
	if err != nil {
		return fmt.Errorf("encrypt request: %w", err)
	}
	envelopeBody, err := json.Marshal(envelope)
	if err != nil {
		return err
	}
	var responseKeys relayblind.ResponseKeys
	var envelopeDigest string
	if opts.privacyClass {
		responseKeys, err = envelope.DeriveBuyerResponseKeys(buyerKey, providerPublicKey)
		if err != nil {
			return fmt.Errorf("derive response keys: %w", err)
		}
		defer zeroResponseKeys(&responseKeys)
		envelopeDigest, err = relayblind.DigestEnvelopeBytes(envelopeBody)
		if err != nil {
			return fmt.Errorf("envelope digest: %w", err)
		}
	}
	zeroBytes(buyerKey)

	request, err := newSignedRequest(ctx, base, "/v1/chat/completions", bearer, opts.walletSessionID, sessionKey, inferenceRequestID, envelopeBody, opts.privacyClass, "")
	if err != nil {
		return err
	}
	response, err := httpClient().Do(request)
	if err != nil {
		if opts.privacyClass {
			return privacyDoNotResubmit("encrypted request failed")
		}
		return fmt.Errorf("encrypted request failed: %w", err)
	}
	defer response.Body.Close()
	if opts.privacyClass {
		if err := copyPrivacyResponse(response, envelope.Stream, responseKeys, envelopeDigest, envelope.KID, envelope.RequestID, reservation.InputTokenUpperBound, reservation.MaxOutputTokens, reservation.PrivacyAssurance, stdout); err != nil {
			return err
		}
		zeroResponseKeys(&responseKeys)
		writePrivacySuccess(stderr, pin.Fingerprint, reservation.PrivacyAssurance)
		return nil
	}
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

func requirePrivacyReservation(reservation relayblind.ReservationResponse, pin relayblind.IdentityPin, required string) error {
	if reservation.Version != relayblind.PrivacyReservationVersion {
		return errors.New("privacy class reservation rejected")
	}
	attestation := reservation.PrivacyKeyAttestation
	if reservation.PrivacyClass != relayblind.PrivacyClassV1 || !relayblind.ValidPrivacyAssurance(reservation.PrivacyAssurance) || attestation == nil || attestation.Assurance != reservation.PrivacyAssurance {
		return errors.New("privacy assurance rejected")
	}
	if required != "" && reservation.PrivacyAssurance != required {
		return errors.New("privacy assurance requirement not met")
	}
	if err := attestation.Verify(pin, reservation.PrivacyKeyAttestationSignature, reservation.KeyRecord); err != nil {
		return fmt.Errorf("privacy key attestation rejected: %w", err)
	}
	return nil
}

func copyPrivacyResponse(response *http.Response, stream bool, keys relayblind.ResponseKeys, envelopeDigest, kid, requestID string, inputCap, outputCap int64, assurance string, stdout io.Writer) error {
	defer zeroResponseKeys(&keys)
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return privacyDoNotResubmit(fmt.Sprintf("encrypted request returned HTTP %d", response.StatusCode))
	}
	if err := requirePrivacyResponseHeaders(response.Header, assurance); err != nil {
		return err
	}
	if stream {
		return copyPrivacyStream(response.Body, keys, envelopeDigest, kid, requestID, inputCap, outputCap, assurance, stdout)
	}
	return copyPrivacyNonStream(response.Body, keys, envelopeDigest, kid, requestID, inputCap, outputCap, assurance, stdout)
}

func requirePrivacyResponseHeaders(h http.Header, assurance string) error {
	checks := []struct {
		name string
		want string
	}{
		{"X-MacProvider-Requested-Privacy-Mode", "relay_blind_required"},
		{"X-MacProvider-Effective-Privacy-Outcome", "relay_blind_satisfied"},
		{privacyClassHeader, relayblind.PrivacyClassV1},
		{privacyAssuranceHeader, assurance},
		{privacyResponseEncryptionHeader, relayblind.PrivacyResponseEncryption},
	}
	for _, check := range checks {
		values := h.Values(check.name)
		if len(values) != 1 || values[0] != check.want {
			return privacyDoNotResubmit("privacy response headers rejected")
		}
	}
	return nil
}

func copyPrivacyNonStream(body io.Reader, keys relayblind.ResponseKeys, envelopeDigest, kid, requestID string, inputCap, outputCap int64, assurance string, stdout io.Writer) error {
	raw, err := io.ReadAll(io.LimitReader(body, maxPrivacyResponseBytes+1))
	if err != nil {
		return privacyDoNotResubmit("incomplete privacy response")
	}
	if len(raw) > maxPrivacyResponseBytes {
		return privacyDoNotResubmit("response exceeds local verification limit")
	}
	frames, usage, err := parsePrivacyResponse(raw)
	if err != nil {
		return privacyDoNotResubmit("invalid privacy response")
	}
	plaintexts, finalRaw, err := openPrivacyFrames(keys, envelopeDigest, kid, requestID, false, frames)
	if err != nil {
		return err
	}
	return commitPrivacyPlaintext(plaintexts, finalRaw, usage, inputCap, outputCap, assurance, stdout)
}

func parsePrivacyResponse(raw []byte) ([]relayblind.PrivacyFrame, json.RawMessage, error) {
	if err := rejectDuplicateKeys(raw); err != nil {
		return nil, nil, err
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var body struct {
		Object  string            `json:"object"`
		Version string            `json:"version"`
		Frames  []json.RawMessage `json:"frames"`
		Usage   json.RawMessage   `json:"usage"`
	}
	if err := dec.Decode(&body); err != nil {
		return nil, nil, err
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		return nil, nil, errors.New("trailing JSON")
	}
	if body.Object != relayblind.PrivacyResponseObject || body.Version != relayblind.PrivacyResponseVersion || len(body.Usage) == 0 || bytes.Equal(body.Usage, []byte("null")) {
		return nil, nil, errors.New("privacy response")
	}
	frames := make([]relayblind.PrivacyFrame, 0, len(body.Frames))
	for _, rawFrame := range body.Frames {
		frame, err := relayblind.ParsePrivacyFrame(rawFrame)
		if err != nil {
			return nil, nil, err
		}
		frames = append(frames, frame)
	}
	return frames, body.Usage, nil
}

func copyPrivacyStream(body io.Reader, keys relayblind.ResponseKeys, envelopeDigest, kid, requestID string, inputCap, outputCap int64, assurance string, stdout io.Writer) error {
	scanner := bufio.NewScanner(body)
	scanner.Buffer(make([]byte, 4096), maxPrivacyStreamLine)
	var frames []relayblind.PrivacyFrame
	var usage json.RawMessage
	wireBytes := 0
	sawFinal := false
	done := false
	for scanner.Scan() {
		line := strings.TrimRight(scanner.Text(), "\r")
		wireBytes += len(line) + 1
		if wireBytes > maxPrivacyResponseBytes {
			return privacyDoNotResubmit("response exceeds local verification limit")
		}
		if line == "" {
			continue
		}
		if !strings.HasPrefix(line, "data:") {
			return privacyDoNotResubmit("invalid privacy response")
		}
		data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if done {
			return privacyDoNotResubmit("data after stream completion")
		}
		if data == "[DONE]" {
			if !sawFinal {
				return privacyDoNotResubmit("privacy response missing final frame")
			}
			if len(usage) == 0 {
				return privacyDoNotResubmit("privacy usage mismatch")
			}
			done = true
			continue
		}
		if data == "" {
			return privacyDoNotResubmit("invalid privacy response")
		}
		if privacyFramePayload(data) {
			if sawFinal || len(usage) != 0 {
				return privacyDoNotResubmit("privacy frame after final")
			}
			frame, err := relayblind.ParsePrivacyFrame([]byte(data))
			if err != nil {
				return privacyDoNotResubmit("invalid privacy response")
			}
			if frame.Seq != uint64(len(frames)) {
				return privacyDoNotResubmit("privacy frame sequence rejected")
			}
			frames = append(frames, frame)
			sawFinal = frame.Final
			continue
		}
		if !sawFinal {
			return privacyDoNotResubmit("privacy response missing final frame")
		}
		if len(usage) != 0 {
			return privacyDoNotResubmit("invalid privacy response")
		}
		eventUsage, err := streamEventUsage([]byte(data))
		if err != nil {
			return privacyDoNotResubmit("invalid privacy response")
		}
		usage = eventUsage
	}
	if err := scanner.Err(); err != nil || !done {
		if !sawFinal {
			return privacyDoNotResubmit("privacy response missing final frame")
		}
		return privacyDoNotResubmit("incomplete privacy response")
	}
	plaintexts, finalRaw, err := openPrivacyFrames(keys, envelopeDigest, kid, requestID, true, frames)
	if err != nil {
		return err
	}
	return commitPrivacyPlaintext(plaintexts, finalRaw, usage, inputCap, outputCap, assurance, stdout)
}

func privacyFramePayload(data string) bool {
	var probe struct {
		Object string `json:"object"`
	}
	if json.Unmarshal([]byte(data), &probe) != nil {
		return false
	}
	return probe.Object == relayblind.PrivacyFrameObject
}

func streamEventUsage(raw []byte) (json.RawMessage, error) {
	if err := rejectDuplicateKeys(raw); err != nil {
		return nil, err
	}
	var event map[string]json.RawMessage
	if err := json.Unmarshal(raw, &event); err != nil || event == nil {
		return nil, errors.New("usage")
	}
	usage := event["usage"]
	if len(usage) == 0 || bytes.Equal(usage, []byte("null")) {
		return nil, errors.New("usage")
	}
	return usage, nil
}

func openPrivacyFrames(keys relayblind.ResponseKeys, envelopeDigest, kid, requestID string, stream bool, frames []relayblind.PrivacyFrame) ([][]byte, []byte, error) {
	if err := relayblind.ValidatePrivacyFrameSequence(frames); err != nil {
		return nil, nil, privacyDoNotResubmit("privacy frame sequence rejected")
	}
	var plaintexts [][]byte
	var finalRaw []byte
	total := 0
	for _, frame := range frames {
		plaintext, err := relayblind.OpenFrame(keys, envelopeDigest, kid, requestID, stream, frame)
		if err != nil {
			zeroSlices(plaintexts)
			zeroBytes(finalRaw)
			zeroBytes(plaintext)
			return nil, nil, privacyDoNotResubmit("privacy frame authentication failed")
		}
		if len(plaintext) > maxPrivacyResponseBytes || total > maxPrivacyResponseBytes-len(plaintext) {
			zeroSlices(plaintexts)
			zeroBytes(finalRaw)
			zeroBytes(plaintext)
			return nil, nil, privacyDoNotResubmit("response exceeds local verification limit")
		}
		total += len(plaintext)
		if frame.Final {
			finalRaw = plaintext
			continue
		}
		plaintexts = append(plaintexts, plaintext)
	}
	if finalRaw == nil {
		zeroSlices(plaintexts)
		return nil, nil, privacyDoNotResubmit("privacy response missing final frame")
	}
	return plaintexts, finalRaw, nil
}

func commitPrivacyPlaintext(plaintexts [][]byte, finalRaw []byte, usage json.RawMessage, inputCap, outputCap int64, assurance string, stdout io.Writer) error {
	final, err := relayblind.ParsePrivacyFinal(finalRaw)
	zeroBytes(finalRaw)
	if err != nil {
		zeroSlices(plaintexts)
		return privacyDoNotResubmit("privacy final frame rejected")
	}
	if final.Status != relayblind.PrivacyFinalStatusComplete {
		zeroSlices(plaintexts)
		return privacyDoNotResubmit("privacy response was not complete")
	}
	if err := privacyUsageAgrees(usage, final, inputCap, outputCap, assurance); err != nil {
		zeroSlices(plaintexts)
		return err
	}
	var out bytes.Buffer
	for _, part := range plaintexts {
		_, _ = out.Write(part)
		zeroBytes(part)
	}
	if _, err := stdout.Write(out.Bytes()); err != nil {
		zeroBytes(out.Bytes())
		return privacyDoNotResubmit("privacy response write failed")
	}
	zeroBytes(out.Bytes())
	return nil
}

func privacyUsageAgrees(raw json.RawMessage, final relayblind.PrivacyFinal, inputCap, outputCap int64, assurance string) error {
	if len(raw) == 0 || bytes.Equal(raw, []byte("null")) || rejectDuplicateKeys(raw) != nil {
		return privacyDoNotResubmit("privacy usage mismatch")
	}
	var usage struct {
		PromptTokens     *int64          `json:"prompt_tokens"`
		CompletionTokens *int64          `json:"completion_tokens"`
		TotalTokens      *int64          `json:"total_tokens"`
		Macprovider      json.RawMessage `json:"macprovider"`
	}
	if json.Unmarshal(raw, &usage) != nil || usage.PromptTokens == nil || usage.CompletionTokens == nil || usage.TotalTokens == nil {
		return privacyDoNotResubmit("privacy usage mismatch")
	}
	prompt := final.PromptTokens
	completion := final.CompletionTokens
	if inputCap <= 0 || outputCap <= 0 || prompt < 0 || completion < 0 {
		return privacyDoNotResubmit("privacy usage mismatch")
	}
	if prompt > inputCap {
		prompt = inputCap
	}
	if completion > outputCap {
		completion = outputCap
	}
	if *usage.PromptTokens != prompt || *usage.CompletionTokens != completion || *usage.TotalTokens != prompt+completion {
		return privacyDoNotResubmit("privacy usage mismatch")
	}
	return privacyMetadataAgrees(usage.Macprovider, assurance)
}

func privacyMetadataAgrees(raw json.RawMessage, assurance string) error {
	if len(raw) == 0 || bytes.Equal(raw, []byte("null")) || rejectDuplicateKeys(raw) != nil {
		return privacyDoNotResubmit("missing successful privacy usage metadata")
	}
	var meta struct {
		Requested  string `json:"requested_privacy_mode"`
		Effective  string `json:"effective_privacy_outcome"`
		Scope      string `json:"scope"`
		Settlement struct {
			Verified string `json:"verified_model_settlement"`
			Usage    string `json:"usage_settlement"`
		} `json:"settlement"`
		Privacy json.RawMessage `json:"privacy"`
	}
	if json.Unmarshal(raw, &meta) != nil || meta.Requested != "relay_blind_required" || meta.Effective != "relay_blind_satisfied" || meta.Scope != requestScope || meta.Settlement.Verified != "unavailable_for_relay_blind_request" || meta.Settlement.Usage != "standard_usage_settlement_and_clear_cap_enforcement_still_apply" {
		return privacyDoNotResubmit("missing successful privacy usage metadata")
	}
	return privacyDisclosureAgrees(meta.Privacy, assurance)
}

type privacyDisclosure struct {
	Class                 string   `json:"class"`
	Assurance             string   `json:"assurance"`
	Scope                 string   `json:"scope"`
	Protects              []string `json:"protects"`
	DoesNotProtect        []string `json:"does_not_protect"`
	ResidualRisks         []string `json:"residual_risks"`
	PostureVerifiedAtUnix int64    `json:"posture_verified_at_unix"`
}

func privacyDisclosureAgrees(raw json.RawMessage, assurance string) error {
	if len(raw) == 0 || bytes.Equal(raw, []byte("null")) || rejectDuplicateKeys(raw) != nil {
		return privacyDoNotResubmit("privacy class disclosure rejected")
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var got privacyDisclosure
	if err := dec.Decode(&got); err != nil {
		return privacyDoNotResubmit("privacy class disclosure rejected")
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		return privacyDoNotResubmit("privacy class disclosure rejected")
	}
	want := privacyStringsFor(assurance)
	if !relayblind.ValidPrivacyAssurance(assurance) || got.Class != relayblind.PrivacyClassV1 || got.Assurance != assurance || got.Scope != want.scope || got.PostureVerifiedAtUnix <= 0 || !stringSlicesEqual(got.Protects, want.protects) || !stringSlicesEqual(got.DoesNotProtect, want.doesNotProtect) || !stringSlicesEqual(got.ResidualRisks, want.residualRisks) {
		return privacyDoNotResubmit("privacy class disclosure rejected")
	}
	return nil
}

func writePrivacySuccess(stderr io.Writer, fingerprint, assurance string) {
	set := privacyStringsFor(assurance)
	fmt.Fprintf(stderr, "privacy class satisfied; identity fingerprint=%s\nprivacy_class: %s\nassurance: %s\nscope: %s\n", fingerprint, relayblind.PrivacyClassV1, assurance, set.scope)
	for _, risk := range set.residualRisks {
		fmt.Fprintf(stderr, "residual_risks: %s\n", risk)
	}
	fmt.Fprintf(stderr, "verified_model_settlement: unavailable_for_relay_blind_request\nusage_settlement: standard_usage_settlement_and_clear_cap_enforcement_still_apply\n")
}

func privacyDoNotResubmit(reason string) error {
	return errors.New(reason + "; do not resubmit")
}

func zeroBytes(b []byte) {
	for i := range b {
		b[i] = 0
	}
}

func zeroSlices(parts [][]byte) {
	for _, part := range parts {
		zeroBytes(part)
	}
}

func zeroResponseKeys(keys *relayblind.ResponseKeys) {
	if keys == nil {
		return
	}
	zeroBytes(keys.Key[:])
	zeroBytes(keys.NoncePrefix[:])
}

func stringSlicesEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func doJSON(ctx context.Context, base *url.URL, path, bearer, sessionID string, sessionKey ed25519.PrivateKey, requestID string, body []byte, privacy bool, requireAssurance string) ([]byte, error) {
	request, err := newSignedRequest(ctx, base, path, bearer, sessionID, sessionKey, requestID, body, privacy, requireAssurance)
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

func newSignedRequest(ctx context.Context, base *url.URL, path, bearer, sessionID string, sessionKey ed25519.PrivateKey, requestID string, body []byte, privacy bool, requireAssurance string) (*http.Request, error) {
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
	if privacy {
		// Wallet profiles do not list this header. Set it before signing so
		// a profile that names it covers the marker; today the hash is unchanged.
		request.Header.Set(privacyClassHeader, relayblind.PrivacyClassV1)
		if requireAssurance != "" {
			request.Header.Set(privacyAssuranceRequiredHeader, requireAssurance)
		}
	}
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
