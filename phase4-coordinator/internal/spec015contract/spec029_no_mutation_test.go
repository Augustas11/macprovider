package spec015contract

import "testing"

func TestSPEC029DoesNotExtendSPEC015ReceiptOrUsageKeys(t *testing.T) {
	fixtures := loadV04Fixtures(t)
	if len(fixtures.ReceiptTuples) == 0 {
		t.Fatal("missing v0.4 receipt tuple fixtures")
	}

	tuple := fixtures.ReceiptTuples[0]
	receipt := copyMap(tuple.Value)
	usage, ok := receipt["usage"].(map[string]any)
	if !ok {
		t.Fatalf("%s usage = %#v, want object", tuple.ID, receipt["usage"])
	}
	usage = copyMap(usage)

	assertOnlyKeys(t, tuple.ID, receipt, receiptTupleKeys)
	assertOnlyKeys(t, tuple.ID+".usage", usage, usageKeys)

	receipt["losslessness_profile_state"] = "candidate"
	if hasOnlyKeys(receipt, receiptTupleKeys) {
		t.Fatal("SPEC-015 receipt tuple unexpectedly allows SPEC-029 probe metadata")
	}

	usage["probe_request_digest"] = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
	if hasOnlyKeys(usage, usageKeys) {
		t.Fatal("SPEC-015 usage object unexpectedly allows SPEC-029 probe metadata")
	}
}

func copyMap(in map[string]any) map[string]any {
	out := make(map[string]any, len(in))
	for key, value := range in {
		out[key] = value
	}
	return out
}

func assertOnlyKeys(t *testing.T, id string, value map[string]any, want []string) {
	t.Helper()
	if !hasOnlyKeys(value, want) {
		t.Fatalf("%s keys are not strict before SPEC-029 mutation probe", id)
	}
}

func hasOnlyKeys(value map[string]any, want []string) bool {
	if len(value) != len(want) {
		return false
	}
	allowed := make(map[string]struct{}, len(want))
	for _, key := range want {
		allowed[key] = struct{}{}
	}
	for key := range value {
		if _, ok := allowed[key]; !ok {
			return false
		}
	}
	return true
}
