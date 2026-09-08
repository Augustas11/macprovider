package main

import "testing"

// #1248 "Offer submit" disablement row: the boot-time policy switch must default
// to enabled, accept only enabled/disabled (case- and whitespace-insensitive),
// and refuse to boot on anything else rather than silently leaving submissions on.
func TestModelAdmissionSubmissionsDisabledParsesPolicyValues(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name     string
		raw      string
		disabled bool
		wantErr  bool
	}{
		{name: "unset defaults to enabled", raw: "", disabled: false},
		{name: "whitespace only defaults to enabled", raw: "  \t", disabled: false},
		{name: "enabled", raw: "enabled", disabled: false},
		{name: "enabled mixed case and padding", raw: " Enabled ", disabled: false},
		{name: "disabled", raw: "disabled", disabled: true},
		{name: "disabled upper case", raw: "DISABLED", disabled: true},
		{name: "unknown value refuses boot", raw: "off", wantErr: true},
		{name: "boolean-looking value refuses boot", raw: "true", wantErr: true},
		{name: "numeric value refuses boot", raw: "0", wantErr: true},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got, err := modelAdmissionSubmissionsDisabled(tc.raw)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error for %q, got disabled=%v", tc.raw, got)
				}
				if got {
					t.Fatalf("invalid value %q must not report disabled=true", tc.raw)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error for %q: %v", tc.raw, err)
			}
			if got != tc.disabled {
				t.Fatalf("value %q: disabled=%v, want %v", tc.raw, got, tc.disabled)
			}
		})
	}
}
