package sourceevidence

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"regexp"
	"runtime/debug"
	"strings"
	"time"
)

const (
	EnvelopeSchema = "macprovider.source-authenticated-export-envelope.v1"
	SignedSchema   = "macprovider.source-authenticated-export.v1"
	SnapshotSchema = "macprovider.coordinator-source-snapshot.v1"
	RecordSchema   = "macprovider.coordinator-no-dispatch-record.v1"
	RequestSchema  = "macprovider.coordinator-source-export-request.v1"

	ProducerName = "coordinator"
	ProducerRole = "no_dispatch_refusal"
	SignDomain   = "macprovider.source-authenticated-export.v1"

	TerminalModelNotFound   = "model_not_found_no_dispatch"
	TerminalPoolUnavailable = "pool_unavailable_no_dispatch"
	StatusClosedTerminal    = "closed_terminal"
	StatusSnapshotOnly      = "snapshot_only_non_promotable"
	StatusMissingRequestLog = "missing_request_log"
	StatusAmbiguousIdentity = "ambiguous_request_identity"
	StatusPendingOrUnclosed = "pending_or_unclosed"
	StatusStaleScopeFence   = "stale_scope_fence"
	StatusPrivacyViolation  = "privacy_redaction_violation"
	StatusClosureMismatch   = "closure_mismatch"
	StatusSourceUnavailable = "source_unavailable"

	ContractVersion  = "coordinator-no-dispatch-v1"
	ClosureSchema    = "coordinator_source_no_dispatch_closures.v1"
	FenceSchema      = "coordinator_source_no_dispatch_fence.v1"
	Canonicalization = "ascii-jcs-subset-v1"
	ScopeHMAC        = "hmac-sha256-length-prefixed-v1"
)

var (
	ErrDisabled          = errors.New("source evidence disabled")
	ErrUnavailable       = errors.New("source evidence unavailable")
	ErrScopeNotClosed    = errors.New("source evidence scope is not closed")
	ErrInvalidRequest    = errors.New("invalid source evidence request")
	ErrProvenanceMissing = errors.New("source evidence provenance missing")

	hex64RE = regexp.MustCompile(`^[0-9a-f]{64}$`)
	hex40RE = regexp.MustCompile(`^[0-9a-f]{40}$`)
)

type Config struct {
	Enabled               bool
	SigningPrivateKeyPath string
	ScopeHMACKeyPath      string
	MaxScopes             int
	MaxBodyBytes          int64
}

type FixedProvenance struct {
	InstanceID           string
	SourceSHA            string
	KeyID                string
	ReviewedRegistryPath string
	RegistryDigest       string
	Now                  func() time.Time
}

func (p FixedProvenance) validate() error {
	if strings.TrimSpace(p.InstanceID) == "" || strings.TrimSpace(p.KeyID) == "" || strings.TrimSpace(p.ReviewedRegistryPath) == "" {
		return ErrProvenanceMissing
	}
	if !hex40RE.MatchString(p.SourceSHA) {
		return fmt.Errorf("%w: immutable source sha missing", ErrProvenanceMissing)
	}
	if !strings.HasPrefix(p.RegistryDigest, "sha256:") || !hex64RE.MatchString(strings.TrimPrefix(p.RegistryDigest, "sha256:")) {
		return fmt.Errorf("%w: reviewed registry digest missing", ErrProvenanceMissing)
	}
	return nil
}

// DefaultFixedProvenance deliberately has no production pins in this source
// slice. Enabling the endpoint without a reviewed release wiring fails closed.
func DefaultFixedProvenance() FixedProvenance {
	return FixedProvenance{SourceSHA: cleanVCSRevision()}
}

func cleanVCSRevision() string {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return ""
	}
	var revision string
	clean := true
	for _, setting := range info.Settings {
		switch setting.Key {
		case "vcs.revision":
			revision = setting.Value
		case "vcs.modified":
			clean = setting.Value != "true"
		}
	}
	if !clean || !hex40RE.MatchString(revision) {
		return ""
	}
	return revision
}

type Scope struct {
	AccountID                 string `json:"account_id"`
	ExternalRequestID         string `json:"external_request_id"`
	RequiredInternalRequestID string `json:"required_internal_request_id"`
	NotBeforeUnixMS           int64  `json:"not_before_unix_ms"`
}

func ScopeCommitment(key []byte, scope Scope) string {
	return hmacHex(key, "macprovider.coordinator-source.request-scope.v1\n", scope.AccountID, scope.ExternalRequestID, scope.RequiredInternalRequestID)
}

func InternalRequestCommitment(key []byte, requestID string) string {
	return hmacHex(key, "macprovider.coordinator-source.internal-request.v1\n", requestID)
}

func ClosureIDCommitment(key []byte, id int64) string {
	return hmacHex(key, "macprovider.coordinator-source.closure-id.v1\n", fmt.Sprintf("%d", id))
}

func hmacHex(key []byte, domain string, parts ...string) string {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(domain))
	var lenbuf [4]byte
	for _, part := range parts {
		binary.BigEndian.PutUint32(lenbuf[:], uint32(len(part)))
		mac.Write(lenbuf[:])
		mac.Write([]byte(part))
	}
	return hex.EncodeToString(mac.Sum(nil))
}

func utcMillis(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05.000Z")
}
