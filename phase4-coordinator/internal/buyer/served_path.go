package buyer

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"sync/atomic"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// servedPathHeader is the SPEC-002-R007 served-path label on the internal
// coordinator-to-gateway hop. It is a telemetry label only: no value of it
// enters the performance store, routing, request_log, billing or settlement
// (SPEC-002-R005), and the gateway strips it before the buyer.
const servedPathHeader = "X-MacProvider-Internal-Served-Path"

const (
	servedPathMaxBytes = 128
	servedPathMaxRows  = 256
)

// servedPathRejectReasons are the closed reasons of
// macprovider_served_path_rejected_total, in exposition order.
var servedPathRejectReasons = []string{"decode", "shard_group", "profile", "engine", "rows"}

var servedPathRejectedTotal [5]atomic.Uint64

func countServedPathRejected(reason string) {
	for i, r := range servedPathRejectReasons {
		if r == reason {
			servedPathRejectedTotal[i].Add(1)
			return
		}
	}
}

func writeServedPathMetrics(w io.Writer) {
	_, _ = fmt.Fprint(w, "# HELP macprovider_served_path_rejected_total Provider served-path reports labelled unknown (SPEC-002-R007).\n# TYPE macprovider_served_path_rejected_total counter\n")
	for i, reason := range servedPathRejectReasons {
		_, _ = fmt.Fprintf(w, "macprovider_served_path_rejected_total{reason=%q} %d\n", reason, servedPathRejectedTotal[i].Load())
	}
}

// servedPathValue renders the SPEC-002-R007 value for a provider report,
// checked for consistency with the provider's own self-reported R006
// profile and shard-group advertisement as recorded at dispatch. It returns
// "" when the provider sent no report. A report that does not decode or
// contradicts that record renders path=unknown; it never fails the request.
func servedPathValue(provider pool.Provider, end providerws.InferenceResponseEnd) string {
	raw := bytes.TrimSpace(end.ServedPath)
	if len(raw) == 0 || bytes.Equal(raw, []byte("null")) {
		return ""
	}
	path, rows, reason := checkServedPath(provider, end, raw)
	if reason != "" {
		countServedPathRejected(reason)
		return "v=1; path=unknown; rows=unknown"
	}
	return "v=1; path=" + path + "; rows=" + strconv.FormatInt(rows, 10)
}

// decodeServedPath walks the object token by token: exactly the members
// "path" (a string) and "rows" (an integer), each once, with exact names.
// encoding/json alone would fold key case and keep the last duplicate.
func decodeServedPath(raw []byte) (string, int64, bool) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	if tok, err := dec.Token(); err != nil || tok != json.Delim('{') {
		return "", 0, false
	}
	var path *string
	var rows *int64
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return "", 0, false
		}
		switch tok {
		case "path":
			if path != nil || dec.Decode(&path) != nil || path == nil {
				return "", 0, false
			}
		case "rows":
			if rows != nil || dec.Decode(&rows) != nil || rows == nil {
				return "", 0, false
			}
		default:
			return "", 0, false
		}
	}
	if tok, err := dec.Token(); err != nil || tok != json.Delim('}') || path == nil || rows == nil {
		return "", 0, false
	}
	if _, err := dec.Token(); err != io.EOF {
		return "", 0, false
	}
	return *path, *rows, true
}

func checkServedPath(provider pool.Provider, end providerws.InferenceResponseEnd, raw []byte) (string, int64, string) {
	if len(raw) > servedPathMaxBytes {
		return "", 0, "decode"
	}
	path, rows, ok := decodeServedPath(raw)
	if !ok {
		return "", 0, "decode"
	}
	switch path {
	case "serial", "continuous_batching", "native_mtp", "shard_group":
	default:
		return "", 0, "decode"
	}
	if rows < 1 || rows > servedPathMaxRows {
		return "", 0, "decode"
	}
	if provider.ShardGroupHeadV1 != (path == "shard_group") {
		return "", 0, "shard_group"
	}
	if path == "shard_group" {
		if !end.ShardGroupAttestationVerified {
			return "", 0, "shard_group"
		}
		return path, rows, ""
	}
	profile := provider.EngineProfile
	if profile == nil {
		return "", 0, "profile"
	}
	switch path {
	case "native_mtp":
		if profile.EngineFamily != "native_mtp" || !profile.NativeMTPActive {
			return "", 0, "engine"
		}
	case "continuous_batching":
		if profile.EngineFamily != "continuous_batching" && profile.EngineFamily != "native_mtp" {
			return "", 0, "engine"
		}
	}
	limit := int64(1)
	if path != "serial" && profile.CBGrantedSlots > 1 {
		limit = int64(profile.CBGrantedSlots)
	}
	if rows > limit {
		return "", 0, "rows"
	}
	return path, rows, ""
}

// servedPathFor is the value of a provider's terminal frame, or "". Only a
// complete frame on a request that carries the gateway's internal bearer
// has one, so a client calling the coordinator directly never receives it.
// The value is not written here: acceptServedPath writes it once the
// coordinator has accepted the attempt as its successful response.
func (s *Server) servedPathFor(r *http.Request, provider pool.Provider, end providerws.InferenceResponseEnd) string {
	if end.Status != "complete" {
		return ""
	}
	if auth.GatewayInternalBearerMatches(r.Header, s.gatewayServiceToken) == auth.BearerKindNone {
		return ""
	}
	return servedPathValue(provider, end)
}

// acceptServedPath writes the value of the attempt the coordinator is about
// to deliver as its successful response, after every post-end check and
// pool-cancel boundary, so an error response or a re-dispatched attempt
// never carries it. It follows the X-MacProvider-Timing-Provider-Decode-Ms
// rule: a header before the response is committed, a trailer after.
func acceptServedPath(h http.Header, value string, committed bool) {
	if value == "" {
		return
	}
	if committed {
		h.Set(http.TrailerPrefix+servedPathHeader, value)
		return
	}
	h.Set(servedPathHeader, value)
}
