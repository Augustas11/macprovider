package payout

import (
	"errors"
	"strings"
	"testing"
)

// EIP-55 vectors from the official spec:
//
//	https://eips.ethereum.org/EIPS/eip-55#test-cases
//
// The canonical mixed-case form is the input; lowercase and
// uppercase variants are accepted per the EIP-55 backward-compat
// rule; a mutated mixed-case variant is rejected.
func TestParseAndCanonicalizeEIP55_OfficialVectors(t *testing.T) {
	vectors := []string{
		"0x52908400098527886E0F7030069857D2E4169EE7",
		"0x8617E340B3D01FA5F11F306F4090FD50E238070D",
		"0xde709f2102306220921060314715629080e2fb77",
		"0x27b1fdb04752bbc536007a920d24acb045561c26",
		"0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
		"0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
		"0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB",
		"0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb",
	}
	for _, canonical := range vectors {
		// Canonical form should round-trip.
		got, err := ParseAndCanonicalizeEIP55(canonical)
		if err != nil {
			t.Fatalf("canonical %s rejected: %v", canonical, err)
		}
		if got != canonical {
			t.Errorf("canonical round-trip: want %s, got %s", canonical, got)
		}
		// All-lowercase should be accepted as checksum-skipped
		// and canonicalised.
		lower := strings.ToLower(canonical)
		got, err = ParseAndCanonicalizeEIP55(lower)
		if err != nil {
			t.Fatalf("lowercase %s rejected: %v", lower, err)
		}
		if got != canonical {
			t.Errorf("lowercase canonicalise: want %s, got %s", canonical, got)
		}
		// All-uppercase (after stripping 0x) should be accepted.
		upper := "0x" + strings.ToUpper(canonical[2:])
		got, err = ParseAndCanonicalizeEIP55(upper)
		if err != nil {
			t.Fatalf("uppercase %s rejected: %v", upper, err)
		}
		if got != canonical {
			t.Errorf("uppercase canonicalise: want %s, got %s", canonical, got)
		}
	}
}

func TestParseAndCanonicalizeEIP55_MixedCaseMismatchRejected(t *testing.T) {
	// Canonical form from the EIP-55 spec.
	canonical := "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
	// Mutate a single hex char's case (the first uppercase 'A' →
	// 'a'). Now the input is mixed-case but the wrong checksum.
	mutated := "0x5aaeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
	if mutated == canonical {
		t.Fatal("mutation produced canonical form by accident")
	}
	_, err := ParseAndCanonicalizeEIP55(mutated)
	if !errors.Is(err, ErrChecksumMismatch) {
		t.Fatalf("expected ErrChecksumMismatch, got %v", err)
	}
}

func TestParseAndCanonicalizeEIP55_BadFormat(t *testing.T) {
	cases := []string{
		"",
		"0x",
		"0x1234",
		"5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", // no 0x
		"0xZZAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
	}
	for _, c := range cases {
		_, err := ParseAndCanonicalizeEIP55(c)
		if !errors.Is(err, ErrBadFormat) {
			t.Errorf("%q: want ErrBadFormat, got %v", c, err)
		}
	}
}
