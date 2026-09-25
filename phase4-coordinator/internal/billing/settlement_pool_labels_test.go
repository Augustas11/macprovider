package billing

import (
	"context"
	"database/sql"
	"strings"
	"testing"
)

// Golden digests computed before the SPEC-042 R006 manifest labels existed.
// Global and pool_id-only snapshots MUST keep these exact digests.
const (
	goldenGlobalRouteSnapshotDigest = "292b275c9c00be61f56e14887a33b8d94ae8931a9911104f4e87fccbe37a5142"
	goldenPoolIDRouteSnapshotDigest = "1c79b3757e31bdb3273e632a47ff54075b78879788e87cf8d401884dc396184a"
)

func TestRouteSnapshotPoolLabels_GlobalDigestGoldenUnchanged(t *testing.T) {
	global := testRouteSnapshot()
	digest, _, err := global.Digest()
	if err != nil {
		t.Fatal(err)
	}
	if digest != goldenGlobalRouteSnapshotDigest {
		t.Fatalf("poolless route snapshot digest=%s, want golden %s", digest, goldenGlobalRouteSnapshotDigest)
	}
	for _, key := range []string{"pool_id", "manifest_version", "manifest_core_digest"} {
		if _, ok := global.Value()[key]; ok {
			t.Fatalf("poolless snapshot must not carry %s", key)
		}
	}

	pooled := testRouteSnapshot()
	pooled.PoolID = "pool-abc"
	digest, _, err = pooled.Digest()
	if err != nil {
		t.Fatal(err)
	}
	if digest != goldenPoolIDRouteSnapshotDigest {
		t.Fatalf("pool_id-only route snapshot digest=%s, want golden %s", digest, goldenPoolIDRouteSnapshotDigest)
	}
}

func TestRouteSnapshotPoolLabels_ManifestLabelsBindDigestAndRoundTrip(t *testing.T) {
	labeled := testRouteSnapshot()
	labeled.PoolID = "pool-abc"
	labeled.ManifestVersion = 3
	labeled.ManifestCoreDigest = strings.Repeat("d", 64)
	value := labeled.Value()
	if value["manifest_version"] != int64(3) || value["manifest_core_digest"] != strings.Repeat("d", 64) {
		t.Fatalf("labeled snapshot value missing manifest labels: %#v", value)
	}
	labeledDigest, _, err := labeled.Digest()
	if err != nil {
		t.Fatal(err)
	}
	if labeledDigest == goldenPoolIDRouteSnapshotDigest {
		t.Fatal("manifest labels must change the route snapshot digest")
	}
	bumped := labeled
	bumped.ManifestVersion = 4
	bumpedDigest, _, err := bumped.Digest()
	if err != nil {
		t.Fatal(err)
	}
	if bumpedDigest == labeledDigest {
		t.Fatal("manifest_version must bind into the digest")
	}

	_, store := newRequestAndBillingStores(t)
	insertDigest, err := store.InsertRouteSnapshot(context.Background(), labeled)
	if err != nil {
		t.Fatal(err)
	}
	conn, err := store.db.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	loaded, loadedDigest, err := loadSettlementRouteSnapshotConn(context.Background(), conn, SettlementReceiptIdentity{
		AccountScope: labeled.AccountScope,
		RequestID:    labeled.RequestID,
		AttemptN:     labeled.AttemptN,
		ProviderID:   labeled.ProviderID,
	})
	if err != nil {
		t.Fatalf("settlement loader: %v", err)
	}
	if loaded.ManifestVersion != 3 || loaded.ManifestCoreDigest != strings.Repeat("d", 64) || loadedDigest != insertDigest {
		t.Fatalf("loaded labels=%d/%q digest=%s, want 3/%q %s", loaded.ManifestVersion, loaded.ManifestCoreDigest, loadedDigest, strings.Repeat("d", 64), insertDigest)
	}
}

func TestRouteSnapshotPoolLabels_ValidateRejectsInconsistentLabels(t *testing.T) {
	cases := map[string]func(*RouteSnapshot){
		"labels without pool_id": func(r *RouteSnapshot) {
			r.ManifestVersion = 1
			r.ManifestCoreDigest = strings.Repeat("d", 64)
		},
		"version without digest": func(r *RouteSnapshot) {
			r.PoolID = "pool-abc"
			r.ManifestVersion = 1
		},
		"digest without version": func(r *RouteSnapshot) {
			r.PoolID = "pool-abc"
			r.ManifestCoreDigest = strings.Repeat("d", 64)
		},
		"non-hex digest": func(r *RouteSnapshot) {
			r.PoolID = "pool-abc"
			r.ManifestVersion = 1
			r.ManifestCoreDigest = strings.Repeat("D", 64)
		},
	}
	for name, mutate := range cases {
		snapshot := testRouteSnapshot()
		mutate(&snapshot)
		if err := snapshot.Validate(); err == nil {
			t.Fatalf("%s: Validate succeeded, want error", name)
		}
	}
}

func TestSettlementPoolLabelStatus(t *testing.T) {
	route := testRouteSnapshot()
	route.PoolID = "pool-abc"
	route.ManifestVersion = 2
	route.ManifestCoreDigest = strings.Repeat("d", 64)
	match := &SettlementPoolLabels{PoolID: "pool-abc", ManifestVersion: 2, ManifestCoreDigest: strings.Repeat("d", 64), RouteSnapshotHash: "h"}
	cases := []struct {
		name   string
		route  RouteSnapshot
		labels *SettlementPoolLabels
		want   string
	}{
		{"global", testRouteSnapshot(), nil, ""},
		{"global route pool labels", testRouteSnapshot(), match, PoolLabelStatusDisputed},
		{"pool without settlement labels", route, nil, PoolLabelStatusUnverified},
		{"matching", route, match, PoolLabelStatusVerified},
		{"pool mismatch", route, &SettlementPoolLabels{PoolID: "pool-x", ManifestVersion: 2, ManifestCoreDigest: strings.Repeat("d", 64)}, PoolLabelStatusDisputed},
		{"version mismatch", route, &SettlementPoolLabels{PoolID: "pool-abc", ManifestVersion: 3, ManifestCoreDigest: strings.Repeat("d", 64)}, PoolLabelStatusDisputed},
		{"digest mismatch", route, &SettlementPoolLabels{PoolID: "pool-abc", ManifestVersion: 2, ManifestCoreDigest: strings.Repeat("e", 64)}, PoolLabelStatusDisputed},
		{"route hash mismatch", route, &SettlementPoolLabels{PoolID: "pool-abc", ManifestVersion: 2, ManifestCoreDigest: strings.Repeat("d", 64), RouteSnapshotHash: "other"}, PoolLabelStatusDisputed},
	}
	for _, tc := range cases {
		if got := settlementPoolLabelStatus(tc.route, "h", tc.labels); got != tc.want {
			t.Fatalf("%s: status=%q want %q", tc.name, got, tc.want)
		}
	}
}

// Recording labels never changes the verdict: a disputed label leaves the
// outcome and reason identical to the global run, and a dispute is sticky
// across the pending->terminal update.
func TestSettlementPoolLabels_DisputedSettlesUnchangedAndIsSticky(t *testing.T) {
	type verdict struct {
		outcome, reason string
		closed          bool
		poolID          sql.NullString
		status          sql.NullString
		manifestVersion sql.NullInt64
	}
	run := func(t *testing.T, pooled bool, first, second *SettlementPoolLabels) (SettlementPoolLabelRecord, verdict) {
		t.Helper()
		fixtures := loadSettlementVerifierFixtures(t)
		pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
		tuple := firstSettlementTupleWithNegativeVariant(t, fixtures, "normal_done")
		input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
		if pooled {
			input.RouteSnapshot.PoolID = "pool-abc"
			input.RouteSnapshot.ManifestVersion = 2
			input.RouteSnapshot.ManifestCoreDigest = strings.Repeat("d", 64)
		}
		_, store := newRequestAndBillingStores(t)
		createSettlementReceiptAuditLog(t, store.db)
		seedSettlementReceiptEvidence(t, store, input)
		insertSPEC022LedgerCredit(t, store.db, input, 700)
		id := SettlementReceiptIdentity{AccountScope: input.AccountScope, RequestID: input.RequestID, AttemptN: input.AttemptN, ProviderID: input.ProviderID}
		ctx := context.Background()
		if rec, err := store.RecordSettlementPoolLabels(ctx, id, first); err != nil || rec.Status != "" {
			t.Fatalf("labels before any verdict row: rec=%+v err=%v, want no-op", rec, err)
		}
		deadline := input.TerminalStateTSUnixMS + input.RouteSnapshot.PendingDeadlineSeconds*1000
		if _, err := store.RecordMissingSettlementReceipt(ctx, SettlementReceiptMissingInput{SettlementReceiptIdentity: id, NowUnixMS: deadline - 1}); err != nil {
			t.Fatal(err)
		}
		if _, err := store.RecordSettlementPoolLabels(ctx, id, first); err != nil {
			t.Fatal(err)
		}
		if _, err := store.RecordMissingSettlementReceipt(ctx, SettlementReceiptMissingInput{SettlementReceiptIdentity: id, NowUnixMS: deadline + 1}); err != nil {
			t.Fatal(err)
		}
		rec, err := store.RecordSettlementPoolLabels(ctx, id, second)
		if err != nil {
			t.Fatal(err)
		}
		var v verdict
		var closed int
		if err := store.db.QueryRow(`SELECT settlement_outcome, reason, closed, pool_id, pool_label_status, pool_manifest_version FROM settlement_receipt_verdicts WHERE request_id = ?`, input.RequestID).
			Scan(&v.outcome, &v.reason, &closed, &v.poolID, &v.status, &v.manifestVersion); err != nil {
			t.Fatal(err)
		}
		v.closed = closed == 1
		return rec, v
	}
	match := &SettlementPoolLabels{PoolID: "pool-abc", ManifestVersion: 2, ManifestCoreDigest: strings.Repeat("d", 64)}
	mismatch := &SettlementPoolLabels{PoolID: "pool-abc", ManifestVersion: 3, ManifestCoreDigest: strings.Repeat("e", 64)}

	_, global := run(t, false, nil, nil)
	if global.poolID.Valid || global.status.Valid || global.manifestVersion.Valid {
		t.Fatalf("global verdict pool columns must stay NULL: %#v", global)
	}
	_, verified := run(t, true, match, match)
	if verified.status.String != PoolLabelStatusVerified || verified.poolID.String != "pool-abc" || verified.manifestVersion.Int64 != 2 {
		t.Fatalf("verified verdict=%#v", verified)
	}
	rec, disputed := run(t, true, mismatch, match)
	if disputed.status.String != PoolLabelStatusDisputed || rec.Status != PoolLabelStatusDisputed {
		t.Fatalf("disputed label must stay sticky: row=%#v rec=%+v", disputed, rec)
	}
	for name, got := range map[string]verdict{"verified": verified, "disputed": disputed} {
		if got.outcome != global.outcome || got.reason != global.reason || got.closed != global.closed {
			t.Fatalf("%s pool verdict settled %s/%s/%v, want global %s/%s/%v", name, got.outcome, got.reason, got.closed, global.outcome, global.reason, global.closed)
		}
	}
}
