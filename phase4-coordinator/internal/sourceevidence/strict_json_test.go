package sourceevidence

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestStrictJSONRejectsDuplicateKeysRecursively(t *testing.T) {
	cases := []struct {
		name string
		json string
	}{
		{name: "top level schema", json: `{"schema_version":"one","schema_version":"two"}`},
		{name: "nested scope", json: `{"schema_version":"macprovider.coordinator-source-export-request.v1","run_id":"run","challenge_nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","scopes":[{"account_id":"acct","account_id":"acct2"}]}`},
		{name: "nested registry public key", json: `{"schema_version":"macprovider.source-evidence-key-registry.v1","keys":[{"public_key":"one","public_key":"two"}]}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var out any
			if err := decodeStrictJSONBytes([]byte(tc.json), &out); err == nil {
				t.Fatalf("duplicate key accepted")
			}
		})
	}
}

func TestStrictJSONRejectsTrailingBoundsDepthAndUnsafeValues(t *testing.T) {
	cases := []struct {
		name     string
		json     string
		maxBytes int64
	}{
		{name: "second document", json: `{} {}`, maxBytes: 64},
		{name: "suffix garbage", json: `{} trailing`, maxBytes: 64},
		{name: "byte bound", json: `{"ok":true}`, maxBytes: 4},
		{name: "unsafe integer", json: `{"n":9007199254740992}`, maxBytes: 64},
		{name: "float", json: `{"n":1.25}`, maxBytes: 64},
		{name: "non ascii", json: `{"s":"é"}`, maxBytes: 64},
		{name: "depth", json: strings.Repeat(`[`, maxStrictJSONDepth+2) + `0` + strings.Repeat(`]`, maxStrictJSONDepth+2), maxBytes: 2048},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var out any
			if err := decodeStrictJSONFromReader(strings.NewReader(tc.json), tc.maxBytes, &out); err == nil {
				t.Fatalf("invalid JSON accepted")
			}
		})
	}
}

func TestCanonicalBytesDoesNotHTMLEscapeStrings(t *testing.T) {
	got, err := canonicalBytes(map[string]any{
		"note": `reviewed <tag>&value "quoted" \ slash`,
	})
	if err != nil {
		t.Fatalf("canonicalBytes: %v", err)
	}
	want := `{"note":"reviewed <tag>&value \"quoted\" \\ slash"}`
	if string(got) != want {
		t.Fatalf("canonical bytes = %q, want %q", got, want)
	}
}

func TestRegistryValidationMatchesPythonClosedContract(t *testing.T) {
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	prov := FixedProvenance{
		InstanceID: "coordinator-prod-a",
		SourceSHA:  "0123456789abcdef0123456789abcdef01234567",
		KeyID:      "coordinator-key-1",
		Now:        func() time.Time { return time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC) },
	}
	valid := func() map[string]any {
		return map[string]any{
			"schema_version": registrySchema,
			"keys": []any{map[string]any{
				"key_id":            prov.KeyID,
				"algorithm":         "ed25519",
				"public_key":        base64.RawURLEncoding.EncodeToString(pub),
				"producer":          ProducerName,
				"instance_id":       prov.InstanceID,
				"permitted_roles":   []any{ProducerRole},
				"permitted_domains": []any{SignDomain},
				"not_before":        "2026-10-07T00:00:00.000Z",
				"not_after":         "2026-10-08T00:00:00.000Z",
				"revoked_at":        nil,
				"reviewed_source_constraints": map[string]any{
					"source_sha_allowlist": []any{prov.SourceSHA},
					"notes":                "reviewed test key",
				},
			}},
		}
	}
	if err := authorizeRegistryKey(valid(), prov, pub); err != nil {
		t.Fatalf("valid registry rejected: %v", err)
	}
	cases := []struct {
		name   string
		mutate func(map[string]any)
	}{
		{name: "unknown top level field", mutate: func(reg map[string]any) { reg["extra"] = true }},
		{name: "wrong schema", mutate: func(reg map[string]any) { reg["schema_version"] = "legacy" }},
		{name: "missing notes", mutate: func(reg map[string]any) {
			delete(firstRegistryKey(reg)["reviewed_source_constraints"].(map[string]any), "notes")
		}},
		{name: "unknown constraints field", mutate: func(reg map[string]any) {
			firstRegistryKey(reg)["reviewed_source_constraints"].(map[string]any)["extra"] = "x"
		}},
		{name: "duplicate roles", mutate: func(reg map[string]any) { firstRegistryKey(reg)["permitted_roles"] = []any{ProducerRole, ProducerRole} }},
		{name: "duplicate domains", mutate: func(reg map[string]any) { firstRegistryKey(reg)["permitted_domains"] = []any{SignDomain, SignDomain} }},
		{name: "duplicate source shas", mutate: func(reg map[string]any) {
			firstRegistryKey(reg)["reviewed_source_constraints"].(map[string]any)["source_sha_allowlist"] = []any{prov.SourceSHA, prov.SourceSHA}
		}},
		{name: "timestamp without milliseconds", mutate: func(reg map[string]any) { firstRegistryKey(reg)["not_before"] = "2026-10-07T00:00:00Z" }},
		{name: "inverted window", mutate: func(reg map[string]any) { firstRegistryKey(reg)["not_after"] = "2026-10-07T00:00:00.000Z" }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reg := valid()
			tc.mutate(reg)
			if err := authorizeRegistryKey(reg, prov, pub); !errors.Is(err, ErrProvenanceMissing) {
				t.Fatalf("got err=%v, want ErrProvenanceMissing", err)
			}
		})
	}
}

func firstRegistryKey(reg map[string]any) map[string]any {
	return reg["keys"].([]any)[0].(map[string]any)
}
