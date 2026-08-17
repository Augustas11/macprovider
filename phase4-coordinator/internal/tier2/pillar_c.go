package tier2

import (
	"bytes"
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

const (
	MaxAttestationTokenBytes    = 16 * 1024
	MaxAttestationEnvelopeBytes = MaxAttestationTokenBytes + 4*1024
	mockAttestationRoot         = "mock-root"
	mockAttestationToken        = "mock-devicecheck-token"
)

var (
	mdaOIDSerialNumber                    = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 9, 1}
	mdaOIDUDID                            = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 9, 2}
	mdaOIDSoftwareUpdateDeviceID          = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 9, 4}
	mdaOIDOSVersion                       = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 10, 1}
	mdaOIDSepOSVersion                    = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 10, 2}
	mdaOIDLLBVersion                      = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 10, 3}
	mdaOIDFreshness                       = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 11, 1}
	mdaOIDSIPStatus                       = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 13, 1}
	mdaOIDSecureBootStatus                = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 13, 2}
	mdaOIDThirdPartyKernelExtensions      = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 13, 3}
	mdaRecognizedDevicePropertyExtensions = []asn1.ObjectIdentifier{
		mdaOIDSerialNumber,
		mdaOIDUDID,
		mdaOIDSoftwareUpdateDeviceID,
		mdaOIDOSVersion,
		mdaOIDSepOSVersion,
		mdaOIDLLBVersion,
		mdaOIDSIPStatus,
		mdaOIDSecureBootStatus,
		mdaOIDThirdPartyKernelExtensions,
	}
)

type AttestationToken struct {
	Format           string                 `json:"format"`
	Token            string                 `json:"token"`
	Challenge        string                 `json:"challenge"`
	IssuedAt         time.Time              `json:"issued_at"`
	ExpiresAt        time.Time              `json:"expires_at"`
	ProviderID       string                 `json:"provider_id"`
	BinaryVersion    string                 `json:"binary_version"`
	Claimed          map[string]any         `json:"claimed"`
	KeyBinding       AttestationKeyBinding  `json:"key_binding"`
	CertificateChain []string               `json:"certificate_chain,omitempty"`
	X5C              []string               `json:"x5c,omitempty"`
	CSR              string                 `json:"csr,omitempty"`
	CertificateCSR   string                 `json:"certificate_signing_request,omitempty"`
	Signature        map[string]interface{} `json:"signature,omitempty"`
}

type AttestationKeyBinding struct {
	ProviderECDHPublicKey string `json:"provider_ecdh_public_key"`
}

type attestationBindingSignature struct {
	Alg       string `json:"alg"`
	Signature string `json:"signature"`
}

// AttestationVerifyResult wraps the attestation status together with any
// format-specific side-channel data returned by format-specific verifiers.
// Callers that only need the status use the thin VerifyAttestationToken wrapper.
type AttestationVerifyResult struct {
	Status   pool.AttestationStatus
	SEResult *SEAttestationResult
	// MDAHardware is true when MDA chain verification succeeded AND the
	// freshness extension matched SHA256(sePublicKey) — i.e. the Apple MDA
	// is bound to the provider's SE key via MDM DeviceAttestationNonce.
	// Observe-only: does NOT alone publish pool AttestationTierHardware
	// (R3-M1). Hardware tier is set only via LiveMDAService SetMDAProof /
	// tryUpgradeFromCache after binding-serial + SE freshness checks.
	MDAHardware bool
}

type attestationModelHashCheck struct {
	Catalog *Catalog
	ModelID string
}

// VerifyAttestationTokenExt is the full-result variant of VerifyAttestationToken.
// It returns an AttestationVerifyResult so the caller can access SE-specific
// output (e.g. the verified SE public key) without a second parse pass.
// sePublicKey is optional (may be nil): when len==64 it is used as an additional
// MDA freshness nonce (SHA256(sePublicKey)), enabling MDM DeviceAttestationNonce mode.
func VerifyAttestationTokenExt(raw json.RawMessage, cfg config.Tier2Config, challenge []byte, authAttemptID, providerID, providerECDHPublicKey string, sePublicKey []byte, now time.Time, logger zerolog.Logger) AttestationVerifyResult {
	status, seResult, mdaHardware := verifyAttestationTokenInternal(raw, cfg, challenge, authAttemptID, providerID, providerECDHPublicKey, sePublicKey, now, logger, attestationModelHashCheck{})
	return AttestationVerifyResult{Status: status, SEResult: seResult, MDAHardware: mdaHardware}
}

// VerifyAttestationTokenExtWithCatalog is the catalog-aware variant used by
// provider admission. It preserves attestation status semantics while emitting
// observe-mode diagnostics when the already-signed claimed.model_hash disagrees
// with the active catalog row for modelID.
// sePublicKey is optional (may be nil): when len==64 it is used as an additional
// MDA freshness nonce (SHA256(sePublicKey)), enabling MDM DeviceAttestationNonce mode.
func VerifyAttestationTokenExtWithCatalog(raw json.RawMessage, cfg config.Tier2Config, challenge []byte, authAttemptID, providerID, providerECDHPublicKey, modelID string, catalog *Catalog, sePublicKey []byte, now time.Time, logger zerolog.Logger) AttestationVerifyResult {
	status, seResult, mdaHardware := verifyAttestationTokenInternal(raw, cfg, challenge, authAttemptID, providerID, providerECDHPublicKey, sePublicKey, now, logger, attestationModelHashCheck{
		Catalog: catalog,
		ModelID: modelID,
	})
	return AttestationVerifyResult{Status: status, SEResult: seResult, MDAHardware: mdaHardware}
}

// VerifyAttestationToken verifies an attestation token and returns the status.
// Use VerifyAttestationTokenExt when the caller needs format-specific results.
func VerifyAttestationToken(raw json.RawMessage, cfg config.Tier2Config, challenge []byte, authAttemptID, providerID, providerECDHPublicKey string, now time.Time, logger zerolog.Logger) pool.AttestationStatus {
	status, _, _ := verifyAttestationTokenInternal(raw, cfg, challenge, authAttemptID, providerID, providerECDHPublicKey, nil, now, logger, attestationModelHashCheck{})
	return status
}

func verifyAttestationTokenInternal(raw json.RawMessage, cfg config.Tier2Config, challenge []byte, authAttemptID, providerID, providerECDHPublicKey string, sePublicKey []byte, now time.Time, logger zerolog.Logger, modelHashCheck attestationModelHashCheck) (pool.AttestationStatus, *SEAttestationResult, bool) {
	if !cfg.RequireAttestation && len(raw) == 0 {
		return pool.AttestationStatusNotRequired, nil, false
	}
	if len(raw) == 0 || string(raw) == "null" {
		if cfg.RequireAttestation {
			logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", "missing_token", "tier2.require_attestation")
			return pool.AttestationStatusFailed, nil, false
		}
		// A missing token is a capability absence, not an unsupported token
		// format. When attestation is optional, report the policy decision
		// explicitly so clients do not treat the accepted session as an
		// attestation failure during autoupdate eligibility checks.
		return pool.AttestationStatusNotRequired, nil, false
	}
	if len(raw) > MaxAttestationEnvelopeBytes {
		logAttestationEvent(logger, "attestation_token_too_large", "WARN", providerID, "reject", "token_too_large", "tier2.attestation_max_age_s")
		return pool.AttestationStatusFailed, nil, false
	}
	var token AttestationToken
	if err := json.Unmarshal(raw, &token); err != nil {
		logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", "invalid_json", "tier2.require_attestation")
		return pool.AttestationStatusFailed, nil, false
	}
	if !attestationFormatAllowed(token.Format, cfg.AttestationFormats) {
		logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", "unsupported_format", "tier2.attestation_formats")
		return pool.AttestationStatusUnsupported, nil, false
	}
	if len(token.Token) > MaxAttestationTokenBytes {
		logAttestationEvent(logger, "attestation_token_too_large", "WARN", providerID, "reject", "token_too_large", "tier2.attestation_max_age_s")
		return pool.AttestationStatusFailed, nil, false
	}
	if !validAttestationTokenEncoding(token.Token) {
		logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", "invalid_token_encoding", "tier2.require_attestation")
		return pool.AttestationStatusFailed, nil, false
	}
	if token.ProviderID != providerID {
		logAttestationEvent(logger, "provider_binding_mismatch", "WARN", providerID, "reject", "provider_binding_mismatch", "tier2.require_attestation")
		return pool.AttestationStatusFailed, nil, false
	}
	wantChallenge := base64.RawURLEncoding.EncodeToString(challenge)
	if token.Challenge != wantChallenge {
		logAttestationEvent(logger, "attestation_replay", "WARN", providerID, "reject", "challenge_mismatch", "tier2.require_attestation")
		return pool.AttestationStatusStale, nil, false
	}
	if strings.TrimSpace(providerECDHPublicKey) != "" && token.KeyBinding.ProviderECDHPublicKey != providerECDHPublicKey {
		logAttestationEvent(logger, "provider_binding_mismatch", "WARN", providerID, "reject", "ecdh_binding_mismatch", "tier2.require_attestation")
		return pool.AttestationStatusFailed, nil, false
	}
	if !attestationHardwareFamilyAllowed(token) {
		logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", "hardware_family_policy_mismatch", "tier2.attestation_formats")
		return pool.AttestationStatusFailed, nil, false
	}
	if now.IsZero() {
		now = time.Now().UTC()
	}
	if token.IssuedAt.IsZero() || token.ExpiresAt.IsZero() || now.Before(token.IssuedAt.Add(-1*time.Minute)) || !now.Before(token.ExpiresAt) {
		logAttestationEvent(logger, "attestation_stale", "WARN", providerID, "reject", "stale_or_expired", "tier2.attestation_max_age_s")
		return pool.AttestationStatusStale, nil, false
	}
	if cfg.AttestationMaxAgeS > 0 && now.Sub(token.IssuedAt) > time.Duration(cfg.AttestationMaxAgeS)*time.Second {
		logAttestationEvent(logger, "attestation_stale", "WARN", providerID, "reject", "max_age_exceeded", "tier2.attestation_max_age_s")
		return pool.AttestationStatusStale, nil, false
	}
	// SE P-256 format: self-signed attestation, no MDA root required.
	// Common checks above (challenge, providerID, ECDH, hardware family,
	// time) have already passed. SE-specific cryptographic verification
	// runs here before the MDA root / mock paths.
	if token.Format == seAttestationFormat {
		status, seResult := verifySEAttestationToken(token, challenge, authAttemptID)
		if status == pool.AttestationStatusAttested {
			observeSignedModelHashAgainstCatalog(token, modelHashCheck, providerID, logger)
			logAttestationEvent(logger, "attestation_valid", "INFO", providerID, "allow", "se_p256_attested", "tier2.attestation_formats")
		} else {
			logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", "se_p256_verification_failed", "tier2.attestation_formats")
		}
		return status, seResult, false
	}
	if len(cfg.AttestationRoots) == 0 {
		logAttestationEvent(logger, "attestation_root_missing", "WARN", providerID, "reject", "missing_attestation_roots", "tier2.attestation_roots")
		if cfg.RequireAttestation {
			return pool.AttestationStatusFailed, nil, false
		}
		return pool.AttestationStatusUnsupported, nil, false
	}
	if cfg.AllowMockAttestation && hasMockAttestationRoot(cfg.AttestationRoots) {
		if validMockAttestationToken(token.Token) {
			logAttestationEvent(logger, "attestation_valid", "INFO", providerID, "allow", "mock_attested", "tier2.attestation_roots")
			return pool.AttestationStatusAttested, nil, false
		}
		logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", "invalid_mock_attestation", "tier2.attestation_roots")
		return pool.AttestationStatusFailed, nil, false
	}
	// Production Apple MDA roots must not become a positive hardware signal
	// until certificate-chain, freshness-code, public-key, device-property,
	// and ACME CSR key-binding validation all pass.
	if status, ok, mdaHardware := verifyProductionMDAChainShape(token, cfg, sePublicKey, now, authAttemptID, providerID, logger, modelHashCheck); ok {
		return status, nil, mdaHardware
	}
	decision := "observe"
	if cfg.RequireAttestation {
		decision = "reject"
	}
	logAttestationEvent(logger, "attestation_unsupported", "WARN", providerID, decision, "mda_certificate_chain_missing", "tier2.attestation_roots")
	if cfg.RequireAttestation {
		return pool.AttestationStatusFailed, nil, false
	}
	return pool.AttestationStatusUnsupported, nil, false
}

// verifyProductionMDAChainShape verifies the full Apple MDA certificate chain
// for a production token. sePublicKey is optional (may be nil or len!=64); when
// len==64 it is used as an additional freshness nonce (SHA256(sePublicKey)) and
// the third return value (mdaHardware) is true when that SE-key digest matched.
func verifyProductionMDAChainShape(token AttestationToken, cfg config.Tier2Config, sePublicKey []byte, now time.Time, authAttemptID, providerID string, logger zerolog.Logger, modelHashCheck attestationModelHashCheck) (pool.AttestationStatus, bool, bool) {
	certs, ok, err := extractAttestationCertificateChain(token)
	if !ok {
		return "", false, false
	}
	if err != nil {
		logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", "invalid_certificate_chain", "tier2.attestation_roots")
		return pool.AttestationStatusFailed, true, false
	}
	roots, err := parseAttestationRootCertificates(cfg.AttestationRoots)
	if err != nil {
		decision := "observe"
		if cfg.RequireAttestation {
			decision = "reject"
		}
		logAttestationEvent(logger, "attestation_unsupported", "WARN", providerID, decision, "invalid_attestation_roots", "tier2.attestation_roots")
		if cfg.RequireAttestation {
			return pool.AttestationStatusFailed, true, false
		}
		return pool.AttestationStatusUnsupported, true, false
	}
	if err := verifyAttestationCertificateChain(certs, roots, now); err != nil {
		logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", "certificate_chain_untrusted", "tier2.attestation_roots")
		return pool.AttestationStatusFailed, true, false
	}
	if err := verifyMDALeafPublicKey(certs[0]); err != nil {
		logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", "mda_leaf_public_key_invalid", "tier2.attestation_roots")
		return pool.AttestationStatusFailed, true, false
	}
	reason, seKeyUsed := verifyMDAFreshness(certs[0], token.Token, sePublicKey)
	if reason != "" {
		logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", reason, "tier2.attestation_roots")
		return pool.AttestationStatusFailed, true, false
	}
	if reason := verifyMDADeviceProperties(certs[0]); reason != "" {
		logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", reason, "tier2.attestation_roots")
		return pool.AttestationStatusFailed, true, false
	}
	csrStatus, csrReason := verifyMDACSRKeyBinding(certs[0], token)
	if csrReason != "" {
		if csrStatus == pool.AttestationStatusFailed {
			logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", csrReason, "tier2.attestation_roots")
			return pool.AttestationStatusFailed, true, false
		}
		decision := "observe"
		if cfg.RequireAttestation {
			decision = "reject"
		}
		logAttestationEvent(logger, "attestation_unsupported", "WARN", providerID, decision, csrReason, "tier2.attestation_roots")
		if cfg.RequireAttestation {
			return pool.AttestationStatusFailed, true, false
		}
		return pool.AttestationStatusUnsupported, true, false
	}
	if reason := verifyAttestationBindingSignature(certs[0], token, authAttemptID); reason != "" {
		logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", reason, "tier2.require_attestation")
		return pool.AttestationStatusFailed, true, false
	}
	observeSignedModelHashAgainstCatalog(token, modelHashCheck, providerID, logger)
	if seKeyUsed {
		logAttestationEvent(logger, "attestation_valid", "INFO", providerID, "allow", "mda_hardware_attested", "tier2.attestation_roots")
	} else {
		logAttestationEvent(logger, "attestation_valid", "INFO", providerID, "allow", "mda_attested", "tier2.attestation_roots")
	}
	return pool.AttestationStatusAttested, true, seKeyUsed
}

// VerifyMDACertChainWithSEKey verifies a raw DER certificate chain (leaf first)
// against the configured attestation roots and the provided SE public key.
// Used by internal/mdm.LiveMDAService to re-verify cached MDA proofs without
// synthesising a full AttestationToken.
//
// Returns (true, seKeyUsed) when the chain is valid; seKeyUsed=true when
// freshness was satisfied by SHA256(sePublicKey) (MDA hardware tier).
// Returns (false, false) on any chain or freshness failure.
func VerifyMDACertChainWithSEKey(certChain [][]byte, cfg config.Tier2Config, sePublicKey []byte, now time.Time, logger zerolog.Logger) (ok bool, seKeyUsed bool) {
	if len(certChain) == 0 {
		return false, false
	}
	certs := make([]*x509.Certificate, 0, len(certChain))
	for _, der := range certChain {
		c, err := x509.ParseCertificate(der)
		if err != nil {
			return false, false
		}
		certs = append(certs, c)
	}
	roots, err := parseAttestationRootCertificates(cfg.AttestationRoots)
	if err != nil {
		return false, false
	}
	if err := verifyAttestationCertificateChain(certs, roots, now); err != nil {
		return false, false
	}
	if err := verifyMDALeafPublicKey(certs[0]); err != nil {
		return false, false
	}
	// Use an empty token string for the legacy freshness digest so that it
	// effectively cannot match — only the SE key path should succeed here.
	reason, seKeyUsed := verifyMDAFreshness(certs[0], "", sePublicKey)
	if reason != "" {
		return false, false
	}
	if reason := verifyMDADeviceProperties(certs[0]); reason != "" {
		return false, false
	}
	_ = logger
	return true, seKeyUsed
}

// ExtractMDASerialNumber returns the hardware serial number from an Apple MDA
// leaf certificate (OID 1.2.840.113635.100.8.9.1), or "" when absent/unparseable.
// Used by LiveMDAService to bind MDM responses to the enrolled MicroMDM device.
func ExtractMDASerialNumber(leaf *x509.Certificate) string {
	if leaf == nil {
		return ""
	}
	extension, ok := certificateExtension(leaf, mdaOIDSerialNumber)
	if !ok {
		return ""
	}
	return decodeMDAExtensionText(extension.Value)
}

func decodeMDAExtensionText(value []byte) string {
	if len(value) == 0 {
		return ""
	}
	var text string
	if rest, err := asn1.Unmarshal(value, &text); err == nil && len(rest) == 0 {
		return strings.TrimSpace(text)
	}
	var octets []byte
	if rest, err := asn1.Unmarshal(value, &octets); err == nil && len(rest) == 0 {
		return strings.TrimSpace(string(octets))
	}
	// Some test / vendor encodings store the UTF-8 serial as raw OCTET contents.
	if isMostlyPrintable(value) {
		return strings.TrimSpace(string(value))
	}
	return ""
}

func isMostlyPrintable(b []byte) bool {
	if len(b) == 0 {
		return false
	}
	for _, c := range b {
		if c < 0x20 || c > 0x7e {
			return false
		}
	}
	return true
}

func verifyMDALeafPublicKey(leaf *x509.Certificate) error {
	if leaf == nil {
		return fmt.Errorf("missing leaf certificate")
	}
	pub, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok {
		return fmt.Errorf("MDA leaf public key is not ECSECPrimeRandom")
	}
	if pub.Curve == nil {
		return fmt.Errorf("MDA leaf public key is missing curve")
	}
	switch pub.Curve.Params().Name {
	case "P-256", "P-384":
		return nil
	default:
		return fmt.Errorf("MDA leaf public key curve %q is unsupported", pub.Curve.Params().Name)
	}
}

func attestationHardwareFamilyAllowed(token AttestationToken) bool {
	hardwareFamily, ok := token.Claimed["hardware_family"].(string)
	return ok && hardwareFamily == "apple_silicon"
}

func observeSignedModelHashAgainstCatalog(token AttestationToken, check attestationModelHashCheck, providerID string, logger zerolog.Logger) {
	if check.Catalog == nil {
		return
	}
	modelID := strings.TrimSpace(check.ModelID)
	if modelID == "" {
		modelID = tokenClaimedModelID(token)
	}
	if modelID == "" {
		return
	}
	claimedValue, present := token.Claimed["model_hash"]
	if !present {
		return
	}
	claimedRaw, claimedStringOK := claimedValue.(string)
	if claimedStringOK {
		claimedRaw = strings.TrimSpace(claimedRaw)
	}
	material, ok := check.Catalog.RouteSnapshotMaterial(modelID, claimedRaw)
	if !ok {
		return
	}
	if !claimedStringOK || claimedRaw == "" || !hashPattern.MatchString(claimedRaw) {
		logAttestationModelHashMismatch(logger, providerID, modelID, claimedRaw, material.ExpectedModelHash, material.CatalogID, "signed_model_hash_invalid")
		return
	}
	claimed := strings.ToLower(claimedRaw)
	if material.HashStatus == pool.HashStatusMismatch || subtle.ConstantTimeCompare([]byte(claimed), []byte(material.ExpectedModelHash)) != 1 {
		logAttestationModelHashMismatch(logger, providerID, modelID, claimed, material.ExpectedModelHash, material.CatalogID, "signed_model_hash_mismatch")
	}
}

func tokenClaimedModelID(token AttestationToken) string {
	modelID, _ := token.Claimed["model_id"].(string)
	return strings.TrimSpace(modelID)
}

// verifyMDAFreshness checks the MDA leaf freshness extension against expected
// digest(s). Always accepts SHA256(deviceAttestToken) (legacy SPEC-008 path).
// When len(sePublicKey)==64, also accepts SHA256(sePublicKey) (MDM
// DeviceAttestationNonce mode); seKeyUsed=true when that path matched.
func verifyMDAFreshness(leaf *x509.Certificate, deviceAttestToken string, sePublicKey []byte) (reason string, seKeyUsed bool) {
	extension, ok := certificateExtension(leaf, mdaOIDFreshness)
	if !ok || len(extension.Value) == 0 {
		return "mda_freshness_missing", false
	}
	expected := expectedMDAFreshnessDigest(deviceAttestToken)
	for _, candidate := range mdaFreshnessValueCandidates(extension.Value) {
		if subtle.ConstantTimeCompare(candidate, expected[:]) == 1 {
			return "", false
		}
	}
	if len(sePublicKey) == rawP256PubkeyBytes {
		seExpected := sha256.Sum256(sePublicKey)
		for _, candidate := range mdaFreshnessValueCandidates(extension.Value) {
			if subtle.ConstantTimeCompare(candidate, seExpected[:]) == 1 {
				return "", true
			}
		}
	}
	return "mda_freshness_mismatch", false
}

func expectedMDAFreshnessDigest(deviceAttestToken string) [sha256.Size]byte {
	return sha256.Sum256([]byte(deviceAttestToken))
}

func verifyMDADeviceProperties(leaf *x509.Certificate) string {
	for _, oid := range mdaRecognizedDevicePropertyExtensions {
		extension, ok := certificateExtension(leaf, oid)
		if !ok {
			continue
		}
		if mdaExtensionValueBlank(extension.Value) {
			return "mda_device_property_blank"
		}
		return ""
	}
	return "mda_device_property_missing"
}

func verifyMDACSRKeyBinding(leaf *x509.Certificate, token AttestationToken) (pool.AttestationStatus, string) {
	csr, ok, err := extractAttestationCSR(token)
	if !ok {
		return pool.AttestationStatusUnsupported, "mda_csr_key_binding_missing"
	}
	if err != nil {
		return pool.AttestationStatusFailed, "mda_csr_invalid"
	}
	if err := csr.CheckSignature(); err != nil {
		return pool.AttestationStatusFailed, "mda_csr_signature_invalid"
	}
	if !bytes.Equal(csr.RawSubjectPublicKeyInfo, leaf.RawSubjectPublicKeyInfo) {
		return pool.AttestationStatusFailed, "mda_csr_key_mismatch"
	}
	return "", ""
}

func verifyAttestationBindingSignature(leaf *x509.Certificate, token AttestationToken, authAttemptID string) string {
	sig, ok := parseAttestationBindingSignature(token.Signature)
	if !ok {
		return "attestation_binding_signature_missing"
	}
	payload, err := attestationBindingPayload(token, authAttemptID)
	if err != nil {
		return "attestation_binding_payload_invalid"
	}
	signature, err := base64.RawURLEncoding.DecodeString(sig.Signature)
	if err != nil {
		return "attestation_binding_signature_invalid"
	}
	switch sig.Alg {
	case "ES256":
		pub, ok := leaf.PublicKey.(*ecdsa.PublicKey)
		if !ok {
			return "attestation_binding_signature_key_invalid"
		}
		digest := sha256.Sum256(payload)
		if !ecdsa.VerifyASN1(pub, digest[:], signature) {
			return "attestation_binding_signature_mismatch"
		}
		return ""
	case "Ed25519":
		pub, ok := leaf.PublicKey.(ed25519.PublicKey)
		if !ok {
			return "attestation_binding_signature_key_invalid"
		}
		if !ed25519.Verify(pub, payload, signature) {
			return "attestation_binding_signature_mismatch"
		}
		return ""
	default:
		return "attestation_binding_signature_alg_unsupported"
	}
}

func parseAttestationBindingSignature(raw map[string]interface{}) (attestationBindingSignature, bool) {
	if len(raw) == 0 {
		return attestationBindingSignature{}, false
	}
	alg, _ := raw["alg"].(string)
	signature, _ := raw["signature"].(string)
	if strings.TrimSpace(alg) == "" || strings.TrimSpace(signature) == "" {
		return attestationBindingSignature{}, false
	}
	return attestationBindingSignature{Alg: alg, Signature: signature}, true
}

func BuildAttestationBindingSignature(token AttestationToken, authAttemptID string, signer crypto.Signer) (map[string]interface{}, error) {
	if signer == nil {
		return nil, fmt.Errorf("missing attestation binding signer")
	}
	payload, err := attestationBindingPayload(token, authAttemptID)
	if err != nil {
		return nil, err
	}
	var alg string
	var signature []byte
	switch signer.Public().(type) {
	case *ecdsa.PublicKey:
		alg = "ES256"
		digest := sha256.Sum256(payload)
		signature, err = signer.Sign(rand.Reader, digest[:], crypto.SHA256)
	case ed25519.PublicKey:
		alg = "Ed25519"
		signature, err = signer.Sign(rand.Reader, payload, crypto.Hash(0))
	default:
		return nil, fmt.Errorf("unsupported attestation binding signer key type %T", signer.Public())
	}
	if err != nil {
		return nil, err
	}
	return map[string]interface{}{
		"alg":       alg,
		"signature": base64.RawURLEncoding.EncodeToString(signature),
	}, nil
}

func attestationBindingPayload(token AttestationToken, authAttemptID string) ([]byte, error) {
	claimed, err := json.Marshal(token.Claimed)
	if err != nil {
		return nil, err
	}
	claimedHash := sha256.Sum256(claimed)
	tokenHash := sha256.Sum256([]byte(token.Token))
	return json.Marshal(struct {
		Version               string `json:"version"`
		ProviderID            string `json:"provider_id"`
		BinaryVersion         string `json:"binary_version"`
		Challenge             string `json:"challenge"`
		AuthAttemptID         string `json:"auth_attempt_id"`
		ProviderECDHPublicKey string `json:"provider_ecdh_public_key"`
		IssuedAt              string `json:"issued_at"`
		ExpiresAt             string `json:"expires_at"`
		TokenSHA256           string `json:"token_sha256"`
		ClaimedSHA256         string `json:"claimed_sha256"`
	}{
		Version:               "macprovider/spec008/attestation-binding/v1",
		ProviderID:            token.ProviderID,
		BinaryVersion:         token.BinaryVersion,
		Challenge:             token.Challenge,
		AuthAttemptID:         authAttemptID,
		ProviderECDHPublicKey: token.KeyBinding.ProviderECDHPublicKey,
		IssuedAt:              token.IssuedAt.UTC().Format(time.RFC3339),
		ExpiresAt:             token.ExpiresAt.UTC().Format(time.RFC3339),
		TokenSHA256:           base64.RawURLEncoding.EncodeToString(tokenHash[:]),
		ClaimedSHA256:         base64.RawURLEncoding.EncodeToString(claimedHash[:]),
	})
}

func extractAttestationCSR(token AttestationToken) (*x509.CertificateRequest, bool, error) {
	value := strings.TrimSpace(token.CertificateCSR)
	if value == "" {
		value = strings.TrimSpace(token.CSR)
	}
	if value == "" {
		return nil, false, nil
	}
	csr, err := parseEncodedCSR(value)
	if err != nil {
		return nil, true, err
	}
	return csr, true, nil
}

func parseEncodedCSR(value string) (*x509.CertificateRequest, error) {
	raw := strings.TrimSpace(value)
	if raw == "" {
		return nil, fmt.Errorf("empty csr")
	}
	if block, _ := pem.Decode([]byte(raw)); block != nil {
		if block.Type != "CERTIFICATE REQUEST" && block.Type != "NEW CERTIFICATE REQUEST" {
			return nil, fmt.Errorf("unexpected pem block type %q", block.Type)
		}
		return x509.ParseCertificateRequest(block.Bytes)
	}
	for _, encoding := range []*base64.Encoding{
		base64.StdEncoding,
		base64.RawStdEncoding,
		base64.URLEncoding,
		base64.RawURLEncoding,
	} {
		decoded, err := encoding.DecodeString(raw)
		if err == nil {
			return x509.ParseCertificateRequest(decoded)
		}
	}
	return nil, fmt.Errorf("csr is not PEM or base64 DER")
}

func certificateExtension(cert *x509.Certificate, oid asn1.ObjectIdentifier) (pkix.Extension, bool) {
	if cert == nil {
		return pkix.Extension{}, false
	}
	for _, extension := range cert.Extensions {
		if extension.Id.Equal(oid) {
			return extension, true
		}
	}
	return pkix.Extension{}, false
}

func mdaFreshnessValueCandidates(value []byte) [][]byte {
	candidates := [][]byte{value}
	var octets []byte
	if rest, err := asn1.Unmarshal(value, &octets); err == nil && len(rest) == 0 {
		candidates = append(candidates, octets)
	}
	return candidates
}

func mdaExtensionValueBlank(value []byte) bool {
	if len(value) == 0 {
		return true
	}
	var text string
	if rest, err := asn1.Unmarshal(value, &text); err == nil && len(rest) == 0 {
		return strings.TrimSpace(text) == ""
	}
	var octets []byte
	if rest, err := asn1.Unmarshal(value, &octets); err == nil && len(rest) == 0 {
		return len(octets) == 0
	}
	return false
}

func validAttestationTokenEncoding(token string) bool {
	token = strings.TrimSpace(token)
	if token == "" {
		return false
	}
	if strings.Contains(token, ".") {
		parts := strings.Split(token, ".")
		if len(parts) != 3 {
			return false
		}
		for _, part := range parts {
			if part == "" {
				return false
			}
			if _, err := base64.RawURLEncoding.DecodeString(part); err != nil {
				return false
			}
		}
		return true
	}
	decoded, err := base64.RawURLEncoding.DecodeString(token)
	return err == nil && len(decoded) > 0
}

func hasMockAttestationRoot(roots []string) bool {
	for _, root := range roots {
		if strings.TrimSpace(root) == mockAttestationRoot {
			return true
		}
	}
	return false
}

func validMockAttestationToken(token string) bool {
	decoded, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(token))
	return err == nil && string(decoded) == mockAttestationToken
}

func extractAttestationCertificateChain(token AttestationToken) ([]*x509.Certificate, bool, error) {
	values := append([]string{}, token.CertificateChain...)
	values = append(values, token.X5C...)
	if len(values) == 0 && strings.Contains(token.Token, ".") {
		headerX5C, err := compactJWSHeaderX5C(token.Token)
		if err != nil {
			return nil, true, err
		}
		values = append(values, headerX5C...)
	}
	if len(values) == 0 {
		decoded, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(token.Token))
		if err != nil {
			return nil, false, nil
		}
		cert, err := x509.ParseCertificate(decoded)
		if err != nil {
			return nil, false, nil
		}
		return []*x509.Certificate{cert}, true, nil
	}
	certs := make([]*x509.Certificate, 0, len(values))
	for _, value := range values {
		cert, err := parseEncodedCertificate(value)
		if err != nil {
			return nil, true, err
		}
		certs = append(certs, cert)
	}
	return certs, true, nil
}

func compactJWSHeaderX5C(token string) ([]string, error) {
	parts := strings.Split(strings.TrimSpace(token), ".")
	if len(parts) != 3 {
		return nil, fmt.Errorf("compact jws must have three segments")
	}
	header, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, err
	}
	var decoded struct {
		X5C []string `json:"x5c"`
	}
	if err := json.Unmarshal(header, &decoded); err != nil {
		return nil, err
	}
	return decoded.X5C, nil
}

func parseAttestationRootCertificates(roots []string) ([]*x509.Certificate, error) {
	var certs []*x509.Certificate
	for _, root := range roots {
		root = strings.TrimSpace(root)
		if root == "" || root == mockAttestationRoot {
			continue
		}
		parsed, err := parseCertificateBundle(root)
		if err != nil {
			return nil, err
		}
		certs = append(certs, parsed...)
	}
	if len(certs) == 0 {
		return nil, fmt.Errorf("no parseable root certificates")
	}
	return certs, nil
}

func parseCertificateBundle(value string) ([]*x509.Certificate, error) {
	remaining := []byte(strings.TrimSpace(value))
	var certs []*x509.Certificate
	for {
		block, rest := pem.Decode(remaining)
		if block == nil {
			break
		}
		if block.Type == "CERTIFICATE" {
			cert, err := x509.ParseCertificate(block.Bytes)
			if err != nil {
				return nil, err
			}
			certs = append(certs, cert)
		}
		remaining = rest
	}
	if len(certs) > 0 {
		return certs, nil
	}
	cert, err := parseEncodedCertificate(value)
	if err != nil {
		return nil, err
	}
	return []*x509.Certificate{cert}, nil
}

func parseEncodedCertificate(value string) (*x509.Certificate, error) {
	raw := strings.TrimSpace(value)
	if raw == "" {
		return nil, fmt.Errorf("empty certificate")
	}
	if block, _ := pem.Decode([]byte(raw)); block != nil {
		if block.Type != "CERTIFICATE" {
			return nil, fmt.Errorf("unexpected pem block type %q", block.Type)
		}
		return x509.ParseCertificate(block.Bytes)
	}
	for _, encoding := range []*base64.Encoding{
		base64.StdEncoding,
		base64.RawStdEncoding,
		base64.URLEncoding,
		base64.RawURLEncoding,
	} {
		decoded, err := encoding.DecodeString(raw)
		if err == nil {
			return x509.ParseCertificate(decoded)
		}
	}
	return nil, fmt.Errorf("certificate is not PEM or base64 DER")
}

func verifyAttestationCertificateChain(certs, roots []*x509.Certificate, now time.Time) error {
	if len(certs) == 0 {
		return fmt.Errorf("empty attestation certificate chain")
	}
	rootPool := x509.NewCertPool()
	for _, root := range roots {
		rootPool.AddCert(root)
	}
	intermediates := x509.NewCertPool()
	for _, cert := range certs[1:] {
		intermediates.AddCert(cert)
	}
	_, err := certs[0].Verify(x509.VerifyOptions{
		Roots:         rootPool,
		Intermediates: intermediates,
		CurrentTime:   now,
		KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
	})
	return err
}

func logAttestationEvent(logger zerolog.Logger, event, severity, providerID, decision, reason, configFlag string) {
	level := logger.Info()
	if severity == "WARN" {
		level = logger.Warn()
	}
	level.
		Str("event", event).
		Str("category", "T2.C").
		Str("severity", severity).
		Str("provider_id", providerID).
		Str("pillar", "C").
		Str("decision", decision).
		Str("reason", reason).
		Str("config_flag", configFlag).
		Msg("tier2 attestation event")
}

func logAttestationModelHashMismatch(logger zerolog.Logger, providerID, modelID, claimedHash, expectedHash, catalogID, reason string) {
	logger.Warn().
		Str("event", "attestation_model_hash_mismatch").
		Str("category", "T2.C").
		Str("severity", "WARN").
		Str("provider_id", providerID).
		Str("model_id", modelID).
		Str("pillar", "C").
		Str("claimed_hash_prefix", hashPrefix(claimedHash)).
		Str("expected_hash_prefix", hashPrefix(expectedHash)).
		Str("catalog_id", catalogID).
		Str("decision", "observe").
		Str("reason", reason).
		Str("config_flag", "tier2.catalog_path").
		Msg("tier2 attestation event")
}

func attestationFormatAllowed(format string, formats []string) bool {
	if strings.TrimSpace(format) == "" {
		return false
	}
	for _, allowed := range formats {
		if format == allowed {
			return true
		}
	}
	return false
}

func BuildMockAttestationToken(format string, challenge []byte, providerID, providerECDHPublicKey string, issuedAt, expiresAt time.Time) json.RawMessage {
	raw, err := json.Marshal(AttestationToken{
		Format:     format,
		Token:      base64.RawURLEncoding.EncodeToString([]byte(mockAttestationToken)),
		Challenge:  base64.RawURLEncoding.EncodeToString(challenge),
		IssuedAt:   issuedAt,
		ExpiresAt:  expiresAt,
		ProviderID: providerID,
		Claimed: map[string]any{
			"hardware_family": "apple_silicon",
		},
		KeyBinding: AttestationKeyBinding{ProviderECDHPublicKey: providerECDHPublicKey},
	})
	if err != nil {
		panic(fmt.Sprintf("mock attestation token marshal failed: %v", err))
	}
	return raw
}
