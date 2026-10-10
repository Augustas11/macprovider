package relayblind

import (
	"context"
	"strings"
	"sync"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

type recordingPrivacyMetrics struct {
	mu         sync.Mutex
	rejections map[string]int
	versions   [][]string
}

func (r *recordingPrivacyMetrics) IncPrivacyPostureRejection(reason string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.rejections == nil {
		r.rejections = map[string]int{}
	}
	r.rejections[reason]++
}

func (r *recordingPrivacyMetrics) SetPrivacyReleaseIdentityVersions(versions []string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.versions = append(r.versions, append([]string(nil), versions...))
}

func (r *recordingPrivacyMetrics) count(reason string) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.rejections[reason]
}

func (r *recordingPrivacyMetrics) lastVersions() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.versions) == 0 {
		return "<none>"
	}
	return strings.Join(r.versions[len(r.versions)-1], ",")
}

// An unapproved code identity is counted by reason, on both the key
// advertisement and the posture paths, and a quarantine is counted too.
func TestPrivacyRejectionsAreCountedByReason(t *testing.T) {
	unapproved := newPrivacyFixture(t, func(cfg *config.PrivacyClassConfig) {
		cfg.ApprovedCodeIdentities = []config.ApprovedCodeIdentity{approvedIdentity(secondFixtureCDHash)}
	})
	metrics := &recordingPrivacyMetrics{}
	unapproved.auth.UseMetrics(metrics)
	err := unapproved.auth.AcceptPrivacyKeys(context.Background(), unapproved.providerID, unapproved.session, []PrivacyKeyRecord{unapproved.record}, unapproved.now)
	mustReject(t, err, "posture_unapproved_code_identity")
	if got := metrics.count("posture_unapproved_code_identity"); got != 1 {
		t.Fatalf("advertisement rejection count = %d, want 1", got)
	}

	f := newPrivacyFixture(t, nil)
	f.auth.UseMetrics(metrics)
	f.accept()
	nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
	if err != nil {
		t.Fatal(err)
	}
	statement := f.statement(nonce, 0, issued)
	statement.BinaryVersion = "9.9.9"
	err = f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.response(statement), nil, f.now)
	mustReject(t, err, "posture_unapproved_code_identity")
	if got := metrics.count("posture_unapproved_code_identity"); got != 2 {
		t.Fatalf("posture rejection count = %d, want 2", got)
	}

	denied := newPrivacyFixture(t, func(cfg *config.PrivacyClassConfig) {
		cfg.DeniedCodeCDHashes = []string{fixtureCDHash}
	})
	denied.auth.UseMetrics(metrics)
	err = denied.auth.AcceptPrivacyKeys(context.Background(), denied.providerID, denied.session, []PrivacyKeyRecord{denied.record}, denied.now)
	mustQuarantine(t, err, "posture_denied_code_identity")
	if got := metrics.count("posture_denied_code_identity"); got != 1 {
		t.Fatalf("quarantine count = %d, want 1", got)
	}
}

// Every reload publishes the versions approved from signed release files,
// and wiring metrics publishes what is already loaded.
func TestReleaseIdentityVersionsArePublished(t *testing.T) {
	dir := t.TempDir()
	key, public := releaseSigningKey(t)
	writeSignedReleaseMetadata(t, dir, "v1.8.230", key, releaseIdentityObject("1.8.230", fixtureCDHash))
	f := newPrivacyFixture(t, nil)
	f.auth.ConfigureReleaseIdentities(dir, public)
	metrics := &recordingPrivacyMetrics{}
	f.auth.UseMetrics(metrics)
	if got := metrics.lastVersions(); got != "1.8.230" {
		t.Fatalf("versions on UseMetrics = %q", got)
	}
	writeSignedReleaseMetadata(t, dir, "v1.8.232", key, releaseIdentityObject("1.8.232", secondFixtureCDHash))
	if load := f.auth.RefreshReleaseIdentities(); load.Identities != 2 {
		t.Fatalf("load = %+v", load)
	}
	if got := metrics.lastVersions(); got != "1.8.230,1.8.232" {
		t.Fatalf("versions after reload = %q", got)
	}
}
