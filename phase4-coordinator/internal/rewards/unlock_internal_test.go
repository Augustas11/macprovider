package rewards

import "testing"

func TestDistinctUnlockPairRequiresDistinctCriteria(t *testing.T) {
	if distinctUnlockPair([]string{CriterionE2WalletEconomic}, []string{CriterionWalletBalance72h}) {
		t.Fatal("wallet-only pair must not unlock")
	}
	if !distinctUnlockPair([]string{CriterionE1Receipts}, []string{CriterionAppAttest}) {
		t.Fatal("E1 + app attest should unlock")
	}
}

func TestCriteriaOverlap(t *testing.T) {
	if !criteriaOverlap(CriterionE1Receipts, CriterionE1Receipts) {
		t.Fatal("same criterion must overlap")
	}
	if !criteriaOverlap(CriterionE2WalletEconomic, CriterionWalletBalance72h) {
		t.Fatal("E2 and A3 must overlap")
	}
}

func TestSatisfiedCriteriaE1CountsBothSlots(t *testing.T) {
	econ, addl := satisfiedCriteria(satisfiedInput{ReceiptCount: 100})
	if len(econ) != 1 || len(addl) != 1 {
		t.Fatalf("econ=%v addl=%v", econ, addl)
	}
	if distinctUnlockPair(econ, addl) {
		t.Fatal("E1 alone in both slots must not unlock")
	}
}
