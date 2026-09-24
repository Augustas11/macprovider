package integration

import (
	"context"
	"database/sql"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// J2 — load across the switch: a -race coordinator, 20 concurrent buyer
// streams, the O2 sampler and a gateway-style rate-card pair prober, all
// running while J1's SIGHUP moves the table A -> B.
func TestPricingLaneJ2LoadAcrossSwitchRace(t *testing.T) {
	p := newPricingLane(t, pricingLaneOpts{providerCount: 11, raceCoordinator: true, gatewayConcurrency: 64})
	tableA := p.cardA.table()
	cardB, cardBRaw := p.cardB()
	tableB := cardB.table()
	reviewed := map[string]pricingTable{"A": tableA, "B": tableB}
	cardByHash := map[string]string{sha256HexBytes(p.cardARaw): "A", sha256HexBytes(cardBRaw): "B"}
	priceLabel := func(e pricingEntry) string {
		switch {
		case e.Prompt == tableA[pricingLlamaKey].Prompt && e.Completion == tableA[pricingLlamaKey].Completion:
			return "A"
		case e.Prompt == tableB[pricingLlamaKey].Prompt && e.Completion == tableB[pricingLlamaKey].Completion:
			return "B"
		}
		return "?"
	}
	yamlB := p.spliceYAML(p.coordYAML, rateCardBlock(cardB))
	p.paidRequests(p.apiKey, 2) // warm the path

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	client := &http.Client{Timeout: 60 * time.Second}

	// 20 concurrent buyer streams.
	type result struct {
		status int
		err    string
		at     time.Time
	}
	var (
		resMu   sync.Mutex
		results []result
		wg      sync.WaitGroup
	)
	for w := 0; w < 20; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for i := 0; ctx.Err() == nil; i++ {
				body := fmt.Sprintf(`{"model":%q,"max_tokens":32,"stream":true,"messages":[{"role":"user","content":"load %d/%d"}]}`, settlementFixtureModelID, w, i)
				req, _ := http.NewRequest(http.MethodPost, p.gatewayBaseURL+"/v1/chat/completions", strings.NewReader(body))
				req.Header.Set("Authorization", "Bearer "+p.apiKey)
				req.Header.Set("Content-Type", "application/json")
				req.Header.Set("X-Request-ID", newUUID(t))
				resp, err := client.Do(req)
				r := result{at: time.Now()}
				if err != nil {
					r.err = err.Error()
				} else {
					out, _ := io.ReadAll(resp.Body)
					resp.Body.Close()
					r.status = resp.StatusCode
					if resp.StatusCode != http.StatusOK || !strings.Contains(string(out), "[DONE]") {
						r.err = fmt.Sprintf("status=%d body=%.300s", resp.StatusCode, out)
					}
				}
				resMu.Lock()
				results = append(results, r)
				resMu.Unlock()
			}
		}(w)
	}

	// O2 sampler: card read -> priced request -> ledger row -> card read.
	type sample struct {
		before, after, price string
		requestID            string
	}
	var (
		samples   []sample
		samplesMu sync.Mutex
		samplerWG sync.WaitGroup
		samplerEr atomic.Value
	)
	for sg := 0; sg < 4; sg++ {
		samplerWG.Add(1)
		go func() {
			defer samplerWG.Done()
			db, err := sql.Open("sqlite", "file:"+p.coordinatorDB+"?_pragma=busy_timeout(10000)")
			if err != nil {
				samplerEr.Store(err.Error())
				return
			}
			defer db.Close()
			readCard := func() string {
				status, b, err := feedGET(client, p.coordBuyerURL+"/v1/rate-card")
				if err != nil {
					return "err:" + err.Error()
				}
				if status != http.StatusOK {
					return fmt.Sprintf("status:%d", status)
				}
				if l, ok := cardByHash[sha256HexBytes(b)]; ok {
					return l
				}
				return "?"
			}
			for ctx.Err() == nil {
				before := readCard()
				ext := newUUID(t)
				body := fmt.Sprintf(`{"model":%q,"max_tokens":32,"messages":[{"role":"user","content":"sampler %s"}]}`, settlementFixtureModelID, ext)
				req, _ := http.NewRequest(http.MethodPost, p.gatewayBaseURL+"/v1/chat/completions", strings.NewReader(body))
				req.Header.Set("Authorization", "Bearer "+p.apiKey)
				req.Header.Set("Content-Type", "application/json")
				req.Header.Set("X-Request-ID", ext)
				resp, err := client.Do(req)
				if err != nil {
					samplerEr.Store("sampler request: " + err.Error())
					return
				}
				io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
				if resp.StatusCode != http.StatusOK {
					samplerEr.Store(fmt.Sprintf("sampler request status %d", resp.StatusCode))
					return
				}
				// "recorded": wait for the ledger row before the second read.
				var rid string
				var prompt, completion int64
				deadline := time.Now().Add(15 * time.Second)
				for {
					err := db.QueryRow(`SELECT c.request_id, c.prompt_rate_per_mtok, c.completion_rate_per_mtok
  FROM request_log r JOIN ledger_request_credits c ON c.request_id = r.request_id
 WHERE r.external_request_id = ? OR r.request_id = ? LIMIT 1`, ext, ext).Scan(&rid, &prompt, &completion)
					if err == nil {
						break
					}
					if time.Now().After(deadline) {
						samplerEr.Store("sampler: no ledger row for " + ext)
						return
					}
					time.Sleep(5 * time.Millisecond)
				}
				after := readCard()
				samplesMu.Lock()
				samples = append(samples, sample{before: before, after: after, price: priceLabel(pricingEntry{Prompt: prompt, Completion: completion}), requestID: rid})
				samplesMu.Unlock()
				time.Sleep(50 * time.Millisecond)
			}
		}()
	}

	// Gateway-style pair prober: phase5-gateway proxyRateCardPair fetches
	// /v1/rate-card and /v1/rate-card.sig as two concurrent upstream GETs and
	// caches the pair for 300 s without verifying it. Mirror that exactly.
	var pairs, mismatched atomic.Int64
	var mismatchExample atomic.Value
	for g := 0; g < 4; g++ {
		samplerWG.Add(1)
		go func() {
			defer samplerWG.Done()
			for ctx.Err() == nil {
				var body, sig []byte
				var inner sync.WaitGroup
				inner.Add(2)
				go func() {
					defer inner.Done()
					if st, b, err := feedGET(client, p.coordBuyerURL+"/v1/rate-card"); err == nil && st == http.StatusOK {
						body = b
					}
				}()
				go func() {
					defer inner.Done()
					if st, b, err := feedGET(client, p.coordBuyerURL+"/v1/rate-card.sig"); err == nil && st == http.StatusOK {
						sig = b
					}
				}()
				inner.Wait()
				time.Sleep(2 * time.Millisecond)
				if len(body) == 0 || len(sig) == 0 {
					continue
				}
				pairs.Add(1)
				if !p.keys.verify(body, sig) {
					mismatched.Add(1)
					mismatchExample.Store(fmt.Sprintf("body card %s with a signature that does not verify it", cardByHash[sha256HexBytes(body)]))
				}
			}
		}()
	}

	time.Sleep(6 * time.Second)
	p.installPricing(yamlB, cardBRaw)
	hupAt := time.Now()
	ok, logs := p.sighup(rejectMarkersAll...)
	hupDone := time.Now()
	if !ok {
		t.Errorf("J2 reload under load rejected:\n%s", strings.Join(logs, "\n"))
	}
	time.Sleep(6 * time.Second)
	cancel()
	wg.Wait()
	samplerWG.Wait()

	if v := samplerEr.Load(); v != nil {
		t.Errorf("O2 sampler aborted: %v", v)
	}
	// Request errors.
	var failed []string
	for _, r := range results {
		if r.err != "" {
			failed = append(failed, fmt.Sprintf("[t%+.2fs rel. SIGHUP, reload took %s] %s", r.at.Sub(hupAt).Seconds(), hupDone.Sub(hupAt), r.err))
		}
	}
	t.Logf("J2: %d buyer streams, %d failed; %d sampler samples; %d gateway-style pairs, %d unverifiable", len(results), len(failed), len(samples), pairs.Load(), mismatched.Load())
	if len(failed) > 0 {
		t.Errorf("J2: %d/%d buyer streams failed across the reload:\n%s", len(failed), len(results), strings.Join(failed, "\n"))
	}
	// O2.
	sawSwitch := false
	for _, s := range samples {
		if s.before != s.after {
			sawSwitch = true
		}
		if s.price == "?" || s.before == "?" || s.after == "?" {
			t.Errorf("O2: unclassifiable sample %+v", s)
			continue
		}
		if s.before == s.after && s.price != s.before {
			t.Errorf("O2: request %s priced at %s while the coordinator served card %s before and after it", s.requestID, s.price, s.before)
		}
		if s.before == "B" && s.price == "A" {
			t.Errorf("O2: request %s priced at A after the coordinator already served card B", s.requestID)
		}
		if s.after == "A" && s.price == "B" {
			t.Errorf("O2: request %s priced at B while the coordinator still served card A after it was recorded", s.requestID)
		}
	}
	t.Logf("O2: sampler straddled the switch: %v", sawSwitch)
	if len(samples) < 10 {
		t.Errorf("O2: only %d samples", len(samples))
	}
	// O1 over every row the load produced.
	labels := p.assertO1(reviewed)
	counts := map[string]int{}
	for _, l := range labels {
		counts[l]++
	}
	t.Logf("O1: ledger rows by table: %v", counts)
	if counts["A"] == 0 || counts["B"] == 0 {
		t.Errorf("O1: expected rows priced at both A and B, got %v", counts)
	}
	p.assertO6(cardBRaw)
	p.assertO5()
	// -race: the coordinator reports races on stderr (GORACE halt_on_error=0).
	for _, line := range p.coordLogBuf.snapshot() {
		if strings.Contains(line, "WARNING: DATA RACE") {
			t.Errorf("race detector fired in the coordinator: see coord.err log")
			break
		}
	}
	// Gateway pair integrity: a straddling pair is exactly what the gateway
	// would cache for 300 s (see TestPricingLaneGatewayCachesUnverifiablePair).
	if n := mismatched.Load(); n > 0 {
		t.Logf("gateway-style pair fetch straddled the switch %d time(s): %v", n, mismatchExample.Load())
	}
}

var feedClientSeq atomic.Int64

// feedGET reads a public feed with a distinct X-Forwarded-For so the
// coordinator's per-client feed limiter (10 rps, buyer/server.go
// allowReceiptKeys; loopback is a trusted proxy) does not throttle the
// probes into 429s.
func feedGET(client *http.Client, url string) (int, []byte, error) {
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return 0, nil, err
	}
	n := feedClientSeq.Add(1)
	req.Header.Set("X-Forwarded-For", fmt.Sprintf("198.18.%d.%d", (n/250)%250, n%250+1))
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	return resp.StatusCode, b, err
}
