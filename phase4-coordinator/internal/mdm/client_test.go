package mdm

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestNewClientRequiresBaseURL(t *testing.T) {
	_, err := NewClient(ClientConfig{BaseURL: "", APIToken: "tok"})
	if err == nil {
		t.Fatal("expected error for empty BaseURL")
	}
}

func TestListDevices(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/devices" {
			t.Errorf("unexpected path %q", r.URL.Path)
		}
		if r.Method != http.MethodPost {
			t.Errorf("unexpected method %q want POST", r.Method)
		}
		if ct := r.Header.Get("Content-Type"); !strings.Contains(ct, "json") {
			t.Errorf("Content-Type=%q want json", ct)
		}
		user, pass, ok := r.BasicAuth()
		if !ok || user != "micromdm" || pass != "test-token" {
			t.Errorf("bad basic auth: user=%q pass=%q ok=%v", user, pass, ok)
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(listDevicesResponse{
			Devices: []Device{
				{UDID: "AAAA-BBBB", SerialNumber: "C02T1234ABC", EnrollmentStatus: true},
				{UDID: "CCCC-DDDD", SerialNumber: "C02X5678DEF", EnrollmentStatus: false},
			},
		})
	}))
	defer srv.Close()

	c, err := NewClient(ClientConfig{BaseURL: srv.URL, APIToken: "test-token"})
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	devices, err := c.ListDevices(context.Background())
	if err != nil {
		t.Fatalf("list devices: %v", err)
	}
	if len(devices) != 2 {
		t.Fatalf("expected 2 devices, got %d", len(devices))
	}
	if devices[0].UDID != "AAAA-BBBB" {
		t.Errorf("device[0].UDID=%q want AAAA-BBBB", devices[0].UDID)
	}
}

func TestFindDeviceBySerial(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(listDevicesResponse{
			Devices: []Device{
				{UDID: "AAAA-BBBB", SerialNumber: "C02T1234ABC"},
				{UDID: "CCCC-DDDD", SerialNumber: "C02X5678DEF"},
			},
		})
	}))
	defer srv.Close()

	c, _ := NewClient(ClientConfig{BaseURL: srv.URL, APIToken: "tok"})

	d, found, err := c.FindDeviceBySerial(context.Background(), "c02t1234abc") // lowercase
	if err != nil {
		t.Fatalf("find device: %v", err)
	}
	if !found {
		t.Fatal("expected device to be found")
	}
	if d.UDID != "AAAA-BBBB" {
		t.Errorf("found wrong device: UDID=%q", d.UDID)
	}

	_, found2, _ := c.FindDeviceBySerial(context.Background(), "NOTEXIST")
	if found2 {
		t.Fatal("expected not found for unknown serial")
	}
}

func TestEnqueueDeviceInformationAttestation(t *testing.T) {
	var capturedBody []byte
	var capturedPath string
	var capturedCT string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedPath = r.URL.Path
		capturedCT = r.Header.Get("Content-Type")
		if r.Method != http.MethodPost {
			t.Errorf("unexpected method %q", r.Method)
		}
		buf := new(bytes.Buffer)
		_, _ = buf.ReadFrom(r.Body)
		capturedBody = buf.Bytes()
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("{}"))
	}))
	defer srv.Close()

	c, _ := NewClient(ClientConfig{BaseURL: srv.URL, APIToken: "tok"})
	nonce := make([]byte, 32)
	for i := range nonce {
		nonce[i] = byte(i)
	}
	cmdUUID, err := c.EnqueueDeviceInformationAttestation(context.Background(), "TEST-UDID-001", nonce)
	if err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	if cmdUUID == "" {
		t.Fatal("expected non-empty commandUUID")
	}
	if capturedPath != "/v1/commands/TEST-UDID-001" {
		t.Errorf("path=%q want /v1/commands/TEST-UDID-001", capturedPath)
	}
	if !strings.Contains(capturedCT, "xml") && capturedCT != "application/x-apple-aspen-mdm" {
		t.Errorf("Content-Type=%q want xml", capturedCT)
	}
	body := string(capturedBody)
	if !strings.Contains(body, "DeviceAttestationNonce") {
		t.Fatal("body must contain DeviceAttestationNonce")
	}
	if !strings.Contains(body, "RequestType") || !strings.Contains(body, "DeviceInformation") {
		t.Fatal("body must contain RequestType DeviceInformation")
	}
	if !strings.Contains(body, cmdUUID) {
		t.Fatalf("body must contain CommandUUID %s", cmdUUID)
	}
	// Must NOT be the dropped JSON field as sole delivery mechanism.
	if strings.Contains(body, `"device_attestation_nonce"`) {
		t.Fatal("must not use JSON device_attestation_nonce field")
	}
	nonceB64 := base64.StdEncoding.EncodeToString(nonce)
	if !strings.Contains(body, nonceB64) {
		t.Fatal("body must embed nonce as base64 inside <data>")
	}
}

func TestEnqueueDeviceInformationAttestationReturnsErrorOnHTTPFailure(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "internal error", http.StatusInternalServerError)
	}))
	defer srv.Close()

	c, _ := NewClient(ClientConfig{BaseURL: srv.URL, APIToken: "tok"})
	_, err := c.EnqueueDeviceInformationAttestation(context.Background(), "UDID", make([]byte, 32))
	if err == nil {
		t.Fatal("expected error on 500 response")
	}
	if !strings.Contains(err.Error(), "500") {
		t.Errorf("error should mention status 500, got: %v", err)
	}
}

func TestParseDeviceAttestationFromPlistArrayFormat(t *testing.T) {
	cert1B64 := base64.StdEncoding.EncodeToString([]byte("fake-der-cert-1"))
	cert2B64 := base64.StdEncoding.EncodeToString([]byte("fake-der-cert-2"))
	data, _ := json.Marshal(map[string]interface{}{
		"payload": map[string]interface{}{
			"DeviceAttestation": []interface{}{cert1B64, cert2B64},
		},
	})
	result, err := ParseDeviceAttestationFromPlist(data)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(result.CertificateChain) != 2 {
		t.Fatalf("expected 2 certs, got %d", len(result.CertificateChain))
	}
	if string(result.CertificateChain[0]) != "fake-der-cert-1" {
		t.Errorf("cert[0] mismatch")
	}
}

func TestParseDeviceAttestationFromPlistFlatFormat(t *testing.T) {
	cert1B64 := base64.StdEncoding.EncodeToString([]byte("flat-cert"))
	data, _ := json.Marshal(map[string]interface{}{
		"DeviceAttestation": cert1B64,
	})
	result, err := ParseDeviceAttestationFromPlist(data)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(result.CertificateChain) != 1 {
		t.Fatalf("expected 1 cert, got %d", len(result.CertificateChain))
	}
}

func TestParseDeviceAttestationFromPlistMissingReturnsError(t *testing.T) {
	data := []byte(`{"payload": {"OtherKey": "value"}}`)
	_, err := ParseDeviceAttestationFromPlist(data)
	if err != ErrNoDeviceAttestation {
		t.Fatalf("expected ErrNoDeviceAttestation, got %v", err)
	}
}

func TestParseDeviceAttestationConcatenatedDER(t *testing.T) {
	now := time.Now().UTC()
	rootPub, rootPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("root key: %v", err)
	}
	rootTmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "test-root"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	rootDER, err := x509.CreateCertificate(rand.Reader, rootTmpl, rootTmpl, rootPub, rootPriv)
	if err != nil {
		t.Fatalf("root cert: %v", err)
	}
	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("leaf key: %v", err)
	}
	leafTmpl := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: "test-leaf"},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTmpl, rootTmpl, &leafKey.PublicKey, rootPriv)
	if err != nil {
		t.Fatalf("leaf cert: %v", err)
	}
	concat := append(append([]byte{}, leafDER...), rootDER...)
	b64 := base64.StdEncoding.EncodeToString(concat)
	data, _ := json.Marshal(map[string]interface{}{
		"DeviceAttestation": b64,
	})
	result, err := ParseDeviceAttestationFromPlist(data)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(result.CertificateChain) != 2 {
		t.Fatalf("expected 2 certs from concatenated DER, got %d", len(result.CertificateChain))
	}
	if !bytes.Equal(result.CertificateChain[0], leafDER) {
		t.Fatal("cert[0] should be leaf DER")
	}
	if !bytes.Equal(result.CertificateChain[1], rootDER) {
		t.Fatal("cert[1] should be root DER")
	}
}
