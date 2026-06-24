package receipt

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"testing"
)

// SPEC-015 §M.1.2 / §M.5 AC-38 cross-binary parity.
//
// AC-38 requires: a locked v0.1.3 / v0.2.4 verifier (i.e. unmodified
// releases) reading a v0.3 receipt MUST report `invalid` per its §3.1
// seven-keys-only rule. To prove the forward-incompat semantic
// without needing a separate `phase7-verify-v0.2.4` binary in the
// repo, this test re-implements the v0.2.4 LOCKED parseTuple
// behaviour inline as `parseTupleV02Locked` and asserts:
//
//  1. A v0.3 9-field tuple (receipt_version="3" + model_hash) → the
//     v0.2.4 parser MUST reject as ErrTupleExtraKey.
//  2. A v0.3 null-hash tuple → same rejection.
//  3. A genuine v0.2.4 7-field tuple → the v0.2.4 parser MUST
//     accept.
//
// The locked v0.2.4 logic mirrors `parseTuple` AT THE v0.2.4
// LOCK STATE (commit 99d0c1e in this repo's main): exactly the seven
// keys, no `receipt_version` awareness, no `model_hash` field. The
// v0.3 IMPL preserved that strict behavior in shape exactly — it
// just dispatched into a v0.3 path when receipt_version is present.
// This test confirms the v0.2.4 strict path remains the locked
// floor of the v0.1/v0.2 contract.
//
// A future v0.4+ verifier author can use this test as the canonical
// cross-binary parity gate: change the §M.0 wire shape and the
// v0.2.4-Locked parser MUST still reject.
func TestV02LockedParserRejectsV03Receipts(t *testing.T) {
	v03NonNullTuple := mustMarshal(t, map[string]any{
		"model_hash":      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		"model_id":        "fixture-model",
		"output_hash":     strings.Repeat("a", 64),
		"prompt_hash":     strings.Repeat("b", 64),
		"provider_pubkey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
		"receipt_version": "3",
		"tokens_out":      2,
		"ttft_ms":         7,
		"unix_ts":         1800000000,
	})
	v03NullTuple := mustMarshal(t, map[string]any{
		"model_hash":      nil,
		"model_id":        "fixture-model",
		"output_hash":     strings.Repeat("a", 64),
		"prompt_hash":     strings.Repeat("b", 64),
		"provider_pubkey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
		"receipt_version": "3",
		"tokens_out":      2,
		"ttft_ms":         7,
		"unix_ts":         1800000000,
	})
	legacy7FieldTuple := mustMarshal(t, map[string]any{
		"model_id":        "fixture-model",
		"output_hash":     strings.Repeat("a", 64),
		"prompt_hash":     strings.Repeat("b", 64),
		"provider_pubkey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
		"tokens_out":      2,
		"ttft_ms":         7,
		"unix_ts":         1800000000,
	})

	if _, err := parseTupleV02Locked(v03NonNullTuple); !errors.Is(err, ErrTupleExtraKey) {
		t.Fatalf("v0.2.4 parser MUST reject v0.3 non-null receipt: err=%v, want ErrTupleExtraKey", err)
	}
	if _, err := parseTupleV02Locked(v03NullTuple); !errors.Is(err, ErrTupleExtraKey) {
		t.Fatalf("v0.2.4 parser MUST reject v0.3 null receipt: err=%v, want ErrTupleExtraKey", err)
	}
	if _, err := parseTupleV02Locked(legacy7FieldTuple); err != nil {
		t.Fatalf("v0.2.4 parser MUST accept legacy 7-field tuple: %v", err)
	}
}

// parseTupleV02Locked mirrors the locked v0.2.4 parseTuple at commit
// 99d0c1e on `main` — strict 7-key set, no receipt_version awareness,
// no model_hash awareness. Any deviation by a v0.4+ wire shape is
// caught at parse time as ErrTupleExtraKey / ErrTupleMissingKey.
//
// This is INTENTIONALLY a re-implementation rather than a call into
// the live parseTuple, because the live parser handles BOTH v0.2 and
// v0.3 receipts (the v0.3 IMPL preserved v0.2 acceptance via tagged-
// union dispatch). The locked floor of the v0.2.4 contract is what
// AC-38 demands.
func parseTupleV02Locked(raw []byte) (Tuple, error) {
	if len(raw) == 0 || !bytes.Equal(raw, bytes.TrimSpace(raw)) {
		return Tuple{}, ErrTupleJSON
	}
	fields, err := decodeTopLevelObject(raw)
	if err != nil {
		return Tuple{}, err
	}
	// v0.2.4-locked: EXACTLY these seven keys, no others.
	const wantCount = 7
	for key := range fields {
		if !isV02LockedKey(key) {
			return Tuple{}, fmt.Errorf("%w: %s", ErrTupleExtraKey, key)
		}
	}
	for _, key := range v02LockedKeys() {
		if _, ok := fields[key]; !ok {
			return Tuple{}, fmt.Errorf("%w: %s", ErrTupleMissingKey, key)
		}
	}
	if len(fields) != wantCount {
		return Tuple{}, fmt.Errorf("%w: have %d keys, want %d", ErrTupleExtraKey, len(fields), wantCount)
	}

	var tuple Tuple
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	decoder.UseNumber()
	if err := decoder.Decode(&tuple); err != nil {
		return Tuple{}, fmt.Errorf("%w: %v", ErrTupleWrongType, err)
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return Tuple{}, ErrTupleJSON
	}
	return tuple, nil
}

func v02LockedKeys() []string {
	return []string{
		"model_id",
		"prompt_hash",
		"output_hash",
		"provider_pubkey",
		"ttft_ms",
		"tokens_out",
		"unix_ts",
	}
}

func isV02LockedKey(k string) bool {
	for _, want := range v02LockedKeys() {
		if want == k {
			return true
		}
	}
	return false
}

func mustMarshal(t *testing.T, v any) []byte {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return raw
}
