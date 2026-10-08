package ws

import (
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/base64"
	"strings"
	"testing"
)

// SPEC-049 §4.10: the privacy_enrollment claim is optional on hello,
// auth_request, and heartbeat; when present it must be the closed object.
func TestPrivacyEnrollmentClaimParses(t *testing.T) {
	public, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	se, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	raw := make([]byte, 64)
	se.X.FillBytes(raw[:32])
	se.Y.FillBytes(raw[32:])
	claim := `{"version":"privacy-enrollment-v1","identity_public_key":"` + base64.RawURLEncoding.EncodeToString(public) + `","se_public_key":"` + base64.StdEncoding.EncodeToString(raw) + `"}`
	hello := `{"type":"hello","version":1,"tier":1,"provider_id":"provider-a","hostname":"host.local","model_id":"model-a","model_params_b":7,"ram_gb":16,"max_context_tokens":4096,"max_concurrency":1,"throughput_tps_estimate":10,"binary_version":"0.0.0-fixture"`

	without, _, err := ParseHello([]byte(hello + `}`))
	if err != nil || without.PrivacyEnrollment != nil {
		t.Fatalf("hello without claim = %+v, %v", without.PrivacyEnrollment, err)
	}
	with, _, err := ParseHello([]byte(hello + `,"privacy_enrollment":` + claim + `}`))
	if err != nil || with.PrivacyEnrollment == nil || with.PrivacyEnrollment.SEPublicKey != base64.StdEncoding.EncodeToString(raw) {
		t.Fatalf("hello with claim = %+v, %v", with.PrivacyEnrollment, err)
	}
	for name, bad := range map[string]string{
		"null":    `null`,
		"extra":   strings.Replace(claim, `{"version"`, `{"provider_id":"x","version"`, 1),
		"version": strings.Replace(claim, "privacy-enrollment-v1", "privacy-enrollment-v2", 1),
	} {
		if _, field, err := ParseHello([]byte(hello + `,"privacy_enrollment":` + bad + `}`)); err == nil || field != "privacy_enrollment" {
			t.Fatalf("%s claim accepted: field=%q err=%v", name, field, err)
		}
	}
	heartbeat := `{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":7,"ram_gb":16,"max_context_tokens":4096,"max_concurrency":1,"slots_free":1,"slots_total":1,"throughput_tps_estimate":10,"requests_served_since_last":0,"avg_latency_ms_since_last":1,"throughput_tps_since_last":1,"privacy_enrollment":` + claim + `}`
	parsed, _, field, err := ParseHeartbeat([]byte(heartbeat))
	if err != nil || field != "" || parsed.PrivacyEnrollment == nil {
		t.Fatalf("heartbeat claim field=%q err=%v claim=%+v", field, err, parsed.PrivacyEnrollment)
	}
}
