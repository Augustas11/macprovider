#!/usr/bin/env bash
set -euo pipefail

if [ "${MACPROVIDER_HTTP2_LIVE:-}" != "1" ]; then
  if [ "${MACPROVIDER_HTTP2_LIVE_OPTIONAL:-}" = "1" ]; then
    echo "skip: MACPROVIDER_HTTP2_LIVE_OPTIONAL=1 - #379 live HTTP/2 smoke/bench not exercised in this run"
    exit 0
  fi
  echo "FAIL: MACPROVIDER_HTTP2_LIVE is unset (set MACPROVIDER_HTTP2_LIVE=1 to probe live nginx, or pass MACPROVIDER_HTTP2_LIVE_OPTIONAL=1 to opt out)" >&2
  exit 1
fi

command -v curl >/dev/null || {
  echo "FAIL: curl is required for #379 live HTTP/2 checks" >&2
  exit 1
}
command -v python3 >/dev/null || {
  echo "FAIL: python3 is required for #379 live HTTP/2 checks" >&2
  exit 1
}

GATEWAY_URL="${MACPROVIDER_HTTP2_GATEWAY_URL:-https://api.malibu.tech}"
GATEWAY_ORIGIN="${GATEWAY_URL%/}"
CURL_CONNECT_TIMEOUT="${MACPROVIDER_HTTP2_CONNECT_TIMEOUT:-10}"
CURL_HEALTH_MAX_TIME="${MACPROVIDER_HTTP2_HEALTH_MAX_TIME:-20}"
CURL_MODELS_MAX_TIME="${MACPROVIDER_HTTP2_MODELS_MAX_TIME:-30}"
CHAT_MAX_TIME="${MACPROVIDER_HTTP2_CHAT_MAX_TIME:-120}"
ENV_API_KEY="${MACPROVIDER_HTTP2_API_KEY:-}"
ENV_API_KEY_FILE="${MACPROVIDER_HTTP2_API_KEY_FILE:-}"
ENV_GENERIC_API_KEY="${MP_API_KEY:-${BUYER_TOKEN:-}}"
unset MACPROVIDER_HTTP2_API_KEY MACPROVIDER_HTTP2_API_KEY_FILE MP_API_KEY BUYER_TOKEN
TMPDIR="$(mktemp -d -t macprovider-http2-live.XXXXXX)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

parse_meta() {
  local key="$1"
  local file="$2"
  awk -F= -v key="$key" '$1 == key { print $2 }' "$file"
}

host_port_from_url() {
  python3 - "$GATEWAY_ORIGIN" <<'PY'
from urllib.parse import urlparse
import sys

url = urlparse(sys.argv[1])
if url.scheme != "https" or not url.hostname:
    raise SystemExit("FAIL: MACPROVIDER_HTTP2_GATEWAY_URL must be an https URL")
port = url.port or 443
print(f"{url.hostname}:{port}")
PY
}

host_from_url() {
  python3 - "$GATEWAY_ORIGIN" <<'PY'
from urllib.parse import urlparse
import sys

url = urlparse(sys.argv[1])
if url.scheme != "https" or not url.hostname:
    raise SystemExit("FAIL: MACPROVIDER_HTTP2_GATEWAY_URL must be an https URL")
print(url.hostname)
PY
}

health_body="$TMPDIR/health.body"
health_meta="$TMPDIR/health.meta"
curl --http2 -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_HEALTH_MAX_TIME" -o "$health_body" \
  -w 'http_version=%{http_version}\nhttp_code=%{http_code}\ntime_total=%{time_total}\n' \
  "$GATEWAY_ORIGIN/healthz" >"$health_meta"

health_version="$(parse_meta http_version "$health_meta")"
health_code="$(parse_meta http_code "$health_meta")"
if [ "$health_version" != "2" ]; then
  echo "FAIL: /healthz negotiated HTTP/$health_version, want HTTP/2" >&2
  exit 1
fi
if [ "$health_code" != "200" ]; then
  echo "FAIL: /healthz returned status $health_code, want 200" >&2
  exit 1
fi
echo "ok: $GATEWAY_ORIGIN/healthz negotiated HTTP/2 and returned 200"

host="$(host_from_url)"
host_port="$(host_port_from_url)"
python3 - "$host" "$host_port" "$CURL_CONNECT_TIMEOUT" <<'PY'
import socket
import ssl
import sys

host = sys.argv[1]
host_port = sys.argv[2]
timeout = float(sys.argv[3])
if ":" in host_port:
    _, raw_port = host_port.rsplit(":", 1)
else:
    raw_port = "443"
context = ssl.create_default_context()
context.set_alpn_protocols(["h2"])
try:
    with socket.create_connection((host, int(raw_port)), timeout=timeout) as sock:
        with context.wrap_socket(sock, server_hostname=host) as tls:
            protocol = tls.selected_alpn_protocol()
except OSError as exc:
    raise SystemExit(f"FAIL: TLS ALPN probe failed: {exc}")
if protocol != "h2":
    raise SystemExit(f"FAIL: TLS ALPN probe negotiated {protocol!r}, want 'h2'")
print("ok: TLS ALPN negotiated h2")
PY

run_transport_bench="${MACPROVIDER_HTTP2_RUN_TRANSPORT_BENCH:-${MACPROVIDER_HTTP2_RUN_BENCH:-}}"
run_chat_bench="${MACPROVIDER_HTTP2_RUN_CHAT_BENCH:-}"
if [ "$run_transport_bench" != "1" ] && [ "$run_chat_bench" != "1" ] && [ "${MACPROVIDER_HTTP2_RUN_SSE:-}" != "1" ]; then
  echo "skip: authenticated point/parallel bench and SSE compatibility checks not requested"
  exit 0
fi

API_KEY="$ENV_API_KEY"
if [ -z "$API_KEY" ] && [ -n "$ENV_API_KEY_FILE" ]; then
  API_KEY="$(tr -d '\n' < "$ENV_API_KEY_FILE")"
fi
if [ -z "$API_KEY" ]; then
  if [ "$GATEWAY_ORIGIN" != "https://api.malibu.tech" ] && [ "${MACPROVIDER_HTTP2_ALLOW_GENERIC_KEY_FOR_CUSTOM_GATEWAY:-}" != "1" ]; then
    echo "FAIL: non-default gateway URLs require MACPROVIDER_HTTP2_API_KEY_FILE or MACPROVIDER_HTTP2_API_KEY (or MACPROVIDER_HTTP2_ALLOW_GENERIC_KEY_FOR_CUSTOM_GATEWAY=1)" >&2
    exit 1
  fi
  API_KEY="$ENV_GENERIC_API_KEY"
  if [ -z "$API_KEY" ] && [ -n "${HOME:-}" ] && [ -s "$HOME/.config/macprovider/buyer-api-key" ]; then
    API_KEY="$(tr -d '\n' < "$HOME/.config/macprovider/buyer-api-key")"
  fi
fi

if [ -z "$API_KEY" ]; then
  echo "FAIL: authenticated #379 checks require MACPROVIDER_HTTP2_API_KEY_FILE, MACPROVIDER_HTTP2_API_KEY, MP_API_KEY, BUYER_TOKEN, or ~/.config/macprovider/buyer-api-key" >&2
  exit 1
fi

auth_curl_config="$TMPDIR/auth.curlrc"
api_key_file="$TMPDIR/api-key"
printf '%s' "$API_KEY" >"$api_key_file"
printf 'header = "Authorization: Bearer %s"\n' "$API_KEY" >"$auth_curl_config"
chmod 600 "$api_key_file" "$auth_curl_config"

model="${MACPROVIDER_HTTP2_MODEL:-}"
models_json="$TMPDIR/models.json"
curl --config "$auth_curl_config" --http2 -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MODELS_MAX_TIME" -o "$models_json" \
  "$GATEWAY_ORIGIN/v1/models"
if [ -z "$model" ] && { [ "$run_chat_bench" = "1" ] || [ "${MACPROVIDER_HTTP2_RUN_SSE:-}" = "1" ]; }; then
  model="$(python3 - "$models_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    payload = json.load(fh)
data = payload.get("data") or []
if not data or not data[0].get("id"):
    raise SystemExit("FAIL: /v1/models returned no model ids; set MACPROVIDER_HTTP2_MODEL to the live provider model id")
print(data[0]["id"])
PY
)"
fi
if [ -n "$model" ]; then
  echo "ok: using model $model for authenticated #379 probes"
else
  echo "ok: authenticated /v1/models available for #379 transport benchmark"
fi

assert_chat_bench_capacity() {
  if [ "${MACPROVIDER_HTTP2_ALLOW_LOW_CAPACITY_CHAT_BENCH:-}" = "1" ]; then
    return 0
  fi
  python3 - "$models_json" "$model" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    payload = json.load(fh)
model = sys.argv[2]
data = payload.get("data") or []
for row in data:
    if row.get("id") == model:
        slots = int(row.get("total_slots") or 0)
        if slots < 8:
            raise SystemExit(
                "FAIL: MACPROVIDER_HTTP2_RUN_CHAT_BENCH=1 requires the selected model "
                f"to advertise total_slots >= 8 for the issue #379 8-request fan-out; "
                f"{model} advertises total_slots={slots}. Bring enough providers/slots online "
                "or set MACPROVIDER_HTTP2_ALLOW_LOW_CAPACITY_CHAT_BENCH=1 to run the "
                "negative-capacity check anyway."
            )
        print(f"ok: selected model {model} advertises total_slots={slots} for #379 chat benchmark")
        raise SystemExit(0)
raise SystemExit(f"FAIL: selected model {model} was not present in /v1/models")
PY
}

write_payload() {
  local stream="$1"
  local path="$2"
  python3 - "$model" "$stream" >"$path" <<'PY'
import json
import sys

model = sys.argv[1]
stream = sys.argv[2] == "true"
payload = {
    "model": model,
    "max_tokens": 8,
    "temperature": 0,
    "stream": stream,
    "messages": [
        {
            "role": "user",
            "content": "Reply with the single word ok.",
        }
    ],
}
json.dump(payload, sys.stdout, separators=(",", ":"))
PY
}

chat_payload="$TMPDIR/chat.json"
stream_payload="$TMPDIR/stream.json"
write_payload false "$chat_payload"
write_payload true "$stream_payload"

run_shared_connection_bench() {
  local target="$1"
  local label="$2"

  command -v go >/dev/null || {
    echo "FAIL: go is required for #379 shared-connection benchmark" >&2
    exit 1
  }

  bench_go="$TMPDIR/http2_shared_connection_bench.go"
  cat >"$bench_go" <<'GO'
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptrace"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

type benchmark struct {
	target  string
	method  string
	path    string
	payload []byte
}

type result struct {
	label    string
	proto    string
	status   int
	duration time.Duration
	conn     string
	body     string
	err      error
}

const maxBenchmarkResponseBytes = 1 << 20

type summary struct {
	count  int
	min    time.Duration
	median time.Duration
	p95    time.Duration
	max    time.Duration
}

func getenv(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "FAIL: "+format+"\n", args...)
	os.Exit(1)
}

func newClient(forceH2 bool, timeout time.Duration) *http.Client {
	tr := &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		MaxIdleConns:          100,
		MaxIdleConnsPerHost:   100,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		ForceAttemptHTTP2:     forceH2,
	}
	if !forceH2 {
		// #379 is about shared-connection head-of-line blocking. Constrain
		// the forced HTTP/1.1 comparison to one connection so the benchmark
		// does not hide that cost behind eight parallel TCP connections.
		tr.TLSNextProto = map[string]func(string, *tls.Conn) http.RoundTripper{}
		tr.MaxConnsPerHost = 1
		tr.MaxIdleConnsPerHost = 1
	}
	return &http.Client{Transport: tr, Timeout: timeout}
}

func makeChatPayload(model string) []byte {
	payload := map[string]any{
		"model":       model,
		"max_tokens":  8,
		"temperature": 0,
		"stream":      false,
		"messages": []map[string]string{
			{"role": "user", "content": "Reply with the single word ok."},
		},
	}
	out, err := json.Marshal(payload)
	if err != nil {
		fail("marshal payload: %v", err)
	}
	return out
}

func benchmarkFromEnv() benchmark {
	target := getenv("MACPROVIDER_HTTP2_BENCH_TARGET", "models")
	switch target {
	case "models":
		return benchmark{target: target, method: http.MethodGet, path: "/v1/models"}
	case "chat":
		model := os.Getenv("MACPROVIDER_HTTP2_MODEL")
		if model == "" {
			fail("MACPROVIDER_HTTP2_MODEL is required for chat benchmark")
		}
		return benchmark{target: target, method: http.MethodPost, path: "/v1/chat/completions", payload: makeChatPayload(model)}
	default:
		fail("invalid MACPROVIDER_HTTP2_BENCH_TARGET %q", target)
		return benchmark{}
	}
}

func doBenchmarkRequest(ctx context.Context, client *http.Client, origin, apiKey string, bench benchmark, label string) result {
	start := time.Now()
	var conn string
	trace := &httptrace.ClientTrace{
		GotConn: func(info httptrace.GotConnInfo) {
			if info.Conn != nil {
				conn = info.Conn.LocalAddr().String()
			}
		},
	}
	ctx = httptrace.WithClientTrace(ctx, trace)
	var body io.Reader
	if bench.payload != nil {
		body = bytes.NewReader(bench.payload)
	}
	req, err := http.NewRequestWithContext(ctx, bench.method, strings.TrimRight(origin, "/")+bench.path, body)
	if err != nil {
		return result{label: label, err: err}
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	if bench.payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := client.Do(req)
	if err != nil {
		return result{label: label, duration: time.Since(start), err: err}
	}
	defer resp.Body.Close()
	bodyBytes, readErr := io.ReadAll(io.LimitReader(resp.Body, maxBenchmarkResponseBytes))
	return result{
		label:    label,
		proto:    resp.Proto,
		status:   resp.StatusCode,
		duration: time.Since(start),
		conn:     conn,
		body:     string(bodyBytes),
		err:      readErr,
	}
}

func requireOK(res result, wantProto string, bench benchmark) {
	if res.err != nil {
		fail("%s request failed: %v", res.label, res.err)
	}
	if res.status != http.StatusOK {
		fail("%s request returned status %d\n%s", res.label, res.status, res.body)
	}
	if res.proto != wantProto {
		fail("%s request used %s, want %s", res.label, res.proto, wantProto)
	}
	switch bench.target {
	case "models":
		var payload struct {
			Object string            `json:"object"`
			Data   []json.RawMessage `json:"data"`
		}
		if err := json.Unmarshal([]byte(res.body), &payload); err != nil {
			fail("%s response was not valid JSON: %v\n%s", res.label, err, res.body)
		}
		if payload.Object != "list" || payload.Data == nil {
			fail("%s response did not include OpenAI-compatible models list\n%s", res.label, res.body)
		}
	case "chat":
		var payload struct {
			Choices []struct {
				Message struct {
					Content string `json:"content"`
				} `json:"message"`
			} `json:"choices"`
		}
		if err := json.Unmarshal([]byte(res.body), &payload); err != nil {
			fail("%s response was not valid JSON: %v\n%s", res.label, err, res.body)
		}
		if len(payload.Choices) == 0 || payload.Choices[0].Message.Content == "" {
			fail("%s response did not include non-empty choices[0].message.content\n%s", res.label, res.body)
		}
	}
}

func summarize(results []result) summary {
	if len(results) == 0 {
		fail("no benchmark results to summarize")
	}
	values := make([]time.Duration, 0, len(results))
	for _, res := range results {
		values = append(values, res.duration)
	}
	sort.Slice(values, func(i, j int) bool { return values[i] < values[j] })
	p95Index := int(float64(len(values))*0.95 + 0.999999) - 1
	if p95Index < 0 {
		p95Index = 0
	}
	if p95Index >= len(values) {
		p95Index = len(values) - 1
	}
	return summary{
		count:  len(values),
		min:    values[0],
		median: values[len(values)/2],
		p95:    values[p95Index],
		max:    values[len(values)-1],
	}
}

func printSummary(label, proto string, s summary) {
	fmt.Printf("ok: %s %s count=%d min=%.3fs median=%.3fs p95=%.3fs max=%.3fs\n",
		label, proto, s.count, s.min.Seconds(), s.median.Seconds(), s.p95.Seconds(), s.max.Seconds())
}

func runParallel(ctx context.Context, client *http.Client, origin, apiKey string, bench benchmark, label, wantProto string) []result {
	results := make([]result, 8)
	var wg sync.WaitGroup
	for i := range results {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			results[i] = doBenchmarkRequest(ctx, client, origin, apiKey, bench, fmt.Sprintf("%s-%d", label, i+1))
		}(i)
	}
	wg.Wait()
	for _, res := range results {
		requireOK(res, wantProto, bench)
	}
	conns := map[string]bool{}
	for _, res := range results {
		if res.conn == "" {
			fail("%s did not record a client connection", res.label)
		}
		conns[res.conn] = true
	}
	if len(conns) != 1 {
		fail("%s used %d client connections, want 1 shared connection", label, len(conns))
	}
	return results
}

func main() {
	origin := os.Getenv("MACPROVIDER_HTTP2_GATEWAY_URL")
	apiKeyFile := os.Getenv("MACPROVIDER_HTTP2_API_KEY_FILE")
	if origin == "" || apiKeyFile == "" {
		fail("MACPROVIDER_HTTP2_GATEWAY_URL and MACPROVIDER_HTTP2_API_KEY_FILE are required")
	}
	rawAPIKey, err := os.ReadFile(apiKeyFile)
	if err != nil {
		fail("read MACPROVIDER_HTTP2_API_KEY_FILE: %v", err)
	}
	apiKey := strings.TrimSpace(string(rawAPIKey))
	if apiKey == "" {
		fail("MACPROVIDER_HTTP2_API_KEY_FILE is empty")
	}
	timeout, err := time.ParseDuration(getenv("MACPROVIDER_HTTP2_CHAT_MAX_TIME", "120") + "s")
	if err != nil {
		fail("invalid MACPROVIDER_HTTP2_CHAT_MAX_TIME: %v", err)
	}
	pointFactor := 1.20
	if raw := os.Getenv("MACPROVIDER_HTTP2_POINT_REGRESSION_FACTOR"); raw != "" {
		if _, err := fmt.Sscanf(raw, "%f", &pointFactor); err != nil || pointFactor < 1 {
			fail("invalid MACPROVIDER_HTTP2_POINT_REGRESSION_FACTOR: %q", raw)
		}
	}

	ctx := context.Background()
	h2Client := newClient(true, timeout)
	h1Client := newClient(false, timeout)
	bench := benchmarkFromEnv()
	label := getenv("MACPROVIDER_HTTP2_BENCH_LABEL", bench.target)

	h2Point := doBenchmarkRequest(ctx, h2Client, origin, apiKey, bench, "h2-point")
	requireOK(h2Point, "HTTP/2.0", bench)
	h1Point := doBenchmarkRequest(ctx, h1Client, origin, apiKey, bench, "h1-point")
	requireOK(h1Point, "HTTP/1.1", bench)
	printSummary(label+" point request", "HTTP/2", summarize([]result{h2Point}))
	printSummary(label+" point request", "HTTP/1.1", summarize([]result{h1Point}))

	h2Parallel := runParallel(ctx, h2Client, origin, apiKey, bench, "h2-parallel", "HTTP/2.0")
	h1Parallel := runParallel(ctx, h1Client, origin, apiKey, bench, "h1-parallel", "HTTP/1.1")
	h2Summary := summarize(h2Parallel)
	h1Summary := summarize(h1Parallel)
	printSummary(label+" parallel 8-request", "HTTP/2", h2Summary)
	printSummary(label+" parallel 8-request", "HTTP/1.1", h1Summary)

	if h2Summary.p95 >= h1Summary.p95 {
		fail("%s parallel HTTP/2 p95 %.3fs is not lower than HTTP/1.1 p95 %.3fs", label, h2Summary.p95.Seconds(), h1Summary.p95.Seconds())
	}
	if h2Point.duration > time.Duration(float64(h1Point.duration)*pointFactor) {
		fail("%s point HTTP/2 %.3fs regressed beyond %.2fx HTTP/1.1 %.3fs", label, h2Point.duration.Seconds(), pointFactor, h1Point.duration.Seconds())
	}
}
GO

  bench_bin="$TMPDIR/http2_shared_connection_bench"
  go build -o "$bench_bin" "$bench_go"

  MACPROVIDER_HTTP2_GATEWAY_URL="$GATEWAY_ORIGIN" \
    MACPROVIDER_HTTP2_API_KEY_FILE="$api_key_file" \
    MACPROVIDER_HTTP2_MODEL="$model" \
    MACPROVIDER_HTTP2_BENCH_TARGET="$target" \
    MACPROVIDER_HTTP2_BENCH_LABEL="$label" \
    MACPROVIDER_HTTP2_CHAT_MAX_TIME="$CHAT_MAX_TIME" \
    MACPROVIDER_HTTP2_POINT_REGRESSION_FACTOR="${MACPROVIDER_HTTP2_POINT_REGRESSION_FACTOR:-1.20}" \
    "$bench_bin"
}

if [ "$run_transport_bench" = "1" ]; then
  run_shared_connection_bench models transport
else
  echo "skip: MACPROVIDER_HTTP2_RUN_TRANSPORT_BENCH is not 1 - authenticated transport bench not exercised"
fi

if [ "$run_chat_bench" = "1" ]; then
  if [ -z "$model" ]; then
    echo "FAIL: MACPROVIDER_HTTP2_RUN_CHAT_BENCH=1 requires MACPROVIDER_HTTP2_MODEL or a non-empty /v1/models response" >&2
    exit 1
  fi
  assert_chat_bench_capacity
  run_shared_connection_bench chat chat
else
  echo "skip: MACPROVIDER_HTTP2_RUN_CHAT_BENCH is not 1 - authenticated chat point/parallel bench not exercised"
fi

if [ "${MACPROVIDER_HTTP2_RUN_SSE:-}" = "1" ]; then
  sse_headers="$TMPDIR/sse.headers"
  sse_body="$TMPDIR/sse.body"
  sse_meta="$TMPDIR/sse.meta"
  curl --http2 -sS -N --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "${MACPROVIDER_HTTP2_SSE_MAX_TIME:-120}" \
    --config "$auth_curl_config" \
    -D "$sse_headers" -o "$sse_body" \
    -w 'http_version=%{http_version}\nhttp_code=%{http_code}\ntime_total=%{time_total}\n' \
    -H "Content-Type: application/json" \
    --data-binary "@$stream_payload" \
    "$GATEWAY_ORIGIN/v1/chat/completions" >"$sse_meta"
  sse_code="$(parse_meta http_code "$sse_meta")"
  if [ "$sse_code" != "200" ]; then
    echo "FAIL: SSE probe returned status $sse_code" >&2
    sed -n '1,20p' "$sse_body" >&2
    exit 1
  fi
  sse_version="$(parse_meta http_version "$sse_meta")"
  if [ "$sse_version" != "2" ]; then
    echo "FAIL: SSE probe used HTTP/$sse_version, want HTTP/2" >&2
    exit 1
  fi
  if ! grep -qi '^content-type: text/event-stream' "$sse_headers"; then
    echo "FAIL: SSE probe did not return text/event-stream" >&2
    exit 1
  fi
  if ! grep -q 'data: \[DONE\]' "$sse_body"; then
    echo "FAIL: SSE probe did not complete with data: [DONE]" >&2
    exit 1
  fi
  echo "ok: curl HTTP/2 SSE stream returned text/event-stream and data: [DONE]"
else
  echo "skip: MACPROVIDER_HTTP2_RUN_SSE is not 1 - curl SSE compatibility probe not exercised"
fi
