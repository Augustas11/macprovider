package ws

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
)

type operatorClient struct {
	t *testing.T
	s *Server
}

func (c operatorClient) do(method, path, token string, body any) (int, map[string]any) {
	c.t.Helper()
	var reader *bytes.Reader
	if body == nil {
		reader = bytes.NewReader(nil)
	} else {
		raw, err := json.Marshal(body)
		if err != nil {
			c.t.Fatal(err)
		}
		reader = bytes.NewReader(raw)
	}
	req := httptest.NewRequest(method, path, reader)
	req.RemoteAddr = "127.0.0.1:4242"
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rr := httptest.NewRecorder()
	switch {
	case strings.HasPrefix(path, "/admin/model-admission/decisions/"):
		c.s.handleAdminModelAdmissionApprove(rr, req)
	case strings.HasPrefix(path, "/admin/model-admission/decisions"):
		c.s.handleAdminModelAdmissionDecisions(rr, req)
	default:
		c.s.handleAdminModelAdmissionOffers(rr, req)
	}
	var parsed map[string]any
	if rr.Body.Len() > 0 {
		_ = json.Unmarshal(rr.Body.Bytes(), &parsed)
	}
	return rr.Code, parsed
}

func errorCode(body map[string]any) string {
	if body == nil {
		return ""
	}
	if inner, ok := body["error"].(map[string]any); ok {
		code, _ := inner["code"].(string)
		return code
	}
	return ""
}

func decisionRequest(providerID, candidateID, next, reason, head, key string) map[string]any {
	return map[string]any{
		"schema": "model_admission_decision_request.v1", "provider_id": providerID, "candidate_id": candidateID,
		"next_state": next, "reason_code": reason, "expected_coordinator_event_id": head, "idempotency_key": key,
	}
}

func approveRequest(providerID, candidateID, pendingID, head, key string) map[string]any {
	return map[string]any{
		"schema": "model_admission_decision_approve_request.v1", "provider_id": providerID, "candidate_id": candidateID,
		"pending_decision_id": pendingID, "expected_coordinator_event_id": head, "idempotency_key": key,
	}
}

// SPEC-047-R001 v0.1.5 / R008: per-actor operator authentication, the closed
// request grammars, the decision precedence (idempotency → stale_head →
// invalid_transition → precondition codes), replay after the head advanced,
// dual control on settlement_capable (pending record, request replay,
// same-actor refusal, path/body and bound-field disagreement, approval
// replay, distinct-key double approval), the bound member, and the listing.
func TestModelAdmissionOperatorDecisionPath(t *testing.T) {
	f := newBindingFixture(t)
	s := f.server
	s.cfg.Auth.OperatorKey = "shared-secret"
	s.cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret"}
	s.newUUID = uuid.NewString
	c := operatorClient{t: t, s: s}
	const decisions = "/admin/model-admission/decisions"

	f.registerSession(t, "p1", "s1", "model-a", true)
	offer := f.offer(t, "p1", "a", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash})
	head := offer.CoordinatorEventID
	other := strings.Repeat("0", 64)

	// Authentication: no bearer, the shared operator_key, and a wrong key
	// are all `invalid_operator_token`; no state is touched.
	for _, token := range []string{"", "shared-secret", "wrong"} {
		if code, body := c.do(http.MethodPost, decisions, token, decisionRequest("p1", offer.CandidateID, "catalog_priced", "operator_ok", head, "k1")); code != http.StatusUnauthorized || errorCode(body) != "invalid_operator_token" {
			t.Fatalf("token %q: %d %v", token, code, body)
		}
	}
	// Closed grammars → invalid_request.
	bad := func(mutate func(map[string]any)) map[string]any {
		body := decisionRequest("p1", offer.CandidateID, "catalog_priced", "operator_ok", head, "k1")
		mutate(body)
		return body
	}
	for name, body := range map[string]map[string]any{
		"unknown field":         bad(func(m map[string]any) { m["extra"] = 1 }),
		"bad state":             bad(func(m map[string]any) { m["next_state"] = "sandbox_probe_only" }),
		"drift reason":          bad(func(m map[string]any) { m["reason_code"] = "runtime_identity_drift" }),
		"withdrawal reason":     bad(func(m map[string]any) { m["reason_code"] = "provider_requested" }),
		"probe reason":          bad(func(m map[string]any) { m["reason_code"] = "synthetic_probe_required" }),
		"bad idempotency key":   bad(func(m map[string]any) { m["idempotency_key"] = "has space" }),
		"malformed expected id": bad(func(m map[string]any) { m["expected_coordinator_event_id"] = "abc" }),
		"bad candidate":         bad(func(m map[string]any) { m["candidate_id"] = "byom_short" }),
		"wrong schema":          bad(func(m map[string]any) { m["schema"] = "model_admission_decision_request.v2" }),
		"reason without prefix": bad(func(m map[string]any) { m["reason_code"] = "ok" }),
		"bad provider grammar":  bad(func(m map[string]any) { m["provider_id"] = "p/1" }),
		"missing idempotency":   bad(func(m map[string]any) { delete(m, "idempotency_key") }),
	} {
		if code, resp := c.do(http.MethodPost, decisions, "alice-secret", body); code != http.StatusBadRequest || errorCode(resp) != "invalid_request" {
			t.Fatalf("%s: %d %v", name, code, resp)
		}
	}
	// No offer → 404.
	if code, resp := c.do(http.MethodPost, decisions, "alice-secret", decisionRequest("p1", "byom_"+strings.Repeat("z", 52), "catalog_priced", "operator_ok", head, "k1")); code != http.StatusNotFound || errorCode(resp) != "no_offer" {
		t.Fatalf("no offer: %d %v", code, resp)
	}
	// stale_head wins over invalid_transition: a stale head with an illegal
	// edge is `stale_head`; a current head with an illegal edge is
	// `invalid_transition` (offer_submitted → settlement_capable).
	if code, resp := c.do(http.MethodPost, decisions, "alice-secret", decisionRequest("p1", offer.CandidateID, "settlement_capable", "operator_ok", other, "k2")); code != http.StatusConflict || errorCode(resp) != "stale_head" {
		t.Fatalf("stale head precedence: %d %v", code, resp)
	}
	if code, resp := c.do(http.MethodPost, decisions, "alice-secret", decisionRequest("p1", offer.CandidateID, "settlement_capable", "operator_ok", head, "k2")); code != http.StatusConflict || errorCode(resp) != "invalid_transition" {
		t.Fatalf("invalid transition: %d %v", code, resp)
	}
	// catalog_priced commits: operator actor, catalog material bound, no
	// bound member, the session binding refreshed to the new head.
	code, priced := c.do(http.MethodPost, decisions, "alice-secret", decisionRequest("p1", offer.CandidateID, "catalog_priced", "operator_priced", head, "k3"))
	if code != http.StatusOK || priced["admission_state"] != "catalog_priced" || priced["previous_admission_state"] != "offer_submitted" ||
		priced["decided_by"] != "operator:alice" || priced["replayed"] != false || priced["pending_decision_id"] != nil || priced["bound_member"] != nil ||
		priced["reason_code"] != "operator_priced" || priced["catalog_model_key"] != "small" {
		t.Fatalf("catalog_priced: %d %v", code, priced)
	}
	pricedHead, _ := priced["coordinator_event_id"].(string)
	stored := f.latest(t, "p1", offer.CandidateID)
	if stored.CoordinatorEventID != pricedHead || stored.Actor != "operator:alice" || stored.CatalogID != "tier2-1" || stored.EvaluatedReleaseGeneration != s.ReleaseGeneration() || len(stored.CatalogMembers) != 1 {
		t.Fatalf("stored decision: %+v", stored)
	}
	if p, _ := s.pool.Resolve("p1", ""); p.ModelAdmissionCoordinatorEventID != pricedHead {
		t.Fatal("decision must refresh the session binding")
	}
	// Identical replay after the head advanced answers the original event;
	// the same key with another body is `idempotency_conflict` — both before
	// any head compare.
	if code, replay := c.do(http.MethodPost, decisions, "alice-secret", decisionRequest("p1", offer.CandidateID, "catalog_priced", "operator_priced", head, "k3")); code != http.StatusOK || replay["replayed"] != true || replay["coordinator_event_id"] != pricedHead {
		t.Fatalf("replay: %d %v", code, replay)
	}
	if code, resp := c.do(http.MethodPost, decisions, "alice-secret", decisionRequest("p1", offer.CandidateID, "revoked", "operator_priced", head, "k3")); code != http.StatusConflict || errorCode(resp) != "idempotency_conflict" {
		t.Fatalf("divergent reuse: %d %v", code, resp)
	}
	// Dual control unavailable with a single configured actor: refused
	// synchronously, no pending record.
	if code, resp := c.do(http.MethodPost, decisions, "alice-secret", decisionRequest("p1", offer.CandidateID, "settlement_capable", "operator_settle", pricedHead, "k4")); code != http.StatusConflict || errorCode(resp) != "dual_control_unavailable" {
		t.Fatalf("dual control unavailable: %d %v", code, resp)
	}
	if _, found, _ := s.modelAdmissions.PendingModelAdmissionDecisionByRequest(t.Context(), "p1", offer.CandidateID, modelAdmissionDecisionRequest{CandidateID: offer.CandidateID, IdempotencyKey: "k4"}.requestID()); found {
		t.Fatal("no pending record may exist after dual_control_unavailable")
	}
	s.cfg.Auth.OperatorKeys["bob"] = "bob-secret"
	// The pending response values.
	code, pending := c.do(http.MethodPost, decisions, "alice-secret", decisionRequest("p1", offer.CandidateID, "settlement_capable", "operator_settle", pricedHead, "k4"))
	pendingID, _ := pending["pending_decision_id"].(string)
	if code != http.StatusOK || pending["admission_state"] != "catalog_priced" || pending["previous_admission_state"] != "catalog_priced" ||
		pending["coordinator_event_id"] != pricedHead || pending["decided_by"] != "operator:alice" || pending["replayed"] != false ||
		pending["reason_code"] != "operator_settle" || pending["bound_member"] != nil || !modelAdmissionPendingIDPattern.MatchString(pendingID) {
		t.Fatalf("pending: %d %v", code, pending)
	}
	if latest := f.latest(t, "p1", offer.CandidateID); latest.State != "catalog_priced" {
		t.Fatal("the settlement request must append nothing")
	}
	if code, replay := c.do(http.MethodPost, decisions, "alice-secret", decisionRequest("p1", offer.CandidateID, "settlement_capable", "operator_settle", pricedHead, "k4")); code != http.StatusOK || replay["replayed"] != true || replay["pending_decision_id"] != pendingID {
		t.Fatalf("pending replay: %d %v", code, replay)
	}
	approvePath := decisions + "/" + pendingID + "/approve"
	// Same actor → dual_control_required.
	if code, resp := c.do(http.MethodPost, approvePath, "alice-secret", approveRequest("p1", offer.CandidateID, pendingID, pricedHead, "a1")); code != http.StatusConflict || errorCode(resp) != "dual_control_required" {
		t.Fatalf("same actor: %d %v", code, resp)
	}
	// Path/body disagreement and bound-field disagreement → invalid_request.
	if code, resp := c.do(http.MethodPost, approvePath, "bob-secret", approveRequest("p1", offer.CandidateID, strings.Repeat("f", 32), pricedHead, "a1")); code != http.StatusBadRequest || errorCode(resp) != "invalid_request" {
		t.Fatalf("path/body mismatch: %d %v", code, resp)
	}
	if code, resp := c.do(http.MethodPost, approvePath, "bob-secret", approveRequest("p1", offer.CandidateID, pendingID, other, "a1")); code != http.StatusBadRequest || errorCode(resp) != "invalid_request" {
		t.Fatalf("bound field mismatch: %d %v", code, resp)
	}
	// Unknown pending id → no_pending_decision.
	unknown := strings.Repeat("e", 32)
	if code, resp := c.do(http.MethodPost, decisions+"/"+unknown+"/approve", "bob-secret", approveRequest("p1", offer.CandidateID, unknown, pricedHead, "a1")); code != http.StatusConflict || errorCode(resp) != "no_pending_decision" {
		t.Fatalf("unknown pending: %d %v", code, resp)
	}
	// Approval commits: settlement_capable, bound member = the session's
	// pinned candidate_row member, decided by bob.
	code, approved := c.do(http.MethodPost, approvePath, "bob-secret", approveRequest("p1", offer.CandidateID, pendingID, pricedHead, "a1"))
	member, _ := approved["bound_member"].(map[string]any)
	if code != http.StatusOK || approved["admission_state"] != "settlement_capable" || approved["decided_by"] != "operator:bob" || approved["replayed"] != false ||
		member == nil || member["source"] != "candidate_row" || member["hash"] != bindingRowHash || member["hash_algorithm"] != modelidentity.SnapshotManifestV1 || member["artifact_id"] != nil {
		t.Fatalf("approval: %d %v", code, approved)
	}
	settledHead, _ := approved["coordinator_event_id"].(string)
	settled := f.latest(t, "p1", offer.CandidateID)
	if settled.State != "settlement_capable" || settled.BoundMemberSource != "candidate_row" || settled.ExpectedCatalogModelHash != bindingRowHash || settled.Actor != "operator:bob" {
		t.Fatalf("stored settlement: %+v", settled)
	}
	// Identical-key approval retry answers the committed response; a
	// distinct-key approval of the consumed record is pending_consumed; a
	// divergent body under the reused key is idempotency_conflict.
	if code, replay := c.do(http.MethodPost, approvePath, "bob-secret", approveRequest("p1", offer.CandidateID, pendingID, pricedHead, "a1")); code != http.StatusOK || replay["replayed"] != true || replay["coordinator_event_id"] != settledHead {
		t.Fatalf("approval replay: %d %v", code, replay)
	}
	if code, resp := c.do(http.MethodPost, approvePath, "bob-secret", approveRequest("p1", offer.CandidateID, pendingID, pricedHead, "a2")); code != http.StatusConflict || errorCode(resp) != "pending_consumed" {
		t.Fatalf("distinct-key double approval: %d %v", code, resp)
	}
	// A divergent body under the reused key changes a bound field: (a)
	// answers invalid_request before (b).
	if code, resp := c.do(http.MethodPost, approvePath, "bob-secret", approveRequest("p1", offer.CandidateID, pendingID, other, "a1")); code != http.StatusBadRequest || errorCode(resp) != "invalid_request" {
		t.Fatalf("divergent approval body: %d %v", code, resp)
	}
	// A pending record dies when the head moves: request, then a revocation
	// by the operator, then the approval is stale_head.
	code, pending2 := c.do(http.MethodPost, decisions, "alice-secret", decisionRequest("p1", offer.CandidateID, "catalog_priced", "operator_demote", settledHead, "k5"))
	if code != http.StatusOK {
		t.Fatalf("demotion: %d %v", code, pending2)
	}
	demotedHead, _ := pending2["coordinator_event_id"].(string)
	code, pending3 := c.do(http.MethodPost, decisions, "alice-secret", decisionRequest("p1", offer.CandidateID, "settlement_capable", "operator_settle", demotedHead, "k6"))
	pendingID3, _ := pending3["pending_decision_id"].(string)
	if code != http.StatusOK || pendingID3 == "" {
		t.Fatalf("second pending: %d %v", code, pending3)
	}
	code, revoked := c.do(http.MethodPost, decisions, "alice-secret", decisionRequest("p1", offer.CandidateID, "revoked", "operator_revoke", demotedHead, "k7"))
	if code != http.StatusOK || revoked["admission_state"] != "revoked" {
		t.Fatalf("operator revocation: %d %v", code, revoked)
	}
	if code, resp := c.do(http.MethodPost, decisions+"/"+pendingID3+"/approve", "bob-secret", approveRequest("p1", offer.CandidateID, pendingID3, demotedHead, "a3")); code != http.StatusConflict || errorCode(resp) != "no_pending_decision" {
		t.Fatalf("approval after the head moved: %d %v", code, resp)
	}
	if p, _ := s.pool.Resolve("p1", ""); p.ModelAdmissionCandidateID != "" {
		t.Fatal("revoked candidate must not stay bound")
	}

	// Preconditions: an unmatched candidate is catalog_match_required; a
	// settlement request with no bound verified session is
	// no_verified_session; a listed row is catalog_row_not_recommendable.
	f.registerSession(t, "p2", "s2", "model-a", false)
	unmatched := f.offer(t, "p2", "u", "ollama_loopback", map[string]string{})
	if code, resp := c.do(http.MethodPost, decisions, "alice-secret", decisionRequest("p2", unmatched.CandidateID, "catalog_priced", "operator_ok", unmatched.CoordinatorEventID, "k1")); code != http.StatusConflict || errorCode(resp) != "catalog_match_required" {
		t.Fatalf("unmatched: %d %v", code, resp)
	}
	matched := f.offer(t, "p2", "m", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash})
	code, priced2 := c.do(http.MethodPost, decisions, "alice-secret", decisionRequest("p2", matched.CandidateID, "catalog_priced", "operator_ok", matched.CoordinatorEventID, "k2"))
	if code != http.StatusOK {
		t.Fatalf("p2 priced: %d %v", code, priced2)
	}
	priced2Head, _ := priced2["coordinator_event_id"].(string)
	// p2's session has no receipt key: no_verified_session.
	if code, resp := c.do(http.MethodPost, decisions, "alice-secret", decisionRequest("p2", matched.CandidateID, "settlement_capable", "operator_settle", priced2Head, "k3")); code != http.StatusConflict || errorCode(resp) != "no_verified_session" {
		t.Fatalf("no verified session: %d %v", code, resp)
	}
	// Listing: ordered by candidate id, session facts, members, actors.
	code, listing := c.do(http.MethodGet, "/admin/model-admission/offers?provider_id=p2", "alice-secret", nil)
	items, _ := listing["candidates"].([]any)
	if code != http.StatusOK || listing["schema"] != "model_admission_offer_list.v1" || len(items) != 2 {
		t.Fatalf("listing: %d %v", code, listing)
	}
	first, _ := items[0].(map[string]any)
	second, _ := items[1].(map[string]any)
	if first["candidate_id"] != matched.CandidateID || second["candidate_id"] != unmatched.CandidateID {
		t.Fatalf("listing order: %v %v", first["candidate_id"], second["candidate_id"])
	}
	session, _ := first["session"].(map[string]any)
	members, _ := first["catalog_members"].([]any)
	if first["catalog_match_state"] != "catalog_matched" || first["catalog_model_key"] != "small" || first["last_event_actor"] != "operator:alice" ||
		first["runtime_source"] != "mlx_cache" || len(members) != 1 || session == nil || session["bound"] != true || session["receipt_key_present"] != false || session["verified_member"] == nil {
		t.Fatalf("listing item: %v", first)
	}
	if second["catalog_match_state"] != "unmatched" || second["catalog_model_key"] != nil || second["catalog_match_reason"] != "no_artifact_match" {
		t.Fatalf("unmatched item: %v", second)
	}
	if code, resp := c.do(http.MethodGet, "/admin/model-admission/offers?provider_id=p2&extra=1", "alice-secret", nil); code != http.StatusBadRequest || errorCode(resp) != "invalid_request" {
		t.Fatalf("extra query parameter: %d %v", code, resp)
	}
	if code, resp := c.do(http.MethodGet, "/admin/model-admission/offers?provider_id=p2", "shared-secret", nil); code != http.StatusUnauthorized || errorCode(resp) != "invalid_operator_token" {
		t.Fatalf("listing auth: %d %v", code, resp)
	}
	// Row demoted to listed → catalog_row_not_recommendable at decision time.
	f.registerSession(t, "p3", "s3", "model-a", true)
	listedOffer := f.offer(t, "p3", "l", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash})
	f.publish(bindingCatalog(t, "release-listed", "listed", bindingRowHash), nil)
	if code, resp := c.do(http.MethodPost, decisions, "alice-secret", decisionRequest("p3", listedOffer.CandidateID, "catalog_priced", "operator_ok", listedOffer.CoordinatorEventID, "k1")); code != http.StatusConflict || errorCode(resp) != "catalog_row_not_recommendable" {
		t.Fatalf("listed row: %d %v", code, resp)
	}
	// Operator rate limiting is independent of any provider window.
	for i := 0; i < modelAdmissionOperatorRateCap; i++ {
		s.modelAdmissionOperatorLimiter.allow("operator:alice|127.0.0.1", f.now, modelAdmissionOperatorRateCap)
	}
	if code, resp := c.do(http.MethodPost, decisions, "alice-secret", decisionRequest("p3", listedOffer.CandidateID, "catalog_priced", "operator_ok", listedOffer.CoordinatorEventID, "k1")); code != http.StatusTooManyRequests || errorCode(resp) != "rate_limited" {
		t.Fatalf("operator rate limit: %d %v", code, resp)
	}
	if !s.allowModelAdmissionAttempt("p3") {
		t.Fatal("the provider window must be untouched by operator rate limiting")
	}
}

// Independent review: dual control needs two DISTINCT secrets (two actor
// ids sharing one secret are one principal; an ambiguous bearer is refused),
// a provider cannot squat coordinator/operator replay keys, an approval of an
// expired record is pending_expired, and a no-op heartbeat refresh does not
// advance the binding generation.
func TestModelAdmissionOperatorDualControlSecretsAndReservedKeys(t *testing.T) {
	f := newBindingFixture(t)
	s := f.server
	s.cfg.Auth.OperatorKeys = map[string]string{"alice": "shared", "bob": "shared"}
	s.newUUID = uuid.NewString
	c := operatorClient{t: t, s: s}
	const decisions = "/admin/model-admission/decisions"
	f.registerSession(t, "p1", "s1", "model-a", true)
	offer := f.offer(t, "p1", "a", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash})
	// The shared bearer matches two entries: no attribution, refused.
	if code, resp := c.do(http.MethodPost, decisions, "shared", decisionRequest("p1", offer.CandidateID, "catalog_priced", "operator_ok", offer.CoordinatorEventID, "k1")); code != http.StatusUnauthorized || errorCode(resp) != "invalid_operator_token" {
		t.Fatalf("ambiguous bearer: %d %v", code, resp)
	}
	// Two actors, one of them a duplicate secret of the other: not dual control.
	s.cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "alice-secret", "carol": "carol-secret"}
	code, priced := c.do(http.MethodPost, decisions, "carol-secret", decisionRequest("p1", offer.CandidateID, "catalog_priced", "operator_ok", offer.CoordinatorEventID, "k1"))
	if code != http.StatusOK {
		t.Fatalf("priced: %d %v", code, priced)
	}
	pricedHead, _ := priced["coordinator_event_id"].(string)
	if code, resp := c.do(http.MethodPost, decisions, "carol-secret", decisionRequest("p1", offer.CandidateID, "settlement_capable", "operator_settle", pricedHead, "k2")); code != http.StatusConflict || errorCode(resp) != "dual_control_unavailable" {
		t.Fatalf("duplicated secrets must not count as dual control: %d %v", code, resp)
	}
	// Aliases that normalize to one actor, or an entry the SPEC actor
	// grammar rejects, do not count toward dual control either.
	for name, tc := range map[string]struct {
		keys   map[string]string
		bearer string
	}{
		"alias":                    {map[string]string{"alice": "alice-secret", "operator:alice": "alias-secret"}, "alice-secret"},
		"invalid actor":            {map[string]string{"alice": "alice-secret", "Bob!": "bob-secret"}, "alice-secret"},
		"invalid actor shares key": {map[string]string{"alice": "shared", "Bob!": "shared", "carol": "carol-secret"}, "carol-secret"},
	} {
		s.cfg.Auth.OperatorKeys = tc.keys
		if code, resp := c.do(http.MethodPost, decisions, tc.bearer, decisionRequest("p1", offer.CandidateID, "settlement_capable", "operator_settle", pricedHead, "k2-"+strings.ReplaceAll(name, " ", "-"))); code != http.StatusConflict || errorCode(resp) != "dual_control_unavailable" {
			t.Fatalf("%s: %d %v", name, code, resp)
		}
	}
	// Distinct secrets: pending; then an expired record is pending_expired.
	s.cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	code, pending := c.do(http.MethodPost, decisions, "alice-secret", decisionRequest("p1", offer.CandidateID, "settlement_capable", "operator_settle", pricedHead, "k3"))
	pendingID, _ := pending["pending_decision_id"].(string)
	if code != http.StatusOK || pendingID == "" {
		t.Fatalf("pending: %d %v", code, pending)
	}
	later := f.now.Add(25 * time.Hour)
	s.now = func() time.Time { return later }
	if code, resp := c.do(http.MethodPost, decisions+"/"+pendingID+"/approve", "bob-secret", approveRequest("p1", offer.CandidateID, pendingID, pricedHead, "a1")); code != http.StatusConflict || errorCode(resp) != "pending_expired" {
		t.Fatalf("expired pending: %d %v", code, resp)
	}
	// A provider-chosen replay key in a reserved namespace is rejected at
	// offer validation (it could pre-empt a coordinator revocation or an
	// operator decision in the shared replay index).
	for _, key := range []string{"coordinator_revoked_abc", "operator_decision_k1", "operator_x"} {
		maxContext := 2048
		payload := modelAdmissionOfferSubmitRequest{
			Schema: "model_admission_offer_submit.v1", SignatureDomain: "macprovider.model_admission.offer.v1",
			ProviderID: "p1", CandidateID: "byom_" + strings.Repeat("a", 52), RuntimeSource: "mlx_cache",
			ServedModelRef: "ref", DiscoveryDigestSHA256: strings.Repeat("a", 64), EvaluationDigestSHA256: strings.Repeat("b", 64),
			ArtifactHashes:       map[string]string{},
			AdvisoryCapabilities: &modelAdmissionAdvisoryCapabilities{MaxContextTokens: &maxContext},
			FitEvidenceSource:    "local_discovery", LocalReadiness: "ready", RequestedDisclosureClass: "non_earning_provider_asserted",
			Timestamp: f.now.Format(time.RFC3339Nano), Nonce: "nonce_1", IdempotencyKey: key,
			SigningKeyDigest: strings.Repeat("e", 64), SignatureAlgorithm: "ed25519", ProviderSignature: "AA==", CLIVersion: "1.8.123",
		}
		if err := validateModelAdmissionPayload(payload); err == nil {
			t.Fatalf("reserved idempotency key %q must be rejected", key)
		}
		payload.IdempotencyKey, payload.Nonce = "request_1", key
		if err := validateModelAdmissionPayload(payload); err == nil {
			t.Fatalf("reserved nonce %q must be rejected", key)
		}
	}
	// A heartbeat that changes nothing keeps the binding generation.
	s.now = func() time.Time { return f.now }
	before, _ := s.pool.Resolve("p1", "")
	s.withProviderSection("p1", func(section *providerSection) {
		s.refreshModelAdmissionBindingLocked(context.Background(), "p1", section)
	})
	after, _ := s.pool.Resolve("p1", "")
	if after.ModelAdmissionBindingGeneration != before.ModelAdmissionBindingGeneration || s.ModelAdmissionBindingGeneration("p1") != before.ModelAdmissionBindingGeneration {
		t.Fatalf("no-op refresh must not advance the binding generation: %d → %d", before.ModelAdmissionBindingGeneration, after.ModelAdmissionBindingGeneration)
	}
	// An append for an UNRELATED candidate advances the section generation;
	// the unchanged binding is re-stamped with it, so a route resolved after
	// the append compares equal while one captured before it fails closed.
	f.offer(t, "p1", "z", "ollama_loopback", map[string]string{})
	stamped, _ := s.pool.Resolve("p1", "")
	if stamped.ModelAdmissionCandidateID != offer.CandidateID || stamped.ModelAdmissionBindingGeneration != s.ModelAdmissionBindingGeneration("p1") || stamped.ModelAdmissionBindingGeneration == before.ModelAdmissionBindingGeneration {
		t.Fatalf("unchanged binding must be re-stamped with the advanced section generation: %+v vs %d", stamped.ModelAdmissionBindingGeneration, s.ModelAdmissionBindingGeneration("p1"))
	}
}
