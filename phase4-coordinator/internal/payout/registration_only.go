package payout

import (
	"database/sql"
	"fmt"
	"net/http"
	"time"

	"github.com/rs/zerolog"
)

// RegistrationOnlyOptions configures the SPEC-016 §3.3 + §6.4.1
// registration-only surface (#954 / SPEC v0.1.26).
//
// Callers MUST NOT start a runner, load a signer/KEK, open RPC
// clients, or acquire the payout lease after this returns.
type RegistrationOnlyOptions struct {
	DB          *sql.DB
	HotWallet   string
	CoolingOff  time.Duration
	Tokens      providerTokenValidator
	Identity    providerIdentityChecker
	Fallback    http.Handler
	OperatorKey string
	// PauseResumeMinInterval is payout.security.pause_resume_min_interval.
	PauseResumeMinInterval time.Duration
	Logger                 zerolog.Logger
}

// BuildRegistrationOnly constructs the registration-only mux:
// provider-token §3.3 challenge/register plus operator-key
// §6.4.1 pause/resume. Execution-only admin routes (run-now,
// abandon, funding, orphans) and GET /providers/{id}/payouts
// are NOT mounted.
func BuildRegistrationOnly(opts RegistrationOnlyOptions) (*AddressesService, http.Handler, error) {
	if opts.DB == nil {
		return nil, nil, fmt.Errorf("payout.BuildRegistrationOnly: db is required")
	}
	if opts.Tokens == nil {
		return nil, nil, fmt.Errorf("payout.BuildRegistrationOnly: tokens is required")
	}
	if opts.Identity == nil {
		return nil, nil, fmt.Errorf("payout.BuildRegistrationOnly: identity is required")
	}
	if opts.Fallback == nil {
		return nil, nil, fmt.Errorf("payout.BuildRegistrationOnly: fallback is required")
	}
	if opts.OperatorKey == "" {
		return nil, nil, fmt.Errorf("payout.BuildRegistrationOnly: OperatorKey is required")
	}
	if opts.CoolingOff < time.Hour {
		return nil, nil, fmt.Errorf("payout.BuildRegistrationOnly: coolingOff must be >= 1h (SPEC §3.1)")
	}
	if opts.PauseResumeMinInterval < time.Second {
		return nil, nil, fmt.Errorf("payout.BuildRegistrationOnly: PauseResumeMinInterval must be >= 1s")
	}

	sec, err := LoadSecurityConfig(opts.HotWallet)
	if err != nil {
		return nil, nil, fmt.Errorf("payout.BuildRegistrationOnly: load security config: %w", err)
	}
	if err := AssertPayoutRuntimeTopology(PayoutRuntimeTopology{
		HandlerEnabled:         true,
		RunnerCoResident:       false,
		ExecutionEnabled:       false,
		HotWalletAddressPinned: sec.HotWalletAddress,
		LinuxRequired:          false,
	}); err != nil {
		return nil, nil, fmt.Errorf("payout.BuildRegistrationOnly: topology: %w", err)
	}

	denyList, err := NewDenyList(sec.HotWalletAddress)
	if err != nil {
		return nil, nil, fmt.Errorf("payout.BuildRegistrationOnly: deny-list: %w", err)
	}
	pauseReader, err := NewPauseReader(opts.DB)
	if err != nil {
		return nil, nil, fmt.Errorf("payout.BuildRegistrationOnly: pause reader: %w", err)
	}
	svc, err := NewAddressesService(opts.DB, sec, denyList, opts.Tokens, opts.Identity, pauseReader, opts.CoolingOff, opts.Logger)
	if err != nil {
		return nil, nil, fmt.Errorf("payout.BuildRegistrationOnly: addresses service: %w", err)
	}

	flagWriter, err := NewRuntimeFlagWriter(opts.DB, opts.Logger)
	if err != nil {
		return nil, nil, fmt.Errorf("payout.BuildRegistrationOnly: flag writer: %w", err)
	}
	pauseSvc, err := NewPauseResumeService(PauseResumeOptions{
		Writer:      flagWriter,
		MinInterval: opts.PauseResumeMinInterval,
		Logger:      opts.Logger,
	})
	if err != nil {
		return nil, nil, fmt.Errorf("payout.BuildRegistrationOnly: pause service: %w", err)
	}

	mux, err := NewMuxRegistrationOnly(RegistrationOnlyMuxOptions{
		Addresses:   svc,
		Pause:       pauseSvc,
		OperatorKey: opts.OperatorKey,
		Actor:       "operator_key:coordinator",
		Fallback:    opts.Fallback,
	})
	if err != nil {
		return nil, nil, fmt.Errorf("payout.BuildRegistrationOnly: mux: %w", err)
	}
	return svc, mux, nil
}
