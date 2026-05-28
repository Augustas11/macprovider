package ws

import "testing"

func TestParseNakAcceptsSwiftSpecShape(t *testing.T) {
	payload := []byte(`{"type":"nak","in_reply_to":"req-nak","error":{"code":"unknown_message_type","message":"Unrecognized message type: 'inference_request'"}}`)

	nak, field, err := ParseNak(payload)
	if err != nil {
		t.Fatalf("ParseNak field=%q err=%v", field, err)
	}
	if nak.Type != "nak" {
		t.Fatalf("type = %q", nak.Type)
	}
	if nak.InReplyTo != "req-nak" {
		t.Fatalf("in_reply_to = %q", nak.InReplyTo)
	}
	if nak.Error.Code != "unknown_message_type" {
		t.Fatalf("error.code = %q", nak.Error.Code)
	}
	if nak.Error.Message != "Unrecognized message type: 'inference_request'" {
		t.Fatalf("error.message = %q", nak.Error.Message)
	}
}

func TestParseHeartbeatPreservesRollingMetrics(t *testing.T) {
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"mlx-community/Qwen2.5-7B-Instruct-4bit","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5}`)

	hb, field, err := ParseHeartbeat(payload)
	if err != nil {
		t.Fatalf("ParseHeartbeat field=%q err=%v", field, err)
	}
	if hb.RequestsServedSinceLast != 12 {
		t.Fatalf("requests_served_since_last = %d", hb.RequestsServedSinceLast)
	}
	if hb.AvgLatencyMSSinceLast != 450.0 {
		t.Fatalf("avg_latency_ms_since_last = %v", hb.AvgLatencyMSSinceLast)
	}
	if hb.ThroughputTPSSinceLast != 18.5 {
		t.Fatalf("throughput_tps_since_last = %v", hb.ThroughputTPSSinceLast)
	}
}
