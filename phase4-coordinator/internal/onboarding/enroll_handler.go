package onboarding

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"

	"github.com/augstar/macprovider-coordinator/internal/mdm"
	"github.com/rs/zerolog"
)

// serialNumberRegexp matches valid device serial numbers: 8-14 alphanumeric
// characters (case-insensitive). Apple serials are typically 12 chars but
// range from 8-14 in practice.
var serialNumberRegexp = regexp.MustCompile(`^[A-Za-z0-9]{8,14}$`)

// maxEnrollBodyBytes caps the JSON body for POST /v1/enroll.
const maxEnrollBodyBytes = 4 * 1024

// ProfileSigner optionally CMS-signs a generated .mobileconfig before it is
// served to the client. Signing is install-time trust only — it does not
// affect the SCEP/MDM chain inside the profile. When the signer is nil or
// returns an error the handler serves the unsigned profile with a loud log.
type ProfileSigner interface {
	Sign(profile []byte) ([]byte, error)
}

// EnrollHandler handles POST /v1/enroll and returns per-device
// .mobileconfig files for MDM enrollment (Phase 2 Track P2-A, Scenario B).
//
// No authentication is required: the serial number is not secret. Trust is
// established via MDM SecurityInfo verification after enrollment completes,
// not from possession of the profile.
type EnrollHandler struct {
	// MDMConfig carries the profile generation parameters (base URL, SCEP URL,
	// MDM connect URL, push topic). Populated from config.Tier2MDMConfig.
	MDMConfig mdm.Config

	// Signer optionally CMS-signs the profile. When nil the profile is served
	// unsigned. Build via NewFileProfileSigner from config signer paths.
	Signer ProfileSigner

	// Logger is required; use zerolog.Nop() for tests.
	Logger zerolog.Logger
}

// HandleEnroll is the HTTP handler for POST /v1/enroll.
func (h *EnrollHandler) HandleEnroll(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeJSONError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}

	lr := io.LimitReader(r.Body, maxEnrollBodyBytes+1)
	body, err := io.ReadAll(lr)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "bad_request", "failed to read request body")
		return
	}
	if int64(len(body)) > maxEnrollBodyBytes {
		writeJSONError(w, http.StatusRequestEntityTooLarge, "request_too_large", "body exceeds 4 KiB")
		return
	}

	var req struct {
		SerialNumber string `json:"serial_number"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "bad_request", "invalid json body")
		return
	}

	if req.SerialNumber == "" {
		writeJSONError(w, http.StatusBadRequest, "invalid_request_error", "serial_number is required")
		return
	}
	if !serialNumberRegexp.MatchString(req.SerialNumber) {
		writeJSONError(w, http.StatusBadRequest, "invalid_request_error", "invalid serial number format")
		return
	}

	h.Logger.Info().
		Str("serial_number", req.SerialNumber).
		Msg("generating MDM enrollment profile")

	profileBody := []byte(mdm.GenerateEnrollmentProfile(req.SerialNumber, h.MDMConfig))

	// Optionally CMS-sign the profile. When signing is not configured or
	// fails, serve unsigned — enrollment is never blocked by signing.
	// Failure is logged loudly so operators are alerted.
	if h.Signer != nil {
		signed, err := h.Signer.Sign(profileBody)
		if err != nil {
			h.Logger.Error().
				Str("serial_number", req.SerialNumber).
				Err(err).
				Msg("profile CMS signing failed — serving unsigned profile")
		} else {
			profileBody = signed
		}
	}

	w.Header().Set("Content-Type", "application/x-apple-aspen-config")
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`attachment; filename="macprovider-enroll-%s.mobileconfig"`, req.SerialNumber))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(profileBody)
}

// NewFileProfileSigner loads a PEM cert + key from disk and returns a
// ProfileSigner that CMS-signs profiles using that identity. Supports RSA and
// ECDSA private keys.
//
// Returns an error if either path is empty or the files cannot be loaded.
// Callers should set EnrollHandler.Signer to nil when signer paths are not
// configured.
func NewFileProfileSigner(certPath, keyPath string) (ProfileSigner, error) {
	if certPath == "" || keyPath == "" {
		return nil, fmt.Errorf("mdm profile signer: cert_path and key_path must both be set")
	}
	certPEM, err := os.ReadFile(certPath)
	if err != nil {
		return nil, fmt.Errorf("mdm profile signer: read cert: %w", err)
	}
	keyPEM, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, fmt.Errorf("mdm profile signer: read key: %w", err)
	}
	block, _ := pem.Decode(certPEM)
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, fmt.Errorf("mdm profile signer: cert file does not contain a PEM CERTIFICATE block")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("mdm profile signer: parse cert: %w", err)
	}
	keyBlock, _ := pem.Decode(keyPEM)
	if keyBlock == nil {
		return nil, fmt.Errorf("mdm profile signer: key file does not contain a PEM block")
	}
	var signer crypto.Signer
	switch keyBlock.Type {
	case "RSA PRIVATE KEY":
		rsaKey, err := x509.ParsePKCS1PrivateKey(keyBlock.Bytes)
		if err != nil {
			return nil, fmt.Errorf("mdm profile signer: parse RSA key: %w", err)
		}
		signer = rsaKey
	case "EC PRIVATE KEY":
		ecKey, err := x509.ParseECPrivateKey(keyBlock.Bytes)
		if err != nil {
			return nil, fmt.Errorf("mdm profile signer: parse EC key: %w", err)
		}
		signer = ecKey
	case "PRIVATE KEY":
		key, err := x509.ParsePKCS8PrivateKey(keyBlock.Bytes)
		if err != nil {
			return nil, fmt.Errorf("mdm profile signer: parse PKCS8 key: %w", err)
		}
		switch k := key.(type) {
		case *rsa.PrivateKey:
			signer = k
		case *ecdsa.PrivateKey:
			signer = k
		default:
			return nil, fmt.Errorf("mdm profile signer: unsupported PKCS8 key type %T", key)
		}
	default:
		return nil, fmt.Errorf("mdm profile signer: unsupported PEM key type %q", keyBlock.Type)
	}
	return &fileProfileSigner{cert: cert, key: signer}, nil
}

type fileProfileSigner struct {
	cert *x509.Certificate
	key  crypto.Signer
}

func (s *fileProfileSigner) Sign(profile []byte) ([]byte, error) {
	return mdm.SignMobileconfig(profile, s.cert, s.key)
}
