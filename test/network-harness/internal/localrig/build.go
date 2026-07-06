package localrig

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
)

// findRepoRoot walks up from CWD looking for the repo markers used by
// test/integration: a Makefile alongside a phase4-coordinator/ dir.
func findRepoRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "Makefile")); err == nil {
			if _, err := os.Stat(filepath.Join(dir, "phase4-coordinator")); err == nil {
				return dir, nil
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("could not locate repo root from %s", dir)
		}
		dir = parent
	}
}

// buildBinaries builds coordinator, coordinator-cli, and gateway into
// binDir. If all three already exist under binDir the build is skipped
// (per-Rig cache; the second scenario in the same WorkDir gets an
// instant boot). Returns absolute paths.
//
// ctx is propagated to each `go build` child — SIGINT during the ~15s
// cold build cancels the sub-process promptly, so a caller cancel is
// observable inside Start rather than blocking until the compiler is
// done.
func buildBinaries(ctx context.Context, repoRoot, binDir string) (coord, coordCLI, gw string, err error) {
	coord = filepath.Join(binDir, "coordinator")
	coordCLI = filepath.Join(binDir, "coordinator-cli")
	gw = filepath.Join(binDir, "gateway")
	if fileExists(coord) && fileExists(coordCLI) && fileExists(gw) {
		return coord, coordCLI, gw, nil
	}
	if err := buildOne(ctx, filepath.Join(repoRoot, "phase4-coordinator"), "./cmd/coordinator", coord); err != nil {
		return "", "", "", err
	}
	if err := buildOne(ctx, filepath.Join(repoRoot, "phase4-coordinator"), "./cmd/coordinator-cli", coordCLI); err != nil {
		return "", "", "", err
	}
	if err := buildOne(ctx, filepath.Join(repoRoot, "phase5-gateway"), "./cmd/gateway", gw); err != nil {
		return "", "", "", err
	}
	return coord, coordCLI, gw, nil
}

func buildOne(ctx context.Context, modDir, pkg, outPath string) error {
	cmd := exec.CommandContext(ctx, "go", "build", "-o", outPath, pkg)
	cmd.Dir = modDir
	cmd.Env = append(os.Environ(), "CGO_ENABLED=0")
	out, err := cmd.CombinedOutput()
	if err != nil {
		if ctxErr := ctx.Err(); ctxErr != nil {
			return fmt.Errorf("build %s cancelled: %w", pkg, ctxErr)
		}
		return fmt.Errorf("build %s in %s: %v\n%s", pkg, modDir, err, string(out))
	}
	return nil
}

func fileExists(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && !fi.IsDir()
}

// randHex returns 2n hex chars of crypto-random bytes.
func randHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// streamPipes wires cmd's stdout+stderr through logger, one line each.
// Must be called before cmd.Start().
func streamPipes(cmd *exec.Cmd, logger func(string)) error {
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return err
	}
	go pump(stdout, logger)
	go pump(stderr, logger)
	return nil
}

func pump(r io.ReadCloser, logger func(string)) {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		logger(scanner.Text())
	}
}
