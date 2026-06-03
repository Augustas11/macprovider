package auth

import (
	"testing"
	"time"
)

func TestNormalizeDemoIP(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want string
	}{
		{name: "ipv4", raw: "198.51.100.7", want: "198.51.100.7"},
		{name: "ipv6_masks_to_prefix", raw: "2001:db8:abcd:12:1111:2222:3333:4444", want: "2001:db8:abcd:12::/64"},
		{name: "ipv6_compressed_masks_to_prefix", raw: "2001:db8:abcd:12::99", want: "2001:db8:abcd:12::/64"},
		{name: "invalid", raw: "not an ip", want: "not an ip"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := normalizeDemoIP(tc.raw); got != tc.want {
				t.Fatalf("normalizeDemoIP(%q)=%q, want %q", tc.raw, got, tc.want)
			}
		})
	}
}

func TestDemoTokenAllowsIPv6PrivacyAddressWithinSame64(t *testing.T) {
	manager := NewDemoManager("secret")
	now := time.Unix(1717200000, 0)
	token, _, err := manager.Issue("2001:db8:abcd:12:1111:2222:3333:4444", now, time.Hour)
	if err != nil {
		t.Fatalf("issue: %v", err)
	}

	payload, err := manager.Validate(token, "2001:db8:abcd:12:ffff:eeee:dddd:cccc", now.Add(time.Minute))
	if err != nil {
		t.Fatalf("validate same /64: %v", err)
	}
	if payload.IP != "2001:db8:abcd:12::/64" {
		t.Fatalf("payload ip=%q", payload.IP)
	}
	if _, err := manager.Validate(token, "2001:db8:abcd:13::1", now.Add(time.Minute)); err != ErrInvalidDemoToken {
		t.Fatalf("validate different /64 err=%v, want ErrInvalidDemoToken", err)
	}
}
