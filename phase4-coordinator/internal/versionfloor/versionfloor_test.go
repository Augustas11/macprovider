package versionfloor

import "testing"

func TestCompareOrdersAndRejectsNonNumeric(t *testing.T) {
	for _, tc := range []struct {
		lhs, rhs string
		want     int
		valid    bool
	}{
		{lhs: "1.8.33", rhs: "1.8.33", want: 0, valid: true},
		{lhs: "1.8.32", rhs: "1.8.33", want: -1, valid: true},
		{lhs: "1.8.65", rhs: "1.8.33", want: 1, valid: true},
		{lhs: "v1.9", rhs: "1.8.99", want: 1, valid: true},
		{lhs: "2", rhs: "1.8.65", want: 1, valid: true},
		// Suffixed / non-numeric / over-long versions are NOT comparable. The
		// existing hello floor pins this (TestProviderHelloRejectsSuffixed
		// RequiredBinaryVersion) and Check turns it into a denial.
		{lhs: "1.8.33-dev", rhs: "1.8.33", valid: false},
		{lhs: "1.8.33", rhs: "1.8.33.1", valid: false},
		{lhs: "", rhs: "1.0.0", valid: false},
		{lhs: "1..3", rhs: "1.0.0", valid: false},
	} {
		got, ok := Compare(tc.lhs, tc.rhs)
		if ok != tc.valid {
			t.Fatalf("Compare(%q,%q) valid = %v, want %v", tc.lhs, tc.rhs, ok, tc.valid)
		}
		if ok && got != tc.want {
			t.Fatalf("Compare(%q,%q) = %d, want %d", tc.lhs, tc.rhs, got, tc.want)
		}
	}
}

func TestValid(t *testing.T) {
	for _, ok := range []string{"1", "1.2", "1.2.3", "v1.8.65", " 1.8.65 "} {
		if !Valid(ok) {
			t.Fatalf("Valid(%q) = false, want true", ok)
		}
	}
	for _, bad := range []string{"", "latest", "1.8.65-rc1", "1.2.3.4", "1.-2"} {
		if Valid(bad) {
			t.Fatalf("Valid(%q) = true, want false", bad)
		}
	}
}

// TestCheckUnconfiguredIsNoOp is the default-posture guarantee: with no floors
// configured, no provider is ever excluded, whatever it reports.
func TestCheckUnconfiguredIsNoOp(t *testing.T) {
	for _, floors := range []map[string]string{nil, {}} {
		for _, version := range []string{"", "0.1.0", "1.8.65", "garbage"} {
			got := Check(floors, "model-a", version)
			if !got.Allowed || got.Floor != "" || got.Malformed {
				t.Fatalf("Check(%v, model-a, %q) = %+v, want allowed no-op", floors, version, got)
			}
		}
	}
}

func TestCheckPerModelFloor(t *testing.T) {
	floors := map[string]string{
		"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit": "1.8.60",
	}
	for _, tc := range []struct {
		name          string
		modelID       string
		binaryVersion string
		wantAllowed   bool
		wantFloor     string
		wantMalformed bool
	}{
		{
			name: "unfloored model untouched", modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit",
			binaryVersion: "0.1.0", wantAllowed: true,
		},
		{
			name: "below floor denied", modelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
			binaryVersion: "1.8.59", wantAllowed: false, wantFloor: "1.8.60",
		},
		{
			name: "at floor allowed", modelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
			binaryVersion: "1.8.60", wantAllowed: true, wantFloor: "1.8.60",
		},
		{
			name: "above floor allowed", modelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
			binaryVersion: "1.8.65", wantAllowed: true, wantFloor: "1.8.60",
		},
		{
			name: "model id matched case-insensitively", modelID: "MLX-COMMUNITY/qwen3-coder-30b-a3b-instruct-4bit",
			binaryVersion: "1.8.59", wantAllowed: false, wantFloor: "1.8.60",
		},
		// Fail-safe: a provider reporting a version we cannot parse while a
		// floor is in force is suspect. Gate it out, and flag it so the caller
		// can log it louder than an honestly-old build.
		{
			name: "malformed provider version fails safe", modelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
			binaryVersion: "1.8.60-hotfix", wantAllowed: false, wantFloor: "1.8.60", wantMalformed: true,
		},
		{
			name: "empty provider version fails safe", modelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
			binaryVersion: "", wantAllowed: false, wantFloor: "1.8.60", wantMalformed: true,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := Check(floors, tc.modelID, tc.binaryVersion)
			if got.Allowed != tc.wantAllowed || got.Floor != tc.wantFloor || got.Malformed != tc.wantMalformed {
				t.Fatalf("Check(%q,%q) = %+v, want allowed=%v floor=%q malformed=%v",
					tc.modelID, tc.binaryVersion, got, tc.wantAllowed, tc.wantFloor, tc.wantMalformed)
			}
		})
	}
}

// TestCheckMalformedFloorFailsSafe is defense in depth: config.Validate rejects
// an unparseable floor at load, so this path is unreachable in prod — but if it
// were ever reached it must deny, not silently allow.
func TestCheckMalformedFloorFailsSafe(t *testing.T) {
	got := Check(map[string]string{"model-a": "latest"}, "model-a", "1.8.65")
	if got.Allowed || !got.Malformed {
		t.Fatalf("Check with malformed floor = %+v, want denied+malformed", got)
	}
}
