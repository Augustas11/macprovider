package routing

import (
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// The perf store folds model ids as the pool does (NFC, then lowercase), so
// canonically equivalent spellings share one record.
func TestPerfKeyFoldsLikeThePool(t *testing.T) {
	composed, decomposed := "Café-7B", "CAFÉ-7b"
	if newPerfKey("p1", composed) != newPerfKey("p1", decomposed) {
		t.Fatalf("perf keys differ: %+v %+v", newPerfKey("p1", composed), newPerfKey("p1", decomposed))
	}
	if newPerfKey("p1", composed).model != pool.ModelKey(decomposed) {
		t.Fatal("perf key is not pool.ModelKey")
	}
}
