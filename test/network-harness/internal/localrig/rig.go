// Package localrig spins up a fully-connected macprovider stack —
// coordinator + gateway + N in-process fake providers — on 127.0.0.1
// for load/fairness scenarios that would DoS Pearl at production
// scale.
//
// TODO(shared-rig-refactor): the coordinator / gateway YAML shapes
// written here parallel what test/integration/harness_test.go writes.
// PR 1 forks the config on purpose so the load-lane deadline doesn't
// unpick integration's testing.T assumptions; after 2-3 load scenarios
// reveal the shared surface, lift a canonical rigconfig package that
// both call sites depend on, plus a shape-parity test that fails when
// integration's YAML shape diverges from the load rig's.
//
// The rig is bring-up-only: it produces URLs, a fresh buyer API key,
// and SQLite paths, then hands control to the caller. Nothing here
// fires requests; that is the scenario runner's job. Shutdown cancels
// the rig's root context, waits for the coordinator, gateway, and
// every fake provider to exit, and removes the rig's WorkDir.
//
// Design notes:
//
//   - Coordinator + gateway are real binaries built by go build. The
//     rig treats them as opaque processes so the boundary contract is
//     exercised end-to-end (same shape as test/integration).
//
//   - Fake providers run in-process. Each connects to the coordinator
//     over WebSocket using the v1 hello handshake (endpoint_url mode)
//     and serves canned OpenAI-shaped chat completions on 127.0.0.1
//     with configurable TTFT, TPS, and concurrency cap.
//
//   - Settlement is off (verified_model_settlement_mode="observe"),
//     so no SPEC-015 receipt crypto ships in this package.
package localrig

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"sync/atomic"
)

// Config parameterizes a rig lifecycle. Populated from scenario.Target.
type Config struct {
	Providers []Provider

	// WorkDir, when non-empty, is used as the rig's root tempdir. Empty
	// → os.MkdirTemp("macprovider-localrig-*"). Written binaries land
	// under WorkDir/bin, DBs under WorkDir/db, YAMLs under WorkDir/etc.
	WorkDir string

	// Logger, when non-nil, receives one line per subprocess stdout/stderr
	// line prefixed with "[coord] " / "[gateway] " / "[prov-<id>] ".
	// nil → log.Default().
	Logger func(string)
}

// Provider mirrors scenario.RigProvider without dragging the scenario
// package into localrig (which would create an import cycle once the
// scenario runner calls into localrig).
//
// The rig only implements one provider process kind in PR 1 (the
// in-process fake); the internal providerProcess interface below is
// the seam future PRs use to add failure-mode-injecting or real
// `macprovider-cli` providers without rewriting Start.
type Provider struct {
	ID            string
	Model         string
	TTFTMs        int
	TokensPerSec  float64
	CapacitySlots int

	// Kind selects which provider-process implementation the rig will
	// spin up. Zero value = ProviderKindFake (the only kind PR 1
	// ships). Follow-up PRs add ProviderKindFailInject (PR 3 asymmetric
	// starvation, with policy fields for controlled 5xx / slow-response)
	// and ProviderKindRealBinary (attaches a real macprovider-cli
	// process; needs BinaryPath / ModelWeights fields not defined here).
	// Fields specific to a Kind live on a matching *Config sub-struct
	// added when that Kind ships, so this stable shape never breaks.
	Kind ProviderKind
}

// ProviderKind selects the provider-process implementation.
type ProviderKind string

const (
	// ProviderKindFake is the in-process synthetic provider: canned
	// OpenAI-shaped completion with TTFTMs sleep + TokensPerSec pacing
	// + CapacitySlots concurrency cap. The only kind implemented in
	// PR 1; also the default when Kind is empty.
	ProviderKindFake ProviderKind = ""
)

// providerProcess is the internal contract every provider-process
// implementation satisfies. Kept unexported so PR 1's public API stays
// stable while follow-up PRs plug in more implementations. rig.Start
// dispatches on Provider.Kind to construct the right instance.
type providerProcess interface {
	// start brings the process to Ready: an in-process HTTP endpoint
	// listening on 127.0.0.1:port plus, if applicable, a WS connection
	// to the coordinator's provider plane. Returns when both halves
	// are running; readiness at the coord's /poolz view is a separate
	// wait step outside the process's control.
	start(ctx context.Context) error
	// stop signals the process to tear down. Idempotent; must be safe
	// to call even if start returned an error.
	stop()
}

// Rig is a running local stack. Constructed by Start; released by Shutdown.
type Rig struct {
	// GatewayURL is the buyer-facing http://127.0.0.1:<port> URL.
	GatewayURL string
	// CoordinatorBuyerURL is the coordinator's buyer-plane URL.
	CoordinatorBuyerURL string
	// BuyerToken is a fresh mp_<...> API key seeded into the gateway
	// for this rig's lifetime. Test tokens only; never Pearl.
	BuyerToken string
	// CoordinatorDBPath / GatewayDBPath are the SQLite files the harness
	// reconcile package reads.
	CoordinatorDBPath string
	GatewayDBPath     string

	// unexported bookkeeping
	workDir       string
	ownWorkDir    bool // rig created the tempdir → remove on shutdown
	logger        func(string)
	rootCancel    context.CancelFunc
	procWG        sync.WaitGroup
	// providers holds every started provider-process implementation.
	// In PR 1 every entry is a *FakeProvider; the interface indirection
	// makes ProviderKindFailInject / ProviderKindRealBinary additive
	// without changing Start's control flow.
	providers []providerProcess

	// fakeProviders is a typed slice of the *FakeProvider subset of
	// providers, retained for future test hooks that need the concrete
	// type (e.g., inspecting Hits()). Kept in sync with providers.
	fakeProviders []*FakeProvider
	shutdownOnce  sync.Once
	shutdownErr   error

	// crash tracks the first supervised subprocess (coord/gateway) that
	// exits unexpectedly. Closed once the first crash lands so callers
	// can select on it and fail-fast instead of blocking on buyer.Run
	// against a dead gateway. Populated only via registerProc's
	// exit-observer goroutine.
	crashOnce sync.Once
	crashCh   chan struct{}
	crashErr  error
	crashMu   sync.Mutex

	// shuttingDown flips true once Shutdown begins so registerProc's
	// exit observer knows subsequent child exits are expected and MUST
	// NOT be recorded as crashes. Atomic because both Shutdown and the
	// exit-observer goroutines touch it without external coordination.
	shuttingDown atomic.Bool
}

// Done returns a channel that closes when any supervised subprocess
// (coordinator or gateway) exits unexpectedly. Fake providers do not
// count — they are in-process and their errors surface directly to the
// buyer request path. Callers should race Done() against buyer.Run to
// abort a scenario as soon as the rig loses a required binary.
func (r *Rig) Done() <-chan struct{} {
	return r.crashCh
}

// Err returns the reason recorded on the first supervised crash, or
// nil if no crash has been observed. Only meaningful after Done()
// closes.
func (r *Rig) Err() error {
	r.crashMu.Lock()
	defer r.crashMu.Unlock()
	return r.crashErr
}

// Start builds binaries (once per WorkDir), writes configs, spawns
// coordinator + gateway + fake providers, waits for everything to be
// Ready, and returns the running rig.
//
// On any bring-up failure Start tears down whatever it has already
// spawned and cleans the WorkDir before returning. Callers get an
// error and should NOT call Shutdown.
func Start(ctx context.Context, cfg Config) (_ *Rig, retErr error) {
	if len(cfg.Providers) == 0 {
		return nil, fmt.Errorf("localrig: config.Providers must be non-empty")
	}
	logger := cfg.Logger
	if logger == nil {
		logger = func(line string) { log.Println(line) }
	}

	workDir := cfg.WorkDir
	ownWorkDir := false
	if workDir == "" {
		dir, err := os.MkdirTemp("", "macprovider-localrig-*")
		if err != nil {
			return nil, fmt.Errorf("localrig: mkdir tempdir: %w", err)
		}
		workDir = dir
		ownWorkDir = true
	}
	// Ensure sub-dirs exist so Write callers can drop files straight in.
	for _, sub := range []string{"bin", "db", "etc"} {
		if err := os.MkdirAll(filepath.Join(workDir, sub), 0o750); err != nil {
			if ownWorkDir {
				_ = os.RemoveAll(workDir)
			}
			return nil, fmt.Errorf("localrig: mkdir %s: %w", sub, err)
		}
	}

	rigCtx, cancel := context.WithCancel(ctx)
	r := &Rig{
		workDir:           workDir,
		ownWorkDir:        ownWorkDir,
		logger:            logger,
		rootCancel:        cancel,
		crashCh:           make(chan struct{}),
		CoordinatorDBPath: filepath.Join(workDir, "db", "coordinator.db"),
		GatewayDBPath:     filepath.Join(workDir, "db", "gateway.db"),
	}
	// Defer a full teardown on error so partial state doesn't leak.
	defer func() {
		if retErr == nil {
			return
		}
		cancel()
		r.procWG.Wait()
		if ownWorkDir {
			_ = os.RemoveAll(workDir)
		}
	}()

	repoRoot, err := findRepoRoot()
	if err != nil {
		return nil, fmt.Errorf("localrig: find repo root: %w", err)
	}
	binDir := filepath.Join(workDir, "bin")
	coordBin, coordCLIBin, gwBin, err := buildBinaries(rigCtx, repoRoot, binDir)
	if err != nil {
		return nil, fmt.Errorf("localrig: build binaries: %w", err)
	}

	// Ports.
	buyerPort, err := allocatePort()
	if err != nil {
		return nil, fmt.Errorf("localrig: alloc buyer port: %w", err)
	}
	provPort, err := allocatePort()
	if err != nil {
		return nil, fmt.Errorf("localrig: alloc provider port: %w", err)
	}
	gwPort, err := allocatePort()
	if err != nil {
		return nil, fmt.Errorf("localrig: alloc gateway port: %w", err)
	}
	providerPorts := make([]int, len(cfg.Providers))
	for i := range cfg.Providers {
		p, err := allocatePort()
		if err != nil {
			return nil, fmt.Errorf("localrig: alloc provider[%d] port: %w", i, err)
		}
		providerPorts[i] = p
	}

	r.CoordinatorBuyerURL = fmt.Sprintf("http://127.0.0.1:%d", buyerPort)
	coordProvURL := fmt.Sprintf("http://127.0.0.1:%d", provPort)
	r.GatewayURL = fmt.Sprintf("http://127.0.0.1:%d", gwPort)

	// Secrets — every rig gets a fresh set. Test-only material; never
	// printed via the Logger.
	operatorKey, err := randHex(32)
	if err != nil {
		return nil, fmt.Errorf("localrig: gen operator key: %w", err)
	}
	serviceToken, err := randHex(32)
	if err != nil {
		return nil, fmt.Errorf("localrig: gen service token: %w", err)
	}
	keyHashSecret, err := randHex(32)
	if err != nil {
		return nil, fmt.Errorf("localrig: gen key-hash secret: %w", err)
	}
	demoSecret, err := randHex(32)
	if err != nil {
		return nil, fmt.Errorf("localrig: gen demo secret: %w", err)
	}
	accountSuffix, err := randHex(8)
	if err != nil {
		return nil, fmt.Errorf("localrig: gen account id: %w", err)
	}
	accountID := "acct_" + accountSuffix

	coordYAML := filepath.Join(workDir, "etc", "coordinator.yaml")
	gwYAML := filepath.Join(workDir, "etc", "gateway.yaml")

	if err := writeCoordinatorYAML(coordYAML, coordYAMLInputs{
		buyerPort:           buyerPort,
		provPort:            provPort,
		dbPath:              r.CoordinatorDBPath,
		operatorKey:         operatorKey,
		gatewayServiceToken: serviceToken,
		providers:           cfg.Providers,
		providerPorts:       providerPorts,
	}); err != nil {
		return nil, fmt.Errorf("localrig: write coordinator yaml: %w", err)
	}
	if err := writeGatewayYAML(gwYAML, gwYAMLInputs{
		gwPort:         gwPort,
		dbPath:         r.GatewayDBPath,
		coordBuyerURL:  r.CoordinatorBuyerURL,
		coordProvURL:   coordProvURL,
		operatorKey:    operatorKey,
		serviceToken:   serviceToken,
		keyHashSecret:  keyHashSecret,
		demoSecret:     demoSecret,
	}); err != nil {
		return nil, fmt.Errorf("localrig: write gateway yaml: %w", err)
	}

	// Issue a token per pinned provider BEFORE the coordinator starts.
	// coordinator-cli creates + migrates the DB, so this is the first
	// thing that touches the SQLite file. The coordinator binary then
	// opens the same WAL DB on startup.
	providerTokens := make([]string, len(cfg.Providers))
	for i, p := range cfg.Providers {
		tok, err := issueProviderToken(coordCLIBin, r.CoordinatorDBPath, p.ID, fmt.Sprintf("fake-%s", p.ID))
		if err != nil {
			return nil, fmt.Errorf("localrig: issue provider token %q: %w", p.ID, err)
		}
		providerTokens[i] = tok
	}

	// Seed the gateway account + api_keys row. This pre-boots the
	// gateway binary briefly to run schema migrations, kills it, then
	// writes rows directly.
	buyerToken, err := seedGatewayAccountAndKey(ctx, gwBin, gwYAML, r.GatewayDBPath, keyHashSecret, accountID)
	if err != nil {
		return nil, fmt.Errorf("localrig: seed gateway account: %w", err)
	}
	r.BuyerToken = buyerToken

	// Start coordinator first — the gateway's healthz reaches back to
	// coord on first hit, so ordering matters for a clean startup.
	if err := startCoordinator(rigCtx, r, coordBin, coordYAML); err != nil {
		return nil, fmt.Errorf("localrig: start coordinator: %w", err)
	}
	// Health-check both coord ports before spawning fakes; providers-
	// ready check comes AFTER the fakes are connected + heartbeating.
	if err := waitForHealth(rigCtx, r.CoordinatorBuyerURL+"/healthz"); err != nil {
		return nil, fmt.Errorf("localrig: coord buyer healthz: %w", err)
	}
	if err := waitForHealth(rigCtx, coordProvURL+"/healthz"); err != nil {
		return nil, fmt.Errorf("localrig: coord provider healthz: %w", err)
	}
	providerIDs := make([]string, len(cfg.Providers))
	for i, p := range cfg.Providers {
		providerIDs[i] = p.ID
	}

	// Spawn providers. Dispatched on Kind; PR 1 only implements
	// ProviderKindFake so any other Kind is a validation error caught
	// upstream in scenario.validateRigTarget or here as a fallback.
	for i, p := range cfg.Providers {
		proc, fake, err := r.newProviderProcess(p, providerPorts[i], coordProvURL, providerTokens[i])
		if err != nil {
			return nil, fmt.Errorf("localrig: build provider %q: %w", p.ID, err)
		}
		if err := proc.start(rigCtx); err != nil {
			return nil, fmt.Errorf("localrig: start provider %q: %w", p.ID, err)
		}
		r.providers = append(r.providers, proc)
		if fake != nil {
			r.fakeProviders = append(r.fakeProviders, fake)
		}
	}
	if err := waitForProvidersReady(rigCtx, coordProvURL, providerIDs, operatorKey); err != nil {
		return nil, fmt.Errorf("localrig: providers-ready: %w", err)
	}

	// Start the gateway.
	if err := startGateway(rigCtx, r, gwBin, gwYAML); err != nil {
		return nil, fmt.Errorf("localrig: start gateway: %w", err)
	}
	if err := waitForHealth(rigCtx, r.GatewayURL+"/healthz"); err != nil {
		return nil, fmt.Errorf("localrig: gateway healthz: %w", err)
	}

	return r, nil
}

// Shutdown cancels the rig's root context, waits for all subprocesses
// to exit, and cleans the WorkDir if the rig created it. Idempotent.
func (r *Rig) Shutdown() error {
	r.shutdownOnce.Do(func() {
		// Flip the shuttingDown flag BEFORE cancelling so exit observers
		// racing the child process exit see it in time and treat the
		// resulting cmd.Wait return as expected.
		r.shuttingDown.Store(true)
		if r.rootCancel != nil {
			r.rootCancel()
		}
		for _, p := range r.providers {
			p.stop()
		}
		r.procWG.Wait()
		if r.ownWorkDir && r.workDir != "" {
			if err := os.RemoveAll(r.workDir); err != nil {
				r.shutdownErr = err
			}
		}
	})
	return r.shutdownErr
}

// newProviderProcess dispatches on cfg.Kind. Returns the interface
// value used by rig internals plus, when the Kind is Fake, the concrete
// *FakeProvider so hooks that need the concrete type can reach it. The
// second return is nil for non-Fake kinds.
func (r *Rig) newProviderProcess(cfg Provider, httpPort int, coordProvURL, providerToken string) (providerProcess, *FakeProvider, error) {
	switch cfg.Kind {
	case ProviderKindFake:
		fp := newFakeProvider(cfg, httpPort, coordProvURL, providerToken, r.taggedLogger(fmt.Sprintf("prov-%s", cfg.ID)))
		return fp, fp, nil
	default:
		return nil, nil, fmt.Errorf("unsupported provider kind %q (PR 1 implements ProviderKindFake only)", cfg.Kind)
	}
}

// taggedLogger returns a Logger that prefixes each line with tag.
func (r *Rig) taggedLogger(tag string) func(string) {
	return func(line string) {
		r.logger(fmt.Sprintf("[%s] %s", tag, line))
	}
}

// registerProc adds cmd to procWG and pumps its stdout/stderr through
// tagged log lines. When the process exits, the first non-Shutdown
// exit is recorded on the rig's crash channel — callers of Rig.Done()
// see the crash immediately and can abort their scenario rather than
// blocking on buyer.Run against a dead binary.
//
// If the parent context has already been cancelled (Shutdown path),
// the exit is treated as expected and NOT recorded on crashCh.
func (r *Rig) registerProc(cmd *exec.Cmd, tag string) error {
	if err := streamPipes(cmd, r.taggedLogger(tag)); err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	r.procWG.Add(1)
	go func() {
		defer r.procWG.Done()
		waitErr := cmd.Wait()
		if cmd.ProcessState != nil && !cmd.ProcessState.Success() {
			r.recordCrash(fmt.Errorf("localrig: %s exited unexpectedly: %v (state=%s)", tag, waitErr, cmd.ProcessState.String()))
			return
		}
		if waitErr != nil {
			r.recordCrash(fmt.Errorf("localrig: %s wait: %w", tag, waitErr))
		}
	}()
	return nil
}

// recordCrash closes crashCh on first supervised-subprocess crash. Called
// from registerProc's exit observer. The first crash wins; subsequent
// exits are dropped so a coord death followed by a gateway death from
// the same shutdown cascade doesn't reopen the channel.
//
// Shutdown is expected to cancel rootCtx before the child exits, so
// crashOnce won't fire under an intentional Shutdown — see the guard
// on rootCancel state in Shutdown.
func (r *Rig) recordCrash(err error) {
	if r.shuttingDown.Load() {
		return
	}
	r.crashOnce.Do(func() {
		r.crashMu.Lock()
		r.crashErr = err
		r.crashMu.Unlock()
		close(r.crashCh)
	})
}
