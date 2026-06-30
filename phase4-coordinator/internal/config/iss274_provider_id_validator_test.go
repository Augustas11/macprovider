package config_test

import (
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

// TestValidateProviderID_Iss274 pins the canonical validator's accept/reject
// table. The "/" delimiter inside pool.Provider.SortKey
// (ProviderID + "/" + AssignedID) is only unambiguous when no ProviderID
// contains "/", so every WS / admission registration path funnels through
// this helper.
func TestValidateProviderID_Iss274(t *testing.T) {
	cases := []struct {
		name string
		id   string
		want bool // true = accept
	}{
		{name: "letters_digits_dash", id: "m4-anon", want: true},
		{name: "underscore_dot", id: "host_01.prod", want: true},
		{name: "max_len_64", id: strings.Repeat("a", 64), want: true},
		{name: "single_char", id: "a", want: true},

		{name: "rejects_slash_delimiter_collision_seed", id: "a/b", want: false},
		{name: "rejects_double_slash", id: "x//y", want: false},
		{name: "rejects_empty", id: "", want: false},
		{name: "rejects_len_65", id: strings.Repeat("a", 65), want: false},
		{name: "rejects_space", id: "m4 anon", want: false},
		{name: "rejects_colon", id: "m4:anon", want: false},
		{name: "rejects_at", id: "m4@anon", want: false},
		{name: "rejects_unicode", id: "café", want: false},
		{name: "rejects_newline", id: "m4\nanon", want: false},
		{name: "rejects_null", id: "m4\x00anon", want: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := config.ValidateProviderID(tc.id)
			if tc.want && err != nil {
				t.Fatalf("ValidateProviderID(%q) err = %v, want nil", tc.id, err)
			}
			if !tc.want && err == nil {
				t.Fatalf("ValidateProviderID(%q) err = nil, want non-nil", tc.id)
			}
		})
	}
}
