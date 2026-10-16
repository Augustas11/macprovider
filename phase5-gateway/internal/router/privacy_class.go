package router

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"github.com/augstar/macprovider-gateway/internal/relayblind"
)

const (
	privacyClassHeader              = "X-MacProvider-Privacy-Class"
	privacyAssuranceHeader          = "X-MacProvider-Privacy-Assurance"
	privacyResponseEncryptionHeader = "X-MacProvider-Response-Encryption"
	privacyPostureVerifiedAtHeader  = "X-MacProvider-Privacy-Posture-Verified-At"

	privacyClassDisabled    = "privacy_class_disabled"
	privacyClassUnavailable = "privacy_class_unavailable"
	privacyClassDowngrade   = "privacy_class_downgrade_rejected"
	privacyClassStale       = "privacy_class_posture_stale"
	privacyClassUnconfirmed = "privacy_class_unconfirmed"

	// SPEC-049-R020, copied verbatim. Short tokens must stay equal to the
	// shared relayblind constants; tests pin that.
	privacyClassV1                = "operator_constrained_beta_v1"
	privacyAssuranceV1            = "device_bound_self_attested_beta"
	privacyResponseEncryptionV1   = "buyer_provider_aead_v1"
	privacyDisclosureVersion      = "privacy-class-disclosure-v1"
	privacyScope                  = "request_and_response_content_hidden_from_relays; provider_runtime_reads_plaintext; ordinary_operator_access_paths_constrained_on_approved_signed_runtime; posture_self_attested_device_bound_not_code_bound"
	privacyPlaintextDowngradeText = "Privacy class marker is not valid for a plaintext request"
	privacyPoolDowngradeText      = "Privacy class does not accept pool-scoped requests"
	privacyDemoDowngradeText      = "Privacy class does not accept demo requests"
)

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

// SPEC-049-R020 pool-scoped disclosure, copied verbatim.
const privacyPoolScope = "served_only_by_current_trusted_pool_members_enrolled_in_this_class; pool_membership_is_administrative_trust_not_content_privacy; a_pool_operator_running_a_member_mac_is_its_provider_operator"

var privacyPoolOperatorSees = []string{
	"pool_policy_membership_and_buyer_grants",
	"aggregate_payable_request_counts_and_provider_credits",
}

var privacyPoolOperatorDoesNotSee = []string{
	"request_and_response_content_through_pool_surfaces",
	"per_request_metadata_and_buyer_attribution_through_pool_surfaces",
}

// SPEC-049-R020 strings for code_bound_attested (v0.5.0), copied verbatim.
const (
	privacyAssuranceCodeBound = "code_bound_attested"
	privacyCodeBoundScope     = "request_and_response_content_hidden_from_relays; provider_runtime_reads_plaintext; ordinary_operator_access_paths_constrained_on_approved_signed_runtime; posture_asserted_by_apple_attested_malibu_app_after_kernel_code_identity_check; label_verified_by_coordinator_not_by_buyer"
)

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
	"modified_or_resigned_malibu_app_cannot_assert_posture",
	"posture_replay_refused_by_attested_counter",
}

var privacyCodeBoundDoesNotProtect = []string{
	"provider_runtime_reads_plaintext_to_infer",
	"request_metadata_visible_to_relays",
	"confidential_compute_or_hardware_enclave_execution",
	"end_to_end_encryption_excluding_the_provider",
	"kernel_or_firmware_compromise_with_sip_on",
	"compromised_team_signing_key",
	"pool_scoped_requests",
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
	"sip_and_full_security_attested_when_app_attest_key_was_attested",
	"label_verified_by_coordinator_not_by_buyer",
	"crash_report_register_and_stack_residue",
	"secure_boot_level_not_evaluated",
	"immutable_prompt_strings_not_zeroized",
	"relays_observe_sizes_timing_and_token_counts",
	"provider_identity_enrolled_on_first_attested_session",
	"coordinator_operator_signs_provider_identity_directory",
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
	"provider_identity_enrolled_on_first_attested_session",
	"coordinator_operator_signs_provider_identity_directory",
}

// privacyUsageContext is the only privacy state attached to a chat execution.
// It carries the reservation timestamp and the consumed envelope's canonical
// model, never ciphertext or prompts.
type privacyUsageContext struct {
	PostureVerifiedAtUnix int64
	Model                 string
	// PoolID is the SPEC-049-R032 pool of a pool-scoped request; "" global.
	PoolID string
	// Assurance is the SPEC-049-R034 label the coordinator echoed for this
	// chat; the disclosure strings follow it.
	Assurance string
}

// privacyUsageObject is the closed SPEC-049-R020 usage.macprovider.privacy
// object. Field order is the wire order; a map would alphabetize it.
type privacyUsageObject struct {
	Class                 string   `json:"class"`
	Assurance             string   `json:"assurance"`
	Scope                 string   `json:"scope"`
	Protects              []string `json:"protects"`
	DoesNotProtect        []string `json:"does_not_protect"`
	ResidualRisks         []string `json:"residual_risks"`
	PostureVerifiedAtUnix int64    `json:"posture_verified_at_unix"`
	// Pool is present only on a pool-scoped response (SPEC-049-R020).
	Pool *privacyPoolDisclosure `json:"pool,omitempty"`
}

// privacyPoolDisclosure is the closed SPEC-049-R020 pool member: what the
// pool operator can and cannot see.
type privacyPoolDisclosure struct {
	PoolID                 string   `json:"pool_id"`
	Scope                  string   `json:"scope"`
	PoolOperatorSees       []string `json:"pool_operator_sees"`
	PoolOperatorDoesNotSee []string `json:"pool_operator_does_not_see"`
}

type operatorConstrainedPrivacyDisclosure struct {
	Version        string                           `json:"version"`
	Class          string                           `json:"class"`
	Assurance      string                           `json:"assurance"`
	Scope          string                           `json:"scope"`
	Protects       []string                         `json:"protects"`
	DoesNotProtect []string                         `json:"does_not_protect"`
	ResidualRisks  []string                         `json:"residual_risks"`
	Models         map[string]privacyProviderCounts `json:"models,omitempty"`
}

type privacyProviderCounts struct {
	CapableProviderCount   int `json:"capable_provider_count"`
	IncapableProviderCount int `json:"incapable_provider_count"`
}

func (s *Server) privacyClassEnabled() bool {
	return s != nil && s.cfg.Features.PrivacyClass.Enabled && s.cfg.Features.RelayBlindRequests.Enabled
}

// privacyRequested reports whether the buyer sent the privacy-class header
// and whether that single value is the SPEC-049 marker. A repeated header,
// a list value, or any other token is present and invalid.
func privacyRequested(r *http.Request) (present, valid bool) {
	if r == nil {
		return false, false
	}
	values := r.Header.Values(privacyClassHeader)
	if len(values) == 0 {
		return false, false
	}
	if len(values) != 1 {
		return true, false
	}
	value := strings.TrimSpace(values[0])
	if value == "" || strings.Contains(value, ",") {
		return true, false
	}
	return true, value == privacyClassV1
}

// privacyAssuranceRequested reads the buyer's SPEC-049-R034 requirement. It
// is valid only as exactly one code_bound_attested value.
func privacyAssuranceRequested(r *http.Request) (present, valid bool) {
	if r == nil {
		return false, false
	}
	values := r.Header.Values(relayblind.PrivacyAssuranceRequiredHeader)
	if len(values) == 0 {
		return false, false
	}
	return true, len(values) == 1 && strings.TrimSpace(values[0]) == privacyAssuranceCodeBound
}

// privacyAssuranceEcho reads the coordinator's SPEC-049-R034 label from a
// successful privacy chat. An absent header is device-bound, the only label a
// coordinator before v0.5.0 serves; a repeated or unknown value fails.
func privacyAssuranceEcho(h http.Header) (string, bool) {
	values := h.Values(privacyAssuranceHeader)
	switch {
	case len(values) == 0:
		return privacyAssuranceV1, true
	case len(values) == 1 && (values[0] == privacyAssuranceV1 || values[0] == privacyAssuranceCodeBound):
		return values[0], true
	default:
		return "", false
	}
}

func privacyErrorMessage(code string) string {
	switch code {
	case privacyClassDisabled:
		return "Privacy class is disabled"
	case privacyClassUnavailable:
		return "Privacy class is unavailable"
	case privacyClassDowngrade:
		return "Privacy class marker does not match the reservation"
	case privacyClassStale:
		return "Privacy class posture is stale"
	case privacyClassUnconfirmed:
		return "Privacy class completion was not confirmed"
	default:
		return "Privacy class is unavailable"
	}
}

// privacyRefusalLogCode is the closed buyer-code label of a refused privacy
// request (SPEC-049-R030 item 3): a privacy or relay-blind code, or a
// SPEC-042 pool code the coordinator returns under SPEC-049-R032 item 2.
func privacyRefusalLogCode(code string) string {
	if _, _, _, pool := privacyPoolRefusal(code); pool || privacyClassKnown(code) || code == relayBlindCapabilityRefusalCode || (strings.HasPrefix(code, "relay_blind_") && len(code) <= 64) {
		return code
	}
	return "unknown"
}

func privacyClassKnown(code string) bool {
	switch code {
	case privacyClassDisabled, privacyClassUnavailable, privacyClassDowngrade, privacyClassStale, privacyClassUnconfirmed:
		return true
	default:
		return false
	}
}

func privacyClassHTTP(code string) (int, string) {
	switch code {
	case privacyClassDowngrade:
		return http.StatusBadRequest, "invalid_request_error"
	case privacyClassUnconfirmed:
		return http.StatusInternalServerError, "api_error"
	case privacyClassStale:
		return http.StatusServiceUnavailable, "api_error"
	default:
		return http.StatusServiceUnavailable, "api_error"
	}
}

func privacyBuyerIntentDenied(r *http.Request, accountID string, demo bool) bool {
	return demo || strings.HasPrefix(accountID, "demo:") || relayBlindPoolSelected(r) || poolPrefixedHeaderPresent(r)
}

// poolPrefixedHeaderPresent reports any nonempty X-MacProvider-Pool* header,
// so a route that stays global-only (SPEC-049-R022) refuses all pool intent.
func poolPrefixedHeaderPresent(r *http.Request) bool {
	prefix := strings.ToLower(poolEmitHeader)
	for name, values := range r.Header {
		if lower := strings.ToLower(name); lower != prefix && !strings.HasPrefix(lower, prefix+"-") {
			continue
		}
		for _, v := range values {
			if strings.TrimSpace(v) != "" {
				return true
			}
		}
	}
	return false
}

// privacyPoolIntentDenied is privacyBuyerIntentDenied for the reservation and
// chat hops of SPEC-049-R032: the buyer pool selector is resolved and
// authorized there instead of refused, so a demo request that names a pool
// gets the generic pool_unavailable from the resolver. Any other
// X-MacProvider-Pool* header (buyer-supplied internal pool authority), an
// engine selector, and demo traffic without a pool selector are refused.
func privacyPoolIntentDenied(r *http.Request, accountID string, demo bool) bool {
	poolSelected := false
	for name, values := range r.Header {
		nonempty := false
		for _, v := range values {
			nonempty = nonempty || strings.TrimSpace(v) != ""
		}
		if !nonempty {
			continue
		}
		switch lower := strings.ToLower(name); {
		case lower == strings.ToLower(poolSelectHeader):
			poolSelected = true
		case lower == strings.ToLower(engineSelectHeader), lower == strings.ToLower(poolEmitHeader), strings.HasPrefix(lower, strings.ToLower(poolEmitHeader)+"-"):
			return true
		}
	}
	return (demo || strings.HasPrefix(accountID, "demo:")) && !poolSelected
}

// resolvePrivacyPool is SPEC-049-R032 item 1 at the gateway: the pool of a
// privacy-class request is resolved and authorized exactly as for plaintext.
// A wallet session or demo account cannot select one. A refusal keeps the
// SPEC-042-R010 timing floor and generic pool_unavailable.
func (s *Server) resolvePrivacyPool(w http.ResponseWriter, r *http.Request, accountID string, walletSession bool) (string, bool) {
	startedAt := s.now()
	allowed := !walletSession && !strings.HasPrefix(accountID, "demo:")
	poolID, poolErr := s.resolvePoolSelection(r.Context(), r.Header, accountID, allowed)
	if poolErr != nil {
		s.enforcePoolRejectionTimingFloor(startedAt)
		writeError(w, poolErr.status, poolErr.typ, poolErr.code, poolErr.message)
		return "", false
	}
	return poolID, true
}

func privacyIntentDowngradeMessage(r *http.Request, accountID string, demo bool) string {
	if relayBlindPoolSelected(r) {
		return privacyPoolDowngradeText
	}
	if demo || strings.HasPrefix(accountID, "demo:") {
		return privacyDemoDowngradeText
	}
	return privacyErrorMessage(privacyClassDowngrade)
}

func writePrivacyClassError(w http.ResponseWriter, code, message string) {
	if strings.TrimSpace(message) == "" {
		message = privacyErrorMessage(code)
	}
	satisfied := w.Header().Get(relayBlindEffectiveHeader) == "relay_blind_satisfied"
	relayBlindHeaders(w.Header(), satisfied)
	w.Header().Del(privacyClassHeader)
	w.Header().Del(privacyAssuranceHeader)
	w.Header().Del(privacyResponseEncryptionHeader)
	w.Header().Del(privacyPostureVerifiedAtHeader)
	status, typ := privacyClassHTTP(code)
	// Top-level retry_action is privacy-class-only. writeError is a
	// conformance-frozen SPEC-006 body, so this writer builds the same
	// envelope and lifts retry_action itself.
	retryable := gatewayRetryable(code)
	setGatewayRetryAfter(w, status, code, retryable)
	payload := map[string]any{"message": message, "type": typ, "param": nil, "code": code, "retryable": retryable}
	if metadata := relayBlindOutcomeMetadata(w.Header(), code); metadata != nil {
		payload["macprovider"] = metadata
		if action, _ := metadata["retry_action"].(string); strings.HasPrefix(code, "privacy_class_") && action != "" {
			payload["retry_action"] = action
		}
	}
	writeJSON(w, status, map[string]any{"error": payload})
}

// writePrivacyClassStreamError terminates a privacy stream after the 200
// headers have already been sent. The offending chunk is not written.
func writePrivacyClassStreamError(w http.ResponseWriter, code, message string) {
	if strings.TrimSpace(message) == "" {
		message = privacyErrorMessage(code)
	}
	poisonDedupeCapture(w)
	_, typ := privacyClassHTTP(code)
	retryable := gatewayRetryable(code)
	payload := map[string]any{"message": message, "type": typ, "param": nil, "code": code, "retryable": retryable}
	if metadata := relayBlindOutcomeMetadata(w.Header(), code); metadata != nil {
		payload["macprovider"] = metadata
		if action, _ := metadata["retry_action"].(string); strings.HasPrefix(code, "privacy_class_") && action != "" {
			payload["retry_action"] = action
		}
	}
	raw, _ := json.Marshal(map[string]any{"error": payload})
	_, _ = w.Write([]byte("data: "))
	_, _ = w.Write(raw)
	_, _ = w.Write([]byte("\n\ndata: [DONE]\n\n"))
}

// privacyPostureVerifiedAt accepts exactly one canonical positive base-10
// integer. Repeated headers, signs, leading zeros, and non-integers fail
// closed so a buyer or a split gateway cannot invent the timestamp.
func privacyPostureVerifiedAt(h http.Header) (int64, bool) {
	if h == nil {
		return 0, false
	}
	values := h.Values(privacyPostureVerifiedAtHeader)
	if len(values) != 1 {
		return 0, false
	}
	value := values[0]
	if value == "" || strings.Contains(value, ",") {
		return 0, false
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil || parsed <= 0 || strconv.FormatInt(parsed, 10) != value {
		return 0, false
	}
	return parsed, true
}

func privacyUsageMetadata(verifiedAt int64, poolID string) privacyUsageObject {
	return privacyUsageMetadataFor(privacyAssuranceV1, verifiedAt, poolID)
}

// privacyUsageMetadataFor is the SPEC-049-R020 object of one label.
func privacyUsageMetadataFor(assurance string, verifiedAt int64, poolID string) privacyUsageObject {
	object := privacyUsageObject{
		Class:                 privacyClassV1,
		Assurance:             privacyAssuranceV1,
		Scope:                 privacyScope,
		Protects:              append([]string(nil), privacyProtects...),
		DoesNotProtect:        append([]string(nil), privacyDoesNotProtect...),
		ResidualRisks:         append([]string(nil), privacyResidualRisks...),
		PostureVerifiedAtUnix: verifiedAt,
	}
	if assurance == privacyAssuranceCodeBound {
		object.Assurance = privacyAssuranceCodeBound
		object.Scope = privacyCodeBoundScope
		object.Protects = append([]string(nil), privacyCodeBoundProtects...)
		object.DoesNotProtect = append([]string(nil), privacyCodeBoundDoesNotProtect...)
		object.ResidualRisks = append([]string(nil), privacyCodeBoundResidualRisks...)
	}
	if poolID != "" {
		// The pool-scoped list drops the trailing pool_scoped_requests item.
		object.DoesNotProtect = object.DoesNotProtect[:len(object.DoesNotProtect)-1]
		object.Pool = &privacyPoolDisclosure{
			PoolID:                 poolID,
			Scope:                  privacyPoolScope,
			PoolOperatorSees:       append([]string(nil), privacyPoolOperatorSees...),
			PoolOperatorDoesNotSee: append([]string(nil), privacyPoolOperatorDoesNotSee...),
		}
	}
	return object
}

func privacyEchoConfirmed(h http.Header) bool {
	if h == nil {
		return false
	}
	values := h.Values(privacyClassHeader)
	return len(values) == 1 && values[0] == privacyClassV1
}

// maybeSetPrivacySuccessHeaders writes the SPEC-049-R020 success headers onto
// the buyer response. Call it immediately before WriteHeader(200), after
// header copying, so an earlier error cannot advertise a confirmed class.
func maybeSetPrivacySuccessHeaders(w http.ResponseWriter, r *http.Request) {
	execution := relayBlindExecutionFor(r)
	if execution == nil || execution.Privacy == nil {
		return
	}
	w.Header().Del(privacyPostureVerifiedAtHeader)
	w.Header().Set(privacyClassHeader, privacyClassV1)
	assurance := privacyAssuranceV1
	if execution.Privacy.Assurance == privacyAssuranceCodeBound {
		assurance = privacyAssuranceCodeBound
	}
	w.Header().Set(privacyAssuranceHeader, assurance)
	w.Header().Set(privacyResponseEncryptionHeader, privacyResponseEncryptionV1)
}

// privacyOpaqueStreamFrame reports a relay-blind SSE privacy frame. The
// ciphertext stays opaque: only the object name is inspected.
func privacyOpaqueStreamFrame(data string) bool {
	var probe struct {
		Object string `json:"object"`
	}
	if json.Unmarshal([]byte(data), &probe) != nil {
		return false
	}
	return probe.Object == relayblind.PrivacyFrameObject
}

func privacyCountsInBounds(c privacyProviderCounts) bool {
	return c.CapableProviderCount >= 0 && c.IncapableProviderCount >= 0 &&
		c.CapableProviderCount <= 100000 && c.IncapableProviderCount <= 100000
}

func newOperatorConstrainedPrivacyDisclosure(models map[string]privacyProviderCounts, buyerModelIDs []string) *operatorConstrainedPrivacyDisclosure {
	out := &operatorConstrainedPrivacyDisclosure{
		Version:        privacyDisclosureVersion,
		Class:          privacyClassV1,
		Assurance:      privacyAssuranceV1,
		Scope:          privacyScope,
		Protects:       append([]string(nil), privacyProtects...),
		DoesNotProtect: append([]string(nil), privacyDoesNotProtect...),
		ResidualRisks:  append([]string(nil), privacyResidualRisks...),
	}
	filtered := make(map[string]privacyProviderCounts)
	for _, id := range buyerModelIDs {
		c, ok := models[id]
		if !ok || !privacyCountsInBounds(c) {
			continue
		}
		filtered[id] = c
	}
	if len(filtered) > 0 {
		out.Models = filtered
	}
	return out
}

// privacyPoolRefusal maps the SPEC-042-R010 codes a coordinator returns for a
// pool refused before privacy selection (SPEC-049-R032 item 2). Every other
// code keeps the existing relay-blind mapping.
func privacyPoolRefusal(code string) (int, string, string, bool) {
	switch code {
	case "pool_unavailable":
		return http.StatusServiceUnavailable, "service_unavailable", "Pool unavailable", true
	case "pool_policy_stale":
		return http.StatusServiceUnavailable, "service_unavailable", "Pool policy/status freshness is stale", true
	case "pool_settlement_mode_unsatisfied":
		return http.StatusServiceUnavailable, "service_unavailable", "Pool requires enforce-mode settlement", true
	case "pool_model_not_allowed":
		return http.StatusBadRequest, "invalid_request_error", "Requested model is not allowed by the selected pool", true
	default:
		return 0, "", "", false
	}
}
