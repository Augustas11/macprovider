package computeintegrity

// SPEC-036 FR-20 prompt corpus and verification-request bodies.

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"math/rand"
	"strings"
	"unicode/utf8"
)

// CorpusPrompt is one FR-20 corpus entry: a system message and a user message.
type CorpusPrompt struct {
	System string `json:"system"`
	User   string `json:"user"`
}

// Corpus is the replaceable FR-20 prompt source.
type Corpus interface {
	Version() string
	Len() int
	Prompt(i int) CorpusPrompt
}

const maxCorpusMessageBytes = 2 * 1024

//go:embed corpus/generic_v1.json
var genericCorpusV1 []byte

type staticCorpus struct {
	version string
	prompts []CorpusPrompt
}

func (c *staticCorpus) Version() string           { return c.version }
func (c *staticCorpus) Len() int                  { return len(c.prompts) }
func (c *staticCorpus) Prompt(i int) CorpusPrompt { return c.prompts[i] }

// ParseCorpus validates a corpus document: a version and a non-empty list of
// prompts, each with non-empty messages of at most 2 KiB.
func ParseCorpus(raw []byte) (Corpus, error) {
	var doc struct {
		Version string         `json:"version"`
		Prompts []CorpusPrompt `json:"prompts"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, fmt.Errorf("compute-integrity corpus: %w", err)
	}
	if strings.TrimSpace(doc.Version) == "" || len(doc.Prompts) == 0 {
		return nil, fmt.Errorf("compute-integrity corpus: version and prompts are required")
	}
	for i, p := range doc.Prompts {
		for _, msg := range []string{p.System, p.User} {
			if strings.TrimSpace(msg) == "" || len(msg) > maxCorpusMessageBytes || !utf8.ValidString(msg) {
				return nil, fmt.Errorf("compute-integrity corpus: prompt %d is empty, too long or not UTF-8", i)
			}
		}
	}
	return &staticCorpus{version: doc.Version, prompts: doc.Prompts}, nil
}

// DefaultCorpus is the checked-in rotating generic corpus (no buyer data).
func DefaultCorpus() Corpus {
	c, err := ParseCorpus(genericCorpusV1)
	if err != nil {
		panic(err)
	}
	return c
}

// SamplingProfile is one FR-20 buyer-like sampling setting.
type SamplingProfile struct {
	Temperature float64
	TopP        float64
}

// SamplingProfiles is the closed FR-20 profile mix.
var SamplingProfiles = []SamplingProfile{
	{Temperature: 0, TopP: 1},
	{Temperature: 0.7, TopP: 0.95},
	{Temperature: 1.0, TopP: 1.0},
}

// ProbeMaxTokens is the closed FR-20 max_tokens set.
var ProbeMaxTokens = []int{96, 160, 256}

// probeStyles vary every drawn prompt the way buyers phrase requests, so a
// verification request never repeats a corpus entry verbatim.
var probeStyles = []string{
	"",
	"Keep it brief.",
	"Use plain language.",
	"Give one concrete example.",
	"Answer in about %d sentences.",
	"Use a short list if it helps.",
	"Explain it as you would to a friend.",
	"Be precise.",
	"Start with a one-line summary.",
	"Avoid jargon.",
	"Answer in about %d short paragraphs.",
	"Include a practical tip.",
}

func drawStyle(rng *rand.Rand) string {
	style := probeStyles[rng.Intn(len(probeStyles))]
	if strings.Contains(style, "%d") {
		style = fmt.Sprintf(style, 2+rng.Intn(5))
	}
	return style
}

// ProbeRequest is one drawn verification request.
type ProbeRequest struct {
	ModelID   string
	Body      []byte
	MaxTokens int
	Class     SamplingClass
}

// DrawProbe builds a verification request body for modelID from a random
// corpus prompt, sampling profile and max_tokens value. greedyOnly restricts
// the profile to greedy: escalation requests use it while the sampled band of
// the model is still cold, because the cold sampled prior is too loose to
// decide (FR-20).
func DrawProbe(rng *rand.Rand, corpus Corpus, modelID string, greedyOnly bool) (ProbeRequest, error) {
	if corpus == nil || corpus.Len() == 0 {
		return ProbeRequest{}, fmt.Errorf("compute-integrity corpus is empty")
	}
	prompt := corpus.Prompt(rng.Intn(corpus.Len()))
	if style := drawStyle(rng); style != "" {
		prompt.User = prompt.User + " " + style
	}
	profile := SamplingProfiles[0]
	if !greedyOnly {
		profile = SamplingProfiles[rng.Intn(len(SamplingProfiles))]
	}
	maxTokens := ProbeMaxTokens[rng.Intn(len(ProbeMaxTokens))]
	body, err := json.Marshal(map[string]any{
		"model": modelID,
		"messages": []map[string]string{
			{"role": "system", "content": prompt.System},
			{"role": "user", "content": prompt.User},
		},
		"max_tokens":  maxTokens,
		"temperature": profile.Temperature,
		"top_p":       profile.TopP,
		"stream":      false,
	})
	if err != nil {
		return ProbeRequest{}, err
	}
	return ProbeRequest{ModelID: modelID, Body: body, MaxTokens: maxTokens, Class: SamplingClassFor(profile.Temperature)}, nil
}
