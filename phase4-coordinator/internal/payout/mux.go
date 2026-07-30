package payout

import (
	"crypto/subtle"
	"fmt"
	"net/http"

	"github.com/go-chi/chi/v5"
)

// AuthRealm names the SPEC-016 §3.3 path-table column —
// "single map[path]authRealm table verified at coordinator
// startup; any registered route NOT in the table fails closed".
// At Step 1 the only realm present is "provider_token" (§3.3).
// Operator-authenticated paths land in Step 2 (run-now,
// abandon-attempt) and Step 3 (record-funding, record-orphan,
// pause/resume).
type AuthRealm string

const (
	// RealmProviderToken denotes per-Mac provider-token auth.
	// Used by POST /providers/{provider_id}/payout-address.
	RealmProviderToken AuthRealm = "provider_token"
	// RealmOperatorKey denotes operator-key auth. Reserved for
	// Steps 2-4 admin paths.
	RealmOperatorKey AuthRealm = "operator_key"
)

// PathTableEntry pairs a chi router pattern with its
// HTTP method and the SPEC-pinned auth realm. The static
// declaration is the canonical source of truth; the Mux
// constructor cross-checks every registered route against the
// table at construction time and fails-fast on mismatch.
type PathTableEntry struct {
	Method string
	Path   string
	Realm  AuthRealm
}

// step1PathTable enumerates every payout-package route that
// Step 1 mounts. Subsequent steps extend this slice with their
// own entries; the audit-verifier asserts that no handler
// escapes this declaration. EXACT-MATCH chi patterns only — no
// trailing-slash prefix routes.
var step1PathTable = []PathTableEntry{
	{Method: http.MethodPost, Path: "/providers/{provider_id}/payout-address", Realm: RealmProviderToken},
}

// step2PathTable extends step1PathTable with the Step 2 admin
// routes. The wildcard fallback /providers/* remains anchored to
// step1; Step 2 adds operator-key surfaces under /admin/payout/*.
var step2PathTable = append([]PathTableEntry{
	{Method: http.MethodPost, Path: "/admin/payout/abandon-attempt", Realm: RealmOperatorKey},
	{Method: http.MethodPost, Path: "/admin/payout/run-now", Realm: RealmOperatorKey},
}, step1PathTable...)

// step3PathTable extends step2PathTable with the §4.9 + §6.4.1 +
// §4.7 admin routes.
var step3PathTable = append([]PathTableEntry{
	{Method: http.MethodPost, Path: "/admin/payout/pause-registration", Realm: RealmOperatorKey},
	{Method: http.MethodPost, Path: "/admin/payout/resume-registration", Realm: RealmOperatorKey},
	{Method: http.MethodPost, Path: "/admin/payout/record-funding", Realm: RealmOperatorKey},
	{Method: http.MethodPost, Path: "/admin/payout/record-orphan", Realm: RealmOperatorKey},
}, step2PathTable...)

// step4PathTable extends step3PathTable with the §7.3 provider-
// scoped read endpoint. Provider-token (NOT operator) auth.
var step4PathTable = append([]PathTableEntry{
	{Method: http.MethodGet, Path: "/providers/{provider_id}/payouts", Realm: RealmProviderToken},
}, step3PathTable...)

// NewMux constructs the chi-based payout HTTP router. The
// returned http.Handler is mounted by main.go on the existing
// provider listener (the SPEC's `:8444` ws-mux listener) at the
// `/providers/` prefix; chi's longest-pattern-match semantics
// route /providers/{id}/payout-address to the §3.3 handler and
// delegate everything else (e.g. /providers/{id}/earnings) to
// the fallback handler.
//
// SPEC §3.3 path-table requirement: this constructor checks
// that EVERY route registered with chi appears verbatim in
// step1PathTable AND that NO declared table entry is missing
// from the chi router. Any drift fails-fast at startup.
//
// fallback is invoked for any /providers/* path the payout
// router does not own (e.g. billing earnings). Non-/providers
// paths are NOT delegated to the fallback — they 404.
func NewMux(addresses *AddressesService, fallback http.Handler) (http.Handler, error) {
	if addresses == nil {
		return nil, fmt.Errorf("payout.NewMux: AddressesService is required")
	}
	if fallback == nil {
		return nil, fmt.Errorf("payout.NewMux: fallback handler is required")
	}
	r := chi.NewRouter()

	// §3.3 handler — provider_token auth.
	r.Post("/providers/{provider_id}/payout-address", addresses.ServePayoutAddress)

	// Everything else under /providers/ delegates to the
	// fallback. The route is registered with chi so the path-
	// table audit can declare it; we list it AFTER the explicit
	// /payout-address pattern so chi's most-specific-match
	// resolves correctly.
	r.HandleFunc("/providers/*", fallback.ServeHTTP)

	// SPEC §3.3 path-table verification. Walk chi's routes and
	// confirm parity with step1PathTable.
	if err := verifyPathTable(r, step1PathTable); err != nil {
		return nil, err
	}
	return r, nil
}

// Step2MuxOptions bundles the Step 2 admin-route dependencies
// for the extended router. Caller is responsible for verifying
// operator-key auth BEFORE invoking the handlers; this constructor
// installs a thin auth middleware that extracts the bearer and
// hands `actor` to the abandon service for rate-limit scoping.
type Step2MuxOptions struct {
	Addresses *AddressesService
	Abandon   *AbandonService
	Runner    *Runner
	// RunNow is the shared §4.2 run-now controller. Step 4 r2
	// [code:r2-1]/[sec:r2-1]/[arch:r2-4.1] CONVERGENT MAJOR closure:
	// rate-limit + payout_run_now_invoked event wired through the
	// controller so all Step2/3/4 mux levels share the same gate.
	RunNow      *RunNowController
	OperatorKey string
	Caps        AbandonCaps
	Fallback    http.Handler
}

// NewMuxStep2 returns a chi router with §3.3 + §4.6 + §4.2 admin
// surfaces all registered. The path-table verifier asserts parity
// with step2PathTable. The wildcard /providers/* fallback ALSO
// catches /admin/payout/* not declared (defense-in-depth against
// a future route added without table update).
func NewMuxStep2(opts Step2MuxOptions) (http.Handler, error) {
	if opts.Addresses == nil {
		return nil, fmt.Errorf("payout.NewMuxStep2: AddressesService required")
	}
	if opts.Abandon == nil {
		return nil, fmt.Errorf("payout.NewMuxStep2: AbandonService required")
	}
	if opts.Runner == nil {
		return nil, fmt.Errorf("payout.NewMuxStep2: Runner required")
	}
	if opts.OperatorKey == "" {
		return nil, fmt.Errorf("payout.NewMuxStep2: OperatorKey required")
	}
	if opts.Fallback == nil {
		return nil, fmt.Errorf("payout.NewMuxStep2: Fallback required")
	}
	if opts.RunNow == nil {
		return nil, fmt.Errorf("payout.NewMuxStep2: RunNow controller required")
	}
	r := chi.NewRouter()

	r.Post("/providers/{provider_id}/payout-address", opts.Addresses.ServePayoutAddress)
	r.HandleFunc("/providers/*", opts.Fallback.ServeHTTP)

	// Operator-key auth shim for the admin routes.
	auth := operatorKeyMiddleware(opts.OperatorKey)
	r.With(auth).Post("/admin/payout/abandon-attempt", withHaltObservability(
		"abandon-attempt", opts.Runner,
		func(w http.ResponseWriter, req *http.Request) {
			opts.Abandon.ServeAbandon(w, req, "operator_key", opts.Caps)
		}))
	// Step 4 r2 [code:r2-1]/[sec:r2-1]/[arch:r2-4.1] CONVERGENT MAJOR
	// closure: delegate to shared RunNowController which enforces
	// run_now_min_interval rate-limit and emits payout_run_now_invoked.
	// run-now is the only admin endpoint halt-blocked (the controller
	// returns 409 + runner_halted body); see RunNowController.ServeRunNow.
	r.With(auth).Post("/admin/payout/run-now", func(w http.ResponseWriter, req *http.Request) {
		opts.RunNow.ServeRunNow(w, req, "operator_key")
	})

	if err := verifyPathTable(r, step2PathTable); err != nil {
		return nil, err
	}
	return r, nil
}

// Step3MuxOptions bundles Step 3 admin-route dependencies on top
// of Step 2.
type Step3MuxOptions struct {
	Step2MuxOptions
	Pause   *PauseResumeService
	Funding *FundingService
	Orphans *OrphansService
	Actor   string // operator_key:<key_id> — passed to pause/resume audit row
}

// NewMuxStep3 returns a chi router with §3.3 + §4.2 + §4.6 + §4.7
// + §4.9 + §6.4.1 admin surfaces all registered. The path-table
// verifier asserts parity with step3PathTable.
func NewMuxStep3(opts Step3MuxOptions) (http.Handler, error) {
	if opts.Addresses == nil {
		return nil, fmt.Errorf("payout.NewMuxStep3: AddressesService required")
	}
	if opts.Abandon == nil {
		return nil, fmt.Errorf("payout.NewMuxStep3: AbandonService required")
	}
	if opts.Runner == nil {
		return nil, fmt.Errorf("payout.NewMuxStep3: Runner required")
	}
	if opts.OperatorKey == "" {
		return nil, fmt.Errorf("payout.NewMuxStep3: OperatorKey required")
	}
	if opts.Fallback == nil {
		return nil, fmt.Errorf("payout.NewMuxStep3: Fallback required")
	}
	if opts.Pause == nil {
		return nil, fmt.Errorf("payout.NewMuxStep3: Pause required")
	}
	if opts.Funding == nil {
		return nil, fmt.Errorf("payout.NewMuxStep3: Funding required")
	}
	if opts.Orphans == nil {
		return nil, fmt.Errorf("payout.NewMuxStep3: Orphans required")
	}
	if opts.Actor == "" {
		return nil, fmt.Errorf("payout.NewMuxStep3: Actor required")
	}
	if opts.RunNow == nil {
		return nil, fmt.Errorf("payout.NewMuxStep3: RunNow controller required")
	}
	r := chi.NewRouter()

	r.Post("/providers/{provider_id}/payout-address", opts.Addresses.ServePayoutAddress)
	r.HandleFunc("/providers/*", opts.Fallback.ServeHTTP)

	auth := operatorKeyMiddleware(opts.OperatorKey)
	r.With(auth).Post("/admin/payout/abandon-attempt", withHaltObservability(
		"abandon-attempt", opts.Runner,
		func(w http.ResponseWriter, req *http.Request) {
			opts.Abandon.ServeAbandon(w, req, "operator_key", opts.Caps)
		}))
	// Step 4 r2 [code:r2-1]/[sec:r2-1]/[arch:r2-4.1] CONVERGENT MAJOR
	// closure: shared RunNowController enforces rate-limit + event.
	// run-now is the only admin endpoint halt-blocked (see Step2 mux).
	r.With(auth).Post("/admin/payout/run-now", func(w http.ResponseWriter, req *http.Request) {
		opts.RunNow.ServeRunNow(w, req, "operator_key")
	})
	// §6.4.1 pause/resume — explicit allow-during-halt per
	// FULL-r1 [full-code:r1-3] bypass policy (operator triage tool).
	r.With(auth).Post("/admin/payout/pause-registration", withHaltObservability(
		"pause-registration", opts.Runner,
		func(w http.ResponseWriter, req *http.Request) {
			opts.Pause.ServePause(w, req, opts.Actor)
		}))
	r.With(auth).Post("/admin/payout/resume-registration", withHaltObservability(
		"resume-registration", opts.Runner,
		func(w http.ResponseWriter, req *http.Request) {
			opts.Pause.ServeResume(w, req, opts.Actor)
		}))
	// §4.9 record-funding — explicit allow-during-halt.
	r.With(auth).Post("/admin/payout/record-funding", withHaltObservability(
		"record-funding", opts.Runner, opts.Funding.ServeRecordFunding))
	// §4.7 record-orphan — explicit allow-during-halt.
	r.With(auth).Post("/admin/payout/record-orphan", withHaltObservability(
		"record-orphan", opts.Runner, opts.Orphans.ServeRecordOrphan))

	if err := verifyPathTable(r, step3PathTable); err != nil {
		return nil, err
	}
	return r, nil
}

// Step4MuxOptions extends Step3MuxOptions with the §7.3
// provider-token-authed payouts read endpoint dependency.
type Step4MuxOptions struct {
	Step3MuxOptions
	Payouts *PayoutsHandler
}

// NewMuxStep4 returns the Step 4 chi router with all Step 1+2+3
// surfaces PLUS the §7.3 GET /providers/{provider_id}/payouts
// provider-token read endpoint. Path-table verifier asserts
// parity with step4PathTable.
func NewMuxStep4(opts Step4MuxOptions) (http.Handler, error) {
	if opts.Addresses == nil {
		return nil, fmt.Errorf("payout.NewMuxStep4: AddressesService required")
	}
	if opts.Abandon == nil {
		return nil, fmt.Errorf("payout.NewMuxStep4: AbandonService required")
	}
	if opts.Runner == nil {
		return nil, fmt.Errorf("payout.NewMuxStep4: Runner required")
	}
	if opts.OperatorKey == "" {
		return nil, fmt.Errorf("payout.NewMuxStep4: OperatorKey required")
	}
	if opts.Fallback == nil {
		return nil, fmt.Errorf("payout.NewMuxStep4: Fallback required")
	}
	if opts.Pause == nil {
		return nil, fmt.Errorf("payout.NewMuxStep4: Pause required")
	}
	if opts.Funding == nil {
		return nil, fmt.Errorf("payout.NewMuxStep4: Funding required")
	}
	if opts.Orphans == nil {
		return nil, fmt.Errorf("payout.NewMuxStep4: Orphans required")
	}
	if opts.Actor == "" {
		return nil, fmt.Errorf("payout.NewMuxStep4: Actor required")
	}
	if opts.Payouts == nil {
		return nil, fmt.Errorf("payout.NewMuxStep4: Payouts handler required")
	}
	if opts.RunNow == nil {
		return nil, fmt.Errorf("payout.NewMuxStep4: RunNow controller required")
	}
	r := chi.NewRouter()

	// Step 1: §3.3 provider-token registration handler.
	r.Post("/providers/{provider_id}/payout-address", opts.Addresses.ServePayoutAddress)
	// Step 4: §7.3 provider-token payouts read endpoint.
	r.Get("/providers/{provider_id}/payouts", opts.Payouts.ServePayouts)
	// Fallback wildcard for non-payout /providers/* paths.
	r.HandleFunc("/providers/*", opts.Fallback.ServeHTTP)

	auth := operatorKeyMiddleware(opts.OperatorKey)
	// FULL-r1 [full-code:r1-3] MEDIUM closure: admin halt-bypass
	// policy — every admin endpoint OTHER than run-now is wrapped
	// with withHaltObservability so an invocation during halt
	// emits payout_admin_invoked_while_halted but does NOT block.
	// Rationale: the operator MUST be able to abandon a stuck row,
	// pause registration, record funding, and mark a reorg orphan
	// while triaging the incident that triggered halt. run-now
	// triggers chain operations and is the only halt-blocked
	// admin endpoint; the 409 gate lives in RunNowController.
	r.With(auth).Post("/admin/payout/abandon-attempt", withHaltObservability(
		"abandon-attempt", opts.Runner,
		func(w http.ResponseWriter, req *http.Request) {
			opts.Abandon.ServeAbandon(w, req, "operator_key", opts.Caps)
		}))
	r.With(auth).Post("/admin/payout/run-now", func(w http.ResponseWriter, req *http.Request) {
		opts.RunNow.ServeRunNow(w, req, "operator_key")
	})
	r.With(auth).Post("/admin/payout/pause-registration", withHaltObservability(
		"pause-registration", opts.Runner,
		func(w http.ResponseWriter, req *http.Request) {
			opts.Pause.ServePause(w, req, opts.Actor)
		}))
	r.With(auth).Post("/admin/payout/resume-registration", withHaltObservability(
		"resume-registration", opts.Runner,
		func(w http.ResponseWriter, req *http.Request) {
			opts.Pause.ServeResume(w, req, opts.Actor)
		}))
	r.With(auth).Post("/admin/payout/record-funding", withHaltObservability(
		"record-funding", opts.Runner, opts.Funding.ServeRecordFunding))
	r.With(auth).Post("/admin/payout/record-orphan", withHaltObservability(
		"record-orphan", opts.Runner, opts.Orphans.ServeRecordOrphan))

	if err := verifyPathTable(r, step4PathTable); err != nil {
		return nil, err
	}
	return r, nil
}

// withHaltObservability wraps an admin handler with the FULL-r1
// [full-code:r1-3] MEDIUM bypass policy: admin endpoints OTHER
// than run-now are explicitly ALLOWED during runner halt because
// the operator needs them to triage the incident that triggered
// halt — abandon a stuck broadcast, pause provider registration,
// record a manual funding event, mark a reorg orphan. The wrapper
// emits a non-blocking payout_admin_invoked_while_halted
// observability event so a runbook can correlate the triage
// action to the halt reason.
//
// run-now is the only admin endpoint that triggers chain operations
// (RunOnce); its halt gate lives inside RunNowController and remains
// 409-rejecting.
//
// runner may be nil (Step1MuxOptions does not carry a Runner); in
// that posture the wrapper is a no-op pass-through.
func withHaltObservability(name string, runner *Runner, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		if runner != nil && runner.IsHalted() {
			runner.EmitAdminInvokedWhileHalted(name)
		}
		next(w, req)
	}
}

func operatorKeyMiddleware(operatorKey string) func(http.Handler) http.Handler {
	expected := []byte(operatorKey)
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			raw := bearerFromHeader(r.Header.Get("Authorization"))
			// Codex round-2 [sec:r2-2.2] LOW closure: bearer
			// equality MUST be constant-time. subtle.ConstantTimeCompare
			// also requires equal-length inputs; check up-front.
			given := []byte(raw)
			if len(given) == 0 || len(given) != len(expected) || subtle.ConstantTimeCompare(given, expected) != 1 {
				writeError(w, http.StatusUnauthorized, "unauthorized")
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// verifyPathTable walks the chi router and asserts every
// payout-owned route appears in the SPEC-declared table.
// Routes registered via HandleFunc (the fallback delegate
// wildcard above) are explicitly excluded — they are not
// payout-realm routes.
func verifyPathTable(r chi.Router, table []PathTableEntry) error {
	declared := make(map[string]AuthRealm, len(table))
	for _, entry := range table {
		key := entry.Method + " " + entry.Path
		declared[key] = entry.Realm
	}
	registered := map[string]bool{}
	err := chi.Walk(r, func(method, route string, _ http.Handler, _ ...func(http.Handler) http.Handler) error {
		key := method + " " + route
		// The wildcard fallback is intentionally NOT in the
		// declared table.
		if route == "/providers/*" {
			return nil
		}
		registered[key] = true
		if _, ok := declared[key]; !ok {
			return fmt.Errorf("payout: route %s registered with chi but missing from SPEC path-table", key)
		}
		return nil
	})
	if err != nil {
		return err
	}
	for key := range declared {
		if !registered[key] {
			return fmt.Errorf("payout.NewMux: SPEC §3.3 path-table declares %s but it is not registered with chi", key)
		}
	}
	return nil
}
