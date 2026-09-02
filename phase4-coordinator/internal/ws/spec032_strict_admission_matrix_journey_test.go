package ws

// SPEC-032 strict admission-gate evidence matrix — DRY-RUN rehearsal (issue #959).
//
// This is the isolated in-process rehearsal named in
// journeys/run-plans/RUN-PLAN-959-spec032-strict-admission-matrix.md §11. It
// exercises the three default-off strict admission-gate behaviors end to end
// against ephemeral strict-gated coordinators with synthetic providers, and
// emits a DRAFT v1 evidence artifact marked result.class="dry-run" /
// not-for-promotion.
//
// It is deliberately NOT the promoting evidence: SPEC-032 lives in the
// hardware-evidence-admission authority domain (requires_signed_journey_result),
// so CONFORMANCE promotion still requires a redacted physical-Mac run signed by
// the protected acceptance workflow. A green run here is only the precondition
// for requesting operator approval of the physical run (AC #1 / §12), never a
// substitute for it.
//
// Each phase pairs the offending "subject" provider with a healthy "control"
// provider and asserts the control is never permanently made unroutable
// (issue #959 AC #3, the no-collateral-exclusion invariant).

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

const spec032DryRunSchema = "macprovider.provider-prebeta-admission-evidence.v1"

// spec032MapEvidence returns per-provider verified evidence keyed by provider ID,
// so a single revalidation sweep can hold a healthy control valid while the
// subject goes stale/mismatched/absent. Absent key => no verified evidence.
type spec032MapEvidence struct {
	byProvider map[string]autotune.VerifiedEvidence
}

func (m spec032MapEvidence) LatestVerified(_ context.Context, providerID string, _ time.Duration) (autotune.VerifiedEvidence, bool, error) {
	ev, ok := m.byProvider[providerID]
	return ev, ok, nil
}

type spec032Snap struct {
	AdmissionCeilingExcluded bool `json:"admission_ceiling_excluded"`
	AdmissionEvidenceStale   bool `json:"admission_evidence_stale"`
	AdmissionSandboxed       bool `json:"admission_sandboxed"`
	RoutingEligible          bool `json:"routing_eligible"`
	ServingCapable           bool `json:"serving_capable"`
}

type spec032Step struct {
	ID                 string      `json:"id"`
	Requirement        string      `json:"requirement"`
	Assertion          string      `json:"assertion"`
	Status             string      `json:"status"`
	SubjectFingerprint string      `json:"subject_fingerprint"`
	SubjectBefore      spec032Snap `json:"subject_before"`
	SubjectAfter       spec032Snap `json:"subject_after"`
	NonAdmissionReason string      `json:"non_admission_reason,omitempty"`
	ControlFingerprint string      `json:"control_fingerprint"`
	ControlAfter       spec032Snap `json:"control_after"`
}

func spec032Fingerprint(providerID string) string {
	sum := sha256.Sum256([]byte("spec032-dry-run:" + providerID))
	return hex.EncodeToString(sum[:])[:16]
}

func spec032SnapOf(t *testing.T, s *Server, providerID, assignedID string) spec032Snap {
	t.Helper()
	p, ok := s.pool.Resolve(providerID, assignedID)
	if !ok {
		t.Fatalf("provider %s/%s missing from registry", providerID, assignedID)
	}
	return spec032Snap{
		AdmissionCeilingExcluded: p.AdmissionCeilingExcluded,
		AdmissionEvidenceStale:   p.AdmissionEvidenceStale,
		AdmissionSandboxed:       p.AdmissionSandboxed,
		RoutingEligible:          p.RoutingEligible(),
		ServingCapable:           p.ServingCapable(),
	}
}

func spec032StrictConfig() config.Config {
	cfg := config.Default()
	cfg.ProofOfWeights.RequireAutotuneHelloGate = true
	cfg.ProofOfWeights.AutotuneEvidenceTTLDays = 30
	return cfg
}

// spec032AddSessionedProvider registers a provider into the server pool and
// stores a minimal session so the revalidation/reload paths (which skip
// sessionless providers) consider it. No writer goroutine is started: the
// exercised paths only mutate registry admission flags.
func spec032AddSessionedProvider(t *testing.T, s *Server, prov *pool.Provider, at time.Time) {
	t.Helper()
	if _, registered := s.pool.RegisterAt(prov, nil, at); !registered {
		t.Fatalf("register provider %s failed", prov.ProviderID)
	}
	srvConn, provConn := net.Pipe()
	t.Cleanup(func() {
		_ = provConn.Close()
		_ = srvConn.Close()
	})
	sess := newProviderSession(prov.ProviderID, prov.AssignedID, srvConn, 4)
	s.sessions.Store(sessionKey(prov.ProviderID, prov.AssignedID), sess)
}

func spec032ControlProvider(id, assigned string) *pool.Provider {
	return &pool.Provider{
		ProviderID:           id,
		AssignedID:           assigned,
		Hostname:             "control-mac",
		ModelID:              "small-model",
		MaxAdmittedMinRAMGB:  8,
		MaxAdmittedModelID:   "small-model",
		CatalogAdmissionMode: "current",
		RAMGB:                16,
		MaxConcurrency:       2,
		SlotsFree:            2,
		SlotsTotal:           2,
		State:                pool.StateReady,
	}
}

// TestSpec032StrictAdmissionMatrixDryRunJourney is the §11 dry-run rehearsal.
func TestSpec032StrictAdmissionMatrixDryRunJourney(t *testing.T) {
	now := time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC)
	catalog := admissionCeilingTestCatalog(t)

	var steps []spec032Step
	steps = append(steps, spec032PhaseR001(t, catalog, now)...)
	steps = append(steps, spec032PhaseR002(t, catalog, now)...)
	steps = append(steps, spec032PhaseR003(t, catalog, now)...)

	for _, st := range steps {
		if st.Status != "pass" {
			t.Fatalf("step %s (%s) did not pass: %+v", st.ID, st.Requirement, st)
		}
		if !st.ControlAfter.RoutingEligible {
			t.Fatalf("AC#3 violated: control not routable after %s: %+v", st.ID, st.ControlAfter)
		}
	}

	spec032WriteDryRunEvidence(t, now, steps)
}

// Phase R001 — over-ceiling / uncatalogued heartbeat transitions route-exclude
// the subject; an in-ceiling heartbeat clears it; the control is untouched.
func spec032PhaseR001(t *testing.T, catalog *autotune.Catalog, now time.Time) []spec032Step {
	registry := pool.NewRegistry(nil)
	server := NewServer(spec032StrictConfig(), registry, zerolog.Nop(),
		WithAutotuneCatalog(catalog),
		WithNow(func() time.Time { return now }),
	)

	control := spec032ControlProvider("control-r001", "control-r001-s")
	registerAdmissionCeilingProvider(t, registry, *control)
	registerAdmissionCeilingProvider(t, registry, pool.Provider{
		ProviderID:           "subject-r001",
		AssignedID:           "subject-r001-s",
		ModelID:              "small-model",
		MaxAdmittedMinRAMGB:  8,
		MaxAdmittedModelID:   "small-model",
		CatalogAdmissionMode: "current",
	})

	subID, subSID := "subject-r001", "subject-r001-s"
	ctlID, ctlSID := "control-r001", "control-r001-s"

	type tc struct {
		id, model, assertion, wantReason string
		wantExcluded                     bool
	}
	cases := []tc{
		{"r001-over-ceiling", "large-model", "over-ceiling heartbeat route-excludes subject", "autotune_model_cap_exceeded", true},
		{"r001-uncatalogued", "uncatalogued-model", "uncatalogued heartbeat route-excludes subject", "autotune_model_uncatalogued", true},
		{"r001-clears", "small-model", "in-ceiling heartbeat clears the route exclusion", "", false},
	}

	var out []spec032Step
	for _, c := range cases {
		before := spec032SnapOf(t, server, subID, subSID)
		server.handleHeartbeat(nil, subID, subSID, admissionCeilingHeartbeat(c.model))
		after := spec032SnapOf(t, server, subID, subSID)
		control := spec032SnapOf(t, server, ctlID, ctlSID)

		status := "pass"
		if after.AdmissionCeilingExcluded != c.wantExcluded {
			status = "fail"
		}
		if c.wantExcluded && (after.RoutingEligible || after.ServingCapable) {
			status = "fail"
		}
		if !c.wantExcluded && !after.RoutingEligible {
			status = "fail"
		}
		if !control.RoutingEligible {
			status = "fail"
		}
		reason := ""
		if c.wantExcluded {
			snap, _ := server.pool.Resolve(subID, subSID)
			reason = server.admissionCeilingRouteVerdict(snap).reason
			if reason != c.wantReason {
				status = "fail"
			}
		}
		out = append(out, spec032Step{
			ID: c.id, Requirement: "SPEC-032-R001", Assertion: c.assertion, Status: status,
			SubjectFingerprint: spec032Fingerprint(subID), SubjectBefore: before, SubjectAfter: after,
			NonAdmissionReason: reason,
			ControlFingerprint: spec032Fingerprint(ctlID), ControlAfter: control,
		})
	}
	return out
}

// Phase R002 — the session-time revalidation sweep route-excludes a subject
// whose evidence is stale, tuple-mismatched, or whose admitted tuple is
// missing, while a control with fresh matching evidence keeps routing.
func spec032PhaseR002(t *testing.T, catalog *autotune.Catalog, now time.Time) []spec032Step {
	type tc struct {
		id, assertion string
		subjectEv     func() (autotune.VerifiedEvidence, bool)
		subjectTuple  bool
	}
	cases := []tc{
		{"r002-expired", "expired evidence route-excludes subject",
			func() (autotune.VerifiedEvidence, bool) { return autotune.VerifiedEvidence{}, false }, true},
		{"r002-tuple-mismatch", "tuple-mismatched evidence route-excludes subject",
			func() (autotune.VerifiedEvidence, bool) {
				return admissionCeilingVerifiedEvidence(t, catalog, "small", "hashB", "apple m4 max", 64), true
			}, true},
		{"r002-missing-tuple", "missing admitted tuple route-excludes capped subject",
			func() (autotune.VerifiedEvidence, bool) {
				return admissionCeilingVerifiedEvidence(t, catalog, "small", "hashA", "apple m4 max", 64), true
			}, false},
	}

	var out []spec032Step
	for _, c := range cases {
		s, subject, _ := newEncryptedRelayHarnessWithConfig(t, spec032StrictConfig(), zerolog.Nop(), now)
		subject.ModelID = "small-model"
		subject.MaxAdmittedMinRAMGB = 8
		subject.MaxAdmittedModelID = "small-model"
		subject.CatalogAdmissionMode = "current"
		if c.subjectTuple {
			setAdmittedTupleValues(subject, "hashA", "apple m4 max", 64)
		}

		control := spec032ControlProvider("control-r002", "control-r002-s")
		setAdmittedTupleValues(control, "hashC", "apple m4 max", 64)
		spec032AddSessionedProvider(t, s, control, now)

		subjectEv, subjectOK := c.subjectEv()
		s.autotuneCatalog = catalog
		s.autotuneEvidence = spec032MapEvidence{byProvider: map[string]autotune.VerifiedEvidence{
			control.ProviderID: admissionCeilingVerifiedEvidence(t, catalog, "small", "hashC", "apple m4 max", 64),
		}}
		if subjectOK {
			s.autotuneEvidence.(spec032MapEvidence).byProvider[subject.ProviderID] = subjectEv
		}

		before := spec032SnapOf(t, s, subject.ProviderID, subject.AssignedID)
		s.runTrustRevalidationSweep()
		after := spec032SnapOf(t, s, subject.ProviderID, subject.AssignedID)
		controlAfter := spec032SnapOf(t, s, control.ProviderID, control.AssignedID)

		status := "pass"
		if !after.AdmissionEvidenceStale || after.RoutingEligible {
			status = "fail"
		}
		if !controlAfter.RoutingEligible || controlAfter.AdmissionEvidenceStale {
			status = "fail"
		}
		out = append(out, spec032Step{
			ID: c.id, Requirement: "SPEC-032-R002", Assertion: c.assertion, Status: status,
			SubjectFingerprint: spec032Fingerprint(subject.ProviderID), SubjectBefore: before, SubjectAfter: after,
			NonAdmissionReason: "autotune_evidence_stale_or_mismatched",
			ControlFingerprint: spec032Fingerprint(control.ProviderID), ControlAfter: controlAfter,
		})
	}
	return out
}

// Phase R003 — an evidence-absent subject is sandboxed and unroutable; a
// hot-enable proof-of-weights reload fails closed (the whole pool is
// pre-quarantined), and the next revalidation sweep restores the healthy
// control while the evidence-absent subject stays sandboxed.
func spec032PhaseR003(t *testing.T, catalog *autotune.Catalog, now time.Time) []spec032Step {
	// Start gate OFF so both providers begin routable, then hot-enable.
	cfgOff := config.Default()
	cfgOff.ProofOfWeights.RequireAutotuneHelloGate = false
	cfgOff.ProofOfWeights.AutotuneEvidenceTTLDays = 30
	s, subject, _ := newEncryptedRelayHarnessWithConfig(t, cfgOff, zerolog.Nop(), now)
	// Evidence-absent subject: no admitted tuple => sandboxed on strict revalidate.
	subject.ModelID = "small-model"
	subject.MaxAdmittedMinRAMGB = 0

	control := spec032ControlProvider("control-r003", "control-r003-s")
	setAdmittedTupleValues(control, "hashC", "apple m4 max", 64)
	spec032AddSessionedProvider(t, s, control, now)

	s.autotuneCatalog = catalog
	s.autotuneEvidence = spec032MapEvidence{byProvider: map[string]autotune.VerifiedEvidence{
		control.ProviderID: admissionCeilingVerifiedEvidence(t, catalog, "small", "hashC", "apple m4 max", 64),
	}}

	var out []spec032Step

	// Baseline: both routable while gate is off.
	subBefore := spec032SnapOf(t, s, subject.ProviderID, subject.AssignedID)
	ctlBefore := spec032SnapOf(t, s, control.ProviderID, control.AssignedID)
	baselineStatus := "pass"
	if !subBefore.RoutingEligible || !ctlBefore.RoutingEligible {
		baselineStatus = "fail"
	}

	// Hot-enable the strict gate => fail-closed pre-quarantine of the whole pool.
	on := config.Default().ProofOfWeights
	on.RequireAutotuneHelloGate = true
	on.AutotuneEvidenceTTLDays = 30
	reload := s.SetProofOfWeightsConfig(on)

	subReload := spec032SnapOf(t, s, subject.ProviderID, subject.AssignedID)
	ctlReload := spec032SnapOf(t, s, control.ProviderID, control.AssignedID)
	reloadStatus := "pass"
	// Fail-closed default: the reload pre-quarantines the pool (evidence-stale)
	// before re-admitting only the evidence-backed sessions. The evidence-absent
	// subject ends sandboxed and unroutable; the healthy control, re-validated in
	// the same reload, stays routable (no collateral exclusion — AC #3).
	if reload.PreQuarantined < 1 {
		reloadStatus = "fail"
	}
	if subReload.RoutingEligible || subReload.ServingCapable || !subReload.AdmissionSandboxed {
		reloadStatus = "fail"
	}
	if !ctlReload.RoutingEligible || ctlReload.AdmissionSandboxed || ctlReload.AdmissionEvidenceStale {
		reloadStatus = "fail"
	}
	if baselineStatus != "pass" {
		reloadStatus = "fail"
	}
	out = append(out, spec032Step{
		ID: "r003-sandbox-and-failclosed-reload", Requirement: "SPEC-032-R003",
		Assertion: "evidence-absent subject sandboxed; fail-closed hot-enable reload keeps the evidence-backed control routable",
		Status:    reloadStatus, SubjectFingerprint: spec032Fingerprint(subject.ProviderID),
		SubjectBefore: subBefore, SubjectAfter: subReload, NonAdmissionReason: "autotune_evidence_required",
		ControlFingerprint: spec032Fingerprint(control.ProviderID), ControlAfter: ctlReload,
	})

	// Recovery sweep: control (fresh matching evidence) is restored; the
	// evidence-absent subject stays sandboxed and unroutable.
	s.runTrustRevalidationSweep()
	subRecover := spec032SnapOf(t, s, subject.ProviderID, subject.AssignedID)
	ctlRecover := spec032SnapOf(t, s, control.ProviderID, control.AssignedID)
	recoverStatus := "pass"
	if subRecover.RoutingEligible || subRecover.ServingCapable {
		recoverStatus = "fail"
	}
	if !ctlRecover.RoutingEligible || ctlRecover.AdmissionEvidenceStale || ctlRecover.AdmissionSandboxed {
		recoverStatus = "fail"
	}
	out = append(out, spec032Step{
		ID: "r003-recovery-sweep", Requirement: "SPEC-032-R003",
		Assertion: "recovery sweep restores healthy control; evidence-absent subject stays sandboxed",
		Status:    recoverStatus, SubjectFingerprint: spec032Fingerprint(subject.ProviderID),
		SubjectBefore: subReload, SubjectAfter: subRecover, NonAdmissionReason: "autotune_evidence_required",
		ControlFingerprint: spec032Fingerprint(control.ProviderID), ControlAfter: ctlRecover,
	})
	return out
}

func spec032WriteDryRunEvidence(t *testing.T, now time.Time, steps []spec032Step) {
	t.Helper()
	runID := "provider-prebeta-admission-spec032-strict-dryrun-" + now.Format("20060102T150405Z")
	evidence := map[string]any{
		"schema_version":  spec032DryRunSchema,
		"journey_id":      "JOURNEY-PROVIDER-PREBETA-ADMISSION",
		"run_id":          runID,
		"captured_at":     now.Format("2006-01-02T15:04:05Z"),
		"requirement_ids": []string{"SPEC-032-R001", "SPEC-032-R002", "SPEC-032-R003"},
		"environment": map[string]any{
			"class":                   "in-process-strict-gate-dry-run",
			"hardware_profile":        "synthetic-redacted",
			"production_side_effects": false,
			"production_pearl":        false,
		},
		"result": map[string]any{
			"class":   "dry-run",
			"status":  "pass",
			"promote": false,
			"summary": "SPEC-032 strict admission-gate matrix rehearsed in-process (R001 ceiling route-exclusion, R002 revalidation staleness/mismatch/missing-tuple, R003 evidence-absent sandbox + fail-closed reload). Healthy control never permanently unroutable. NOT promoting evidence: a signed physical-Mac run is still required.",
		},
		"steps": steps,
		"redaction": map[string]any{
			"provider_identity_redacted": true,
			"secrets_redacted":           true,
		},
	}
	payload, err := json.MarshalIndent(evidence, "", "  ")
	if err != nil {
		t.Fatalf("marshal dry-run evidence: %v", err)
	}
	payload = append(payload, '\n')
	// Redaction guard: raw provider IDs must never appear; only fingerprints.
	for _, needle := range []string{"subject-r001", "control-r001", "control-r002", "control-r003"} {
		if strings.Contains(string(payload), needle) {
			t.Fatalf("dry-run evidence leaked raw provider id %q", needle)
		}
	}
	dir := t.TempDir()
	path := filepath.Join(dir, runID+".dry-run.json")
	if err := os.WriteFile(path, payload, 0o644); err != nil {
		t.Fatalf("write dry-run evidence: %v", err)
	}
	t.Logf("wrote dry-run evidence artifact: %s", path)
}
