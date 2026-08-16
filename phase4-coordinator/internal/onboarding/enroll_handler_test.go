package onboarding_test

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/mdm"
	"github.com/augstar/macprovider-coordinator/internal/onboarding"
	"github.com/rs/zerolog"
)

func newTestEnrollHandler() *onboarding.EnrollHandler {
	return &onboarding.EnrollHandler{
		MDMConfig: mdm.Config{
			EnrollmentBaseURL: "https://coordinator.malibu.tech",
			PushTopic:         "com.apple.mgmt.External.test",
		},
		Logger: zerolog.Nop(),
	}
}

func TestHandleEnroll_ValidSerial(t *testing.T) {
	h := newTestEnrollHandler()
	body := bytes.NewBufferString(`{"serial_number":"C02XYZ1234AB"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/enroll", body)
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	h.HandleEnroll(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}
	ct := w.Header().Get("Content-Type")
	if ct != "application/x-apple-aspen-config" {
		t.Errorf("expected Content-Type application/x-apple-aspen-config, got %q", ct)
	}
	if !strings.Contains(w.Body.String(), "com.apple.security.scep") {
		t.Error("response body missing SCEP payload")
	}
	if !strings.Contains(w.Body.String(), "com.apple.mdm") {
		t.Error("response body missing MDM payload")
	}
	if !strings.Contains(w.Body.String(), "C02XYZ1234AB") {
		t.Error("response body missing serial number")
	}
}

func TestHandleEnroll_ContentDispositionHeader(t *testing.T) {
	h := newTestEnrollHandler()
	body := bytes.NewBufferString(`{"serial_number":"C02XYZ1234AB"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/enroll", body)
	w := httptest.NewRecorder()

	h.HandleEnroll(w, req)

	cd := w.Header().Get("Content-Disposition")
	if !strings.Contains(cd, "macprovider-enroll-C02XYZ1234AB.mobileconfig") {
		t.Errorf("unexpected Content-Disposition: %q", cd)
	}
}

func TestHandleEnroll_MissingSerial(t *testing.T) {
	h := newTestEnrollHandler()
	body := bytes.NewBufferString(`{}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/enroll", body)
	w := httptest.NewRecorder()

	h.HandleEnroll(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("expected 400, got %d", w.Code)
	}
}

func TestHandleEnroll_InvalidSerialFormat(t *testing.T) {
	cases := []string{
		"short",          // too short (< 8 chars)
		"C02XYZ1234ABCDE", // too long (> 14 chars)
		"C02-XYZ-1234",  // contains non-alphanumeric
		"",
	}
	h := newTestEnrollHandler()
	for _, serial := range cases {
		body := bytes.NewBufferString(`{"serial_number":"` + serial + `"}`)
		req := httptest.NewRequest(http.MethodPost, "/v1/enroll", body)
		w := httptest.NewRecorder()
		h.HandleEnroll(w, req)
		if w.Code != http.StatusBadRequest {
			t.Errorf("serial %q: expected 400, got %d", serial, w.Code)
		}
	}
}

func TestHandleEnroll_WrongMethod(t *testing.T) {
	h := newTestEnrollHandler()
	req := httptest.NewRequest(http.MethodGet, "/v1/enroll", nil)
	w := httptest.NewRecorder()

	h.HandleEnroll(w, req)

	if w.Code != http.StatusMethodNotAllowed {
		t.Errorf("expected 405, got %d", w.Code)
	}
}

func TestHandleEnroll_InvalidJSON(t *testing.T) {
	h := newTestEnrollHandler()
	body := bytes.NewBufferString(`not json`)
	req := httptest.NewRequest(http.MethodPost, "/v1/enroll", body)
	w := httptest.NewRecorder()

	h.HandleEnroll(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("expected 400, got %d", w.Code)
	}
}

func TestHandleEnroll_ServerURLFromConfig(t *testing.T) {
	h := &onboarding.EnrollHandler{
		MDMConfig: mdm.Config{
			EnrollmentBaseURL: "https://coordinator.malibu.tech",
			MDMServerURL:      "https://mdm.malibu.tech/mdm/connect",
			SCEPUrl:           "https://mdm.malibu.tech/scep",
		},
		Logger: zerolog.Nop(),
	}
	body := bytes.NewBufferString(`{"serial_number":"SERIALTEST1"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/enroll", body)
	w := httptest.NewRecorder()

	h.HandleEnroll(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	resp := w.Body.String()
	if !strings.Contains(resp, "https://mdm.malibu.tech/mdm/connect") {
		t.Error("profile does not contain configured MDM ServerURL")
	}
	if !strings.Contains(resp, "https://mdm.malibu.tech/scep") {
		t.Error("profile does not contain configured SCEP URL")
	}
}
