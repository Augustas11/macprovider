package billing

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

func TestSPEC022D8AcceptanceCoverageMapIncludesAllACs(t *testing.T) {
	repoRoot := filepath.Clean("../../..")
	docPath := filepath.Join(repoRoot, "specs/SPEC-022-IMPL-DELIVERABLE-8.md")
	raw, err := os.ReadFile(docPath)
	if err != nil {
		t.Fatalf("read D8 coverage map: %v", err)
	}
	text := string(raw)

	expectedStatus := map[string]string{
		"AC-022-1":   "Covered",
		"AC-022-2":   "Covered",
		"AC-022-3":   "Covered",
		"AC-022-4":   "Partial",
		"AC-022-5":   "Covered",
		"AC-022-6":   "Covered",
		"AC-022-7":   "Blocked",
		"AC-022-8":   "Blocked",
		"AC-022-9":   "Partial",
		"AC-022-10a": "Partial",
		"AC-022-10b": "Partial",
		"AC-022-10c": "Partial",
		"AC-022-10d": "Partial",
		"AC-022-11":  "Partial",
		"AC-022-12":  "Partial",
		"AC-022-13":  "Blocked",
		"AC-022-14":  "Partial",
		"AC-022-15":  "Blocked",
		"AC-022-16":  "Partial",
		"AC-022-17":  "Partial",
		"AC-022-18":  "Partial",
		"AC-022-19":  "Blocked",
		"AC-022-20":  "Blocked",
		"AC-022-21":  "Blocked",
		"AC-022-22":  "Partial",
		"AC-022-23":  "Blocked",
		"AC-022-24":  "Manual gate",
		"AC-022-25":  "Blocked",
		"AC-022-26":  "Partial",
		"AC-022-27":  "Blocked",
		"AC-022-28":  "Partial",
		"AC-022-29":  "Blocked",
		"AC-022-30":  "Partial",
		"AC-022-31":  "Partial",
		"AC-022-32":  "Blocked",
		"AC-022-33":  "Blocked",
		"AC-022-34":  "Partial",
		"AC-022-35":  "Manual gate",
		"AC-022-36":  "Partial",
		"AC-022-37":  "Partial",
		"AC-022-38":  "Partial",
		"AC-022-39":  "Blocked",
		"AC-022-40":  "Blocked",
		"AC-022-41":  "Blocked",
		"AC-022-42a": "Covered",
		"AC-022-42b": "Covered",
		"AC-022-43":  "Blocked",
		"AC-022-44":  "Blocked",
		"AC-022-45":  "Blocked",
		"AC-022-46":  "Blocked",
		"AC-022-47":  "Blocked",
		"AC-022-48":  "Partial",
		"AC-022-49":  "Blocked",
		"AC-022-50a": "Partial",
		"AC-022-50b": "Partial",
		"AC-022-50c": "Partial",
		"AC-022-50d": "Partial",
		"AC-022-50e": "Partial",
		"AC-022-51":  "Blocked",
		"AC-022-52":  "Blocked",
		"AC-022-53":  "Partial",
		"AC-022-54":  "Covered",
		"AC-022-55":  "Blocked",
		"AC-022-56":  "Blocked",
		"AC-022-57":  "Partial",
		"AC-022-58":  "Partial",
		"AC-022-59":  "Partial",
		"AC-022-60":  "Blocked",
		"AC-022-61":  "Partial",
		"AC-022-62":  "Blocked",
		"AC-022-63":  "Blocked",
		"AC-022-64":  "Blocked",
	}

	rows := parseSPEC022CoverageRows(t, text)
	normativeLabels := parseSPEC022NormativeACLabels(t, filepath.Join(repoRoot, "specs/SPEC-022-verified-model-settlement.md"))
	assertSameLabelSet(t, "D8 coverage rows", labelsFromCoverageRows(rows), "normative SPEC-022 ACs", normativeLabels)
	assertSameLabelSet(t, "D8 expected status map", labelsFromStatusMap(expectedStatus), "normative SPEC-022 ACs", normativeLabels)

	for label, want := range expectedStatus {
		row, ok := rows[label]
		if !ok {
			t.Fatalf("D8 coverage map missing table row for %s", label)
		}
		if row.status != want {
			t.Fatalf("%s status=%q want %q", label, row.status, want)
		}
	}
	testFunctionsByFile := collectRepoTestFunctionsByFile(t, repoRoot)
	assertSPEC022CoverageCitationsExist(t, repoRoot, testFunctionsByFile, rows)
}

type spec022CoverageRow struct {
	status string
	body   string
}

func parseSPEC022CoverageRows(t *testing.T, text string) map[string]spec022CoverageRow {
	t.Helper()

	rows := map[string]spec022CoverageRow{}
	for _, line := range strings.Split(text, "\n") {
		if !strings.HasPrefix(line, "| AC-022-") {
			continue
		}
		parts := strings.Split(line, "|")
		if len(parts) < 5 {
			t.Fatalf("malformed D8 coverage row: %s", line)
		}
		label := strings.TrimSpace(parts[1])
		status := strings.TrimSpace(parts[2])
		body := strings.TrimSpace(parts[3])
		if _, exists := rows[label]; exists {
			t.Fatalf("duplicate D8 coverage row for %s", label)
		}
		rows[label] = spec022CoverageRow{status: status, body: body}
	}
	return rows
}

func parseSPEC022NormativeACLabels(t *testing.T, specPath string) map[string]struct{} {
	t.Helper()

	raw, err := os.ReadFile(specPath)
	if err != nil {
		t.Fatalf("read normative SPEC-022 ACs: %v", err)
	}
	labelRE := regexp.MustCompile(`(?m)^- \*\*(AC-022-[^:]+):\*\*`)
	labels := map[string]struct{}{}
	for _, match := range labelRE.FindAllSubmatch(raw, -1) {
		label := string(match[1])
		if _, exists := labels[label]; exists {
			t.Fatalf("duplicate normative SPEC-022 AC label %s", label)
		}
		labels[label] = struct{}{}
	}
	if len(labels) == 0 {
		t.Fatal("no normative SPEC-022 AC labels found")
	}
	return labels
}

func labelsFromCoverageRows(rows map[string]spec022CoverageRow) map[string]struct{} {
	labels := map[string]struct{}{}
	for label := range rows {
		labels[label] = struct{}{}
	}
	return labels
}

func labelsFromStatusMap(statuses map[string]string) map[string]struct{} {
	labels := map[string]struct{}{}
	for label := range statuses {
		labels[label] = struct{}{}
	}
	return labels
}

func assertSameLabelSet(t *testing.T, gotName string, got map[string]struct{}, wantName string, want map[string]struct{}) {
	t.Helper()

	if len(got) != len(want) {
		t.Fatalf("%s count=%d want %d from %s", gotName, len(got), len(want), wantName)
	}
	for label := range want {
		if _, ok := got[label]; !ok {
			t.Fatalf("%s missing %s from %s", gotName, label, wantName)
		}
	}
	for label := range got {
		if _, ok := want[label]; !ok {
			t.Fatalf("%s has unexpected %s not in %s", gotName, label, wantName)
		}
	}
}

func collectRepoTestFunctionsByFile(t *testing.T, repoRoot string) map[string]map[string]struct{} {
	t.Helper()

	functionRE := regexp.MustCompile(`func\s+(` + testFunctionNamePattern + `)\b`)
	namesByFile := map[string]map[string]struct{}{}
	if err := filepath.WalkDir(repoRoot, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			switch entry.Name() {
			case ".git", ".build", "node_modules", "vendor":
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, "_test.go") && !strings.HasSuffix(path, ".swift") {
			return nil
		}
		raw, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		for _, match := range functionRE.FindAllSubmatch(raw, -1) {
			relPath, err := filepath.Rel(repoRoot, path)
			if err != nil {
				return err
			}
			relPath = filepath.ToSlash(relPath)
			if namesByFile[relPath] == nil {
				namesByFile[relPath] = map[string]struct{}{}
			}
			namesByFile[relPath][string(match[1])] = struct{}{}
		}
		return nil
	}); err != nil {
		t.Fatalf("collect test functions: %v", err)
	}
	return namesByFile
}

const testFunctionNamePattern = `(?:Test[A-Za-z0-9_]+|test[A-Za-z0-9_]+)`

func assertSPEC022CoverageCitationsExist(t *testing.T, repoRoot string, testFunctionsByFile map[string]map[string]struct{}, rows map[string]spec022CoverageRow) {
	t.Helper()

	citationRE := regexp.MustCompile("`([^`]+)`")
	fileCitationRE := regexp.MustCompile(`^[^` + "`" + `]+\.(?:go|swift)$`)
	testCitationRE := regexp.MustCompile("^" + testFunctionNamePattern + "$")
	var missing []string

	for label, row := range rows {
		currentFile := ""
		validatedTests := 0
		for _, match := range citationRE.FindAllStringSubmatch(row.body, -1) {
			token := match[1]
			switch {
			case fileCitationRE.MatchString(token):
				relPath := filepath.Clean(token)
				relPath = filepath.ToSlash(relPath)
				if filepath.IsAbs(relPath) || strings.HasPrefix(relPath, "..") {
					missing = append(missing, label+" has unsafe file citation "+token)
					currentFile = ""
					continue
				}
				if _, err := os.Stat(filepath.Join(repoRoot, relPath)); err != nil {
					missing = append(missing, label+" missing file citation "+token)
					currentFile = ""
					continue
				}
				currentFile = relPath
			case testCitationRE.MatchString(token):
				if currentFile == "" {
					missing = append(missing, label+" test citation "+token+" has no preceding file citation")
					continue
				}
				if _, ok := testFunctionsByFile[currentFile][token]; !ok {
					missing = append(missing, label+" missing test citation "+currentFile+" "+token)
					continue
				}
				validatedTests++
			}
		}
		if row.status == "Covered" && validatedTests == 0 {
			missing = append(missing, label+" covered row has no validated test citation")
		}
	}

	if len(missing) > 0 {
		sort.Strings(missing)
		t.Fatalf("D8 coverage citations are stale:\n%s", strings.Join(missing, "\n"))
	}
}
