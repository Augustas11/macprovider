package ws

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"time"
)

const (
	nativeMTPCanaryProfile              = "native_mtp_canary_v1"
	nativeMTPChallengeBankSchemaVersion = "macprovider.native-mtp-challenge-bank.v1"
	nativeMTPChallengeBankMaxEntries    = 256
	nativeMTPCanaryMaxPromptBytes       = 8 * 1024
	nativeMTPCanaryMaxPromptTokens      = 2048
	nativeMTPCanaryMaxCompletionTokens  = 64
	nativeMTPCanaryMinDepth             = 1
	nativeMTPCanaryMaxDepth             = 16
	nativeMTPCanaryDeadline             = 60 * time.Second
	nativeMTPCanaryDefaultInterval      = time.Hour
	nativeMTPCanaryMinimumInterval      = 15 * time.Minute
)

var (
	errNativeMTPChallengeBankInvalid = errors.New("invalid native MTP challenge bank")
	errNativeMTPCanaryInvalidTuple   = errors.New("invalid native MTP canary tuple")
	errNativeMTPCanaryInFlight       = errors.New("native MTP canary already in flight for tuple")
	errNativeMTPCanaryReplay         = errors.New("native MTP canary replay")
)

type NativeMTPCanaryTupleKey struct {
	ProviderID          string
	AssignedID          string
	TargetGeneration    uint64
	RuntimeTupleSHA256  string
	ChallengeBankSHA256 string
}

func (k NativeMTPCanaryTupleKey) valid() bool {
	return boundedPrintable(k.ProviderID, 1, 256) &&
		boundedPrintable(k.AssignedID, 1, 256) &&
		k.TargetGeneration > 0 &&
		isLowerHex64(k.RuntimeTupleSHA256) &&
		isLowerHex64(k.ChallengeBankSHA256)
}

func (k NativeMTPCanaryTupleKey) storeKey() string {
	return k.ProviderID + "\x00" + k.AssignedID + "\x00" + strconv.FormatUint(k.TargetGeneration, 10) + "\x00" + k.RuntimeTupleSHA256
}

type NativeMTPChallengeBankBinding struct {
	ReleaseID          string
	SidecarValidFrom   time.Time
	SidecarValidUntil  time.Time
	SignerKeyID        string
	EnvelopeKeyID      string
	ExpectedSHA256     string
	AdmissionModelID   string
	AdmissionModelHash string
}

type NativeMTPChallengeBank struct {
	SchemaVersion string
	ReleaseID     string
	IssuedAt      time.Time
	ExpiresAt     time.Time
	SignerKeyID   string
	Entries       []NativeMTPChallengeRecord
	RawSHA256     string
}

type NativeMTPChallengeRecord struct {
	ChallengeID                  string
	ModelID                      string
	ModelHash                    string
	TokenizerSHA256              string
	ArtifactSHA256               string
	MTPManifestSHA256            string
	PromptTokenIDs               []uint32
	MaxCompletionTokens          uint32
	FixedProposalDepth           uint32
	ExpectedTokenIDs             []uint32
	ExpectedTokenIDSHA256        string
	ExpectedTerminalReason       string
	ExpectedCounters             NativeMTPCanaryExpectedCounters
	ExpectedCommittedStateSHA256 string
}

type NativeMTPCanaryExpectedCounters struct {
	Accepted  uint64 `json:"accepted"`
	Rejected  uint64 `json:"rejected"`
	Bonus     uint64 `json:"bonus"`
	Committed uint64 `json:"committed"`
}

type NativeMTPCanaryCoreRequest struct {
	Profile                string
	ProviderID             string
	AssignedID             string
	TargetGeneration       uint64
	RuntimeTupleSHA256     string
	ChallengeBankSHA256    string
	ChallengeID            string
	Nonce                  string
	IssuedAt               time.Time
	ExpiresAt              time.Time
	PromptTokenIDs         []uint32
	MaxCompletionTokens    uint32
	FixedProposalDepth     uint32
	ExpectedTokenIDSHA256  string
	ExpectedTerminalReason string
	ExpectedCounters       NativeMTPCanaryExpectedCounters
	RequestDigestSHA256    string
}

type NativeMTPCanaryCoreResult struct {
	Profile                    string
	ProviderID                 string
	AssignedID                 string
	TargetGeneration           uint64
	RuntimeTupleSHA256         string
	ChallengeBankSHA256        string
	ChallengeID                string
	Nonce                      string
	RequestDigestSHA256        string
	ActualDecodePath           string
	FallbackUsed               bool
	CapacityUnavailable        bool
	ActualTokenIDSHA256        string
	ActualTerminalReason       string
	ActualCounters             NativeMTPCanaryExpectedCounters
	ActualCommittedStateSHA256 string
	ResultDigestSHA256         string
}

type nativeMTPCanaryRequestDigestObject struct {
	Profile                string                          `json:"profile"`
	ProviderID             string                          `json:"provider_id"`
	AssignedID             string                          `json:"assigned_id"`
	TargetGeneration       uint64                          `json:"target_generation"`
	RuntimeTupleSHA256     string                          `json:"runtime_tuple_sha256"`
	ChallengeBankSHA256    string                          `json:"challenge_bank_sha256"`
	ChallengeID            string                          `json:"challenge_id"`
	Nonce                  string                          `json:"nonce"`
	IssuedAt               string                          `json:"issued_at"`
	ExpiresAt              string                          `json:"expires_at"`
	PromptTokenIDs         []uint32                        `json:"prompt_token_ids"`
	MaxCompletionTokens    uint32                          `json:"max_completion_tokens"`
	FixedProposalDepth     uint32                          `json:"fixed_proposal_depth"`
	ExpectedTokenIDSHA256  string                          `json:"expected_token_id_sha256"`
	ExpectedTerminalReason string                          `json:"expected_terminal_reason"`
	ExpectedCounters       NativeMTPCanaryExpectedCounters `json:"expected_counters"`
}

type nativeMTPCanaryResultDigestObject struct {
	Profile                    string                          `json:"profile"`
	ProviderID                 string                          `json:"provider_id"`
	AssignedID                 string                          `json:"assigned_id"`
	TargetGeneration           uint64                          `json:"target_generation"`
	RuntimeTupleSHA256         string                          `json:"runtime_tuple_sha256"`
	ChallengeBankSHA256        string                          `json:"challenge_bank_sha256"`
	ChallengeID                string                          `json:"challenge_id"`
	Nonce                      string                          `json:"nonce"`
	RequestDigestSHA256        string                          `json:"request_digest_sha256"`
	CapacityUnavailable        bool                            `json:"capacity_unavailable"`
	ActualDecodePath           string                          `json:"actual_decode_path"`
	FallbackUsed               bool                            `json:"fallback_used"`
	ActualTokenIDSHA256        string                          `json:"actual_token_id_sha256"`
	ActualTerminalReason       string                          `json:"actual_terminal_reason"`
	ActualCounters             NativeMTPCanaryExpectedCounters `json:"actual_counters"`
	ActualCommittedStateSHA256 string                          `json:"actual_committed_state_sha256"`
}

type NativeMTPCanaryOutcome string

const (
	NativeMTPCanaryPass         NativeMTPCanaryOutcome = "pass"
	NativeMTPCanaryFail         NativeMTPCanaryOutcome = "fail"
	NativeMTPCanaryInconclusive NativeMTPCanaryOutcome = "inconclusive"
	NativeMTPCanaryReschedule   NativeMTPCanaryOutcome = "reschedule"
)

type NativeMTPCanaryEvaluation struct {
	Outcome          NativeMTPCanaryOutcome
	Reason           string
	DisableTupleOnly bool
	TrustSemantics   string
}

func ParseNativeMTPChallengeBank(raw []byte, binding NativeMTPChallengeBankBinding) (NativeMTPChallengeBank, error) {
	if len(raw) == 0 {
		return NativeMTPChallengeBank{}, fmt.Errorf("%w: empty", errNativeMTPChallengeBankInvalid)
	}
	sum := sha256.Sum256(raw)
	actualSHA := hex.EncodeToString(sum[:])
	if binding.ExpectedSHA256 != "" && binding.ExpectedSHA256 != actualSHA {
		return NativeMTPChallengeBank{}, fmt.Errorf("%w: digest mismatch", errNativeMTPChallengeBankInvalid)
	}
	if binding.SignerKeyID == "" || binding.EnvelopeKeyID != binding.SignerKeyID {
		return NativeMTPChallengeBank{}, fmt.Errorf("%w: signer mismatch", errNativeMTPChallengeBankInvalid)
	}

	var top map[string]json.RawMessage
	if err := strictObject(raw, []string{"schema_version", "release_id", "issued_at", "expires_at", "signer_key_id", "entries"}, &top); err != nil {
		return NativeMTPChallengeBank{}, fmt.Errorf("%w: %v", errNativeMTPChallengeBankInvalid, err)
	}
	schema, err := stringField(top, "schema_version")
	if err != nil || schema != nativeMTPChallengeBankSchemaVersion {
		return NativeMTPChallengeBank{}, fmt.Errorf("%w: schema_version", errNativeMTPChallengeBankInvalid)
	}
	releaseID, err := stringField(top, "release_id")
	if err != nil || releaseID == "" || (binding.ReleaseID != "" && releaseID != binding.ReleaseID) {
		return NativeMTPChallengeBank{}, fmt.Errorf("%w: release_id", errNativeMTPChallengeBankInvalid)
	}
	signerKeyID, err := stringField(top, "signer_key_id")
	if err != nil || signerKeyID != binding.SignerKeyID {
		return NativeMTPChallengeBank{}, fmt.Errorf("%w: signer_key_id", errNativeMTPChallengeBankInvalid)
	}
	issuedAt, err := utcSecondField(top, "issued_at")
	if err != nil {
		return NativeMTPChallengeBank{}, fmt.Errorf("%w: issued_at", errNativeMTPChallengeBankInvalid)
	}
	expiresAt, err := utcSecondField(top, "expires_at")
	if err != nil || !expiresAt.After(issuedAt) {
		return NativeMTPChallengeBank{}, fmt.Errorf("%w: expires_at", errNativeMTPChallengeBankInvalid)
	}
	if !binding.SidecarValidFrom.IsZero() && issuedAt.Before(binding.SidecarValidFrom) {
		return NativeMTPChallengeBank{}, fmt.Errorf("%w: issued before sidecar", errNativeMTPChallengeBankInvalid)
	}
	if !binding.SidecarValidUntil.IsZero() && expiresAt.After(binding.SidecarValidUntil) {
		return NativeMTPChallengeBank{}, fmt.Errorf("%w: expires after sidecar", errNativeMTPChallengeBankInvalid)
	}

	var entryRaw []json.RawMessage
	if err := json.Unmarshal(top["entries"], &entryRaw); err != nil || len(entryRaw) == 0 || len(entryRaw) > nativeMTPChallengeBankMaxEntries {
		return NativeMTPChallengeBank{}, fmt.Errorf("%w: entries", errNativeMTPChallengeBankInvalid)
	}
	entries := make([]NativeMTPChallengeRecord, 0, len(entryRaw))
	seen := make(map[string]struct{}, len(entryRaw))
	lastID := ""
	for _, rawEntry := range entryRaw {
		record, err := parseNativeMTPChallengeRecord(rawEntry, binding)
		if err != nil {
			return NativeMTPChallengeBank{}, err
		}
		if _, ok := seen[record.ChallengeID]; ok || (lastID != "" && record.ChallengeID <= lastID) {
			return NativeMTPChallengeBank{}, fmt.Errorf("%w: duplicate or unsorted challenge_id", errNativeMTPChallengeBankInvalid)
		}
		seen[record.ChallengeID] = struct{}{}
		lastID = record.ChallengeID
		entries = append(entries, record)
	}
	return NativeMTPChallengeBank{
		SchemaVersion: schema,
		ReleaseID:     releaseID,
		IssuedAt:      issuedAt,
		ExpiresAt:     expiresAt,
		SignerKeyID:   signerKeyID,
		Entries:       entries,
		RawSHA256:     actualSHA,
	}, nil
}

func (b NativeMTPChallengeBank) Record(challengeID string) (NativeMTPChallengeRecord, bool) {
	for _, record := range b.Entries {
		if record.ChallengeID == challengeID {
			return record, true
		}
	}
	return NativeMTPChallengeRecord{}, false
}

func NewNativeMTPCanaryCoreRequest(tuple NativeMTPCanaryTupleKey, record NativeMTPChallengeRecord, now time.Time) (NativeMTPCanaryCoreRequest, error) {
	nonceBytes := make([]byte, 16)
	if _, err := rand.Read(nonceBytes); err != nil {
		return NativeMTPCanaryCoreRequest{}, err
	}
	return NewNativeMTPCanaryCoreRequestWithNonce(tuple, record, hex.EncodeToString(nonceBytes), now)
}

func NewNativeMTPCanaryCoreRequestWithNonce(tuple NativeMTPCanaryTupleKey, record NativeMTPChallengeRecord, nonce string, now time.Time) (NativeMTPCanaryCoreRequest, error) {
	if !tuple.valid() {
		return NativeMTPCanaryCoreRequest{}, errNativeMTPCanaryInvalidTuple
	}
	if !isLowerHexN(nonce, 32) {
		return NativeMTPCanaryCoreRequest{}, fmt.Errorf("%w: invalid nonce", errNativeMTPCanaryInvalidTuple)
	}
	req := NativeMTPCanaryCoreRequest{
		Profile:                nativeMTPCanaryProfile,
		ProviderID:             tuple.ProviderID,
		AssignedID:             tuple.AssignedID,
		TargetGeneration:       tuple.TargetGeneration,
		RuntimeTupleSHA256:     tuple.RuntimeTupleSHA256,
		ChallengeBankSHA256:    tuple.ChallengeBankSHA256,
		ChallengeID:            record.ChallengeID,
		Nonce:                  nonce,
		IssuedAt:               now.UTC(),
		ExpiresAt:              now.UTC().Add(nativeMTPCanaryDeadline),
		PromptTokenIDs:         append([]uint32(nil), record.PromptTokenIDs...),
		MaxCompletionTokens:    record.MaxCompletionTokens,
		FixedProposalDepth:     record.FixedProposalDepth,
		ExpectedTokenIDSHA256:  record.ExpectedTokenIDSHA256,
		ExpectedTerminalReason: record.ExpectedTerminalReason,
		ExpectedCounters:       record.ExpectedCounters,
	}
	req.RequestDigestSHA256 = digestCanonicalJSON(req.digestObject())
	return req, nil
}

func EvaluateNativeMTPCanaryCoreResult(req NativeMTPCanaryCoreRequest, record NativeMTPChallengeRecord, result NativeMTPCanaryCoreResult, now time.Time) NativeMTPCanaryEvaluation {
	if now.After(req.ExpiresAt) {
		return NativeMTPCanaryEvaluation{Outcome: NativeMTPCanaryFail, Reason: "expired_result", DisableTupleOnly: true, TrustSemantics: "observe_only"}
	}
	if result.Profile != nativeMTPCanaryProfile ||
		result.ProviderID != req.ProviderID ||
		result.AssignedID != req.AssignedID ||
		result.TargetGeneration != req.TargetGeneration ||
		result.RuntimeTupleSHA256 != req.RuntimeTupleSHA256 ||
		result.ChallengeBankSHA256 != req.ChallengeBankSHA256 ||
		result.ChallengeID != req.ChallengeID ||
		result.Nonce != req.Nonce ||
		result.RequestDigestSHA256 != req.RequestDigestSHA256 {
		return NativeMTPCanaryEvaluation{Outcome: NativeMTPCanaryFail, Reason: "binding_mismatch", DisableTupleOnly: true, TrustSemantics: "observe_only"}
	}
	if result.ResultDigestSHA256 == "" || result.ResultDigestSHA256 != digestCanonicalJSON(result.digestObject()) {
		return NativeMTPCanaryEvaluation{Outcome: NativeMTPCanaryFail, Reason: "result_digest_mismatch", DisableTupleOnly: true, TrustSemantics: "observe_only"}
	}
	if result.CapacityUnavailable {
		return NativeMTPCanaryEvaluation{Outcome: NativeMTPCanaryReschedule, Reason: "capacity_unavailable", TrustSemantics: "observe_only"}
	}
	if result.ActualDecodePath != "native_mtp" || result.FallbackUsed {
		return NativeMTPCanaryEvaluation{Outcome: NativeMTPCanaryFail, Reason: "unsupported_path_fallback", DisableTupleOnly: true, TrustSemantics: "observe_only"}
	}
	if result.ActualTokenIDSHA256 != record.ExpectedTokenIDSHA256 ||
		result.ActualTerminalReason != record.ExpectedTerminalReason ||
		result.ActualCounters != record.ExpectedCounters ||
		result.ActualCommittedStateSHA256 != record.ExpectedCommittedStateSHA256 {
		return NativeMTPCanaryEvaluation{Outcome: NativeMTPCanaryFail, Reason: "expected_value_mismatch", DisableTupleOnly: true, TrustSemantics: "observe_only"}
	}
	return NativeMTPCanaryEvaluation{Outcome: NativeMTPCanaryPass, Reason: "passed", TrustSemantics: "observe_only"}
}

func NativeMTPCanaryInterval(configured time.Duration) time.Duration {
	if configured <= 0 {
		return nativeMTPCanaryDefaultInterval
	}
	if configured < nativeMTPCanaryMinimumInterval {
		return nativeMTPCanaryMinimumInterval
	}
	return configured
}

func parseNativeMTPChallengeRecord(raw json.RawMessage, binding NativeMTPChallengeBankBinding) (NativeMTPChallengeRecord, error) {
	var obj map[string]json.RawMessage
	keys := []string{
		"challenge_id", "model_id", "model_hash", "tokenizer_sha256", "artifact_sha256",
		"mtp_manifest_sha256", "prompt_token_ids", "max_completion_tokens",
		"fixed_proposal_depth", "expected_token_ids", "expected_token_id_sha256",
		"expected_terminal_reason", "expected_counters", "expected_committed_state_sha256",
	}
	if err := strictObject(raw, keys, &obj); err != nil {
		return NativeMTPChallengeRecord{}, fmt.Errorf("%w: record %v", errNativeMTPChallengeBankInvalid, err)
	}
	record := NativeMTPChallengeRecord{}
	var err error
	record.ChallengeID, err = stringField(obj, "challenge_id")
	if err != nil || !boundedPrintable(record.ChallengeID, 1, 128) {
		return NativeMTPChallengeRecord{}, fmt.Errorf("%w: challenge_id", errNativeMTPChallengeBankInvalid)
	}
	record.ModelID, err = stringField(obj, "model_id")
	if err != nil || !boundedPrintable(record.ModelID, 1, 256) || (binding.AdmissionModelID != "" && record.ModelID != binding.AdmissionModelID) {
		return NativeMTPChallengeRecord{}, fmt.Errorf("%w: model_id", errNativeMTPChallengeBankInvalid)
	}
	record.ModelHash, err = stringField(obj, "model_hash")
	if err != nil || !isLowerHex64(record.ModelHash) || (binding.AdmissionModelHash != "" && record.ModelHash != binding.AdmissionModelHash) {
		return NativeMTPChallengeRecord{}, fmt.Errorf("%w: model_hash", errNativeMTPChallengeBankInvalid)
	}
	for _, field := range []struct {
		name string
		dst  *string
	}{
		{"tokenizer_sha256", &record.TokenizerSHA256},
		{"artifact_sha256", &record.ArtifactSHA256},
		{"mtp_manifest_sha256", &record.MTPManifestSHA256},
		{"expected_token_id_sha256", &record.ExpectedTokenIDSHA256},
		{"expected_committed_state_sha256", &record.ExpectedCommittedStateSHA256},
	} {
		*field.dst, err = stringField(obj, field.name)
		if err != nil || !isLowerHex64(*field.dst) {
			return NativeMTPChallengeRecord{}, fmt.Errorf("%w: %s", errNativeMTPChallengeBankInvalid, field.name)
		}
	}
	record.PromptTokenIDs, err = uint32ArrayField(obj, "prompt_token_ids", 1, nativeMTPCanaryMaxPromptTokens)
	if err != nil {
		return NativeMTPChallengeRecord{}, fmt.Errorf("%w: prompt_token_ids", errNativeMTPChallengeBankInvalid)
	}
	if len(obj["prompt_token_ids"]) > nativeMTPCanaryMaxPromptBytes {
		return NativeMTPChallengeRecord{}, fmt.Errorf("%w: prompt too large", errNativeMTPChallengeBankInvalid)
	}
	record.MaxCompletionTokens, err = uint32Field(obj, "max_completion_tokens", 1, nativeMTPCanaryMaxCompletionTokens)
	if err != nil {
		return NativeMTPChallengeRecord{}, fmt.Errorf("%w: max_completion_tokens", errNativeMTPChallengeBankInvalid)
	}
	record.FixedProposalDepth, err = uint32Field(obj, "fixed_proposal_depth", nativeMTPCanaryMinDepth, nativeMTPCanaryMaxDepth)
	if err != nil {
		return NativeMTPChallengeRecord{}, fmt.Errorf("%w: fixed_proposal_depth", errNativeMTPChallengeBankInvalid)
	}
	record.ExpectedTokenIDs, err = uint32ArrayField(obj, "expected_token_ids", 0, nativeMTPCanaryMaxCompletionTokens)
	if err != nil {
		return NativeMTPChallengeRecord{}, fmt.Errorf("%w: expected_token_ids", errNativeMTPChallengeBankInvalid)
	}
	record.ExpectedTerminalReason, err = stringField(obj, "expected_terminal_reason")
	if err != nil || !boundedPrintable(record.ExpectedTerminalReason, 1, 64) {
		return NativeMTPChallengeRecord{}, fmt.Errorf("%w: expected_terminal_reason", errNativeMTPChallengeBankInvalid)
	}
	record.ExpectedCounters, err = countersField(obj, "expected_counters")
	if err != nil {
		return NativeMTPChallengeRecord{}, err
	}
	if record.ExpectedTokenIDSHA256 != digestTokenIDs(record.ExpectedTokenIDs) {
		return NativeMTPChallengeRecord{}, fmt.Errorf("%w: expected_token_id_sha256 mismatch", errNativeMTPChallengeBankInvalid)
	}
	if record.ExpectedCounters.Committed != uint64(len(record.ExpectedTokenIDs)) {
		return NativeMTPChallengeRecord{}, fmt.Errorf("%w: inconsistent counters", errNativeMTPChallengeBankInvalid)
	}
	return record, nil
}

func strictObject(raw []byte, allowed []string, out *map[string]json.RawMessage) error {
	if field, err := rejectDuplicateJSONFields(raw); err != nil {
		return fmt.Errorf("%s: %w", field, err)
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var obj map[string]json.RawMessage
	if err := dec.Decode(&obj); err != nil {
		return err
	}
	var extra any
	if err := dec.Decode(&extra); err != io.EOF {
		return errors.New("trailing data")
	}
	if len(obj) != len(allowed) {
		return errors.New("wrong field count")
	}
	allowedSet := make(map[string]struct{}, len(allowed))
	for _, key := range allowed {
		allowedSet[key] = struct{}{}
		if _, ok := obj[key]; !ok {
			return fmt.Errorf("missing %s", key)
		}
	}
	for key := range obj {
		if _, ok := allowedSet[key]; !ok {
			return fmt.Errorf("unknown %s", key)
		}
	}
	*out = obj
	return nil
}

func stringField(obj map[string]json.RawMessage, field string) (string, error) {
	var value string
	if err := json.Unmarshal(obj[field], &value); err != nil {
		return "", err
	}
	return value, nil
}

func utcSecondField(obj map[string]json.RawMessage, field string) (time.Time, error) {
	value, err := stringField(obj, field)
	if err != nil {
		return time.Time{}, err
	}
	t, err := time.Parse("2006-01-02T15:04:05Z", value)
	if err != nil {
		return time.Time{}, err
	}
	return t.UTC(), nil
}

func uint32Field(obj map[string]json.RawMessage, field string, min uint32, max uint32) (uint32, error) {
	var n json.Number
	if err := json.Unmarshal(obj[field], &n); err != nil {
		return 0, err
	}
	i, err := strconv.ParseUint(n.String(), 10, 32)
	if err != nil || uint32(i) < min || uint32(i) > max {
		return 0, errors.New("out of range")
	}
	return uint32(i), nil
}

func uint32ArrayField(obj map[string]json.RawMessage, field string, minLen int, maxLen int) ([]uint32, error) {
	var raw []json.Number
	if err := json.Unmarshal(obj[field], &raw); err != nil || len(raw) < minLen || len(raw) > maxLen {
		return nil, errors.New("invalid array")
	}
	out := make([]uint32, 0, len(raw))
	for _, n := range raw {
		i, err := strconv.ParseUint(n.String(), 10, 32)
		if err != nil {
			return nil, err
		}
		out = append(out, uint32(i))
	}
	return out, nil
}

func countersField(obj map[string]json.RawMessage, field string) (NativeMTPCanaryExpectedCounters, error) {
	var counterObj map[string]json.RawMessage
	if err := strictObject(obj[field], []string{"accepted", "rejected", "bonus", "committed"}, &counterObj); err != nil {
		return NativeMTPCanaryExpectedCounters{}, fmt.Errorf("%w: expected_counters", errNativeMTPChallengeBankInvalid)
	}
	accepted, err := uint64Field(counterObj, "accepted")
	if err != nil {
		return NativeMTPCanaryExpectedCounters{}, fmt.Errorf("%w: expected_counters.accepted", errNativeMTPChallengeBankInvalid)
	}
	rejected, err := uint64Field(counterObj, "rejected")
	if err != nil {
		return NativeMTPCanaryExpectedCounters{}, fmt.Errorf("%w: expected_counters.rejected", errNativeMTPChallengeBankInvalid)
	}
	bonus, err := uint64Field(counterObj, "bonus")
	if err != nil {
		return NativeMTPCanaryExpectedCounters{}, fmt.Errorf("%w: expected_counters.bonus", errNativeMTPChallengeBankInvalid)
	}
	committed, err := uint64Field(counterObj, "committed")
	if err != nil {
		return NativeMTPCanaryExpectedCounters{}, fmt.Errorf("%w: expected_counters.committed", errNativeMTPChallengeBankInvalid)
	}
	return NativeMTPCanaryExpectedCounters{
		Accepted:  accepted,
		Rejected:  rejected,
		Bonus:     bonus,
		Committed: committed,
	}, nil
}

func uint64Field(obj map[string]json.RawMessage, field string) (uint64, error) {
	var n json.Number
	if err := json.Unmarshal(obj[field], &n); err != nil {
		return 0, err
	}
	value, err := strconv.ParseUint(n.String(), 10, 64)
	if err != nil {
		return 0, err
	}
	return value, nil
}

func isLowerHex64(value string) bool {
	return isLowerHexN(value, 64)
}

func isLowerHexN(value string, n int) bool {
	if len(value) != n {
		return false
	}
	for _, r := range value {
		if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f')) {
			return false
		}
	}
	return true
}

func boundedPrintable(value string, min int, max int) bool {
	if len(value) < min || len(value) > max {
		return false
	}
	for _, r := range value {
		if r < 0x21 || r > 0x7e {
			return false
		}
	}
	return true
}

func digestCanonicalJSON(value any) string {
	raw, _ := json.Marshal(value)
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

func digestTokenIDs(tokens []uint32) string {
	return digestCanonicalJSON(tokens)
}

func (r NativeMTPCanaryCoreRequest) digestObject() nativeMTPCanaryRequestDigestObject {
	return nativeMTPCanaryRequestDigestObject{
		Profile:                r.Profile,
		ProviderID:             r.ProviderID,
		AssignedID:             r.AssignedID,
		TargetGeneration:       r.TargetGeneration,
		RuntimeTupleSHA256:     r.RuntimeTupleSHA256,
		ChallengeBankSHA256:    r.ChallengeBankSHA256,
		ChallengeID:            r.ChallengeID,
		Nonce:                  r.Nonce,
		IssuedAt:               r.IssuedAt.UTC().Format(time.RFC3339),
		ExpiresAt:              r.ExpiresAt.UTC().Format(time.RFC3339),
		PromptTokenIDs:         r.PromptTokenIDs,
		MaxCompletionTokens:    r.MaxCompletionTokens,
		FixedProposalDepth:     r.FixedProposalDepth,
		ExpectedTokenIDSHA256:  r.ExpectedTokenIDSHA256,
		ExpectedTerminalReason: r.ExpectedTerminalReason,
		ExpectedCounters:       r.ExpectedCounters,
	}
}

func (r NativeMTPCanaryCoreResult) digestObject() nativeMTPCanaryResultDigestObject {
	return nativeMTPCanaryResultDigestObject{
		Profile:                    r.Profile,
		ProviderID:                 r.ProviderID,
		AssignedID:                 r.AssignedID,
		TargetGeneration:           r.TargetGeneration,
		RuntimeTupleSHA256:         r.RuntimeTupleSHA256,
		ChallengeBankSHA256:        r.ChallengeBankSHA256,
		ChallengeID:                r.ChallengeID,
		Nonce:                      r.Nonce,
		RequestDigestSHA256:        r.RequestDigestSHA256,
		CapacityUnavailable:        r.CapacityUnavailable,
		ActualDecodePath:           r.ActualDecodePath,
		FallbackUsed:               r.FallbackUsed,
		ActualTokenIDSHA256:        r.ActualTokenIDSHA256,
		ActualTerminalReason:       r.ActualTerminalReason,
		ActualCounters:             r.ActualCounters,
		ActualCommittedStateSHA256: r.ActualCommittedStateSHA256,
	}
}
