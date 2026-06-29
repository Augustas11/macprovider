// Package runmeta records run-level metadata for the artifact bundle:
// scenario identity, wall-clock window, and a best-effort git sha so
// triage can tie a finding back to a commit.
package runmeta

import (
	"os/exec"
	"strings"
	"time"
)

type Meta struct {
	ScenarioName string    `json:"scenario_name"`
	ScenarioPath string    `json:"scenario_path"`
	StartUTC     time.Time `json:"start_utc"`
	EndUTC       time.Time `json:"end_utc"`
	GitSHA       string    `json:"git_sha,omitempty"`
}

func New(name, path string) *Meta {
	return &Meta{
		ScenarioName: name,
		ScenarioPath: path,
		StartUTC:     time.Now().UTC(),
		GitSHA:       gitSHA(),
	}
}

func (m *Meta) Finish() {
	m.EndUTC = time.Now().UTC()
}

func gitSHA() string {
	out, err := exec.Command("git", "rev-parse", "HEAD").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}
