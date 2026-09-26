package integration

// #1693 pricing lane — tier E1 journeys J1–J8
// (docs/testing/1693-pricing-lane-e2e-plan.md). Every journey drives the real
// coordinator / gateway binaries, real SQLite and the real lane scripts; the
// oracles O1–O6 are computed from the ledger, the applied-config record and
// real HTTP.

import (
	"bytes"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// J1 forward pricing + J6 reversal on one coordinator process.
func TestPricingLaneJ1ForwardJ6Reversal(t *testing.T) {
	p := newPricingLane(t, pricingLaneOpts{extraAccounts: 1})
	preOnly := p.extraKeys[0] // an account that only ever buys before the change (O4)
	tableA := p.cardA.table()
	cardB, cardBRaw := p.cardB()
	tableB := cardB.table()
	reviewed := map[string]pricingTable{"A": tableA, "B": tableB}

	boot := p.applied()
	if boot.Source != "boot" || boot.BillingSnapshotID == 0 {
		t.Fatalf("boot record=%s", boot.raw)
	}
	p.assertAppliedTable(boot, tableA, "A")
	p.assertO6(p.cardARaw)
	p.assertO5()

	// Paid traffic at A.
	idsA := p.paidRequests(p.apiKey, 4)
	idsPre := p.paidRequests(preOnly.apiKey, 2)
	preAccount := p.requestLogAccount(idsPre[0])
	mainAccount := p.requestLogAccount(idsA[0])
	if preAccount == "" || mainAccount == "" || preAccount == mainAccount {
		t.Fatalf("request_log account ids: pre=%q main=%q", preAccount, mainAccount)
	}
	stmtPreBefore := p.generateWholesale(preAccount)
	if stmtPreBefore.status != http.StatusOK {
		t.Fatalf("wholesale (pre-only account, before change) status=%d body=%s", stmtPreBefore.status, stmtPreBefore.raw)
	}
	// Prime the gateway's public-feed cache with card A.
	if st, _, body := p.gatewayGET("/v1/rate-card"); st != http.StatusOK || !bytes.Equal(body, p.cardARaw) {
		t.Fatalf("gateway /v1/rate-card before change: status=%d sha=%s want card A", st, sha256HexBytes(body))
	}
	snapsBefore := len(p.snapshots())

	t.Run("J1_forward_A_to_B", func(t *testing.T) {
		yamlA, err := os.ReadFile(p.coordYAML)
		if err != nil {
			t.Fatal(err)
		}
		yamlB := p.spliceYAML(p.coordYAML, rateCardBlock(cardB))
		if !strings.Contains(string(yamlB), "completion_credits_per_mtok: 40500") {
			t.Fatalf("spliced yaml lacks the B row")
		}
		p.installPricing(yamlB, cardBRaw)
		ok, logs := p.sighup(rejectMarkersAll...)
		if !ok {
			t.Fatalf("J1 reload rejected:\n%s", strings.Join(logs, "\n"))
		}
		rec := p.applied()
		if rec.Source != "sighup" {
			t.Fatalf("record source=%s", rec.Source)
		}
		if rec.BillingSnapshotID <= boot.BillingSnapshotID || rec.RateTableSHA256 == boot.RateTableSHA256 {
			t.Errorf("record did not advance: boot snapshot=%d table=%s, now snapshot=%d table=%s",
				boot.BillingSnapshotID, boot.RateTableSHA256, rec.BillingSnapshotID, rec.RateTableSHA256)
		}
		if rec.ConfigSHA256 != sha256HexBytes(yamlB) || rec.ConfigSHA256 == sha256HexBytes(yamlA) {
			t.Errorf("record config_sha256=%s want sha(yaml B)=%s", rec.ConfigSHA256, sha256HexBytes(yamlB))
		}
		p.assertAppliedTable(rec, tableB, "B")
		p.assertO6(cardBRaw)
		p.assertO5()

		// O3: exactly one snapshot row for one successful reload, equal to B.
		snaps := p.snapshots()
		if got := len(snaps) - snapsBefore; got != 1 {
			t.Fatalf("O3: reload added %d snapshot rows, want 1", got)
		}
		if !snaps[len(snaps)-1].Table.equal(tableB) {
			t.Errorf("O3: new snapshot row is not table B: %s", snaps[len(snaps)-1].RawJSON)
		}

		idsB := p.paidRequests(p.apiKey, 4)
		labels := p.assertO1(reviewed)
		for _, id := range idsA {
			for _, e := range p.creditRatesFor(id) {
				if e.Prompt != tableA[pricingLlamaKey].Prompt || e.Completion != tableA[pricingLlamaKey].Completion {
					t.Errorf("I5: pre-change request %s re-priced to %+v", id, e)
				}
			}
		}
		for _, id := range idsB {
			for _, e := range p.creditRatesFor(id) {
				if e.Prompt != tableB[pricingLlamaKey].Prompt || e.Completion != tableB[pricingLlamaKey].Completion {
					t.Errorf("post-change request %s priced %+v, want table B", id, e)
				}
			}
		}
		t.Logf("O1 labels: %v", labels)

		// O4: the pre-only account's statement is unchanged by the change.
		stmtPreAfter := p.generateWholesale(preAccount)
		if stmtPreAfter.status != http.StatusOK {
			t.Fatalf("wholesale (pre-only, after change) status=%d body=%s", stmtPreAfter.status, stmtPreAfter.raw)
		}
		if stmtPreBefore.comparable(t) != stmtPreAfter.comparable(t) {
			t.Errorf("O4: statement for pre-change rows changed across the price change:\nbefore=%s\nafter=%s", stmtPreBefore.raw, stmtPreAfter.raw)
		}
		// O4: the main account's statement prices each generation separately.
		stmtMain := p.generateWholesale(mainAccount)
		if stmtMain.status != http.StatusOK {
			t.Fatalf("wholesale main status=%d body=%s", stmtMain.status, stmtMain.raw)
		}
		line := stmtMain.line(t, settlementFixtureModelID)
		// 4 A rows + 4 B rows, 8 prompt / 12 completion tokens each.
		want := listGross(4*8, 4*12, tableA[pricingLlamaKey]) + listGross(4*8, 4*12, tableB[pricingLlamaKey])
		if got := jsonInt(line["gross_credits"]); got != want {
			t.Errorf("O4: main account line gross=%d want per-generation %d (line=%v)", got, want, line)
		}

		// Gateway convergence (I3): no knob shortens the gateway's 300 s
		// public-feed TTL (phase5-gateway public_feeds.go publicRateCardCacheTTL
		// is a const), so the bound is asserted structurally: the gateway may
		// still serve the cached A pair, never a third card, and every pair it
		// serves verifies; a gateway restart converges immediately.
		st, _, gwBody := p.gatewayGET("/v1/rate-card")
		_, _, gwSig := p.gatewayGET("/v1/rate-card.sig")
		if st != http.StatusOK || (!bytes.Equal(gwBody, p.cardARaw) && !bytes.Equal(gwBody, cardBRaw)) {
			t.Errorf("gateway served neither card A nor B: status=%d", st)
		}
		if !p.keys.verify(gwBody, gwSig) {
			t.Errorf("gateway rate-card pair does not verify after the change")
		}
		t.Logf("gateway /v1/rate-card within TTL serves card %s", map[bool]string{true: "A (cached)", false: "B"}[bytes.Equal(gwBody, p.cardARaw)])
		_, hdr, _ := p.coordGET("/v1/rate-card")
		if cc := hdr.Get("Cache-Control"); cc != "public, max-age=300" {
			t.Errorf("coordinator rate-card Cache-Control=%q want public, max-age=300 (the documented client TTL)", cc)
		}
		p.restartGateway()
		if st, _, body := p.gatewayGET("/v1/rate-card"); st != http.StatusOK || !bytes.Equal(body, cardBRaw) {
			t.Errorf("gateway after restart serves sha=%s want card B", sha256HexBytes(body))
		}
	})

	t.Run("J6_reversal_B_to_A", func(t *testing.T) {
		before := p.applied()
		snapsBeforeRev := len(p.snapshots())
		yamlRev := p.spliceYAML(p.coordYAML, rateCardBlock(p.cardA))
		p.installPricing(yamlRev, p.cardARaw)
		ok, logs := p.sighup(rejectMarkersAll...)
		if !ok {
			t.Fatalf("J6 reversal rejected:\n%s", strings.Join(logs, "\n"))
		}
		rec := p.applied()
		if rec.BillingSnapshotID <= before.BillingSnapshotID {
			t.Errorf("reversal did not insert a new snapshot: %d -> %d", before.BillingSnapshotID, rec.BillingSnapshotID)
		}
		if rec.RateTableSHA256 != boot.RateTableSHA256 {
			t.Errorf("reversal rate_table_sha256=%s want the boot (A) digest %s", rec.RateTableSHA256, boot.RateTableSHA256)
		}
		p.assertAppliedTable(rec, tableA, "A")
		p.assertO6(p.cardARaw)
		p.assertO5()
		snaps := p.snapshots()
		if got := len(snaps) - snapsBeforeRev; got != 1 {
			t.Errorf("O3: reversal added %d snapshot rows, want 1", got)
		}
		// Rule 7: earlier snapshot rows untouched (boot A, then B, then A).
		if len(snaps) < 3 || !snaps[0].Table.equal(tableA) || !snaps[len(snaps)-2].Table.equal(tableB) || !snaps[len(snaps)-1].Table.equal(tableA) {
			t.Errorf("snapshot history not A..B,A: %d rows", len(snaps))
		}
		idsA2 := p.paidRequests(p.apiKey, 2)
		for _, id := range append(append([]string{}, idsA...), idsA2...) {
			for _, e := range p.creditRatesFor(id) {
				if e.Prompt != tableA[pricingLlamaKey].Prompt || e.Completion != tableA[pricingLlamaKey].Completion {
					t.Errorf("A-priced request %s has %+v", id, e)
				}
			}
		}
		p.assertO1(reviewed)
		st, _, body := p.gatewayGET("/v1/rate-card")
		if st != http.StatusOK || (!bytes.Equal(body, cardBRaw) && !bytes.Equal(body, p.cardARaw)) {
			t.Errorf("gateway served an unknown card after reversal")
		}
	})
}

// J3 parity reject, J4 feed-load failure, J5 billing txn failure: every
// rejected reload keeps the prior table, card and record, and writes no
// snapshot row.
func TestPricingLaneJ3J4J5RejectedReloadsKeepPriorEconomics(t *testing.T) {
	p := newPricingLane(t, pricingLaneOpts{})
	tableA := p.cardA.table()
	cardB, cardBRaw := p.cardB()
	reviewed := map[string]pricingTable{"A": tableA, "B": cardB.table()}
	yamlA, err := os.ReadFile(p.coordYAML)
	if err != nil {
		t.Fatal(err)
	}
	yamlB := p.spliceYAML(p.coordYAML, rateCardBlock(cardB))
	p.paidRequests(p.apiKey, 2)

	assertKept := func(t *testing.T, what string, before appliedRecord, snaps int) {
		t.Helper()
		after := p.applied()
		if !bytes.Equal(after.raw, before.raw) {
			t.Errorf("%s rewrote the applied-config record:\nbefore=%s\nafter=%s", what, before.raw, after.raw)
		}
		if got := len(p.snapshots()) - snaps; got != 0 {
			t.Errorf("%s: O3 wrote %d snapshot rows, want 0", what, got)
		}
		st, _, served := p.coordGET("/v1/rate-card")
		if st != http.StatusOK || !bytes.Equal(served, p.cardARaw) {
			t.Errorf("%s: coordinator no longer serves card A (sha %s)", what, sha256HexBytes(served))
		}
		ids := p.paidRequests(p.apiKey, 2)
		for _, id := range ids {
			for _, e := range p.creditRatesFor(id) {
				if e.Prompt != tableA[pricingLlamaKey].Prompt || e.Completion != tableA[pricingLlamaKey].Completion {
					t.Errorf("%s: request %s priced %+v, want A", what, id, e)
				}
			}
		}
		p.assertO1(reviewed)
	}
	restoreA := func(t *testing.T) {
		t.Helper()
		p.installPricing(yamlA, p.cardARaw)
		_ = os.Chmod(filepath.Join(p.currentDir, "rate-card.json"), 0o600)
	}

	t.Run("J3_parity_reject_yamlB_cardA", func(t *testing.T) {
		before, snaps := p.applied(), len(p.snapshots())
		writeFileAtomic(t, p.coordYAML, yamlB) // card stays A
		ok, logs := p.sighup(rejectMarkersAll...)
		if ok {
			t.Fatalf("yaml B + card A reload was accepted")
		}
		if !containsLine(logs, "autotune runtime economics reload rejected") {
			t.Errorf("rejection was not the parity rejection:\n%s", strings.Join(logs, "\n"))
		}
		assertKept(t, "J3", before, snaps)
		restoreA(t)
	})

	t.Run("J3b_parity_reject_yamlA_cardB", func(t *testing.T) {
		before, snaps := p.applied(), len(p.snapshots())
		p.keys.writeSignedAtomic(t, filepath.Join(p.currentDir, "rate-card.json"), cardBRaw) // yaml stays A
		ok, logs := p.sighup(rejectMarkersAll...)
		if ok {
			t.Fatalf("yaml A + card B reload was accepted")
		}
		if !containsLine(logs, "autotune runtime economics reload rejected") {
			t.Errorf("rejection was not the parity rejection:\n%s", strings.Join(logs, "\n"))
		}
		assertKept(t, "J3b", before, snaps)
		restoreA(t)
	})

	t.Run("J4_feed_load_failure_unreadable_cardB", func(t *testing.T) {
		before, snaps := p.applied(), len(p.snapshots())
		p.installPricing(yamlB, cardBRaw)
		cardPath := filepath.Join(p.currentDir, "rate-card.json")
		if err := os.Chmod(cardPath, 0o000); err != nil {
			t.Fatal(err)
		}
		if f, err := os.Open(cardPath); err == nil {
			f.Close()
			t.Fatalf("chmod 000 did not make the card unreadable (running as root?)")
		}
		ok, logs := p.sighup(rejectMarkersAll...)
		if ok {
			t.Fatalf("reload with unreadable card B was accepted")
		}
		if !containsLine(logs, "autotune feed reload rejected; keeping prior catalog and served feeds") {
			t.Errorf("feed load failure not logged:\n%s", strings.Join(logs, "\n"))
		}
		if !containsLine(logs, "autotune runtime economics reload rejected") {
			t.Errorf("reload did not continue on card A into the parity rejection:\n%s", strings.Join(logs, "\n"))
		}
		assertKept(t, "J4", before, snaps)
		restoreA(t)
	})

	t.Run("J5_billing_txn_failure_sqlite_write_lock", func(t *testing.T) {
		// Hold the coordinator DB's write lock (BEGIN IMMEDIATE) longer than
		// the coordinator's busy_timeout (5000 ms, requestlog/store.go) so the
		// reload's BEGIN IMMEDIATE in ReloadBillingConfigV05 fails SQLITE_BUSY.
		p.installPricing(yamlB, cardBRaw) // a valid, parity-matching pair
		before, snaps := p.applied(), len(p.snapshots())
		db := p.openCoordDB()
		defer db.Close()
		conn, err := db.Conn(t.Context())
		if err != nil {
			t.Fatal(err)
		}
		if _, err := conn.ExecContext(t.Context(), "BEGIN IMMEDIATE"); err != nil {
			t.Fatalf("take write lock: %v", err)
		}
		released := false
		release := func() {
			if !released {
				_, _ = conn.ExecContext(t.Context(), "ROLLBACK")
				_ = conn.Close()
				released = true
			}
		}
		defer release()
		start := time.Now()
		ok, logs := p.sighup(rejectMarkersAll...)
		release()
		t.Logf("reload outcome after %s under the write lock", time.Since(start))
		if ok {
			t.Fatalf("reload succeeded while the billing DB write lock was held")
		}
		if !containsLine(logs, "billing config reload rejected") {
			t.Errorf("billing txn failure not logged:\n%s", strings.Join(logs, "\n"))
		}
		// The table/card must still be A even though yaml B + card B are on disk.
		time.Sleep(500 * time.Millisecond)
		after := p.applied()
		if !bytes.Equal(after.raw, before.raw) {
			t.Errorf("J5 rewrote the applied-config record:\nbefore=%s\nafter=%s", before.raw, after.raw)
		}
		if got := len(p.snapshots()) - snaps; got != 0 {
			t.Errorf("J5: O3 wrote %d snapshot rows, want 0", got)
		}
		if st, _, served := p.coordGET("/v1/rate-card"); st != http.StatusOK || !bytes.Equal(served, p.cardARaw) {
			t.Errorf("J5: coordinator serves card sha %s after a failed billing txn, want A", sha256HexBytes(served))
		}
		ids := p.paidRequests(p.apiKey, 2)
		for _, id := range ids {
			for _, e := range p.creditRatesFor(id) {
				if e.Prompt != tableA[pricingLlamaKey].Prompt {
					t.Errorf("J5: request %s priced %+v after failed reload, want A", id, e)
				}
			}
		}
		p.assertO1(reviewed)

		// Retrying the same on-disk pair once the lock is gone applies B.
		ok, logs = p.sighup(rejectMarkersAll...)
		if !ok {
			t.Fatalf("retry after the failed billing txn rejected:\n%s", strings.Join(logs, "\n"))
		}
		p.assertAppliedTable(p.applied(), cardB.table(), "B")
		p.assertO6(cardBRaw)
		if got := len(p.snapshots()) - snaps; got != 1 {
			t.Errorf("J5 retry: O3 wrote %d snapshot rows, want 1", got)
		}
	})
}

func containsLine(lines []string, sub string) bool {
	for _, l := range lines {
		if strings.Contains(l, sub) {
			return true
		}
	}
	return false
}
