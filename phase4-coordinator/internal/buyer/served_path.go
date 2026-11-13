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

type servedPathReport struct {
	Path *string `json:"path"`
	Rows *int64  `json:"rows"`
}

// servedPathValue renders the SPEC-002-R007 value for a provider report,
// checked for consistency with the provider's own self-reported R006
// profile and shard-group advertisement as recorded at dispatch. It returns
// "" when the provider sent no report. A report that does not decode or
// contradicts that record renders path=unknown; it never fails the frame.
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

func checkServedPath(provider pool.Provider, end providerws.InferenceResponseEnd, raw []byte) (string, int64, string) {
	if len(raw) > servedPathMaxBytes {
		return "", 0, "decode"
	}
	var report servedPathReport
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&report); err != nil || report.Path == nil || report.Rows == nil {
		return "", 0, "decode"
	}
	if _, err := dec.Token(); err != io.EOF {
		return "", 0, "decode"
	}
	path, rows := *report.Path, *report.Rows
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

// noteServedPath records the value for a completed plaintext attempt. Only
// a request that carries the gateway's internal bearer gets one, so a client
// calling the coordinator directly never receives it.
func (s *Server) noteServedPath(r *http.Request, state *forwardState, provider pool.Provider, end providerws.InferenceResponseEnd) {
	if state == nil || end.Status != "complete" {
		return
	}
	if auth.GatewayInternalBearerMatches(r.Header, s.gatewayServiceToken) == auth.BearerKindNone {
		return
	}
	state.servedPath = servedPathValue(provider, end)
}

// beginServedPathAttempt drops an earlier attempt's value before the next
// dispatch, so the value always describes the provider that served.
func beginServedPathAttempt(h http.Header, state *forwardState) {
	if state != nil {
		state.servedPath = ""
	}
	h.Del(servedPathHeader)
}
