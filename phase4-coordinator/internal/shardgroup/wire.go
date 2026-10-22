// Package shardgroup is the coordinator half of SPEC-051 multi-Mac shard
// groups: the group record and its validation, the group wire messages
// (SPEC-051-R029), the durable record and attestation store, group
// availability (SPEC-051-R015), and group attestation verification
// (SPEC-051-R019).
package shardgroup

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

// Message types (SPEC-051-R029).
const (
	TypeRegister          = "shard_group_register"
	TypeRegisterResult    = "shard_group_register_result"
	TypeHeartbeat         = "shard_group_heartbeat"
	TypeStatus            = "shard_group_status"
	TypeMemberHello       = "shard_member_hello"
	TypeMemberHelloResult = "shard_member_hello_result"
	TypeMemberHealth      = "shard_member_health"

	// WireVersion is the only group message version.
	WireVersion = 1

	// maxJSONInteger is the largest integer a group message may carry
	// (2^53 - 1), so every value survives a float64 JSON parser.
	maxJSONInteger = 1<<53 - 1
)

// Schemas and signing domains (SPEC-051-R005, R019, R029).
const (
	RecordSchema      = "macprovider.shard-group-record.v1"
	AttestationSchema = "macprovider.shard-group-attestation.v1"
	recordDomain      = "macprovider.shard-group-record.v1\n"
	attestationDomain = "macprovider.shard-group-attestation.v1\n"
	subReceiptDomain  = "macprovider.shard-sub-receipt.v1\n"
)

var errStrict = errors.New("shardgroup: message is not strictly well-formed")

// RegisterMessage is `shard_group_register` (head to coordinator).
type RegisterMessage struct {
	Type            string          `json:"type"`
	Version         int             `json:"version"`
	Record          json.RawMessage `json:"record"`
	RecordSignature string          `json:"record_signature"`
}

// Record is the SPEC-051-R005 group record.
type Record struct {
	Schema            string      `json:"schema"`
	GroupProviderID   string      `json:"group_provider_id"`
	GroupEpoch        uint64      `json:"group_epoch"`
	ParallelismMode   string      `json:"parallelism_mode"`
	InterconnectClass string      `json:"interconnect_class"`
	FrameProtection   string      `json:"frame_protection"`
	TransportVersion  int         `json:"transport_version"`
	Model             RecordModel `json:"model"`
	NumLayers         int         `json:"num_layers"`
	MaxConcurrency    int         `json:"max_concurrency"`
	Stages            []Stage     `json:"stages"`
	Spares            []Spare     `json:"spares"`
	Supervision       Supervision `json:"supervision"`
}

// RecordModel names the pool model and its exact artifact pair.
type RecordModel struct {
	ModelID               string `json:"model_id"`
	PoolModelID           string `json:"pool_model_id"`
	ArtifactHashAlgorithm string `json:"artifact_hash_algorithm"`
	ArtifactHash          string `json:"artifact_hash"`
}

// Stage is one active stage of a group record.
type Stage struct {
	StageIndex     int    `json:"stage_index"`
	MemberDeviceID string `json:"member_device_id"`
	LayerStart     int    `json:"layer_start"`
	LayerEnd       int    `json:"layer_end"`
}

// Spare is one spare of a group record.
type Spare struct {
	MemberDeviceID string `json:"member_device_id"`
	StageIndex     int    `json:"stage_index"`
}

// Supervision carries the SPEC-051 §4 group configuration values.
type Supervision struct {
	HeartbeatIntervalMS    int `json:"heartbeat_interval_ms"`
	HeartbeatMissLimit     int `json:"heartbeat_miss_limit"`
	DecodeHopDeadlineMS    int `json:"decode_hop_deadline_ms"`
	PrefillChunkDeadlineMS int `json:"prefill_chunk_deadline_ms"`
	ReplayDeadlineMS       int `json:"replay_deadline_ms"`
}

// Result is `shard_group_register_result` and `shard_member_hello_result`.
type Result struct {
	Type            string `json:"type"`
	Version         int    `json:"version"`
	GroupProviderID string `json:"group_provider_id"`
	GroupEpoch      uint64 `json:"group_epoch"`
	Accepted        bool   `json:"accepted"`
	Reason          string `json:"reason"`
}

// Status is `shard_group_status` (coordinator to head).
type Status struct {
	Type            string `json:"type"`
	Version         int    `json:"version"`
	GroupProviderID string `json:"group_provider_id"`
	GroupEpoch      uint64 `json:"group_epoch"`
	Available       bool   `json:"available"`
	Reason          string `json:"reason"`
}

// MemberHello is `shard_member_hello` (member to coordinator).
type MemberHello struct {
	Type                  string       `json:"type"`
	Version               int          `json:"version"`
	GroupProviderID       string       `json:"group_provider_id"`
	GroupEpoch            uint64       `json:"group_epoch"`
	MemberDeviceID        string       `json:"member_device_id"`
	Role                  string       `json:"role"`
	StageIndex            int          `json:"stage_index"`
	LayerStart            int          `json:"layer_start"`
	LayerEnd              int          `json:"layer_end"`
	TransportVersion      int          `json:"transport_version"`
	ArtifactHashAlgorithm string       `json:"artifact_hash_algorithm"`
	ArtifactHash          string       `json:"artifact_hash"`
	WeightsVerified       bool         `json:"weights_verified"`
	StageFits             bool         `json:"stage_fits"`
	Links                 []MemberLink `json:"links"`
}

// MemberLink is one stage link a member carries.
type MemberLink struct {
	PeerMemberDeviceID string `json:"peer_member_device_id"`
	InterfaceType      string `json:"interface_type"`
}

// Heartbeat is `shard_group_heartbeat` (head to coordinator).
type Heartbeat struct {
	Type            string            `json:"type"`
	Version         int               `json:"version"`
	GroupProviderID string            `json:"group_provider_id"`
	GroupEpoch      uint64            `json:"group_epoch"`
	Members         []HeartbeatMember `json:"members"`
	Links           []HeartbeatLink   `json:"links"`
}

// HeartbeatMember is one member's health as the head observes it.
type HeartbeatMember struct {
	MemberDeviceID string `json:"member_device_id"`
	Healthy        bool   `json:"healthy"`
}

// HeartbeatLink is one required link's interface and measured p99 RTT.
type HeartbeatLink struct {
	FromMemberDeviceID string `json:"from_member_device_id"`
	ToMemberDeviceID   string `json:"to_member_device_id"`
	InterfaceType      string `json:"interface_type"`
	RTTP99US           int    `json:"rtt_p99_us"`
}

// decodeStrict decodes one JSON object into dst and refuses duplicate keys,
// unknown keys, missing keys (every struct field is required, at every
// nesting level), trailing data, and integers above 2^53 - 1.
func decodeStrict(raw []byte, dst any) error {
	if err := rejectDuplicateKeys(raw); err != nil {
		return err
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return fmt.Errorf("%w: %v", errStrict, err)
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return fmt.Errorf("%w: trailing data", errStrict)
	}
	var in any
	inDec := json.NewDecoder(bytes.NewReader(raw))
	inDec.UseNumber()
	if err := inDec.Decode(&in); err != nil {
		return fmt.Errorf("%w: %v", errStrict, err)
	}
	back, err := json.Marshal(dst)
	if err != nil {
		return fmt.Errorf("%w: %v", errStrict, err)
	}
	var out any
	outDec := json.NewDecoder(bytes.NewReader(back))
	outDec.UseNumber()
	if err := outDec.Decode(&out); err != nil {
		return fmt.Errorf("%w: %v", errStrict, err)
	}
	if !sameShape(in, out) {
		return fmt.Errorf("%w: missing or mistyped field", errStrict)
	}
	return nil
}

// sameShape reports whether two decoded JSON values have the same object key
// sets and array lengths at every level, and no integer above 2^53 - 1.
func sameShape(a, b any) bool {
	switch x := a.(type) {
	case map[string]any:
		y, ok := b.(map[string]any)
		if !ok || len(x) != len(y) {
			return false
		}
		for k, v := range x {
			w, ok := y[k]
			if !ok || !sameShape(v, w) {
				return false
			}
		}
		return true
	case []any:
		y, ok := b.([]any)
		if !ok || len(x) != len(y) {
			return false
		}
		for i := range x {
			if !sameShape(x[i], y[i]) {
				return false
			}
		}
		return true
	case json.Number:
		if _, ok := b.(json.Number); !ok {
			return false
		}
		n, err := x.Int64()
		return err == nil && n >= 0 && n <= maxJSONInteger
	case nil:
		// No group message field is nullable.
		return false
	default:
		// Strings and booleans: the typed decode already refused a
		// mistyped scalar.
		return b != nil
	}
}

// rejectDuplicateKeys walks raw and refuses any object with a repeated key.
func rejectDuplicateKeys(raw []byte) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	if err := walkNoDuplicates(dec); err != nil {
		return fmt.Errorf("%w: %v", errStrict, err)
	}
	return nil
}

func walkNoDuplicates(dec *json.Decoder) error {
	tok, err := dec.Token()
	if err != nil {
		return err
	}
	delim, ok := tok.(json.Delim)
	if !ok {
		return nil
	}
	switch delim {
	case '{':
		seen := map[string]bool{}
		for dec.More() {
			keyTok, err := dec.Token()
			if err != nil {
				return err
			}
			key, _ := keyTok.(string)
			if seen[key] {
				return fmt.Errorf("duplicate key %q", key)
			}
			seen[key] = true
			if err := walkNoDuplicates(dec); err != nil {
				return err
			}
		}
		_, err = dec.Token()
		return err
	case '[':
		for dec.More() {
			if err := walkNoDuplicates(dec); err != nil {
				return err
			}
		}
		_, err = dec.Token()
		return err
	}
	return nil
}

// ParseRegister strictly parses `shard_group_register` and its record.
func ParseRegister(payload []byte) (RegisterMessage, Record, error) {
	var msg RegisterMessage
	if err := decodeStrict(payload, &msg); err != nil {
		return RegisterMessage{}, Record{}, err
	}
	if msg.Type != TypeRegister || msg.Version != WireVersion {
		return RegisterMessage{}, Record{}, errStrict
	}
	var rec Record
	if err := decodeStrict(msg.Record, &rec); err != nil {
		return RegisterMessage{}, Record{}, err
	}
	return msg, rec, nil
}

// ParseMemberHello strictly parses `shard_member_hello`.
func ParseMemberHello(payload []byte) (MemberHello, error) {
	var msg MemberHello
	if err := decodeStrict(payload, &msg); err != nil {
		return MemberHello{}, err
	}
	if msg.Type != TypeMemberHello || msg.Version != WireVersion {
		return MemberHello{}, errStrict
	}
	return msg, nil
}

// MemberHealth is `shard_member_health`: a member's own report of its health
// and its stage links under its member device identity (SPEC-051-R015).
type MemberHealth struct {
	Type            string             `json:"type"`
	Version         int                `json:"version"`
	GroupProviderID string             `json:"group_provider_id"`
	GroupEpoch      uint64             `json:"group_epoch"`
	MemberDeviceID  string             `json:"member_device_id"`
	Healthy         bool               `json:"healthy"`
	Reason          string             `json:"reason"`
	Links           []MemberHealthLink `json:"links"`
}

// MemberHealthLink is one stage link as the member measures it.
type MemberHealthLink struct {
	PeerMemberDeviceID string `json:"peer_member_device_id"`
	InterfaceType      string `json:"interface_type"`
	RTTP99US           int    `json:"rtt_p99_us"`
}

// MemberHealthReasons is the closed set of `shard_member_health` reasons; the
// empty reason goes with `healthy: true` only.
var MemberHealthReasons = map[string]bool{"not_joined": true, "link_down": true}

// ParseMemberHealth strictly parses `shard_member_health`.
func ParseMemberHealth(payload []byte) (MemberHealth, error) {
	var msg MemberHealth
	if err := decodeStrict(payload, &msg); err != nil {
		return MemberHealth{}, err
	}
	if msg.Type != TypeMemberHealth || msg.Version != WireVersion {
		return MemberHealth{}, errStrict
	}
	if msg.Healthy != (msg.Reason == "") || (!msg.Healthy && !MemberHealthReasons[msg.Reason]) {
		return MemberHealth{}, errStrict
	}
	return msg, nil
}

// ParseHeartbeat strictly parses `shard_group_heartbeat`.
func ParseHeartbeat(payload []byte) (Heartbeat, error) {
	var msg Heartbeat
	if err := decodeStrict(payload, &msg); err != nil {
		return Heartbeat{}, err
	}
	if msg.Type != TypeHeartbeat || msg.Version != WireVersion {
		return Heartbeat{}, errStrict
	}
	return msg, nil
}
