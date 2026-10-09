package trustpool_test

import (
	"context"
	"encoding/json"
	"net/http"
	"reflect"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

func TestSelfServeEarningsReadsOwnedProviderCreditsOnOwnPools(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	var queries []trustpool.CreatorEarningsQuery
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:                   store,
		Registry:                trustpool.NewRegistry(),
		GatewayServiceToken:     selfServeServiceToken,
		CreatorProviderAdmitted: admittedProviderIDs(selfServeOwnedMac),
		OwnedProviderIDs: func(_ context.Context, githubUserID int64) ([]string, error) {
			if githubUserID == selfServeGitHubID {
				return []string{selfServeOwnedMac}, nil
			}
			return nil, nil
		},
		CreatorEarnings: func(_ context.Context, q trustpool.CreatorEarningsQuery) ([]trustpool.CreatorPoolEarnings, error) {
			queries = append(queries, q)
			out := make([]trustpool.CreatorPoolEarnings, 0, len(q.PoolIDs))
			for _, id := range q.PoolIDs {
				out = append(out, trustpool.CreatorPoolEarnings{PoolID: id, PayableRequests: 2, ProviderCredits: 90})
			}
			return out, nil
		},
	})
	f := selfServeFixture{handler: handler, store: store}
	_, root := selfServeBuildPool(t, f)

	type earningsDoc struct {
		Earnings struct {
			CreatorAccountID     string                          `json:"creator_account_id"`
			OwnedProviderCount   int                             `json:"owned_provider_count"`
			SplitExecutionStatus string                          `json:"split_execution_status"`
			Pools                []trustpool.CreatorPoolEarnings `json:"pools"`
			TotalProviderCredits int64                           `json:"total_provider_credits"`
			From                 *string                         `json:"from"`
			To                   *string                         `json:"to"`
		} `json:"earnings"`
	}
	read := func(p selfServePrincipal, query string, want int) earningsDoc {
		t.Helper()
		rec := selfServeDo(t, handler, p, http.MethodGet, "earnings"+query, nil, "")
		selfServeExpect(t, rec, want, "earnings"+query)
		var doc earningsDoc
		if want == http.StatusOK {
			if err := json.Unmarshal(rec.Body.Bytes(), &doc); err != nil {
				t.Fatalf("decode earnings: %v", err)
			}
		}
		return doc
	}

	all := read(defaultSelfServePrincipal, "", http.StatusOK)
	if all.Earnings.CreatorAccountID != selfServeCreator || all.Earnings.OwnedProviderCount != 1 || all.Earnings.SplitExecutionStatus != "declared_not_executed" ||
		len(all.Earnings.Pools) != 1 || all.Earnings.Pools[0].PoolID != root.poolID || all.Earnings.TotalProviderCredits != 90 || all.Earnings.From != nil {
		t.Fatalf("earnings = %+v", all.Earnings)
	}
	if len(queries) != 1 || !reflect.DeepEqual(queries[0].ProviderIDs, []string{selfServeOwnedMac}) || !reflect.DeepEqual(queries[0].PoolIDs, []string{root.poolID}) || !queries[0].From.IsZero() {
		t.Fatalf("earnings query = %+v", queries)
	}

	ranged := read(defaultSelfServePrincipal, "?pool_id="+root.poolID+"&from=2026-10-01&to=2026-10-08", http.StatusOK)
	if ranged.Earnings.From == nil || *ranged.Earnings.From != "2026-10-01" || *ranged.Earnings.To != "2026-10-08" {
		t.Fatalf("ranged earnings = %+v", ranged.Earnings)
	}
	last := queries[len(queries)-1]
	if !last.From.Equal(time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)) || !last.To.Equal(time.Date(2026, 10, 8, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("ranged query = %+v", last)
	}
	for _, bad := range []string{"?from=2026-10-01", "?from=2026-10-08&to=2026-10-01", "?from=2026-01-01&to=2026-03-01", "?from=x&to=y"} {
		read(defaultSelfServePrincipal, bad, http.StatusBadRequest)
	}

	// A foreign or unknown pool is not_found; a stranger sees no pools.
	read(defaultSelfServePrincipal, "?pool_id=AAAAAAAAAAAAAAAAAAAAAA", http.StatusNotFound)
	stranger := selfServePrincipal{account: "acct_stranger", credential: "key_stranger", github: selfServeGitHubID}
	read(stranger, "?pool_id="+root.poolID, http.StatusNotFound)
	if doc := read(stranger, "", http.StatusOK); len(doc.Earnings.Pools) != 0 || doc.Earnings.TotalProviderCredits != 0 {
		t.Fatalf("stranger earnings = %+v", doc.Earnings)
	}
	// Without a GitHub identity the creator owns no provider and nothing is read.
	before := len(queries)
	noGitHub := read(selfServePrincipal{account: selfServeCreator, credential: selfServeKeyID}, "", http.StatusOK)
	if noGitHub.Earnings.OwnedProviderCount != 0 || noGitHub.Earnings.TotalProviderCredits != 0 || len(queries) != before {
		t.Fatalf("earnings without GitHub identity = %+v (queries %d -> %d)", noGitHub.Earnings, before, len(queries))
	}
	selfServeExpect(t, selfServeDo(t, handler, defaultSelfServePrincipal, http.MethodPost, "earnings", nil, ""), http.StatusMethodNotAllowed, "POST earnings")
}
