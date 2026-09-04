package buyer

import (
	"context"
	"fmt"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

func byomAdmissionCandidate(p pool.Provider) bool {
	return strings.TrimSpace(p.ModelAdmissionCandidateID) != "" ||
		strings.TrimSpace(p.ModelAdmissionServedModelRef) != "" ||
		strings.TrimSpace(p.ModelAdmissionCatalogModelKey) != ""
}

func (s *Server) byomDefaultPaidRoutingEligible(p pool.Provider) bool {
	marked := byomAdmissionCandidate(p)
	if s == nil || s.modelAdmissionStore == nil {
		return !marked
	}
	ctx, cancel := context.WithTimeout(context.Background(), requestLogWriteTimeout)
	defer cancel()
	reportedHash := strings.TrimSpace(p.ModelHash)
	material, ok := tier2.SnapshotMaterial(p.ModelID, reportedHash)
	if !ok {
		_, found, err := s.modelAdmissionStore.LatestModelAdmissionRouteStatus(
			ctx,
			p.ProviderID,
			"",
			"",
		)
		if err != nil || found {
			return false
		}
		return !marked
	}
	_, found, eligible := s.byomRouteSnapshotBinding(ctx, p, material)
	if found {
		return eligible
	}
	return !marked
}

func (s *Server) byomRouteSnapshotBinding(ctx context.Context, p pool.Provider, material tier2.RouteSnapshotMaterial) (providerws.ModelAdmissionSettlementBinding, bool, bool) {
	if s == nil || s.modelAdmissionStore == nil {
		return providerws.ModelAdmissionSettlementBinding{}, false, false
	}
	if ctx == nil {
		ctx = context.Background()
	}
	marked := byomAdmissionCandidate(p)
	candidateID := strings.TrimSpace(p.ModelAdmissionCandidateID)
	servedModelRef := strings.TrimSpace(p.ModelAdmissionServedModelRef)
	if servedModelRef == "" {
		servedModelRef = strings.TrimSpace(p.ModelID)
	}
	catalogModelKey := strings.ToLower(strings.TrimSpace(p.ModelAdmissionCatalogModelKey))
	if catalogModelKey == "" {
		catalogModelKey = strings.ToLower(strings.TrimSpace(material.CatalogModelKey))
	}

	var (
		event providerws.ModelAdmissionEvent
		found bool
		err   error
	)
	if candidateID != "" {
		event, found, err = s.modelAdmissionStore.LatestModelAdmissionStatus(ctx, p.ProviderID, candidateID)
	} else if marked {
		event, found, err = s.modelAdmissionStore.LatestModelAdmissionRouteStatus(ctx, p.ProviderID, servedModelRef, catalogModelKey)
	} else {
		event, found, err = s.modelAdmissionStore.LatestModelAdmissionRouteStatus(ctx, p.ProviderID, servedModelRef, catalogModelKey)
		if err == nil && !found {
			event, found, err = s.modelAdmissionStore.LatestModelAdmissionRouteStatus(ctx, p.ProviderID, "", catalogModelKey)
		}
		if err == nil && !found {
			_, providerFound, providerErr := s.modelAdmissionStore.LatestModelAdmissionRouteStatus(ctx, p.ProviderID, "", "")
			if providerErr != nil || providerFound {
				return providerws.ModelAdmissionSettlementBinding{}, true, false
			}
		}
	}
	if err != nil || !found {
		if err != nil {
			return providerws.ModelAdmissionSettlementBinding{}, true, false
		}
		return providerws.ModelAdmissionSettlementBinding{}, false, false
	}
	if marked {
		if candidateID != "" && event.CandidateID != candidateID {
			return providerws.ModelAdmissionSettlementBinding{}, true, false
		}
		if explicitServed := strings.TrimSpace(p.ModelAdmissionServedModelRef); explicitServed != "" && event.ServedModelRef != explicitServed {
			return providerws.ModelAdmissionSettlementBinding{}, true, false
		}
		if explicitCatalogKey := strings.ToLower(strings.TrimSpace(p.ModelAdmissionCatalogModelKey)); explicitCatalogKey != "" && event.CatalogModelKey != explicitCatalogKey {
			return providerws.ModelAdmissionSettlementBinding{}, true, false
		}
	}
	if !s.byomSettlementPrereqsReady(p, material) {
		return providerws.ModelAdmissionSettlementBinding{}, true, false
	}
	binding, ok := providerws.ModelAdmissionSettlementBindingForRouteSnapshot(event, providerws.ModelAdmissionSettlementPredicate{
		ProviderID:                        p.ProviderID,
		CandidateID:                       event.CandidateID,
		ServedModelRef:                    event.ServedModelRef,
		CatalogModelKey:                   material.CatalogModelKey,
		DiscoveryDigestSHA256:             event.DiscoveryDigestSHA256,
		EvaluationDigestSHA256:            event.EvaluationDigestSHA256,
		CatalogID:                         material.CatalogID,
		CatalogBodyDigest:                 material.CatalogBodyDigest,
		CatalogSignatureKeyID:             material.CatalogSignatureKeyID,
		CatalogSignaturePubkeyFingerprint: material.CatalogSignaturePubkeyFingerprint,
		ExpectedCatalogModelHash:          material.ExpectedModelHash,
		ExpectedCatalogModelHashAlgorithm: material.ExpectedModelHashAlgorithm,
	})
	return binding, true, ok
}

func (s *Server) byomSettlementPrereqsReady(p pool.Provider, material tier2.RouteSnapshotMaterial) bool {
	if s == nil || !s.settlementEnforceMode() {
		return false
	}
	reportedHash := strings.TrimSpace(p.ModelHash)
	expectedHash := strings.TrimSpace(p.ExpectedModelHash)
	return validProviderReceiptPubkey(p) &&
		p.ModelHashAlgorithm == modelidentity.SnapshotManifestV1 &&
		isLowerHex64(reportedHash) &&
		isLowerHex64(expectedHash) &&
		reportedHash == expectedHash &&
		material.HashStatus == pool.HashStatusVerified &&
		material.ExpectedModelHash == expectedHash
}

func validProviderReceiptPubkey(p pool.Provider) bool {
	_, err := billing.ReceiptKeyID(p.ReceiptPubkey)
	return err == nil
}

func (s *Server) requireBYOMRouteSnapshotBinding(ctx context.Context, p pool.Provider, material tier2.RouteSnapshotMaterial) (providerws.ModelAdmissionSettlementBinding, error) {
	binding, found, eligible := s.byomRouteSnapshotBinding(ctx, p, material)
	if !found && !byomAdmissionCandidate(p) {
		return providerws.ModelAdmissionSettlementBinding{}, nil
	}
	if !eligible {
		return providerws.ModelAdmissionSettlementBinding{}, fmt.Errorf("BYOM model admission is not settlement capable")
	}
	return binding, nil
}

func applyBYOMRouteSnapshotBinding(snapshot *billing.RouteSnapshot, binding providerws.ModelAdmissionSettlementBinding) {
	if snapshot == nil || binding.CandidateID == "" {
		return
	}
	snapshot.ModelAdmissionCandidateID = binding.CandidateID
	snapshot.ModelAdmissionCoordinatorEventID = binding.CoordinatorEventID
	snapshot.ModelAdmissionServedModelRef = binding.ServedModelRef
	snapshot.ModelAdmissionCatalogModelKey = binding.CatalogModelKey
	snapshot.ModelAdmissionDiscoveryDigestSHA256 = binding.DiscoveryDigestSHA256
	snapshot.ModelAdmissionEvaluationDigestSHA256 = binding.EvaluationDigestSHA256
}
