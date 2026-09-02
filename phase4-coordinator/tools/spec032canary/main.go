package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/stats/migrations"
	_ "github.com/lib/pq"
	"gopkg.in/yaml.v3"
)

const (
	smallModelKey = "meta-llama/llama-3.2-3b-instruct"
	largeModelKey = "meta-llama/llama-3.1-8b-instruct"

	staticCatalogSignerKeyID = "streamvc-autotune-static-v4"

	publicEvidenceReasonR002 = "autotune_evidence_stale_or_mismatched"
)

type options struct {
	subjectHost     string
	subjectIdentity string
	controlHost     string
	controlIdentity string
	runRoot         string
	keepRunRoot     bool
}

type runner struct {
	opts options

	repoRoot  string
	runID     string
	runRoot   string
	sourceSHA string

	binDir         string
	coordinator    string
	mockProvider   string
	sqliteDB       string
	configPath     string
	coordinatorLog string

	buyerPort    int
	providerPort int
	pgPort       int
	subjectRPort int
	controlRPort int

	operatorKey   string
	gatewayToken  string
	rolePassword  string
	redactionSalt string

	pgContainer string
	pgDSN       string
	pgDB        *sql.DB

	coordCmd *exec.Cmd

	catalog    *autotune.Catalog
	smallRow   autotune.Row
	largeRow   autotune.Row
	smallRowID string
	largeRowID string

	subject providerRef
	control providerRef

	steps []evidenceStep
}

type providerRef struct {
	Role       string
	Host       string
	Identity   string
	ProviderID string
	Name       string
	Token      string
	RemotePort int
	RemoteDir  string
	TunnelCtl  string
	PID        string
}

type canarySnapshot struct {
	ProviderID                       string `json:"provider_id"`
	AssignedID                       string `json:"assigned_id"`
	ModelID                          string `json:"model_id"`
	RoutingEligible                  bool   `json:"routing_eligible"`
	ServingCapable                   bool   `json:"serving_capable"`
	AdmissionCeilingExcluded         bool   `json:"admission_ceiling_excluded"`
	AdmissionEvidenceStale           bool   `json:"admission_evidence_stale"`
	AdmissionSandboxed               bool   `json:"admission_sandboxed"`
	MaxAdmittedModelID               string `json:"max_admitted_model_id"`
	MaxAdmittedMinRAMGB              int    `json:"max_admitted_min_ram_gb"`
	HasAdmittedTuple                 bool   `json:"has_admitted_tuple"`
	AdmissionSandboxCredentialBypass bool   `json:"admission_sandbox_credential_bypassed"`
}

type canaryProof struct {
	Status string `json:"status"`
	Config struct {
		RequireAutotuneHelloGate bool `json:"require_autotune_hello_gate"`
		AutotuneEvidenceTTLDays  int  `json:"autotune_evidence_ttl_days"`
	} `json:"config"`
	LastReload struct {
		Present bool `json:"present"`
		Result  struct {
			Generation            int `json:"generation"`
			PreQuarantined        int `json:"pre_quarantined"`
			Revalidated           int `json:"revalidated"`
			Sandboxed             int `json:"sandboxed"`
			RouteExcluded         int `json:"route_excluded"`
			StillEvidenceStale    int `json:"still_evidence_stale"`
			ClearedGateExclusions int `json:"cleared_gate_exclusions"`
		} `json:"result"`
	} `json:"last_reload"`
	Pool []canarySnapshot `json:"pool"`
}

type evidenceStep struct {
	StepID                           string         `json:"id"`
	Status                           string         `json:"status"`
	Assertion                        string         `json:"assertion"`
	RequirementID                    string         `json:"requirement"`
	Artifacts                        []string       `json:"artifacts"`
	SubjectFingerprint               string         `json:"subject_fingerprint"`
	ControlFingerprint               string         `json:"control_fingerprint"`
	SubjectBefore                    redactedSnap   `json:"subject_before"`
	SubjectAfter                     redactedSnap   `json:"subject_after"`
	ControlAfter                     redactedSnap   `json:"control_after"`
	NonAdmissionReason               string         `json:"non_admission_reason,omitempty"`
	InternalReason                   string         `json:"internal_reason,omitempty"`
	BuyerSmoke                       buyerSmoke     `json:"buyer_smoke"`
	DurableProviderCredentialsMinted bool           `json:"durable_provider_credentials_minted"`
	FailClosedReloadObserved         bool           `json:"fail_closed_reload_observed,omitempty"`
	RawCapture                       map[string]any `json:"raw_capture,omitempty"`
}

type redactedSnap struct {
	RoutingEligible                  bool   `json:"routing_eligible"`
	ServingCapable                   bool   `json:"serving_capable"`
	ModelID                          string `json:"model_id,omitempty"`
	AdmissionCeilingExcluded         bool   `json:"admission_ceiling_excluded,omitempty"`
	AdmissionEvidenceStale           bool   `json:"admission_evidence_stale,omitempty"`
	AdmissionSandboxed               bool   `json:"admission_sandboxed,omitempty"`
	MaxAdmittedModelID               string `json:"max_admitted_model_id,omitempty"`
	MaxAdmittedMinRAMGB              int    `json:"max_admitted_min_ram_gb,omitempty"`
	HasAdmittedTuple                 bool   `json:"has_admitted_tuple,omitempty"`
	DurableProviderCredentialsMinted bool   `json:"durable_provider_credentials_minted,omitempty"`
}

type buyerSmoke struct {
	ControlServedSmallModel      bool   `json:"control_served_small_model"`
	ExpectedSubjectClosed        bool   `json:"expected_subject_closed"`
	SubjectRouteClosed           bool   `json:"subject_route_closed"`
	StatusCode                   int    `json:"status_code"`
	ErrorCode                    string `json:"error_code,omitempty"`
	ControlProbeStatusCode       int    `json:"control_probe_status_code,omitempty"`
	TargetServedProvider         string `json:"target_served_provider_fingerprint,omitempty"`
	ControlProbeServedProvider   string `json:"control_probe_served_provider_fingerprint,omitempty"`
	ControlProbeUnexpectedReason string `json:"control_probe_unexpected_reason,omitempty"`
}

func main() {
	var opts options
	flag.StringVar(&opts.subjectHost, "subject-host", "", "SSH host for P_subject")
	flag.StringVar(&opts.subjectIdentity, "subject-identity", "", "SSH identity file for P_subject")
	flag.StringVar(&opts.controlHost, "control-host", "", "SSH host for P_control")
	flag.StringVar(&opts.controlIdentity, "control-identity", "", "SSH identity file for P_control")
	flag.StringVar(&opts.runRoot, "run-root", "", "local run root; defaults under the operator secret store")
	flag.BoolVar(&opts.keepRunRoot, "keep-run-root", false, "keep local and remote scratch after completion")
	flag.Parse()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := (&runner{opts: opts}).run(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "spec032 physical canary failed: %v\n", err)
		os.Exit(1)
	}
}

func prepareRunRoot(repoRoot, runID, requested string) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	base := filepath.Join(home, ".config", "macprovider", "operator-secrets", "spec032-runs")
	if err := os.MkdirAll(base, 0o700); err != nil {
		return "", err
	}
	if err := os.Chmod(base, 0o700); err != nil {
		return "", err
	}
	root := filepath.Join(base, runID)
	if strings.TrimSpace(requested) != "" {
		root = expandHome(requested)
	}
	absRoot, err := filepath.Abs(root)
	if err != nil {
		return "", err
	}
	absBase, err := filepath.Abs(base)
	if err != nil {
		return "", err
	}
	absRepo, err := filepath.Abs(repoRoot)
	if err != nil {
		return "", err
	}
	absHome, err := filepath.Abs(home)
	if err != nil {
		return "", err
	}
	if absRoot == string(filepath.Separator) || absRoot == absHome || absRoot == absRepo || strings.HasPrefix(absRoot, absRepo+string(filepath.Separator)) {
		return "", fmt.Errorf("refusing unsafe run root %q", absRoot)
	}
	if absRoot != absBase && !strings.HasPrefix(absRoot, absBase+string(filepath.Separator)) {
		return "", fmt.Errorf("run root %q must be under %q", absRoot, absBase)
	}
	parent := filepath.Dir(absRoot)
	parentInfo, err := os.Lstat(parent)
	if err != nil {
		return "", fmt.Errorf("run root parent %q must exist: %w", parent, err)
	}
	if parentInfo.Mode()&os.ModeSymlink != 0 || !parentInfo.IsDir() {
		return "", fmt.Errorf("run root parent %q must be a real directory", parent)
	}
	if info, err := os.Lstat(absRoot); err == nil {
		if info.Mode()&os.ModeSymlink != 0 {
			return "", fmt.Errorf("run root %q must not be a symlink", absRoot)
		}
		if !info.IsDir() {
			return "", fmt.Errorf("run root %q exists and is not a directory", absRoot)
		}
		entries, err := os.ReadDir(absRoot)
		if err != nil {
			return "", err
		}
		if len(entries) > 0 {
			return "", fmt.Errorf("run root %q already exists and is not empty", absRoot)
		}
		if err := os.Chmod(absRoot, 0o700); err != nil {
			return "", err
		}
		return absRoot, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	if err := os.Mkdir(absRoot, 0o700); err != nil {
		return "", err
	}
	return absRoot, nil
}

func (r *runner) run(ctx context.Context) error {
	var err error
	r.repoRoot, err = findRepoRoot()
	if err != nil {
		return err
	}
	r.sourceSHA = mustOutput(r.repoRoot, "git", "rev-parse", "HEAD")
	r.runID = "provider-prebeta-admission-spec032-strict-physical-" + time.Now().UTC().Format("20060102T150405Z")
	r.runRoot, err = prepareRunRoot(r.repoRoot, r.runID, r.opts.runRoot)
	if err != nil {
		return err
	}
	r.binDir = filepath.Join(r.runRoot, "bin")
	r.coordinator = filepath.Join(r.binDir, "coordinator")
	r.mockProvider = filepath.Join(r.binDir, "mockprovider-darwin-arm64")
	r.sqliteDB = filepath.Join(r.runRoot, "state", "coordinator.db")
	r.configPath = filepath.Join(r.runRoot, "coordinator.yaml")
	r.coordinatorLog = filepath.Join(r.runRoot, "coordinator.log")
	r.operatorKey = randomHex(32)
	r.gatewayToken = randomHex(32)
	r.rolePassword = randomHex(24)
	r.redactionSalt = randomHex(32)
	r.subject = providerRef{Role: "subject", Host: r.opts.subjectHost, Identity: expandHome(r.opts.subjectIdentity), ProviderID: "spec032-subject", Name: "subject canary"}
	r.control = providerRef{Role: "control", Host: r.opts.controlHost, Identity: expandHome(r.opts.controlIdentity), ProviderID: "spec032-control", Name: "control canary"}

	if r.subject.Host == "" || r.control.Host == "" {
		return errors.New("both subject-host and control-host are required")
	}
	if r.subject.Identity == "" || r.control.Identity == "" {
		return errors.New("both subject-identity and control-identity are required")
	}
	if strings.EqualFold(r.subject.Host, "coordinator.malibu.tech") || strings.EqualFold(r.control.Host, "coordinator.malibu.tech") {
		return errors.New("refusing production coordinator host in provider host flags")
	}
	if err := os.MkdirAll(r.binDir, 0o700); err != nil {
		return err
	}
	defer r.cleanup(context.Background())

	fmt.Printf("run_id=%s\n", r.runID)
	if err := r.loadCatalog(); err != nil {
		return err
	}
	if err := r.buildBinaries(ctx); err != nil {
		return err
	}
	if err := r.startPostgres(ctx); err != nil {
		return err
	}
	if err := r.seedHardwareEvidence(ctx, r.subject.ProviderID, r.hardwareHash(r.subject.ProviderID), time.Now().UTC(), false); err != nil {
		return err
	}
	if err := r.seedHardwareEvidence(ctx, r.control.ProviderID, r.hardwareHash(r.control.ProviderID), time.Now().UTC(), false); err != nil {
		return err
	}
	if err := r.issueTokens(ctx); err != nil {
		return err
	}
	if err := r.writeConfig(true); err != nil {
		return err
	}
	if err := r.startCoordinator(ctx); err != nil {
		return err
	}
	if err := r.prepareRemoteProvider(ctx, &r.subject); err != nil {
		return err
	}
	if err := r.prepareRemoteProvider(ctx, &r.control); err != nil {
		return err
	}
	if err := r.startRemoteProvider(ctx, &r.subject, r.smallRow.ModelID); err != nil {
		return err
	}
	if err := r.startRemoteProvider(ctx, &r.control, r.smallRow.ModelID); err != nil {
		return err
	}
	subjectBefore, controlBefore, err := r.waitSubjectControl(ctx, true, true, true, true, 45*time.Second)
	if err != nil {
		return err
	}

	if err := r.scenarioR001(ctx, subjectBefore, controlBefore); err != nil {
		return err
	}
	if err := r.scenarioR002(ctx); err != nil {
		return err
	}
	if err := r.scenarioR003(ctx); err != nil {
		return err
	}

	artifact, err := r.writeEvidenceArtifact()
	if err != nil {
		return err
	}
	fmt.Printf("wrote redacted evidence: %s\n", artifact)
	return nil
}

func (r *runner) scenarioR001(ctx context.Context, subjectBefore, controlBefore canarySnapshot) error {
	if err := r.writeRemoteModel(ctx, r.subject, r.largeRow.ModelID); err != nil {
		return err
	}
	after, control, err := r.waitSubjectControlModel(ctx, false, false, true, true, r.largeRow.ModelID, 20*time.Second)
	if err != nil {
		return err
	}
	if !after.AdmissionCeilingExcluded {
		return fmt.Errorf("R001 over-ceiling did not set admission ceiling exclusion: %+v", after)
	}
	smoke := r.buyerSmoke(ctx, r.largeRow.ModelID, true)
	r.addStep("r001-over-ceiling", "SPEC-032-R001", "over-ceiling heartbeat route-excludes only P_subject", subjectBefore, after, control, "autotune_model_cap_exceeded", "autotune_model_cap_exceeded", smoke, false, map[string]any{
		"claimed_model_id":           after.ModelID,
		"admitted_model_id":          after.MaxAdmittedModelID,
		"admitted_min_ram_gb":        after.MaxAdmittedMinRAMGB,
		"catalog_claimed_min_ram_gb": r.largeRow.MinRAMGB,
		"advisory_gate_ignored":      true,
	})

	if err := r.writeRemoteModel(ctx, r.subject, "mlx-community/spec032-uncatalogued-model"); err != nil {
		return err
	}
	before := after
	after, control, err = r.waitSubjectControlModel(ctx, false, false, true, true, "mlx-community/spec032-uncatalogued-model", 20*time.Second)
	if err != nil {
		return err
	}
	if !after.AdmissionCeilingExcluded {
		return fmt.Errorf("R001 uncatalogued did not keep route exclusion: %+v", after)
	}
	smoke = r.buyerSmoke(ctx, "mlx-community/spec032-uncatalogued-model", true)
	r.addStep("r001-uncatalogued", "SPEC-032-R001", "uncatalogued heartbeat route-excludes only P_subject", before, after, control, "autotune_model_uncatalogued", "autotune_model_uncatalogued", smoke, false, map[string]any{
		"claimed_model_id":      after.ModelID,
		"advisory_gate_ignored": true,
	})

	if err := r.writeRemoteModel(ctx, r.subject, r.smallRow.ModelID); err != nil {
		return err
	}
	before = after
	after, control, err = r.waitSubjectControlModel(ctx, true, true, true, true, r.smallRow.ModelID, 20*time.Second)
	if err != nil {
		return err
	}
	r.addStep("r001-clears", "SPEC-032-R001", "in-ceiling catalogued heartbeat clears P_subject exclusion", before, after, control, "", "", r.buyerSmoke(ctx, r.smallRow.ModelID, false), false, map[string]any{
		"claimed_model_id":      after.ModelID,
		"advisory_gate_ignored": true,
	})
	return nil
}

func (r *runner) scenarioR002(ctx context.Context) error {
	if err := r.seedHardwareEvidence(ctx, r.subject.ProviderID, r.hardwareHash(r.subject.ProviderID), time.Now().UTC(), false); err != nil {
		return err
	}
	if err := r.seedHardwareEvidence(ctx, r.control.ProviderID, r.hardwareHash(r.control.ProviderID), time.Now().UTC(), false); err != nil {
		return err
	}
	if err := r.restartRemoteProvider(ctx, &r.subject, r.smallRow.ModelID); err != nil {
		return err
	}
	before, _, err := r.waitSubjectControl(ctx, true, true, true, true, 45*time.Second)
	if err != nil {
		return err
	}

	if err := r.seedHardwareEvidence(ctx, r.subject.ProviderID, r.hardwareHash(r.subject.ProviderID), time.Now().UTC().Add(-31*24*time.Hour), false); err != nil {
		return err
	}
	after, control, err := r.waitForSweep(ctx, "autotune_evidence_expired", 45*time.Second)
	if err != nil {
		return err
	}
	r.addStep("r002-expired", "SPEC-032-R002", "expired admitted evidence route-excludes only P_subject on the 30s sweep", before, after, control, publicEvidenceReasonR002, "autotune_evidence_expired", r.buyerSmoke(ctx, r.smallRow.ModelID, true), false, map[string]any{
		"ttl_days":              30,
		"evidence_generated_at": time.Now().UTC().Add(-31 * 24 * time.Hour).Format(time.RFC3339),
	})

	if err := r.seedHardwareEvidence(ctx, r.subject.ProviderID, r.hardwareHash(r.subject.ProviderID), time.Now().UTC(), false); err != nil {
		return err
	}
	if err := r.restartRemoteProvider(ctx, &r.subject, r.smallRow.ModelID); err != nil {
		return err
	}
	before, _, err = r.waitSubjectControl(ctx, true, true, true, true, 45*time.Second)
	if err != nil {
		return err
	}
	if err := r.appendHardwareEvidence(ctx, r.subject.ProviderID, randomHex(32), time.Now().UTC(), false); err != nil {
		return err
	}
	after, control, err = r.waitForSweep(ctx, "autotune_evidence_tuple_mismatch", 45*time.Second)
	if err != nil {
		return err
	}
	r.addStep("r002-tuple-mismatch", "SPEC-032-R002", "tuple-mismatched verified evidence route-excludes only P_subject on the 30s sweep", before, after, control, publicEvidenceReasonR002, "autotune_evidence_tuple_mismatch", r.buyerSmoke(ctx, r.smallRow.ModelID, true), false, map[string]any{
		"tuple_fields": []string{"hardware_identity_hash", "chip_normalized", "unified_memory_gb"},
	})

	if err := r.seedHardwareEvidence(ctx, r.subject.ProviderID, r.hardwareHash(r.subject.ProviderID), time.Now().UTC(), false); err != nil {
		return err
	}
	if err := r.restartRemoteProvider(ctx, &r.subject, r.smallRow.ModelID); err != nil {
		return err
	}
	before, _, err = r.waitSubjectControl(ctx, true, true, true, true, 45*time.Second)
	if err != nil {
		return err
	}
	if err := r.clearAdmittedTuple(ctx, before); err != nil {
		return err
	}
	after, control, err = r.waitForSweep(ctx, "autotune_admitted_tuple_missing", 45*time.Second)
	if err != nil {
		return err
	}
	r.addStep("r002-missing-tuple", "SPEC-032-R002", "missing admitted tuple route-excludes only P_subject on the 30s sweep", before, after, control, publicEvidenceReasonR002, "autotune_admitted_tuple_missing", r.buyerSmoke(ctx, r.smallRow.ModelID, true), false, map[string]any{
		"admitted_tuple_cleared": true,
	})
	return nil
}

func (r *runner) scenarioR003(ctx context.Context) error {
	if err := r.writeConfig(false); err != nil {
		return err
	}
	if err := r.signalCoordinator(syscall.SIGHUP); err != nil {
		return err
	}
	time.Sleep(2 * time.Second)
	beforeTokens, err := r.activeTokenCount(r.subject.ProviderID)
	if err != nil {
		return err
	}
	if err := r.deleteEvidence(ctx, r.subject.ProviderID); err != nil {
		return err
	}
	if err := r.restartRemoteProvider(ctx, &r.subject, r.smallRow.ModelID); err != nil {
		return err
	}
	before, _, err := r.waitSubjectControl(ctx, true, true, true, true, 45*time.Second)
	if err != nil {
		return err
	}
	if err := r.writeConfig(true); err != nil {
		return err
	}
	if err := r.signalCoordinator(syscall.SIGHUP); err != nil {
		return err
	}
	after, control, err := r.waitSubjectControl(ctx, false, false, true, true, 20*time.Second)
	if err != nil {
		return err
	}
	if !after.AdmissionSandboxed {
		return fmt.Errorf("R003 reload did not sandbox evidence-absent subject: %+v", after)
	}
	afterTokens, err := r.activeTokenCount(r.subject.ProviderID)
	if err != nil {
		return err
	}
	proof, err := r.proof(ctx)
	if err != nil {
		return err
	}
	failClosed := proof.LastReload.Present && proof.LastReload.Result.PreQuarantined > 0 && afterTokens == beforeTokens
	smoke := r.buyerSmoke(ctx, r.smallRow.ModelID, true)
	r.addStep("r003-sandbox-and-failclosed-reload", "SPEC-032-R003", "evidence-absent provider is sandboxed and proof-of-weights reload fails closed", before, after, control, "autotune_evidence_required", "autotune_evidence_required", smoke, failClosed, map[string]any{
		"active_tokens_before":    beforeTokens,
		"active_tokens_after":     afterTokens,
		"proof_of_weights_reload": proof.LastReload.Result,
	})
	if !failClosed {
		return fmt.Errorf("R003 fail-closed reload not observed: last_reload=%+v before_tokens=%d after_tokens=%d", proof.LastReload, beforeTokens, afterTokens)
	}

	before = after
	time.Sleep(35 * time.Second)
	after, control, err = r.waitSubjectControl(ctx, false, false, true, true, 5*time.Second)
	if err != nil {
		return err
	}
	r.addStep("r003-recovery-sweep", "SPEC-032-R003", "revalidation sweep keeps evidence-absent P_subject sandboxed while P_control remains serving", before, after, control, "autotune_evidence_required", "autotune_evidence_required", r.buyerSmoke(ctx, r.smallRow.ModelID, true), false, map[string]any{
		"revalidation_sweep_wait_s": 35,
	})
	return nil
}

func (r *runner) buildBinaries(ctx context.Context) error {
	fmt.Println("building coordinator and darwin mockprovider")
	if err := r.runCmd(ctx, filepath.Join(r.repoRoot, "phase4-coordinator"), "go", "build", "-o", r.coordinator, "./cmd/coordinator"); err != nil {
		return err
	}
	env := append(os.Environ(), "GOOS=darwin", "GOARCH=arm64")
	cmd := exec.CommandContext(ctx, "go", "build", "-o", r.mockProvider, "./tools/mockprovider")
	cmd.Dir = filepath.Join(r.repoRoot, "phase4-coordinator")
	cmd.Env = env
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("go build mockprovider: %w\n%s", err, out)
	}
	return nil
}

func (r *runner) startPostgres(ctx context.Context) error {
	r.pgPort = mustFreePort()
	r.pgContainer = "macprovider-spec032-" + strings.ToLower(randomHex(4))
	args := []string{"run", "-d", "--rm", "--name", r.pgContainer, "-e", "POSTGRES_PASSWORD=" + r.rolePassword, "-e", "POSTGRES_DB=macprovider_spec032", "-p", fmt.Sprintf("127.0.0.1:%d:5432", r.pgPort), "postgres:16-alpine"}
	out, err := exec.CommandContext(ctx, "docker", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("start postgres container: %w\n%s", err, out)
	}
	r.pgDSN = fmt.Sprintf("postgres://postgres:%s@127.0.0.1:%d/macprovider_spec032?sslmode=disable", r.rolePassword, r.pgPort)
	deadline := time.Now().Add(45 * time.Second)
	for {
		db, err := sql.Open("postgres", r.pgDSN)
		if err == nil {
			ctxPing, cancel := context.WithTimeout(ctx, 2*time.Second)
			pingErr := db.PingContext(ctxPing)
			cancel()
			if pingErr == nil {
				r.pgDB = db
				break
			}
			_ = db.Close()
			err = pingErr
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("postgres did not become ready: %w", err)
		}
		time.Sleep(750 * time.Millisecond)
	}
	if err := migrations.Apply(ctx, r.pgDB); err != nil {
		return fmt.Errorf("apply postgres migrations: %w", err)
	}
	for _, role := range []string{"provider_onboarding", "provider_auth_policy_requester", "provider_auth_policy_approver", "provider_auth_policy_cutover", "hardware_trust_requester", "hardware_trust_approver"} {
		if _, err := r.pgDB.ExecContext(ctx, fmt.Sprintf("ALTER ROLE %s LOGIN PASSWORD '%s'", role, strings.ReplaceAll(r.rolePassword, "'", "''"))); err != nil {
			return fmt.Errorf("alter role %s: %w", role, err)
		}
	}
	return nil
}

func (r *runner) loadCatalog() error {
	path := filepath.Join(r.repoRoot, "phase3-binary", "dist", "static", "autotune-candidates.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	r.catalog, err = autotune.ParseCatalog(raw)
	if err != nil {
		return err
	}
	if r.catalog.SignerKeyID == "" {
		r.catalog.SignerKeyID = staticCatalogSignerKeyID
	}
	var ok bool
	r.smallRow, ok = r.catalog.Row(smallModelKey)
	if !ok {
		return fmt.Errorf("small model key %q missing from catalog", smallModelKey)
	}
	r.largeRow, ok = r.catalog.Row(largeModelKey)
	if !ok {
		return fmt.Errorf("large model key %q missing from catalog", largeModelKey)
	}
	r.smallRowID, ok = r.catalog.RowIdentity(smallModelKey)
	if !ok {
		return fmt.Errorf("small row identity unavailable")
	}
	r.largeRowID, ok = r.catalog.RowIdentity(largeModelKey)
	if !ok {
		return fmt.Errorf("large row identity unavailable")
	}
	return nil
}

func (r *runner) issueTokens(ctx context.Context) error {
	store, err := auth.OpenStore(r.sqliteDB)
	if err != nil {
		return err
	}
	defer store.Close()
	if _, token, err := store.IssueToken(ctx, r.subject.ProviderID, r.subject.Name); err != nil {
		return err
	} else {
		r.subject.Token = token
	}
	if _, token, err := store.IssueToken(ctx, r.control.ProviderID, r.control.Name); err != nil {
		return err
	} else {
		r.control.Token = token
	}
	return nil
}

func (r *runner) writeConfig(strict bool) error {
	r.buyerPort = choosePort(r.buyerPort)
	r.providerPort = choosePort(r.providerPort)
	cfg := config.Default()
	cfg.Listen.BuyerPort = r.buyerPort
	cfg.Listen.ProviderPort = r.providerPort
	cfg.Listen.BindAddress = "127.0.0.1"
	cfg.Coordinator.RequireGatewayContext = false
	cfg.Pool.HeartbeatIntervalS = 1
	cfg.Pool.WarmupGateEnabled = false
	cfg.Pool.CanaryEnabled = false
	cfg.Routing.RequestTimeoutS = 30
	cfg.ProviderHTTP.TimeoutS = 30
	cfg.Storage.DBPath = r.sqliteDB
	cfg.Settlement.JobEnabled = false
	cfg.Auth.OperatorKey = r.operatorKey
	cfg.Auth.OperatorKeys = map[string]string{
		"spec032-operator-a": randomHex(32),
		"spec032-operator-b": randomHex(32),
	}
	cfg.Auth.GatewayServiceToken = r.gatewayToken
	cfg.Auth.RequireProviderTokens = true
	cfg.Referrals.RequireForRegistration = true
	cfg.Referrals.Campaign = "prebeta_2026"
	cfg.Referrals.CurrentKeyID = "spec032"
	cfg.Referrals.HMACKeys = map[string]string{"spec032": randomHex(32)}
	cfg.Onboarding.AppTrackRegisterEnabled = true
	cfg.Onboarding.PostgresDSN = r.roleDSN("provider_onboarding")
	cfg.Onboarding.AuthPolicyRequestDSN = r.roleDSN("provider_auth_policy_requester")
	cfg.Onboarding.AuthPolicyApproveDSN = r.roleDSN("provider_auth_policy_approver")
	cfg.Onboarding.AuthPolicyCutoverDSN = r.roleDSN("provider_auth_policy_cutover")
	cfg.Onboarding.HardwareTrustRequestDSN = r.roleDSN("hardware_trust_requester")
	cfg.Onboarding.HardwareTrustApproveDSN = r.roleDSN("hardware_trust_approver")
	cfg.Onboarding.BundleID = "tech.malibu.app"
	cfg.Onboarding.AppleTeamID = "SPEC032CAN"
	cfg.Onboarding.CoordinatorDomain = "spec032-canary.local"
	cfg.Onboarding.ASNPrefixes = map[string]string{"127.0.0.0/8": "AS64512"}
	static := filepath.Join(r.repoRoot, "phase3-binary", "dist", "static")
	cfg.AutotuneFeeds.RateCardPath = filepath.Join(static, "rate-card.json")
	cfg.AutotuneFeeds.RateCardSigPath = filepath.Join(static, "rate-card.json.sig")
	cfg.AutotuneFeeds.DemandRankPath = filepath.Join(static, "demand-rank.json")
	cfg.AutotuneFeeds.DemandRankSigPath = filepath.Join(static, "demand-rank.json.sig")
	cfg.AutotuneFeeds.AutotuneCandidatesPath = filepath.Join(static, "autotune-candidates.json")
	cfg.AutotuneFeeds.AutotuneCandidatesSigPath = filepath.Join(static, "autotune-candidates.json.sig")
	cfg.AutotuneFeeds.EnforceProviderAdmission = true
	cfg.AutotuneFeeds.PublicKeys = map[string]string{"streamvc-autotune-static-v4": "zTKDIdMmKKkO1Cgf5OdTzMOytVqW7U8SGsJ9XrzAltU="}
	cfg.ProofOfWeights.RequireAutotuneHelloGate = strict
	cfg.ProofOfWeights.AutotuneEvidenceTTLDays = 30
	cfg.ProofOfWeights.TelemetryDrift.Enabled = false
	cfg.ProofOfWeights.TelemetryDrift.OPoIPassRateWindow = 0
	cfg.AdmissionCanaryHarness.Enabled = true
	cfg.Providers = nil
	if err := cfg.Validate(); err != nil {
		return fmt.Errorf("validate generated canary config strict=%v: %w", strict, err)
	}
	b, err := yaml.Marshal(cfg)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(r.configPath), 0o700); err != nil {
		return err
	}
	return os.WriteFile(r.configPath, b, 0o600)
}

func (r *runner) roleDSN(role string) string {
	return fmt.Sprintf("postgres://%s:%s@127.0.0.1:%d/macprovider_spec032?sslmode=disable", role, r.rolePassword, r.pgPort)
}

func (r *runner) startCoordinator(ctx context.Context) error {
	logFile, err := os.OpenFile(r.coordinatorLog, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	r.coordCmd = exec.CommandContext(ctx, r.coordinator, "-config", r.configPath)
	r.coordCmd.Dir = filepath.Join(r.repoRoot, "phase4-coordinator")
	r.coordCmd.Stdout = logFile
	r.coordCmd.Stderr = logFile
	if err := r.coordCmd.Start(); err != nil {
		_ = logFile.Close()
		return err
	}
	go func() {
		_ = r.coordCmd.Wait()
		_ = logFile.Close()
	}()
	deadline := time.Now().Add(30 * time.Second)
	for {
		if time.Now().After(deadline) {
			return fmt.Errorf("coordinator did not become ready; see %s", r.coordinatorLog)
		}
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("http://127.0.0.1:%d/healthz", r.providerPort), nil)
		resp, err := http.DefaultClient.Do(req)
		if err == nil {
			_, _ = io.Copy(io.Discard, resp.Body)
			_ = resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return nil
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
}

func (r *runner) prepareRemoteProvider(ctx context.Context, p *providerRef) error {
	p.RemotePort = mustFreePort()
	p.RemoteDir = fmt.Sprintf("/tmp/macprovider-spec032-%s-%s", r.runID, p.Role)
	p.TunnelCtl = filepath.Join(os.TempDir(), "mp32-"+p.Role+"-"+randomHex(3)+".ctl")
	if err := r.ssh(ctx, p.Host, "rm", "-rf", p.RemoteDir); err != nil {
		return err
	}
	if err := r.ssh(ctx, p.Host, "mkdir", "-p", p.RemoteDir); err != nil {
		return err
	}
	if err := r.scp(ctx, r.mockProvider, p.Host+":"+p.RemoteDir+"/mockprovider"); err != nil {
		return err
	}
	tokenPath := filepath.Join(r.runRoot, p.Role+".provider-token")
	if err := os.WriteFile(tokenPath, []byte(p.Token+"\n"), 0o600); err != nil {
		return err
	}
	if err := r.scp(ctx, tokenPath, p.Host+":"+p.RemoteDir+"/provider-token"); err != nil {
		return err
	}
	if err := r.ssh(ctx, p.Host, "chmod", "700", p.RemoteDir); err != nil {
		return err
	}
	if err := r.ssh(ctx, p.Host, "chmod", "700", p.RemoteDir+"/mockprovider"); err != nil {
		return err
	}
	if err := r.ssh(ctx, p.Host, "chmod", "600", p.RemoteDir+"/provider-token"); err != nil {
		return err
	}
	args := append(r.sshBaseArgs(*p), "-fN", "-M", "-S", p.TunnelCtl, "-o", "ExitOnForwardFailure=yes", "-R", fmt.Sprintf("%d:127.0.0.1:%d", p.RemotePort, r.providerPort), p.Host)
	out, err := exec.CommandContext(ctx, "ssh", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("open ssh reverse tunnel to %s: %w\n%s", p.Host, err, out)
	}
	return nil
}

func (r *runner) startRemoteProvider(ctx context.Context, p *providerRef, modelID string) error {
	if err := r.writeRemoteModel(ctx, *p, modelID); err != nil {
		return err
	}
	cmd := fmt.Sprintf("cd %s && (nohup ./mockprovider -coord-url %s -provider-id %s -model %s -ram-gb 8 -max-concurrency 1 -slots 1 -omit-endpoint-url -hb 1 -provider-token-file provider-token -heartbeat-override-file heartbeat-model.json -catalog-release-id %s -catalog-policy-version %s -catalog-candidate-sha256 %s -catalog-signer-key-id %s -catalog-row-identity %s > mockprovider.log 2>&1 & echo $! > provider.pid)",
		shellQuote(p.RemoteDir),
		shellQuote(fmt.Sprintf("ws://127.0.0.1:%d/ws/provider", p.RemotePort)),
		shellQuote(p.ProviderID),
		shellQuote(modelID),
		shellQuote(r.catalog.Version),
		shellQuote(r.catalog.PolicyVersion),
		shellQuote(r.catalog.SHA256),
		shellQuote(r.catalog.SignerKeyID),
		shellQuote(r.smallRowID),
	)
	if err := r.sshShell(ctx, p.Host, cmd); err != nil {
		return err
	}
	time.Sleep(1 * time.Second)
	pidBytes, err := r.sshOutput(ctx, p.Host, "cat", p.RemoteDir+"/provider.pid")
	if err == nil {
		p.PID = strings.TrimSpace(string(pidBytes))
	}
	if p.PID == "" {
		logBytes, _ := r.sshOutput(ctx, p.Host, "tail", "-n", "80", p.RemoteDir+"/mockprovider.log")
		return fmt.Errorf("remote provider %s did not write pid; log:\n%s", p.ProviderID, logBytes)
	}
	return nil
}

func (r *runner) restartRemoteProvider(ctx context.Context, p *providerRef, modelID string) error {
	_ = r.stopRemoteProvider(ctx, *p)
	return r.startRemoteProvider(ctx, p, modelID)
}

func (r *runner) stopRemoteProvider(ctx context.Context, p providerRef) error {
	if p.RemoteDir == "" {
		return nil
	}
	_ = r.sshShell(ctx, p.Host, fmt.Sprintf("if [ -f %s/provider.pid ]; then kill $(cat %s/provider.pid) >/dev/null 2>&1 || true; rm -f %s/provider.pid; fi", shellQuote(p.RemoteDir), shellQuote(p.RemoteDir), shellQuote(p.RemoteDir)))
	time.Sleep(750 * time.Millisecond)
	return nil
}

func (r *runner) writeRemoteModel(ctx context.Context, p providerRef, modelID string) error {
	body := fmt.Sprintf(`{"model_id":%q}`, modelID)
	local := filepath.Join(r.runRoot, p.Role+"-heartbeat-model.json")
	if err := os.WriteFile(local, []byte(body+"\n"), 0o600); err != nil {
		return err
	}
	return r.scp(ctx, local, p.Host+":"+p.RemoteDir+"/heartbeat-model.json")
}

func (r *runner) seedHardwareEvidence(ctx context.Context, providerID, hardwareHash string, generatedAt time.Time, mismatch bool) error {
	return r.writeHardwareEvidence(ctx, providerID, hardwareHash, generatedAt, mismatch, true)
}

func (r *runner) appendHardwareEvidence(ctx context.Context, providerID, hardwareHash string, generatedAt time.Time, mismatch bool) error {
	return r.writeHardwareEvidence(ctx, providerID, hardwareHash, generatedAt, mismatch, false)
}

func (r *runner) writeHardwareEvidence(ctx context.Context, providerID, hardwareHash string, generatedAt time.Time, mismatch, replaceExisting bool) error {
	if r.pgDB == nil {
		return errors.New("postgres not started")
	}
	generatedAt = generatedAt.UTC().Truncate(time.Second)
	chip := "Apple Silicon SPEC-032 Canary"
	chipNorm := "apple silicon spec-032 canary"
	executableSHA, err := fileSHA256(r.mockProvider)
	if err != nil {
		return err
	}
	evidence := map[string]any{
		"generated_at":             generatedAt.Format(time.RFC3339),
		"candidate_catalog_sha256": r.catalog.SHA256,
		"probe_protocol":           "spec-023-harmony-stream.v2",
		"hardware": map[string]any{
			"binary_version":         "mockprovider-0.1.0",
			"hardware_identity_hash": hardwareHash,
			"executable_sha256":      executableSHA,
		},
		"benchmarks": []map[string]any{{
			"model_key":                 smallModelKey,
			"model_id":                  r.smallRow.ModelID,
			"sustained_tps":             1.0,
			"ttft_ms":                   9999,
			"swap_detected":             false,
			"thermal_throttle_detected": false,
			"artifact_sha256":           r.smallRow.ModelSHA256,
			"candidate_catalog_sha256":  r.catalog.SHA256,
			"generated_at":              generatedAt.Format(time.RFC3339),
			"binary_version":            "mockprovider-0.1.0",
			"hardware_identity_hash":    hardwareHash,
			"candidate_row_identity":    r.smallRowID,
		}},
	}
	if mismatch {
		evidence["hardware"].(map[string]any)["hardware_identity_hash"] = randomHex(32)
	}
	raw, err := json.Marshal(evidence)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(raw)
	tx, err := r.pgDB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if replaceExisting {
		if _, err := tx.ExecContext(ctx, `DELETE FROM hardware_verification_jobs WHERE provider_id=$1`, providerID); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM hardware_verification_trust WHERE provider_id=$1`, providerID); err != nil {
			return err
		}
	}
	if _, err := tx.ExecContext(ctx, `
INSERT INTO chip_hardware_profiles (chip_normalized, display_chip, memory_bandwidth_gb_per_s, network_power_kw, gpu_cores, cpu_cores)
VALUES ($1,$2,120,0.02,8,8)
ON CONFLICT (chip_normalized) DO UPDATE SET display_chip=EXCLUDED.display_chip, updated_at=now()`, chipNorm, chip); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
INSERT INTO provider_hardware_profiles (provider_id, chip, chip_normalized, unified_memory_gb, macos_version, app_version, source, verified, last_reported_at)
VALUES ($1,$2,$3,8,'26.5','mockprovider-0.1.0','operator',true,$4)
ON CONFLICT (provider_id) DO UPDATE SET chip=EXCLUDED.chip, chip_normalized=EXCLUDED.chip_normalized, unified_memory_gb=EXCLUDED.unified_memory_gb, macos_version=EXCLUDED.macos_version, app_version=EXCLUDED.app_version, source=EXCLUDED.source, verified=true, last_reported_at=EXCLUDED.last_reported_at`, providerID, chip, chipNorm, generatedAt); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
INSERT INTO hardware_verification_trust (provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb, trusted_by, trusted_at, expires_at, notes, source)
VALUES ($1,$2,$3,8,'spec032-canary',now(),NULL,'SPEC-032 physical canary isolated trust root','operator_api')`, providerID, hardwareHash, chipNorm); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
INSERT INTO hardware_verification_jobs (provider_id, source, status, chip, chip_normalized, unified_memory_gb, bandwidth_tier, os_version, binary_version, benchmark_count, max_sustained_tps, generated_at, submitted_at, processed_at, decision_reason, evidence, evidence_sha256)
VALUES ($1,'autotune','verified',$2,$3,8,'C','26.5','mockprovider-0.1.0',1,1.0,$4,$4,now(),'hardware-verifier.v2:verified_trusted_hardware',$5,$6)`,
		providerID, chip, chipNorm, generatedAt, string(raw), hex.EncodeToString(sum[:])); err != nil {
		return err
	}
	return tx.Commit()
}

func (r *runner) deleteEvidence(ctx context.Context, providerID string) error {
	tx, err := r.pgDB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `DELETE FROM hardware_verification_jobs WHERE provider_id=$1`, providerID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM hardware_verification_trust WHERE provider_id=$1`, providerID); err != nil {
		return err
	}
	return tx.Commit()
}

func (r *runner) waitSubjectControl(ctx context.Context, subjRoute, subjServe, ctrlRoute, ctrlServe bool, timeout time.Duration) (canarySnapshot, canarySnapshot, error) {
	return r.waitSubjectControlModel(ctx, subjRoute, subjServe, ctrlRoute, ctrlServe, "", timeout)
}

func (r *runner) waitSubjectControlModel(ctx context.Context, subjRoute, subjServe, ctrlRoute, ctrlServe bool, subjectModelID string, timeout time.Duration) (canarySnapshot, canarySnapshot, error) {
	deadline := time.Now().Add(timeout)
	var lastSubj, lastCtrl canarySnapshot
	for {
		proof, err := r.proof(ctx)
		if err == nil {
			lastSubj, _ = findSnapshot(proof.Pool, r.subject.ProviderID)
			lastCtrl, _ = findSnapshot(proof.Pool, r.control.ProviderID)
			subjectModelOK := subjectModelID == "" || lastSubj.ModelID == subjectModelID
			if lastSubj.RoutingEligible == subjRoute && lastSubj.ServingCapable == subjServe && subjectModelOK && lastCtrl.RoutingEligible == ctrlRoute && lastCtrl.ServingCapable == ctrlServe {
				if !ctrlRoute || !ctrlServe {
					return lastSubj, lastCtrl, errors.New("stop condition: P_control lost routing or serving")
				}
				return lastSubj, lastCtrl, nil
			}
		}
		if time.Now().After(deadline) {
			return lastSubj, lastCtrl, fmt.Errorf("timeout waiting subject/control state subj=%v/%v ctrl=%v/%v subject_model=%q last subject=%+v control=%+v", subjRoute, subjServe, ctrlRoute, ctrlServe, subjectModelID, lastSubj, lastCtrl)
		}
		time.Sleep(750 * time.Millisecond)
	}
}

func (r *runner) waitForSweep(ctx context.Context, internalReason string, timeout time.Duration) (canarySnapshot, canarySnapshot, error) {
	deadline := time.Now().Add(timeout)
	startOffset := r.logOffset()
	var lastSubj, lastCtrl canarySnapshot
	var lastLogReason string
	for {
		proof, err := r.proof(ctx)
		if err == nil {
			lastSubj, _ = findSnapshot(proof.Pool, r.subject.ProviderID)
			lastCtrl, _ = findSnapshot(proof.Pool, r.control.ProviderID)
			if lastSubj.AdmissionEvidenceStale && !lastSubj.RoutingEligible && !lastSubj.ServingCapable && lastCtrl.RoutingEligible && lastCtrl.ServingCapable {
				var matched bool
				matched, lastLogReason = r.observedAdmissionEvidenceReasonSince(startOffset, r.subject.ProviderID, internalReason)
				if matched {
					return lastSubj, lastCtrl, nil
				}
			}
		}
		if time.Now().After(deadline) {
			if lastLogReason == "" {
				_, lastLogReason = r.observedAdmissionEvidenceReasonSince(startOffset, r.subject.ProviderID, internalReason)
			}
			return lastSubj, lastCtrl, fmt.Errorf("timeout waiting sweep reason=%s last_log_reason=%s subject=%+v control=%+v", internalReason, lastLogReason, lastSubj, lastCtrl)
		}
		time.Sleep(1 * time.Second)
	}
}

func (r *runner) proof(ctx context.Context) (canaryProof, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("http://127.0.0.1:%d/admin/admission-canary/proof-of-weights", r.providerPort), nil)
	if err != nil {
		return canaryProof{}, err
	}
	req.Header.Set("Authorization", "Bearer "+r.operatorKey)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return canaryProof{}, err
	}
	defer resp.Body.Close()
	var proof canaryProof
	if err := json.NewDecoder(resp.Body).Decode(&proof); err != nil {
		return canaryProof{}, err
	}
	if resp.StatusCode != http.StatusOK {
		return proof, fmt.Errorf("proof endpoint status %d", resp.StatusCode)
	}
	return proof, nil
}

func (r *runner) clearAdmittedTuple(ctx context.Context, before canarySnapshot) error {
	body := fmt.Sprintf(`{"provider_id":%q,"assigned_id":%q}`, r.subject.ProviderID, before.AssignedID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, fmt.Sprintf("http://127.0.0.1:%d/admin/admission-canary/clear-admitted-tuple", r.providerPort), strings.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+r.operatorKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("clear admitted tuple status %d: %s", resp.StatusCode, b)
	}
	return nil
}

func (r *runner) buyerSmoke(ctx context.Context, modelID string, expectSubjectClosed bool) buyerSmoke {
	controlStatus, controlErr, controlServed := r.buyerProbe(ctx, r.smallRow.ModelID)
	targetStatus, targetErr, targetServed := r.buyerProbe(ctx, modelID)
	smoke := buyerSmoke{
		StatusCode:             targetStatus,
		ErrorCode:              targetErr,
		ControlProbeStatusCode: controlStatus,
		ExpectedSubjectClosed:  expectSubjectClosed,
	}
	if targetServed != "" {
		smoke.TargetServedProvider = r.fingerprint(targetServed)
	}
	if controlServed != "" {
		smoke.ControlProbeServedProvider = r.fingerprint(controlServed)
	}
	if controlErr != "" {
		smoke.ControlProbeUnexpectedReason = controlErr
	}
	smoke.ControlServedSmallModel = controlStatus >= 200 && controlStatus < 300 && controlServed == r.control.ProviderID
	if controlStatus >= 200 && controlStatus < 300 && controlServed != r.control.ProviderID {
		smoke.ControlProbeUnexpectedReason = "small-model probe served non-control provider"
	}
	if targetStatus >= 200 && targetStatus < 300 {
		smoke.SubjectRouteClosed = expectSubjectClosed && targetServed != r.subject.ProviderID
		return smoke
	}
	smoke.SubjectRouteClosed = expectSubjectClosed
	return smoke
}

func (r *runner) buyerProbe(ctx context.Context, modelID string) (int, string, string) {
	body := fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"spec032 smoke"}],"stream":false}`, modelID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, fmt.Sprintf("http://127.0.0.1:%d/v1/chat/completions", r.buyerPort), strings.NewReader(body))
	if err != nil {
		return 0, err.Error(), ""
	}
	req.Header.Set("Authorization", "Bearer "+r.gatewayToken)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, err.Error(), ""
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return resp.StatusCode, "", providerIDFromCompletion(raw)
	}
	var payload struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	_ = json.Unmarshal(raw, &payload)
	return resp.StatusCode, payload.Error.Code, ""
}

func providerIDFromCompletion(raw []byte) string {
	var payload struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil || len(payload.Choices) == 0 {
		return ""
	}
	content := payload.Choices[0].Message.Content
	const prefix = "hello from "
	if !strings.HasPrefix(content, prefix) {
		return ""
	}
	fields := strings.Fields(strings.TrimPrefix(content, prefix))
	if len(fields) == 0 {
		return ""
	}
	return fields[0]
}

func (r *runner) addStep(stepID, requirementID, assertion string, before, after, control canarySnapshot, reason, internalReason string, smoke buyerSmoke, failClosed bool, raw map[string]any) {
	if strings.Contains(reason, "bench_gate") || strings.Contains(reason, "min_sustained_tps") || strings.Contains(reason, "max_4k_ttft_ms") {
		panic("stop condition: advisory bench gate used as non-admission reason")
	}
	if !control.RoutingEligible || !control.ServingCapable {
		panic("stop condition: P_control lost routing or serving")
	}
	r.steps = append(r.steps, evidenceStep{
		StepID:                           stepID,
		Status:                           "pass",
		Assertion:                        assertion,
		RequirementID:                    requirementID,
		Artifacts:                        []string{"redacted-provider-prebeta-admission"},
		SubjectFingerprint:               r.fingerprint(r.subject.ProviderID),
		ControlFingerprint:               r.fingerprint(r.control.ProviderID),
		SubjectBefore:                    r.redactSnap(before),
		SubjectAfter:                     r.redactSnap(after),
		ControlAfter:                     r.redactSnap(control),
		NonAdmissionReason:               reason,
		InternalReason:                   internalReason,
		BuyerSmoke:                       smoke,
		DurableProviderCredentialsMinted: false,
		FailClosedReloadObserved:         failClosed,
		RawCapture:                       raw,
	})
}

func (r *runner) redactSnap(s canarySnapshot) redactedSnap {
	return redactedSnap{
		RoutingEligible:                  s.RoutingEligible,
		ServingCapable:                   s.ServingCapable,
		ModelID:                          s.ModelID,
		AdmissionCeilingExcluded:         s.AdmissionCeilingExcluded,
		AdmissionEvidenceStale:           s.AdmissionEvidenceStale,
		AdmissionSandboxed:               s.AdmissionSandboxed,
		MaxAdmittedModelID:               s.MaxAdmittedModelID,
		MaxAdmittedMinRAMGB:              s.MaxAdmittedMinRAMGB,
		HasAdmittedTuple:                 s.HasAdmittedTuple,
		DurableProviderCredentialsMinted: false,
	}
}

func (r *runner) writeEvidenceArtifact() (string, error) {
	if len(r.steps) != 8 {
		return "", fmt.Errorf("want 8 evidence steps, got %d", len(r.steps))
	}
	path := filepath.Join(r.repoRoot, "journeys", "evidence", r.runID+".redacted.json")
	captured := time.Now().UTC().Truncate(time.Second)
	artifact := map[string]any{
		"schema_version":  "macprovider.provider-prebeta-admission-evidence.v1",
		"run_id":          r.runID,
		"journey_id":      "JOURNEY-PROVIDER-PREBETA-ADMISSION",
		"requirement_ids": []string{"SPEC-032-R001", "SPEC-032-R002", "SPEC-032-R003"},
		"captured_at":     captured.Format(time.RFC3339),
		"expires_at":      captured.AddDate(0, 3, 0).Format("2006-01-02"),
		"repository": map[string]any{
			"name":         "Augustas11/macprovider",
			"commit":       r.sourceSHA,
			"git_describe": mustOutput(r.repoRoot, "git", "describe", "--always", "--tags", r.sourceSHA),
		},
		"operator": map[string]any{
			"role":                 "canary-operator",
			"identity_fingerprint": r.fingerprint("operator:" + os.Getenv("USER")),
		},
		"environment": map[string]any{
			"class":                "physical-provider-prebeta-admission",
			"hardware_profile":     "one subject canary plus one control canary over local WiFi SSH reverse tunnels",
			"candidate":            "isolated loopback coordinator with disposable Postgres and SQLite state",
			"coordinator_identity": r.fingerprint("coordinator:" + r.runID),
			"production_target":    "not coordinator.malibu.tech",
		},
		"config_flags": map[string]any{
			"autotune.require_autotune_hello_gate":         true,
			"autotune.enforce_provider_admission":          true,
			"autotune.autotune_evidence_ttl_days":          30,
			"proof_of_weights.require_autotune_hello_gate": true,
			"proof_of_weights.autotune_evidence_ttl_days":  30,
			"admission_canary_harness.enabled":             true,
		},
		"redaction": map[string]any{
			"secrets_redacted":               true,
			"operator_identity_redacted":     true,
			"local_account_names_redacted":   true,
			"provider_ids":                   "salted_sha256_fingerprint",
			"operator_identity":              "salted_sha256_fingerprint",
			"raw_machine_identities_omitted": true,
			"buyer_ips_omitted":              true,
		},
		"catalog": map[string]any{
			"candidate_catalog_sha256":        r.catalog.SHA256,
			"small_model_key":                 smallModelKey,
			"small_model_id":                  r.smallRow.ModelID,
			"small_model_min_ram_gb":          r.smallRow.MinRAMGB,
			"small_model_advisory_bench_gate": r.smallRow.BenchGate,
			"large_model_key":                 largeModelKey,
			"large_model_id":                  r.largeRow.ModelID,
			"large_model_min_ram_gb":          r.largeRow.MinRAMGB,
		},
		"steps": r.steps,
		"result": map[string]any{
			"status":  "pass",
			"summary": "S1-S3 passed on isolated physical canary; P_control stayed routing-eligible and serving throughout.",
		},
	}
	b, err := json.MarshalIndent(artifact, "", "  ")
	if err != nil {
		return "", err
	}
	b = append(b, '\n')
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "", err
	}
	if err := os.WriteFile(path, b, 0o644); err != nil {
		return "", err
	}
	return path, nil
}

func (r *runner) activeTokenCount(providerID string) (int, error) {
	db, err := sql.Open("sqlite", r.sqliteDB)
	if err != nil {
		return 0, err
	}
	defer db.Close()
	var n int
	if err := db.QueryRow(`SELECT COUNT(1) FROM provider_tokens WHERE provider_id = ? AND revoked_at IS NULL`, providerID).Scan(&n); err != nil {
		return 0, err
	}
	return n, nil
}

func (r *runner) signalCoordinator(sig syscall.Signal) error {
	if r.coordCmd == nil || r.coordCmd.Process == nil {
		return errors.New("coordinator not running")
	}
	return r.coordCmd.Process.Signal(sig)
}

func (r *runner) cleanup(ctx context.Context) {
	_ = r.stopRemoteProvider(ctx, r.subject)
	_ = r.stopRemoteProvider(ctx, r.control)
	for _, p := range []providerRef{r.subject, r.control} {
		if p.TunnelCtl != "" {
			args := append(r.sshBaseArgs(p), "-S", p.TunnelCtl, "-O", "exit", p.Host)
			_, _ = exec.CommandContext(ctx, "ssh", args...).CombinedOutput()
		}
		if !r.opts.keepRunRoot && p.RemoteDir != "" {
			_ = r.ssh(ctx, p.Host, "rm", "-rf", p.RemoteDir)
		}
	}
	if r.coordCmd != nil && r.coordCmd.Process != nil {
		_ = r.coordCmd.Process.Signal(syscall.SIGTERM)
	}
	if r.pgDB != nil {
		_ = r.pgDB.Close()
	}
	if r.pgContainer != "" {
		_, _ = exec.CommandContext(ctx, "docker", "rm", "-f", r.pgContainer).CombinedOutput()
	}
	if !r.opts.keepRunRoot {
		_ = os.RemoveAll(r.runRoot)
	}
}

func (r *runner) ssh(ctx context.Context, host string, args ...string) error {
	p := r.providerByHost(host)
	full := append(r.sshBaseArgs(p), host)
	full = append(full, args...)
	out, err := exec.CommandContext(ctx, "ssh", full...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("ssh %s %s: %w\n%s", host, strings.Join(args, " "), err, out)
	}
	return nil
}

func (r *runner) sshShell(ctx context.Context, host, script string) error {
	p := r.providerByHost(host)
	full := append(r.sshBaseArgs(p), host, script)
	out, err := exec.CommandContext(ctx, "ssh", full...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("ssh %s shell: %w\n%s", host, err, out)
	}
	return nil
}

func (r *runner) sshOutput(ctx context.Context, host string, args ...string) ([]byte, error) {
	p := r.providerByHost(host)
	full := append(r.sshBaseArgs(p), host)
	full = append(full, args...)
	return exec.CommandContext(ctx, "ssh", full...).CombinedOutput()
}

func (r *runner) scp(ctx context.Context, src, dst string) error {
	host := dst
	if i := strings.Index(dst, ":"); i >= 0 {
		host = dst[:i]
	}
	p := r.providerByHost(host)
	args := []string{"-o", "BatchMode=yes"}
	if p.Identity != "" {
		args = append(args, "-i", p.Identity, "-o", "IdentitiesOnly=yes")
	}
	args = append(args, src, dst)
	out, err := exec.CommandContext(ctx, "scp", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("scp %s %s: %w\n%s", src, dst, err, out)
	}
	return nil
}

func (r *runner) providerByHost(host string) providerRef {
	switch host {
	case r.subject.Host:
		return r.subject
	case r.control.Host:
		return r.control
	default:
		return providerRef{Host: host}
	}
}

func (r *runner) sshBaseArgs(p providerRef) []string {
	args := []string{"-o", "BatchMode=yes"}
	if p.Identity != "" {
		args = append(args, "-i", p.Identity, "-o", "IdentitiesOnly=yes")
	}
	return args
}

func (r *runner) runCmd(ctx context.Context, dir, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s: %w\n%s", name, strings.Join(args, " "), err, out)
	}
	return nil
}

func (r *runner) hardwareHash(providerID string) string {
	sum := sha256.Sum256([]byte(r.runID + ":" + providerID + ":hardware"))
	return hex.EncodeToString(sum[:])
}

func (r *runner) fingerprint(value string) string {
	sum := sha256.Sum256([]byte(r.redactionSalt + ":" + value))
	return hex.EncodeToString(sum[:])
}

func (r *runner) logOffset() int64 {
	info, err := os.Stat(r.coordinatorLog)
	if err != nil {
		return 0
	}
	return info.Size()
}

func (r *runner) observedAdmissionEvidenceReasonSince(offset int64, providerID, expectedReason string) (bool, string) {
	raw, err := os.ReadFile(r.coordinatorLog)
	if err != nil {
		return false, ""
	}
	if offset < 0 || offset > int64(len(raw)) {
		offset = 0
	}
	lines := bytes.Split(raw[offset:], []byte("\n"))
	var lastReason string
	for _, line := range lines {
		if !bytes.Contains(line, []byte(providerID)) || !bytes.Contains(line, []byte(`"provider_admission_evidence_stale"`)) || !bytes.Contains(line, []byte(`"reason"`)) {
			continue
		}
		var payload map[string]any
		if json.Unmarshal(line, &payload) != nil {
			continue
		}
		if gotProvider, _ := payload["provider_id"].(string); gotProvider != providerID {
			continue
		}
		if event, _ := payload["event"].(string); event != "provider_admission_evidence_stale" {
			continue
		}
		reason, _ := payload["reason"].(string)
		if reason == "" {
			continue
		}
		lastReason = reason
		if reason == expectedReason {
			return true, reason
		}
	}
	return false, lastReason
}

func findSnapshot(items []canarySnapshot, providerID string) (canarySnapshot, bool) {
	for _, item := range items {
		if item.ProviderID == providerID {
			return item, true
		}
	}
	return canarySnapshot{}, false
}

func findRepoRoot() (string, error) {
	out, err := exec.Command("git", "rev-parse", "--show-toplevel").CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("git rev-parse --show-toplevel: %w\n%s", err, out)
	}
	return strings.TrimSpace(string(out)), nil
}

func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func expandHome(path string) string {
	if path == "~" {
		if home, err := os.UserHomeDir(); err == nil {
			return home
		}
	}
	if strings.HasPrefix(path, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, strings.TrimPrefix(path, "~/"))
		}
	}
	return path
}

func mustFreePort() int {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port
}

func choosePort(existing int) int {
	if existing > 0 {
		return existing
	}
	return mustFreePort()
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'"
}

func fileSHA256(path string) (string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("hash executable %q: %w", path, err)
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:]), nil
}

func mustOutput(dir, name string, args ...string) string {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		return strings.Join(append([]string{name}, args...), " ")
	}
	return strings.TrimSpace(string(out))
}

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func atoi(s string) int {
	n, _ := strconv.Atoi(strings.TrimSpace(s))
	return n
}
