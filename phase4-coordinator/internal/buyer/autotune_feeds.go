package buyer

import (
	"net/http"
	"os"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

// AutotuneFeeds holds the literal signed bytes for SPEC-023 recommendation
// inputs. Served on the buyer mux at /v1/demand-rank(+ .sig) and
// /v1/autotune-candidates(+ .sig), replacing nginx /static/* hosting.
type AutotuneFeeds struct {
	DemandRankJSON         []byte
	DemandRankSig          []byte
	AutotuneCandidatesJSON []byte
	AutotuneCandidatesSig  []byte
}

func (f AutotuneFeeds) demandRankEnabled() bool {
	return len(f.DemandRankJSON) > 0 && len(f.DemandRankSig) > 0
}

func (f AutotuneFeeds) autotuneCandidatesEnabled() bool {
	return len(f.AutotuneCandidatesJSON) > 0 && len(f.AutotuneCandidatesSig) > 0
}

// LoadAutotuneFeeds reads signed feed files from cfg paths. Empty paths
// disable that feed (handler returns 404). When a JSON path is set, its
// matching .sig path must also be set and both files must exist.
func LoadAutotuneFeeds(cfg config.AutotuneFeedsConfig) (AutotuneFeeds, error) {
	var out AutotuneFeeds
	var err error
	if out.DemandRankJSON, out.DemandRankSig, err = loadAutotuneFeedPair(
		cfg.DemandRankPath, cfg.DemandRankSigPath, "demand_rank",
	); err != nil {
		return AutotuneFeeds{}, err
	}
	if out.AutotuneCandidatesJSON, out.AutotuneCandidatesSig, err = loadAutotuneFeedPair(
		cfg.AutotuneCandidatesPath, cfg.AutotuneCandidatesSigPath, "autotune_candidates",
	); err != nil {
		return AutotuneFeeds{}, err
	}
	return out, nil
}

func loadAutotuneFeedPair(jsonPath, sigPath, label string) ([]byte, []byte, error) {
	jsonPath = strings.TrimSpace(jsonPath)
	sigPath = strings.TrimSpace(sigPath)
	if jsonPath == "" && sigPath == "" {
		return nil, nil, nil
	}
	if jsonPath == "" || sigPath == "" {
		return nil, nil, configPairError(label)
	}
	jsonBytes, err := os.ReadFile(jsonPath)
	if err != nil {
		return nil, nil, err
	}
	sigBytes, err := os.ReadFile(sigPath)
	if err != nil {
		return nil, nil, err
	}
	if len(jsonBytes) == 0 || len(sigBytes) == 0 {
		return nil, nil, configEmptyFeedError(label)
	}
	return jsonBytes, sigBytes, nil
}

type configFeedError string

func (e configFeedError) Error() string { return string(e) }

func configPairError(label string) error {
	return configFeedError("autotune." + label + "_path and autotune." + label + "_sig_path must both be set")
}

func configEmptyFeedError(label string) error {
	return configFeedError("autotune." + label + " feed file is empty")
}

func WithAutotuneFeeds(feeds AutotuneFeeds) Option {
	return func(s *Server) {
		s.autotuneFeedsMu.Lock()
		defer s.autotuneFeedsMu.Unlock()
		s.autotuneFeeds = feeds
	}
}

func (s *Server) autotuneFeedsSnapshot() AutotuneFeeds {
	s.autotuneFeedsMu.RLock()
	defer s.autotuneFeedsMu.RUnlock()
	return s.autotuneFeeds
}

func (s *Server) handleDemandRank(w http.ResponseWriter, r *http.Request) {
	feeds := s.autotuneFeedsSnapshot()
	s.serveAutotuneFeedBytes(w, r, feeds.DemandRankJSON, feeds.demandRankEnabled())
}

func (s *Server) handleDemandRankSig(w http.ResponseWriter, r *http.Request) {
	feeds := s.autotuneFeedsSnapshot()
	s.serveAutotuneFeedBytes(w, r, feeds.DemandRankSig, feeds.demandRankEnabled())
}

func (s *Server) handleAutotuneCandidates(w http.ResponseWriter, r *http.Request) {
	feeds := s.autotuneFeedsSnapshot()
	s.serveAutotuneFeedBytes(w, r, feeds.AutotuneCandidatesJSON, feeds.autotuneCandidatesEnabled())
}

func (s *Server) handleAutotuneCandidatesSig(w http.ResponseWriter, r *http.Request) {
	feeds := s.autotuneFeedsSnapshot()
	s.serveAutotuneFeedBytes(w, r, feeds.AutotuneCandidatesSig, feeds.autotuneCandidatesEnabled())
}

func (s *Server) serveAutotuneFeedBytes(w http.ResponseWriter, r *http.Request, body []byte, enabled bool) {
	if !s.allowReceiptKeys(r) {
		w.Header().Set("Retry-After", "1")
		writeError(w, http.StatusTooManyRequests, "rate_limited", "Autotune feed endpoint rate limit exceeded")
		return
	}
	if !enabled {
		writeError(w, http.StatusNotFound, "autotune_feed_not_found", "Autotune feed not found")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "public, max-age=300")
	if _, err := w.Write(body); err != nil {
		s.log.Warn().Err(err).Msg("write autotune feed response failed")
	}
}
