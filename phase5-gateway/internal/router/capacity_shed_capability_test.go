package router

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Every coordinator chat builder sets the trusted chat context through
// setCoordinatorChatContext; each must also advertise the capacity 429, or a
// coordinator answers that path's capacity sheds with the pre-#1906 503
// (#1906 round-1 audit, version skew).
func TestEveryCoordinatorChatBuilderAdvertisesCapacityShed429(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	builders := 0
	for _, name := range files {
		if strings.HasSuffix(name, "_test.go") {
			continue
		}
		data, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		lines := strings.Split(string(data), "\n")
		for i, line := range lines {
			if !strings.Contains(line, "s.setCoordinatorChatContext(") {
				continue
			}
			builders++
			if i+1 >= len(lines) || !strings.Contains(lines[i+1], "advertiseCapacityShed429(") {
				t.Errorf("%s:%d: setCoordinatorChatContext without advertiseCapacityShed429 on the next line", name, i+1)
			}
		}
	}
	if builders == 0 {
		t.Fatal("found no coordinator chat builders")
	}
}
