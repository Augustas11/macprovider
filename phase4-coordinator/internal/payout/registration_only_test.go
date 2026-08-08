package payout

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestBuildRegistrationOnly_MountsChallengeRegisterAndPause(t *testing.T) {
	db := openTestDB(t)
	logger, _ := quietLogger()
	if err := BootstrapRuntimeFlags(context.Background(), db, time.Now().UTC(), logger); err != nil {
		t.Fatalf("bootstrap: %v", err)
	}

	hotWallet := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	ft := &fakeTokens{token: "tok", providerID: "test-pid"}
	fallback := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})

	svc, mux, err := BuildRegistrationOnly(RegistrationOnlyOptions{
		DB:                     db,
		HotWallet:              hotWallet,
		CoolingOff:             24 * time.Hour,
		Tokens:                 ft,
		Identity:               ft,
		Fallback:               fallback,
		OperatorKey:            "test-operator-key-32bytes-long!!!!",
		PauseResumeMinInterval: time.Second,
		Logger:                 logger,
	})
	if err != nil {
		t.Fatalf("BuildRegistrationOnly: %v", err)
	}
	if svc == nil || mux == nil {
		t.Fatal("expected non-nil service and mux")
	}

	challengeReq := httptest.NewRequest(http.MethodGet, "/providers/test-pid/payout-address/challenge", nil)
	challengeRec := httptest.NewRecorder()
	mux.ServeHTTP(challengeRec, challengeReq)
	if challengeRec.Code != http.StatusUnauthorized {
		t.Fatalf("challenge status=%d want 401 without bearer", challengeRec.Code)
	}

	regReq := httptest.NewRequest(http.MethodPost, "/providers/test-pid/payout-address", strings.NewReader(`{}`))
	regRec := httptest.NewRecorder()
	mux.ServeHTTP(regRec, regReq)
	if regRec.Code == http.StatusNotFound {
		t.Fatalf("register route 404 — registration-only mux did not mount §3.3")
	}
	if regRec.Code != http.StatusUnauthorized {
		t.Fatalf("register status=%d want 401 without bearer", regRec.Code)
	}

	// Pause kill switch MUST be mounted (operator-key auth → 401 without key).
	pauseReq := httptest.NewRequest(http.MethodPost, "/admin/payout/pause-registration", strings.NewReader(`{"reason":"test"}`))
	pauseRec := httptest.NewRecorder()
	mux.ServeHTTP(pauseRec, pauseReq)
	if pauseRec.Code != http.StatusUnauthorized {
		t.Fatalf("pause status=%d want 401 without operator key", pauseRec.Code)
	}

	// Execution-only admin routes MUST NOT be mounted.
	adminReq := httptest.NewRequest(http.MethodPost, "/admin/payout/run-now", nil)
	adminRec := httptest.NewRecorder()
	mux.ServeHTTP(adminRec, adminReq)
	if adminRec.Code != http.StatusNotFound {
		t.Fatalf("admin run-now status=%d want 404 in registration-only", adminRec.Code)
	}

	payoutsReq := httptest.NewRequest(http.MethodGet, "/providers/test-pid/payouts", nil)
	payoutsRec := httptest.NewRecorder()
	mux.ServeHTTP(payoutsRec, payoutsReq)
	if payoutsRec.Code != http.StatusNoContent {
		t.Fatalf("payouts path status=%d want fallback 204", payoutsRec.Code)
	}
}

func TestBuildRegistrationOnly_RequiresHotWallet(t *testing.T) {
	db := openTestDB(t)
	logger, _ := quietLogger()
	ft := &fakeTokens{token: "tok", providerID: "test-pid"}
	fallback := http.HandlerFunc(func(http.ResponseWriter, *http.Request) {})
	_, _, err := BuildRegistrationOnly(RegistrationOnlyOptions{
		DB:                     db,
		HotWallet:              "",
		CoolingOff:             24 * time.Hour,
		Tokens:                 ft,
		Identity:               ft,
		Fallback:               fallback,
		OperatorKey:            "test-operator-key-32bytes-long!!!!",
		PauseResumeMinInterval: time.Second,
		Logger:                 logger,
	})
	if err == nil {
		t.Fatal("expected error for empty hot wallet")
	}
}

func TestBuildRegistrationOnly_RequiresCoolingOffFloor(t *testing.T) {
	db := openTestDB(t)
	logger, _ := quietLogger()
	ft := &fakeTokens{token: "tok", providerID: "test-pid"}
	fallback := http.HandlerFunc(func(http.ResponseWriter, *http.Request) {})
	_, _, err := BuildRegistrationOnly(RegistrationOnlyOptions{
		DB:                     db,
		HotWallet:              "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
		CoolingOff:             30 * time.Minute,
		Tokens:                 ft,
		Identity:               ft,
		Fallback:               fallback,
		OperatorKey:            "test-operator-key-32bytes-long!!!!",
		PauseResumeMinInterval: time.Second,
		Logger:                 logger,
	})
	if err == nil {
		t.Fatal("expected error for coolingOff < 1h")
	}
}
