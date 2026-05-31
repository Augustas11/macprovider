package tier2

import (
	"bytes"
	"crypto/ecdsa"
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

func VerifyAttestationToken(raw json.RawMessage, cfg config.Tier2Config, challenge []byte, providerID, providerECDHPublicKey string, now time.Time, logger zerolog.Logger) pool.AttestationStatus {
	if !cfg.RequireAttestation && len(raw) == 0 {
		return pool.AttestationStatusNotRequired
	}
	if len(raw) == 0 || string(raw) == "null" {
		if cfg.RequireAttestation {
			logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", "missing_token", "tier2.require_attestation")
			return pool.AttestationStatusFailed
		}
		return pool.AttestationStatusUnsupported
	}
	if len(raw) > MaxAttestationEnvelopeBytes {
		logAttestationEvent(logger, "attestation_token_too_large", "WARN", providerID, "reject", "token_too_large", "tier2.attestation_max_age_s")
		return pool.AttestationStatusFailed
	}
	var token AttestationToken
	if err := json.Unmarshal(raw, &token); err != nil {
		logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", "invalid_json", "tier2.require_attestation")
		return pool.AttestationStatusFailed
	}
	if !attestationFormatAllowed(token.Format, cfg.AttestationFormats) {
		logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", "unsupported_format", "tier2.attestation_formats")
		return pool.AttestationStatusUnsupported
	}
	if len(token.Token) > MaxAttestationTokenBytes {
		logAttestationEvent(logger, "attestation_token_too_large", "WARN", providerID, "reject", "token_too_large", "tier2.attestation_max_age_s")
		return pool.AttestationStatusFailed
	}
	if !validAttestationTokenEncoding(token.Token) {
		logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", "invalid_token_encoding", "tier2.require_attestation")
		return pool.AttestationStatusFailed
	}
	if token.ProviderID != providerID {
		logAttestationEvent(logger, "provider_binding_mismatch", "WARN", providerID, "reject", "provider_binding_mismatch", "tier2.require_attestation")
		return pool.AttestationStatusFailed
	}
	wantChallenge := base64.RawURLEncoding.EncodeToString(challenge)
	if token.Challenge != wantChallenge {
		logAttestationEvent(logger, "attestation_replay", "WARN", providerID, "reject", "challenge_mismatch", "tier2.require_attestation")
		return pool.AttestationStatusStale
	}
	if strings.TrimSpace(providerECDHPublicKey) != "" && token.KeyBinding.ProviderECDHPublicKey != providerECDHPublicKey {
		logAttestationEvent(logger, "provider_binding_mismatch", "WARN", providerID, "reject", "ecdh_binding_mismatch", "tier2.require_attestation")
		return pool.AttestationStatusFailed
	}
	if !attestationHardwareFamilyAllowed(token) {
		logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", "hardware_family_policy_mismatch", "tier2.attestation_formats")
		return pool.AttestationStatusFailed
	}
	if now.IsZero() {
		now = time.Now().UTC()
	}
	if token.IssuedAt.IsZero() || token.ExpiresAt.IsZero() || now.Before(token.IssuedAt.Add(-1*time.Minute)) || !now.Before(token.ExpiresAt) {
		logAttestationEvent(logger, "attestation_stale", "WARN", providerID, "reject", "stale_or_expired", "tier2.attestation_max_age_s")
		return pool.AttestationStatusStale
	}
	if cfg.AttestationMaxAgeS > 0 && now.Sub(token.IssuedAt) > time.Duration(cfg.AttestationMaxAgeS)*time.Second {
		logAttestationEvent(logger, "attestation_stale", "WARN", providerID, "reject", "max_age_exceeded", "tier2.attestation_max_age_s")
		return pool.AttestationStatusStale
	}
	if len(cfg.AttestationRoots) == 0 {
		logAttestationEvent(logger, "attestation_root_missing", "WARN", providerID, "reject", "missing_attestation_roots", "tier2.attestation_roots")
		if cfg.RequireAttestation {
			return pool.AttestationStatusFailed
		}
		return pool.AttestationStatusUnsupported
	}
	if hasMockAttestationRoot(cfg.AttestationRoots) {
		if validMockAttestationToken(token.Token) {
			logAttestationEvent(logger, "attestation_valid", "INFO", providerID, "allow", "mock_attested", "tier2.attestation_roots")
			return pool.AttestationStatusAttested
		}
		logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", "invalid_mock_attestation", "tier2.attestation_roots")
		return pool.AttestationStatusFailed
	}
	// Production Apple MDA roots must not become a positive hardware signal
	// until certificate-chain, freshness-code, public-key, device-property,
	// and ACME CSR key-binding validation all pass.
	if status, ok := verifyProductionMDAChainShape(token, cfg, now, providerID, logger); ok {
		return status
	}
	decision := "observe"
	if cfg.RequireAttestation {
		decision = "reject"
	}
	logAttestationEvent(logger, "attestation_unsupported", "WARN", providerID, decision, "mda_certificate_chain_missing", "tier2.attestation_roots")
	if cfg.RequireAttestation {
		return pool.AttestationStatusFailed
	}
	return pool.AttestationStatusUnsupported
}

func verifyProductionMDAChainShape(token AttestationToken, cfg config.Tier2Config, now time.Time, providerID string, logger zerolog.Logger) (pool.AttestationStatus, bool) {
	certs, ok, err := extractAttestationCertificateChain(token)
	if !ok {
		return "", false
	}
	if err != nil {
		logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", "invalid_certificate_chain", "tier2.attestation_roots")
		return pool.AttestationStatusFailed, true
	}
	roots, err := parseAttestationRootCertificates(cfg.AttestationRoots)
	if err != nil {
		decision := "observe"
		if cfg.RequireAttestation {
			decision = "reject"
		}
		logAttestationEvent(logger, "attestation_unsupported", "WARN", providerID, decision, "invalid_attestation_roots", "tier2.attestation_roots")
		if cfg.RequireAttestation {
			return pool.AttestationStatusFailed, true
		}
		return pool.AttestationStatusUnsupported, true
	}
	if err := verifyAttestationCertificateChain(certs, roots, now); err != nil {
		logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", "certificate_chain_untrusted", "tier2.attestation_roots")
		return pool.AttestationStatusFailed, true
	}
	if err := verifyMDALeafPublicKey(certs[0]); err != nil {
		logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", "mda_leaf_public_key_invalid", "tier2.attestation_roots")
		return pool.AttestationStatusFailed, true
	}
	if reason := verifyMDAFreshness(certs[0], token.Challenge); reason != "" {
		logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", reason, "tier2.attestation_roots")
		return pool.AttestationStatusFailed, true
	}
	if reason := verifyMDADeviceProperties(certs[0]); reason != "" {
		logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", reason, "tier2.attestation_roots")
		return pool.AttestationStatusFailed, true
	}
	csrStatus, csrReason := verifyMDACSRKeyBinding(certs[0], token)
	if csrReason != "" {
		if csrStatus == pool.AttestationStatusFailed {
			logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", csrReason, "tier2.attestation_roots")
			return pool.AttestationStatusFailed, true
		}
		decision := "observe"
		if cfg.RequireAttestation {
			decision = "reject"
		}
		logAttestationEvent(logger, "attestation_unsupported", "WARN", providerID, decision, csrReason, "tier2.attestation_roots")
		if cfg.RequireAttestation {
			return pool.AttestationStatusFailed, true
		}
		return pool.AttestationStatusUnsupported, true
	}
	logAttestationEvent(logger, "attestation_valid", "INFO", providerID, "allow", "mda_attested", "tier2.attestation_roots")
	return pool.AttestationStatusAttested, true
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

func verifyMDAFreshness(leaf *x509.Certificate, deviceAttestToken string) string {
	extension, ok := certificateExtension(leaf, mdaOIDFreshness)
	if !ok {
		return "mda_freshness_missing"
	}
	if len(extension.Value) == 0 {
		return "mda_freshness_missing"
	}
	expected := expectedMDAFreshnessDigest(deviceAttestToken)
	for _, candidate := range mdaFreshnessValueCandidates(extension.Value) {
		if subtle.ConstantTimeCompare(candidate, expected[:]) == 1 {
			return ""
		}
	}
	return "mda_freshness_mismatch"
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
