package shardgroup

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"regexp"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/jcs"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
)

// Registration reason codes (SPEC-051-R029).
const (
	ReasonInvalidRecord               = "invalid_record"
	ReasonSignatureInvalid            = "signature_invalid"
	ReasonNotGroupHeadSession         = "not_group_head_session"
	ReasonEpochNotIncreasing          = "epoch_not_increasing"
	ReasonModeReserved                = "mode_reserved"
	ReasonInterconnectReserved        = "interconnect_reserved"
	ReasonFrameProtectionBelowMinimum = "frame_protection_below_minimum"
	ReasonTransportVersionUnsupported = "transport_version_unsupported"
	ReasonPlacementInvalid            = "placement_invalid"
	ReasonTooManyMembers              = "too_many_members"
	ReasonModelMismatch               = "model_mismatch"
	ReasonMemberConflict              = "member_conflict"
	ReasonOwnerMismatch               = "owner_mismatch"
	ReasonStoreUnavailable            = "store_unavailable"
)

// Interconnect classes and the interface type each requires (SPEC-051-R007).
var interconnectInterface = map[string]string{
	"thunderbolt-ip": "thunderbolt",
	"ethernet":       "ethernet",
}

// frameProtectionRank orders the closed SPEC-051-R011 enum by strength.
var frameProtectionRank = map[string]int{"crc32c": 0, "hmac-sha256": 1, "aead-chacha20poly1305": 2}

var (
	providerIDPattern = regexp.MustCompile(`^[a-zA-Z0-9_.-]{1,64}$`)
	hexDigestPattern  = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

// Config is the coordinator `shard_groups` configuration (SPEC-051 §4).
type Config struct {
	MaxMembers                  int
	MaxLinkRTTP99US             int
	GroupHeartbeatStaleMultiple int
	MinFrameProtection          map[string]string
	SupportedTransportVersions  map[int]bool
}

// ConfigFrom converts the validated coordinator configuration.
func ConfigFrom(c config.ShardGroupsConfig) Config {
	versions := make(map[int]bool, len(c.SupportedTransportVersions))
	for _, v := range c.SupportedTransportVersions {
		versions[v] = true
	}
	return Config{
		MaxMembers:                  c.MaxMembers,
		MaxLinkRTTP99US:             c.MaxLinkRTTP99US,
		GroupHeartbeatStaleMultiple: c.GroupHeartbeatStaleMultiple,
		MinFrameProtection: map[string]string{
			"thunderbolt-ip": c.RequiredFrameProtection.ThunderboltIP,
			"ethernet":       c.RequiredFrameProtection.Ethernet,
		},
		SupportedTransportVersions: versions,
	}
}

// HeadView is what record validation needs from the registering head session.
type HeadView struct {
	ProviderID         string
	ModelID            string
	ModelHashAlgorithm string
	ModelHash          string
	MaxConcurrency     int
}

// ValidateRecord applies SPEC-051-R005/R006/R007/R011 to a parsed record and
// returns "" or the first failing registration reason code.
func ValidateRecord(rec Record, cfg Config, head HeadView) string {
	if rec.Schema != RecordSchema || rec.GroupEpoch < 1 || rec.GroupEpoch > maxJSONInteger {
		return ReasonInvalidRecord
	}
	if rec.GroupProviderID != head.ProviderID {
		return ReasonNotGroupHeadSession
	}
	switch rec.ParallelismMode {
	case "pipeline":
	case "tensor":
		return ReasonModeReserved
	default:
		return ReasonInvalidRecord
	}
	switch rec.InterconnectClass {
	case "thunderbolt-ip", "ethernet":
	case "rdma-tb5":
		return ReasonInterconnectReserved
	default:
		return ReasonInvalidRecord
	}
	rank, ok := frameProtectionRank[rec.FrameProtection]
	if !ok {
		return ReasonInvalidRecord
	}
	if rank < frameProtectionRank[cfg.MinFrameProtection[rec.InterconnectClass]] {
		return ReasonFrameProtectionBelowMinimum
	}
	if !cfg.SupportedTransportVersions[rec.TransportVersion] {
		return ReasonTransportVersionUnsupported
	}
	if reason := validateRecordModel(rec.Model, head); reason != "" {
		return reason
	}
	if rec.NumLayers < 2 || rec.NumLayers > 4096 || rec.MaxConcurrency < 1 || rec.MaxConcurrency > 256 || rec.MaxConcurrency > head.MaxConcurrency {
		return ReasonInvalidRecord
	}
	if !validSupervision(rec.Supervision) {
		return ReasonInvalidRecord
	}
	if reason := validatePlacement(rec); reason != "" {
		return reason
	}
	if len(rec.Stages)+len(rec.Spares) > cfg.MaxMembers {
		return ReasonTooManyMembers
	}
	return ""
}

func validateRecordModel(m RecordModel, head HeadView) string {
	if len(m.ModelID) < 1 || len(m.ModelID) > 256 {
		return ReasonInvalidRecord
	}
	if _, _, ok := poolmanifest.ParsePoolModelID(m.PoolModelID); !ok {
		return ReasonInvalidRecord
	}
	if m.ArtifactHashAlgorithm != poolmanifest.ArtifactHashAlgorithmSnapshotManifestV1 || !hexDigestPattern.MatchString(m.ArtifactHash) {
		return ReasonInvalidRecord
	}
	if m.ModelID != head.ModelID || m.ArtifactHashAlgorithm != head.ModelHashAlgorithm || m.ArtifactHash != head.ModelHash {
		return ReasonModelMismatch
	}
	return ""
}

func validSupervision(s Supervision) bool {
	in := func(v, lo, hi int) bool { return v >= lo && v <= hi }
	return in(s.HeartbeatIntervalMS, 20, 1000) &&
		in(s.HeartbeatMissLimit, 2, 10) &&
		in(s.DecodeHopDeadlineMS, 50, 2000) &&
		in(s.PrefillChunkDeadlineMS, 500, 4000) &&
		in(s.ReplayDeadlineMS, 1000, 30000)
}

// validatePlacement applies SPEC-051-R006: stages 0..S-1 with S >= 2,
// contiguous non-empty layer ranges covering [0, num_layers) exactly once,
// stage 0 held by the group provider identity, each member in one role only,
// and each spare backing an existing non-head stage.
func validatePlacement(rec Record) string {
	if len(rec.Stages) < 2 {
		return ReasonPlacementInvalid
	}
	seen := make(map[string]bool, len(rec.Stages)+len(rec.Spares))
	next := 0
	for i, st := range rec.Stages {
		if st.StageIndex != i || st.LayerStart != next || st.LayerEnd <= st.LayerStart || !providerIDPattern.MatchString(st.MemberDeviceID) || seen[st.MemberDeviceID] {
			return ReasonPlacementInvalid
		}
		seen[st.MemberDeviceID] = true
		next = st.LayerEnd
	}
	if next != rec.NumLayers || rec.Stages[0].MemberDeviceID != rec.GroupProviderID {
		return ReasonPlacementInvalid
	}
	for _, sp := range rec.Spares {
		if sp.StageIndex < 1 || sp.StageIndex >= len(rec.Stages) || !providerIDPattern.MatchString(sp.MemberDeviceID) || seen[sp.MemberDeviceID] {
			return ReasonPlacementInvalid
		}
		seen[sp.MemberDeviceID] = true
	}
	return ""
}

// canonicalSigned returns domain || JCS(raw), with the `signature` key of a
// top-level object removed when withoutSignature is true.
func canonicalSigned(domain string, raw []byte, withoutSignature bool) ([]byte, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	if withoutSignature {
		obj, ok := v.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("shardgroup: signed value is not an object")
		}
		delete(obj, "signature")
	}
	canonical, err := jcs.CanonicalJSONRawStrings(v)
	if err != nil {
		return nil, err
	}
	return append([]byte(domain), canonical...), nil
}

// verifySignature checks a base64 Ed25519 signature by pub over message.
func verifySignature(pub []byte, signatureB64 string, message []byte) bool {
	if len(pub) != ed25519.PublicKeySize {
		return false
	}
	sig, err := base64.StdEncoding.Strict().DecodeString(signatureB64)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return false
	}
	return ed25519.Verify(ed25519.PublicKey(pub), message, sig)
}

// VerifyRecordSignature checks `record_signature` against the head session's
// receipt key over the record domain and the JCS bytes of the record.
func VerifyRecordSignature(recordRaw []byte, signatureB64 string, headReceiptKey []byte) bool {
	message, err := canonicalSigned(recordDomain, recordRaw, false)
	if err != nil {
		return false
	}
	return verifySignature(headReceiptKey, signatureB64, message)
}

// RecordDigest is the hex SHA-256 of a record's JCS bytes; equal digests mean
// an identical re-registration.
func RecordDigest(recordRaw []byte) (string, error) {
	message, err := canonicalSigned("", recordRaw, false)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(message)
	return hex.EncodeToString(sum[:]), nil
}

// RequiredInterface is the interface type a record's interconnect requires.
func RequiredInterface(interconnectClass string) string {
	return interconnectInterface[interconnectClass]
}

// MemberIDs lists the record's non-head stage members followed by its spares.
func (r Record) MemberIDs() []string {
	out := make([]string, 0, len(r.Stages)+len(r.Spares))
	for _, st := range r.Stages[1:] {
		out = append(out, st.MemberDeviceID)
	}
	for _, sp := range r.Spares {
		out = append(out, sp.MemberDeviceID)
	}
	return out
}

// role returns a member's role and stage in the record.
func (r Record) role(memberID string) (role string, stage int, ok bool) {
	for _, st := range r.Stages {
		if st.MemberDeviceID == memberID {
			return "stage", st.StageIndex, true
		}
	}
	for _, sp := range r.Spares {
		if sp.MemberDeviceID == memberID {
			return "spare", sp.StageIndex, true
		}
	}
	return "", 0, false
}

// requiredLinks lists the SPEC-051-R029 heartbeat links of a record as
// from->to member pairs: stage i to i+1, the last stage to stage 0, and stage
// 0 to each spare.
func (r Record) requiredLinks() [][2]string {
	var out [][2]string
	for i := 0; i+1 < len(r.Stages); i++ {
		out = append(out, [2]string{r.Stages[i].MemberDeviceID, r.Stages[i+1].MemberDeviceID})
	}
	out = append(out, [2]string{r.Stages[len(r.Stages)-1].MemberDeviceID, r.Stages[0].MemberDeviceID})
	for _, sp := range r.Spares {
		out = append(out, [2]string{r.Stages[0].MemberDeviceID, sp.MemberDeviceID})
	}
	return out
}

// memberLinkPeers lists the peers whose links a member's hello must report:
// a stage's upstream and downstream neighbours (the last stage's downstream
// neighbour is stage 0), and a spare's link to stage 0.
func (r Record) memberLinkPeers(memberID string) []string {
	role, stage, ok := r.role(memberID)
	if !ok {
		return nil
	}
	if role == "spare" {
		return []string{r.Stages[0].MemberDeviceID}
	}
	s := len(r.Stages)
	up := r.Stages[(stage-1+s)%s].MemberDeviceID
	down := r.Stages[(stage+1)%s].MemberDeviceID
	if up == down {
		return []string{up}
	}
	return []string{up, down}
}
