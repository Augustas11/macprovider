package shardgroup

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"strings"
)

// Attestation fault kinds (SPEC-051-R019). A verdict with an empty kind is a
// verified attestation.
const (
	FaultMissing          = "attestation_missing"
	FaultMalformed        = "attestation_malformed"
	FaultReceiptMismatch  = "receipt_mismatch"
	FaultHeadSignature    = "head_signature_invalid"
	FaultSegments         = "segments_invalid"
	FaultUnknownEpoch     = "epoch_unknown"
	FaultStageMismatch    = "stage_mismatch"
	FaultKeyMismatch      = "key_mismatch"
	FaultMemberSignature  = "member_signature_invalid"
	FaultDigestChainBreak = "digest_chain_break"
)

// Attestation is the SPEC-051-R019 group attestation object.
type Attestation struct {
	Schema             string               `json:"schema"`
	GroupProviderID    string               `json:"group_provider_id"`
	RequestID          string               `json:"request_id"`
	AttemptN           int                  `json:"attempt_n"`
	ReceiptTupleSHA256 string               `json:"receipt_tuple_sha256"`
	Segments           []AttestationSegment `json:"segments"`
	Signature          string               `json:"signature"`
}

// AttestationSegment is one epoch's chain over a contiguous step range.
type AttestationSegment struct {
	GroupEpoch  uint64             `json:"group_epoch"`
	StepStart   int                `json:"step_start"`
	StepEnd     int                `json:"step_end"`
	SubReceipts []SignedSubReceipt `json:"sub_receipts"`
}

// SignedSubReceipt is one member's signed account of one request.
type SignedSubReceipt struct {
	SubReceipt SubReceipt `json:"sub_receipt"`
	PublicKey  string     `json:"public_key"`
	Signature  string     `json:"signature"`
}

// SubReceipt is the SPEC-051-R019 per-member sub-receipt.
type SubReceipt struct {
	MemberDeviceID string `json:"member_device_id"`
	GroupEpoch     uint64 `json:"group_epoch"`
	StageIndex     int    `json:"stage_index"`
	LayerStart     int    `json:"layer_start"`
	LayerEnd       int    `json:"layer_end"`
	RequestID      string `json:"request_id"`
	PromptTokens   int    `json:"prompt_tokens"`
	DecodeSteps    int    `json:"decode_steps"`
	InDigest       string `json:"in_digest"`
	OutDigest      string `json:"out_digest"`
}

// EpochKeys is one accepted epoch's record with the receipt key (base64 of the
// raw Ed25519 key) bound to each active stage: stage 0 the head's, any other
// the key its member session carried when its hello was accepted.
type EpochKeys struct {
	Record    Record
	StageKeys map[int]string
}

// Verdict is the outcome of verifying one attestation.
type Verdict struct {
	FaultKind           string
	FaultMemberDeviceID string
	ReceiptTupleSHA256  string
	// RequestID and AttemptN are the receipt tuple's, so a verdict is keyed
	// by the attempt the receipt names even when the attestation is absent.
	RequestID   string
	AttemptN    int
	GroupEpochs []uint64
}

// Verified reports whether the attestation passed every check.
func (v Verdict) Verified() bool { return v.FaultKind == "" }

// receiptTupleFacts are the receipt tuple members the attestation binds.
type receiptTupleFacts struct {
	RequestID  string `json:"request_id"`
	AttemptN   int    `json:"attempt_n"`
	ProviderID string `json:"provider_id"`
}

// ReceiptTupleSHA256 returns the hex SHA-256 of a SPEC-015 v0.4 receipt
// envelope's tuple bytes (`base64(tuple).base64(sig)`) and the tuple facts
// the attestation binds.
func receiptTuple(envelope string) (string, receiptTupleFacts, bool) {
	dot := strings.IndexByte(envelope, '.')
	if dot <= 0 {
		return "", receiptTupleFacts{}, false
	}
	tuple, err := base64.StdEncoding.DecodeString(envelope[:dot])
	if err != nil {
		return "", receiptTupleFacts{}, false
	}
	var facts receiptTupleFacts
	if err := json.Unmarshal(tuple, &facts); err != nil {
		return "", receiptTupleFacts{}, false
	}
	sum := sha256.Sum256(tuple)
	return hex.EncodeToString(sum[:]), facts, true
}

// VerifyAttestation applies SPEC-051-R019 to the attestation a head session
// sent with a receipt. headKey is the head session's raw receipt key and
// epochs returns an accepted epoch of this group with its bound stage keys.
func VerifyAttestation(raw json.RawMessage, receiptEnvelope, groupProviderID string, headKey []byte, epochs func(uint64) (EpochKeys, bool)) Verdict {
	tupleSHA, facts, ok := receiptTuple(receiptEnvelope)
	if !ok {
		return Verdict{FaultKind: FaultReceiptMismatch, FaultMemberDeviceID: groupProviderID}
	}
	verdict := Verdict{ReceiptTupleSHA256: tupleSHA, RequestID: facts.RequestID, AttemptN: facts.AttemptN}
	fail := func(kind, member string) Verdict {
		verdict.FaultKind, verdict.FaultMemberDeviceID = kind, member
		return verdict
	}
	if len(bytes.TrimSpace(raw)) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return fail(FaultMissing, groupProviderID)
	}
	var att Attestation
	if err := decodeStrict(raw, &att); err != nil || att.Schema != AttestationSchema {
		return fail(FaultMalformed, groupProviderID)
	}
	if att.GroupProviderID != groupProviderID || facts.ProviderID != groupProviderID ||
		att.RequestID != facts.RequestID || att.AttemptN != facts.AttemptN || att.ReceiptTupleSHA256 != tupleSHA {
		return fail(FaultReceiptMismatch, groupProviderID)
	}
	headMessage, err := canonicalSigned(attestationDomain, raw, true)
	if err != nil || !verifySignature(headKey, att.Signature, headMessage) {
		return fail(FaultHeadSignature, groupProviderID)
	}
	if len(att.Segments) == 0 {
		return fail(FaultSegments, groupProviderID)
	}
	headKeyB64 := base64.StdEncoding.EncodeToString(headKey)
	nextStep := 0
	var lastEpoch uint64
	for i, seg := range att.Segments {
		if seg.StepStart != nextStep || seg.StepEnd < seg.StepStart || (len(att.Segments) > 1 && seg.StepEnd == seg.StepStart) ||
			(i > 0 && seg.GroupEpoch <= lastEpoch) {
			return fail(FaultSegments, groupProviderID)
		}
		nextStep, lastEpoch = seg.StepEnd, seg.GroupEpoch
		epoch, ok := epochs(seg.GroupEpoch)
		if !ok {
			return fail(FaultUnknownEpoch, groupProviderID)
		}
		verdict.GroupEpochs = append(verdict.GroupEpochs, seg.GroupEpoch)
		if kind, member := verifySegment(seg, epoch, att.RequestID, headKeyB64); kind != "" {
			return fail(kind, member)
		}
	}
	return verdict
}

// verifySegment checks one epoch's sub-receipts against that epoch's record
// and bound keys, then the digest chain, naming the first faulty member.
func verifySegment(seg AttestationSegment, epoch EpochKeys, requestID, headKeyB64 string) (string, string) {
	stages := epoch.Record.Stages
	if len(seg.SubReceipts) != len(stages) {
		return FaultStageMismatch, epoch.Record.GroupProviderID
	}
	for i, signed := range seg.SubReceipts {
		sr, st := signed.SubReceipt, stages[i]
		if sr.StageIndex != i || sr.MemberDeviceID != st.MemberDeviceID || sr.GroupEpoch != seg.GroupEpoch ||
			sr.LayerStart != st.LayerStart || sr.LayerEnd != st.LayerEnd || sr.RequestID != requestID ||
			!hexDigestPattern.MatchString(sr.InDigest) || !hexDigestPattern.MatchString(sr.OutDigest) {
			return FaultStageMismatch, st.MemberDeviceID
		}
		want := epoch.StageKeys[i]
		if i == 0 {
			want = headKeyB64
		}
		if want == "" || signed.PublicKey != want {
			return FaultKeyMismatch, st.MemberDeviceID
		}
		key, err := base64.StdEncoding.Strict().DecodeString(signed.PublicKey)
		if err != nil {
			return FaultKeyMismatch, st.MemberDeviceID
		}
		body, err := json.Marshal(sr)
		if err != nil {
			return FaultMemberSignature, st.MemberDeviceID
		}
		message, err := canonicalSigned(subReceiptDomain, body, false)
		if err != nil || !verifySignature(key, signed.Signature, message) {
			return FaultMemberSignature, st.MemberDeviceID
		}
	}
	// SPEC-051-R019: out_digest of stage i equals in_digest of stage i+1,
	// and the last stage's token out_digest equals the head's in_digest.
	// The fault is the downstream member of the first broken link.
	for i := 0; i+1 < len(seg.SubReceipts); i++ {
		if seg.SubReceipts[i].SubReceipt.OutDigest != seg.SubReceipts[i+1].SubReceipt.InDigest {
			return FaultDigestChainBreak, seg.SubReceipts[i+1].SubReceipt.MemberDeviceID
		}
	}
	last := seg.SubReceipts[len(seg.SubReceipts)-1].SubReceipt
	if last.OutDigest != seg.SubReceipts[0].SubReceipt.InDigest {
		return FaultDigestChainBreak, seg.SubReceipts[0].SubReceipt.MemberDeviceID
	}
	return "", ""
}
