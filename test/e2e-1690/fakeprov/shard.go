package main

// #2084 (test/e2e-2084): SPEC-051 shard group roles for the fake provider.
//
//	-ws-relay            serve inference over the WebSocket tunnel (no
//	                     endpoint_url), as the real CLI and every shard group
//	                     head do (SPEC-051-R015 item 1, R016).
//	-shard-role ROLE     head | member: advertise shard_group_head_v1 or
//	                     shard_member_v1 and speak the SPEC-051-R029 group
//	                     messages. A member is a stage or a spare depending on
//	                     where the current record names it.
//	-shard-group FILE    the shared group file every process of one group
//	                     re-reads each second: {"record": <SPEC-051-R005
//	                     record>, "member_keys": {member: receipt-key-file}}.
//	                     Changing the record's epoch (or its stages/spares) is
//	                     an epoch bump / takeover; the head re-registers and
//	                     each member re-sends its hello.
//	-shard-knobs FILE    per-process fault knobs (JSON object, re-read every
//	                     second and on every request; absent = all defaults).
//
// The head signs the record, receipts and attestations with its own receipt
// key and signs each member's sub-receipt with that member's receipt key (read
// from member_keys): in the VM every process's key file is local, and the
// coordinator verifies only signatures and bindings, so this is exactly the
// wire a real group produces. Observations (register/hello results, the last
// shard_group_status, dispatch counters) are served on /v1/status under
// "shard" so the harness can assert coordinator behaviour from the provider
// side as well as from the coordinator's own tables and logs.

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

type shardState struct {
	role      string // head | member
	groupFile string
	knobsFile string

	mu sync.Mutex
	// group file contents as last read
	record     map[string]any
	recordRaw  []byte
	memberKeys map[string]string
	// head: the epoch / record digest last sent, and the coordinator's answers
	sentDigest     string
	registerResult map[string]any
	status         map[string]any
	statusHistory  []string
	// member: the hello last sent and its result
	helloKey    string
	helloResult map[string]any
	helloSentAt time.Time
	// counters the harness reads
	dispatches             int
	servedWhileUnavailable int
	memberDispatches       int
	attestations           map[string]string // request_id -> attest mode used
	inflight               int
	cancels                map[string]chan struct{}
}

func newShardState(role, groupFile, knobsFile string) *shardState {
	return &shardState{role: role, groupFile: groupFile, knobsFile: knobsFile, attestations: map[string]string{}, cancels: map[string]chan struct{}{}}
}

// knobs returns the current fault knobs (empty on any read error).
func (s *shardState) knobs() map[string]any {
	out := map[string]any{}
	if s.knobsFile == "" {
		return out
	}
	raw, err := os.ReadFile(s.knobsFile)
	if err != nil {
		return out
	}
	_ = json.Unmarshal(raw, &out)
	return out
}

func knobBool(k map[string]any, name string, def bool) bool {
	if v, ok := k[name].(bool); ok {
		return v
	}
	return def
}

func knobInt(k map[string]any, name string, def int) int {
	if v, ok := k[name].(float64); ok {
		return int(v)
	}
	return def
}

func knobString(k map[string]any, name, def string) string {
	if v, ok := k[name].(string); ok {
		return v
	}
	return def
}

// reload re-reads the shared group file. It reports whether the record changed.
func (s *shardState) reload() bool {
	raw, err := os.ReadFile(s.groupFile)
	if err != nil {
		return false
	}
	var doc struct {
		Record     json.RawMessage   `json:"record"`
		MemberKeys map[string]string `json:"member_keys"`
	}
	if json.Unmarshal(raw, &doc) != nil || len(doc.Record) == 0 {
		return false
	}
	var rec map[string]any
	dec := json.NewDecoder(bytes.NewReader(doc.Record))
	dec.UseNumber()
	if dec.Decode(&rec) != nil {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	changed := !bytes.Equal(s.recordRaw, doc.Record)
	s.record, s.recordRaw, s.memberKeys = rec, append([]byte(nil), doc.Record...), doc.MemberKeys
	return changed
}

func (s *shardState) snapshotRecord() map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	return deepCopy(s.record)
}

func deepCopy(v map[string]any) map[string]any {
	if v == nil {
		return nil
	}
	raw, _ := json.Marshal(v)
	var out map[string]any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	_ = dec.Decode(&out)
	return out
}

// jcs is RFC 8785 over v, with integers kept exact (json.Number).
func jcs(v any) ([]byte, error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	var generic any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&generic); err != nil {
		return nil, err
	}
	return spec015CanonicalJSON(generic)
}

func signDomain(priv ed25519.PrivateKey, domain string, v any) (string, error) {
	canonical, err := jcs(v)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(ed25519.Sign(priv, append([]byte(domain), canonical...))), nil
}

func num(v any) int64 {
	switch x := v.(type) {
	case json.Number:
		n, _ := x.Int64()
		return n
	case float64:
		return int64(x)
	case int:
		return int64(x)
	case int64:
		return x
	}
	return 0
}

type shardStage struct {
	index      int64
	member     string
	layerStart int64
	layerEnd   int64
}

func recordStages(rec map[string]any) []shardStage {
	var out []shardStage
	list, _ := rec["stages"].([]any)
	for _, item := range list {
		m, _ := item.(map[string]any)
		out = append(out, shardStage{index: num(m["stage_index"]), member: fmt.Sprint(m["member_device_id"]), layerStart: num(m["layer_start"]), layerEnd: num(m["layer_end"])})
	}
	return out
}

func recordSpares(rec map[string]any) map[string]int64 {
	out := map[string]int64{}
	list, _ := rec["spares"].([]any)
	for _, item := range list {
		m, _ := item.(map[string]any)
		out[fmt.Sprint(m["member_device_id"])] = num(m["stage_index"])
	}
	return out
}

// requiredInterface maps the record's interconnect class to its interface.
func requiredInterface(rec map[string]any) string {
	if fmt.Sprint(rec["interconnect_class"]) == "thunderbolt-ip" {
		return "thunderbolt"
	}
	return "ethernet"
}

// ---- head -------------------------------------------------------------------

// shardRegisterMessage builds the signed shard_group_register for the current
// record, applying the record_override and bad_record_signature knobs.
func (p *fakeProvider) shardRegisterMessage(k map[string]any) (map[string]any, string, error) {
	rec := p.shard.snapshotRecord()
	if rec == nil {
		return nil, "", fmt.Errorf("no group record")
	}
	if ov, ok := k["record_override"].(map[string]any); ok {
		for key, v := range ov {
			if v == nil {
				delete(rec, key)
			} else {
				rec[key] = v
			}
		}
	}
	sig, err := signDomain(p.receiptPrivkey, "macprovider.shard-group-record.v1\n", rec)
	if err != nil {
		return nil, "", err
	}
	if knobBool(k, "bad_record_signature", false) {
		sig = base64.StdEncoding.EncodeToString(make([]byte, 64))
	}
	canonical, _ := jcs(rec)
	sum := sha256.Sum256(append(canonical, []byte(sig)...))
	return map[string]any{"type": "shard_group_register", "version": 1, "record": rec, "record_signature": sig}, hex.EncodeToString(sum[:]), nil
}

// shardHeartbeatMessage lists every record member's health (head view) and the
// required links: stage i -> i+1, last -> stage 0, stage 0 -> each spare.
func (p *fakeProvider) shardHeartbeatMessage(k map[string]any) map[string]any {
	rec := p.shard.snapshotRecord()
	stages := recordStages(rec)
	spares := recordSpares(rec)
	unhealthy, _ := k["unhealthy_members"].([]any)
	isUnhealthy := map[string]bool{}
	for _, u := range unhealthy {
		isUnhealthy[fmt.Sprint(u)] = true
	}
	var members []any
	for _, st := range stages {
		members = append(members, map[string]any{"member_device_id": st.member, "healthy": !isUnhealthy[st.member]})
	}
	for id := range spares {
		members = append(members, map[string]any{"member_device_id": id, "healthy": !isUnhealthy[id]})
	}
	iface := knobString(k, "link_interface", requiredInterface(rec))
	rtt := knobInt(k, "link_rtt_p99_us", 450)
	var links []any
	link := func(from, to string) {
		links = append(links, map[string]any{"from_member_device_id": from, "to_member_device_id": to, "interface_type": iface, "rtt_p99_us": rtt})
	}
	for i := 0; i+1 < len(stages); i++ {
		link(stages[i].member, stages[i+1].member)
	}
	if len(stages) > 0 {
		link(stages[len(stages)-1].member, stages[0].member)
		for id := range spares {
			link(stages[0].member, id)
		}
	}
	if members == nil {
		members = []any{}
	}
	if links == nil {
		links = []any{}
	}
	return map[string]any{"type": "shard_group_heartbeat", "version": 1, "group_provider_id": rec["group_provider_id"], "group_epoch": rec["group_epoch"], "members": members, "links": links}
}

// ---- member -----------------------------------------------------------------

// memberRole returns this member's role and stage in the record.
func memberRole(rec map[string]any, self string) (role string, stage int64, ok bool) {
	for _, st := range recordStages(rec) {
		if st.member == self && st.index > 0 {
			return "stage", st.index, true
		}
	}
	if idx, ok := recordSpares(rec)[self]; ok {
		return "spare", idx, true
	}
	return "", 0, false
}

// memberPeers mirrors the coordinator's memberLinkPeers.
func memberPeers(rec map[string]any, self string) []string {
	role, stage, ok := memberRole(rec, self)
	if !ok {
		return nil
	}
	stages := recordStages(rec)
	if role == "spare" {
		return []string{stages[0].member}
	}
	n := int64(len(stages))
	up := stages[(stage-1+n)%n].member
	down := stages[(stage+1)%n].member
	if up == down {
		return []string{up}
	}
	return []string{up, down}
}

func (p *fakeProvider) shardHelloMessage(k map[string]any) (map[string]any, bool) {
	rec := p.shard.snapshotRecord()
	role, stage, ok := memberRole(rec, p.providerID)
	if !ok {
		return nil, false
	}
	st := recordStages(rec)[stage]
	model, _ := rec["model"].(map[string]any)
	iface := knobString(k, "hello_interface", requiredInterface(rec))
	var links []any
	for _, peer := range memberPeers(rec, p.providerID) {
		links = append(links, map[string]any{"peer_member_device_id": peer, "interface_type": iface})
	}
	hello := map[string]any{
		"type": "shard_member_hello", "version": 1, "group_provider_id": rec["group_provider_id"], "group_epoch": rec["group_epoch"],
		"member_device_id": p.providerID, "role": role, "stage_index": stage, "layer_start": st.layerStart, "layer_end": st.layerEnd,
		"transport_version": rec["transport_version"], "artifact_hash_algorithm": model["artifact_hash_algorithm"], "artifact_hash": model["artifact_hash"],
		"weights_verified": knobBool(k, "weights_verified", true), "stage_fits": true, "links": links,
	}
	if e, ok := k["hello_epoch"].(float64); ok {
		hello["group_epoch"] = int64(e)
	}
	return hello, true
}

func (p *fakeProvider) shardMemberHealthMessage(k map[string]any) (map[string]any, bool) {
	rec := p.shard.snapshotRecord()
	if _, _, ok := memberRole(rec, p.providerID); !ok {
		return nil, false
	}
	healthy := knobBool(k, "self_healthy", true)
	reason := ""
	if !healthy {
		reason = knobString(k, "self_reason", "link_down")
	}
	iface := knobString(k, "health_interface", requiredInterface(rec))
	rtt := knobInt(k, "health_rtt_p99_us", 420)
	var links []any
	for _, peer := range memberPeers(rec, p.providerID) {
		links = append(links, map[string]any{"peer_member_device_id": peer, "interface_type": iface, "rtt_p99_us": rtt})
	}
	return map[string]any{"type": "shard_member_health", "version": 1, "group_provider_id": rec["group_provider_id"], "group_epoch": rec["group_epoch"],
		"member_device_id": p.providerID, "healthy": healthy, "reason": reason, "links": links}, true
}

// shardTick runs once a second on an accepted session: re-read the group
// file, (re-)register or (re-)hello when needed, and send the periodic group
// heartbeat or member health report, unless a knob suppresses it.
func (p *fakeProvider) shardTick(send func(map[string]any) error) error {
	s := p.shard
	s.reload()
	k := s.knobs()
	switch s.role {
	case "head":
		if !knobBool(k, "register", true) {
			return nil
		}
		msg, digest, err := p.shardRegisterMessage(k)
		if err != nil {
			return nil
		}
		s.mu.Lock()
		resend := s.sentDigest != digest
		if knobBool(k, "reregister_every_tick", false) {
			resend = true
		}
		s.mu.Unlock()
		if resend {
			if err := send(msg); err != nil {
				return err
			}
			s.mu.Lock()
			s.sentDigest = digest
			s.registerResult = nil
			s.mu.Unlock()
			logf("shard: sent shard_group_register epoch=%v", msg["record"].(map[string]any)["group_epoch"])
		}
		if knobBool(k, "heartbeat", true) {
			return send(p.shardHeartbeatMessage(k))
		}
	case "member":
		if !knobBool(k, "hello", true) {
			return nil
		}
		hello, ok := p.shardHelloMessage(k)
		if !ok {
			return nil
		}
		key, _ := jcs(hello)
		s.mu.Lock()
		accepted := s.helloResult != nil && s.helloResult["accepted"] == true
		resend := s.helloKey != string(key) || (!accepted && time.Since(s.helloSentAt) > 3*time.Second)
		s.mu.Unlock()
		if resend {
			if err := send(hello); err != nil {
				return err
			}
			s.mu.Lock()
			s.helloKey, s.helloSentAt = string(key), time.Now()
			if s.helloResult != nil && fmt.Sprint(s.helloResult["group_epoch"]) != fmt.Sprint(hello["group_epoch"]) {
				s.helloResult = nil
			}
			s.mu.Unlock()
		}
		if knobBool(k, "health", true) && accepted {
			if msg, ok := p.shardMemberHealthMessage(k); ok {
				return send(msg)
			}
		}
	}
	return nil
}

// shardSessionStarted resets per-session state: a new session re-registers
// (head) and re-sends its hello (member), as the real CLI does on reconnect.
func (p *fakeProvider) shardSessionStarted() {
	s := p.shard
	s.mu.Lock()
	s.sentDigest, s.registerResult, s.status = "", nil, nil
	s.helloKey, s.helloResult = "", nil
	s.mu.Unlock()
}

// shardOnFrame handles a coordinator frame on a shard session. It returns true
// when the frame was a group message.
func (p *fakeProvider) shardOnFrame(payload []byte) bool {
	var env map[string]any
	if json.Unmarshal(payload, &env) != nil {
		return false
	}
	s := p.shard
	switch env["type"] {
	case "shard_group_register_result":
		s.mu.Lock()
		s.registerResult = env
		if env["accepted"] != true {
			// A refused record is re-sent only when the group file changes.
			logf("shard: register refused epoch=%v reason=%v", env["group_epoch"], env["reason"])
		}
		s.mu.Unlock()
		logf("shard: register_result %s", truncate(payload))
		return true
	case "shard_group_status":
		s.mu.Lock()
		s.status = env
		s.statusHistory = append(s.statusHistory, fmt.Sprintf("%v:%v:%v", env["group_epoch"], env["available"], env["reason"]))
		if len(s.statusHistory) > 64 {
			s.statusHistory = s.statusHistory[len(s.statusHistory)-64:]
		}
		s.mu.Unlock()
		logf("shard: status %s", truncate(payload))
		return true
	case "shard_member_hello_result":
		s.mu.Lock()
		s.helloResult = env
		s.mu.Unlock()
		logf("shard: hello_result %s", truncate(payload))
		return true
	}
	return false
}

func (p *fakeProvider) shardStatusJSON() map[string]any {
	s := p.shard
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string]any{
		"role": s.role, "register_result": s.registerResult, "status": s.status, "status_history": append([]string(nil), s.statusHistory...),
		"hello_result": s.helloResult, "dispatches": s.dispatches, "served_while_unavailable": s.servedWhileUnavailable,
		"member_dispatches": s.memberDispatches, "inflight": s.inflight,
	}
	if s.record != nil {
		out["record_epoch"] = s.record["group_epoch"]
		if role, stage, ok := memberRole(s.record, p.providerID); ok {
			out["record_role"], out["record_stage"] = role, stage
		}
	}
	return out
}

// headAvailable reports whether the last shard_group_status says the group is
// available at the record's current epoch (SPEC-051-R015 provider half).
func (s *shardState) headAvailable() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.status != nil && s.status["available"] == true && s.record != nil && fmt.Sprint(s.status["group_epoch"]) == fmt.Sprint(s.record["group_epoch"])
}

// ---- head inference over the WS tunnel ----------------------------------------

type wsInferenceRequest struct {
	Type       string              `json:"type"`
	RequestID  string              `json:"request_id"`
	Stream     bool                `json:"stream"`
	Body       string              `json:"body"`
	Settlement *settlementMetadata `json:"settlement"`
	Encrypted  bool                `json:"encrypted"`
	Enc        tier2Envelope       `json:"enc"`
}

// serveWSInference answers one inference_request on the tunnel. A member
// session never serves (SPEC-051-R016): it counts the dispatch and fails it.
func (p *fakeProvider) serveWSInference(send func(map[string]any) error, req wsInferenceRequest) {
	s := p.shard
	if s != nil && s.role == "member" {
		s.mu.Lock()
		s.memberDispatches++
		s.mu.Unlock()
		logf("shard: MEMBER SESSION RECEIVED BUYER WORK request_id=%s", req.RequestID)
		_ = send(map[string]any{"type": "inference_response_end", "request_id": req.RequestID, "status": "error", "chunks_sent": 0, "error": "shard_member_never_routable"})
		return
	}
	k := map[string]any{}
	if s != nil {
		k = s.knobs()
		available := s.headAvailable()
		s.mu.Lock()
		s.dispatches++
		if !available {
			s.servedWhileUnavailable++
		}
		s.inflight++
		s.mu.Unlock()
		p.kickHeartbeat()
		if !available {
			logf("shard: HEAD DISPATCHED WHILE NOT AVAILABLE request_id=%s", req.RequestID)
		}
		defer func() { s.mu.Lock(); s.inflight--; s.mu.Unlock(); p.kickHeartbeat() }()
	}
	cancel := make(chan struct{})
	p.registerCancel(req.RequestID, cancel)
	defer p.registerCancel(req.RequestID, nil)

	n := knobInt(k, "tokens", p.streamChunks)
	if n < 1 {
		n = 3
	}
	delay := time.Duration(knobInt(k, "chunk_delay_ms", int(p.chunkDelay/time.Millisecond))) * time.Millisecond
	if first := knobInt(k, "first_token_delay_ms", 0); first > 0 {
		select {
		case <-cancel:
			return
		case <-time.After(time.Duration(first) * time.Millisecond):
		}
	}
	if knobBool(k, "fail_before_first_token", false) {
		retryable := true
		_ = send(map[string]any{"type": "inference_response_end", "request_id": req.RequestID, "status": "error_shard_group_failed", "chunks_sent": 0, "retryable": retryable, "error": "shard group failed before the first token"})
		return
	}
	failAfter := knobInt(k, "fail_after_chunks", -1)
	const promptTokens = 8
	var model string
	var body map[string]any
	if json.Unmarshal([]byte(req.Body), &body) == nil {
		model, _ = body["model"].(string)
	}
	pieces := make([]string, n)
	for i := range pieces {
		pieces[i] = fmt.Sprintf("tok%d ", i)
	}
	sent := 0
	delivered := ""
	if req.Stream {
		for i, piece := range pieces {
			if i > 0 && delay > 0 {
				select {
				case <-cancel:
					p.sendCancelled(send, req, delivered, promptTokens, sent, k)
					return
				case <-time.After(delay):
				}
			}
			if failAfter >= 0 && sent >= failAfter {
				// SPEC-051-R022 without a spare: terminate the stream with
				// error_shard_group_failed after the first token(s).
				_ = send(map[string]any{"type": "inference_response_end", "request_id": req.RequestID, "status": "error_shard_group_failed", "chunks_sent": sent, "error": "shard group failed after the first token",
					"usage": map[string]any{"prompt_tokens": promptTokens, "completion_tokens": sent, "total_tokens": promptTokens + sent}})
				return
			}
			chunk, _ := json.Marshal(map[string]any{"id": "chatcmpl-shard-e2e", "object": "chat.completion.chunk", "created": 1780000000, "model": model,
				"choices": []any{map[string]any{"index": 0, "delta": map[string]any{"content": piece}, "finish_reason": nil}}})
			if send(map[string]any{"type": "inference_response_chunk", "request_id": req.RequestID, "seq": sent, "data": "data: " + string(chunk) + "\n\n"}) != nil {
				return
			}
			sent++
			delivered += piece
		}
		tail := fmt.Sprintf("data: {\"id\":\"chatcmpl-shard-e2e\",\"object\":\"chat.completion.chunk\",\"created\":1780000000,\"model\":%q,\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"+
			"data: {\"id\":\"chatcmpl-shard-e2e\",\"object\":\"chat.completion.chunk\",\"created\":1780000000,\"model\":%q,\"usage\":{\"prompt_tokens\":%d,\"completion_tokens\":%d,\"total_tokens\":%d},\"choices\":[]}\n\ndata: [DONE]\n\n",
			model, model, promptTokens, n, promptTokens+n)
		if send(map[string]any{"type": "inference_response_chunk", "request_id": req.RequestID, "seq": sent, "data": tail}) != nil {
			return
		}
		sent++
	} else {
		if delay > 0 {
			select {
			case <-cancel:
				p.sendCancelled(send, req, "", promptTokens, 0, k)
				return
			case <-time.After(delay * time.Duration(n)):
			}
		}
		delivered = strings.Join(pieces, "")
		raw, _ := json.Marshal(map[string]any{"id": "chatcmpl-shard-e2e", "object": "chat.completion", "created": 1780000000, "model": model,
			"usage":   map[string]any{"prompt_tokens": promptTokens, "completion_tokens": n, "total_tokens": promptTokens + n},
			"choices": []any{map[string]any{"index": 0, "message": map[string]any{"role": "assistant", "content": delivered}, "finish_reason": "stop"}}})
		if send(map[string]any{"type": "inference_response_chunk", "request_id": req.RequestID, "seq": 0, "data": string(raw)}) != nil {
			return
		}
		sent = 1
	}
	ts := time.Now().UTC().UnixMilli()
	end := map[string]any{"type": "inference_response_end", "request_id": req.RequestID, "status": "complete", "chunks_sent": sent,
		"usage":                     map[string]any{"prompt_tokens": promptTokens, "completion_tokens": n, "total_tokens": promptTokens + n, "cached_prompt_tokens": 0, "macprovider_model_hash_observed": p.identity().ModelHash},
		"terminal_state_ts_unix_ms": ts}
	if p.settlementEnabled && req.Settlement != nil && !knobBool(k, "omit_receipt", false) {
		receipt, err := p.buildSettlementReceiptHeader(*req.Settlement, delivered, "stop", promptTokens, int64(n), ts)
		if err != nil {
			logf("receipt build failed: %v", err)
		} else {
			end["receipt"] = receipt
			end["receipt_pending_deadline_seconds"] = req.Settlement.PendingDeadlineSeconds
			end["late_receipt_settlement"] = "not_settled"
			p.attachAttestation(end, receipt, req, promptTokens, n+1, k)
		}
	}
	_ = send(end)
}

// kickHeartbeat asks for an immediate heartbeat so the coordinator sees the
// head's free slots change at once, as a provider reports a slot change.
func (p *fakeProvider) kickHeartbeat() {
	select {
	case p.hbKick <- struct{}{}:
	default:
	}
}

func (p *fakeProvider) registerCancel(requestID string, ch chan struct{}) {
	if p.shard == nil {
		p.cancelMu.Lock()
		defer p.cancelMu.Unlock()
		if p.cancels == nil {
			p.cancels = map[string]chan struct{}{}
		}
		if ch == nil {
			delete(p.cancels, requestID)
		} else {
			p.cancels[requestID] = ch
		}
		return
	}
	p.shard.mu.Lock()
	defer p.shard.mu.Unlock()
	if ch == nil {
		delete(p.shard.cancels, requestID)
	} else {
		p.shard.cancels[requestID] = ch
	}
}

func (p *fakeProvider) cancelRequest(requestID string) {
	var ch chan struct{}
	if p.shard != nil {
		p.shard.mu.Lock()
		ch = p.shard.cancels[requestID]
		delete(p.shard.cancels, requestID)
		p.shard.mu.Unlock()
	} else {
		p.cancelMu.Lock()
		ch = p.cancels[requestID]
		delete(p.cancels, requestID)
		p.cancelMu.Unlock()
	}
	if ch != nil {
		close(ch)
	}
}

// sendCancelled answers a buyer cancel with the "cancelled" terminal frame,
// carrying a buyer_cancel receipt for the delivered prefix and its group
// attestation (SPEC-051-R019 item 1: verified like any other terminal).
func (p *fakeProvider) sendCancelled(send func(map[string]any) error, req wsInferenceRequest, delivered string, promptTokens, sent int, k map[string]any) {
	ts := time.Now().UTC().UnixMilli()
	end := map[string]any{"type": "inference_response_end", "request_id": req.RequestID, "status": "cancelled", "chunks_sent": sent,
		"usage":                     map[string]any{"prompt_tokens": promptTokens, "completion_tokens": sent, "total_tokens": promptTokens + sent},
		"terminal_state_ts_unix_ms": ts}
	if p.settlementEnabled && req.Settlement != nil && sent > 0 {
		receipt, err := p.buildSettlementReceiptHeaderState(*req.Settlement, delivered, "", int64(promptTokens), int64(sent), ts, "buyer_cancel")
		if err == nil {
			end["receipt"] = receipt
			p.attachAttestation(end, receipt, req, promptTokens, sent+1, k)
		}
	}
	_ = send(end)
}

// attachAttestation builds the SPEC-051-R019 group attestation for one
// receipt. stepEnd is the token steps the head received. The attest knob
// selects a well-formed attestation ("ok", the default) or one fault.
func (p *fakeProvider) attachAttestation(end map[string]any, receipt string, req wsInferenceRequest, promptTokens, stepEnd int, k map[string]any) {
	s := p.shard
	if s == nil || s.role != "head" {
		return
	}
	mode := knobString(k, "attest", "ok")
	s.mu.Lock()
	s.attestations[req.RequestID] = mode
	s.mu.Unlock()
	if mode == "missing" {
		return
	}
	att, err := p.buildAttestation(receipt, req, promptTokens, stepEnd, mode, k)
	if err != nil {
		logf("attestation build failed: %v", err)
		return
	}
	end["group_attestation"] = att
}

func digestHex(parts ...string) string {
	sum := sha256.Sum256([]byte(strings.Join(parts, "|")))
	return hex.EncodeToString(sum[:])
}

func (p *fakeProvider) buildAttestation(receipt string, req wsInferenceRequest, promptTokens, stepEnd int, mode string, k map[string]any) (map[string]any, error) {
	s := p.shard
	rec := s.snapshotRecord()
	s.mu.Lock()
	keys := map[string]string{}
	for id, f := range s.memberKeys {
		keys[id] = f
	}
	s.mu.Unlock()
	dot := strings.IndexByte(receipt, '.')
	tuple, err := base64.StdEncoding.DecodeString(receipt[:dot])
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(tuple)
	tupleSHA := hex.EncodeToString(sum[:])
	epoch := num(rec["group_epoch"])
	segEpoch := epoch
	if mode == "unknown_epoch" {
		segEpoch = epoch + 1000
	}
	stages := recordStages(rec)
	decodeSteps := stepEnd - 1
	if mode == "coverage_tokens_out" {
		// R3-A1 probe: the head claims fewer token steps than the receipt's
		// v0.4 usage counts; every sub-receipt agrees with that step count.
		stepEnd = 1
		decodeSteps = 0
	}
	// Activation digests chain: head out = member in, ..., last out = head in.
	chain := make([]string, len(stages)+1)
	for i := range chain {
		chain[i] = digestHex("e2e-2084-activation", req.Settlement.RequestID, fmt.Sprint(i))
	}
	chain[len(stages)] = chain[0]
	var subs []any
	for i, st := range stages {
		sr := map[string]any{"member_device_id": st.member, "group_epoch": segEpoch, "stage_index": st.index, "layer_start": st.layerStart, "layer_end": st.layerEnd,
			"request_id": req.Settlement.RequestID, "prompt_tokens": promptTokens, "decode_steps": decodeSteps, "in_digest": chain[i], "out_digest": chain[i+1]}
		if i == 1 && mode == "chain_break" {
			sr["in_digest"] = digestHex("e2e-2084-broken", req.Settlement.RequestID)
		}
		if i == 1 && mode == "coverage" {
			sr["decode_steps"] = decodeSteps + 1
		}
		if i == 1 && mode == "stage_mismatch" {
			sr["layer_end"] = st.layerEnd + 1
		}
		var priv ed25519.PrivateKey
		if i == 0 {
			priv = p.receiptPrivkey
		} else {
			kf, ok := keys[st.member]
			if !ok {
				return nil, fmt.Errorf("no receipt key file for member %s", st.member)
			}
			if priv, err = loadOrCreateAdmissionKey(kf); err != nil {
				return nil, err
			}
		}
		pub := base64.StdEncoding.EncodeToString(priv.Public().(ed25519.PublicKey))
		signer := priv
		if i == 1 && (mode == "member_signature" || mode == "wrong_key") {
			_, other, _ := ed25519.GenerateKey(nil)
			signer = other
			if mode == "wrong_key" {
				pub = base64.StdEncoding.EncodeToString(other.Public().(ed25519.PublicKey))
			}
		}
		sig, err := signDomain(signer, "macprovider.shard-sub-receipt.v1\n", sr)
		if err != nil {
			return nil, err
		}
		subs = append(subs, map[string]any{"sub_receipt": sr, "public_key": pub, "signature": sig})
	}
	var facts struct {
		RequestID string `json:"request_id"`
		AttemptN  int64  `json:"attempt_n"`
	}
	_ = json.Unmarshal(tuple, &facts)
	segment := map[string]any{"group_epoch": segEpoch, "step_start": 0, "step_end": stepEnd, "sub_receipts": subs}
	segments := []any{segment}
	if mode == "two_segments" {
		segments = append(segments, map[string]any{"group_epoch": segEpoch, "step_start": stepEnd, "step_end": stepEnd + 1, "sub_receipts": subs})
	}
	att := map[string]any{"schema": "macprovider.shard-group-attestation.v1", "group_provider_id": p.providerID, "request_id": facts.RequestID,
		"attempt_n": facts.AttemptN, "receipt_tuple_sha256": tupleSHA, "segments": segments}
	switch mode {
	case "receipt_mismatch":
		att["receipt_tuple_sha256"] = digestHex("not the receipt")
	case "takeover":
		att["takeover"] = map[string]any{"from_group_epoch": num(k["takeover_from_epoch"]), "reason": knobString(k, "takeover_reason", "peer_dead")}
		if _, ok := k["takeover_from_epoch"]; !ok {
			att["takeover"] = map[string]any{"from_group_epoch": epoch - 1, "reason": knobString(k, "takeover_reason", "peer_dead")}
		}
	case "takeover_bad_reason":
		att["takeover"] = map[string]any{"from_group_epoch": epoch - 1, "reason": "cosmic_ray"}
	}
	sig, err := signDomain(p.receiptPrivkey, "macprovider.shard-group-attestation.v1\n", att)
	if err != nil {
		return nil, err
	}
	if mode == "bad_head_signature" {
		_, other, _ := ed25519.GenerateKey(nil)
		sig, _ = signDomain(other, "macprovider.shard-group-attestation.v1\n", att)
	}
	att["signature"] = sig
	return att, nil
}
