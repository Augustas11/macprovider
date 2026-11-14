package relayblind

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

const maxIdentityPinBytes = 16 << 10

// ReadIdentityPin opens an integrity-critical public pin without following any
// symlink component. Every directory remains referenced by an open descriptor
// until the final file is read, so pathname replacement cannot change the file
// being verified.
func ReadIdentityPin(path string) (IdentityPin, error) {
	if !filepath.IsAbs(path) || path != filepath.Clean(path) {
		return IdentityPin{}, fmt.Errorf("%w: path must be absolute and clean", ErrInvalidPin)
	}
	components := strings.Split(strings.TrimPrefix(path, string(filepath.Separator)), string(filepath.Separator))
	if len(components) == 0 {
		return IdentityPin{}, fmt.Errorf("%w: missing file", ErrInvalidPin)
	}
	for _, component := range components {
		if component == "" || component == "." || component == ".." {
			return IdentityPin{}, fmt.Errorf("%w: unsafe path component", ErrInvalidPin)
		}
	}

	root, err := os.OpenRoot(string(filepath.Separator))
	if err != nil {
		return IdentityPin{}, fmt.Errorf("%w: open filesystem root", ErrInvalidPin)
	}
	roots := []*os.Root{root}
	defer func() {
		for i := len(roots) - 1; i >= 0; i-- {
			_ = roots[i].Close()
		}
	}()

	rootInfo, err := root.Stat(".")
	if err != nil || !securePinPathInfo(rootInfo, true) {
		return IdentityPin{}, fmt.Errorf("%w: unsafe filesystem root", ErrInvalidPin)
	}

	for _, component := range components[:len(components)-1] {
		before, err := root.Lstat(component)
		if err != nil || before.Mode()&os.ModeSymlink != 0 || !securePinPathInfo(before, true) {
			return IdentityPin{}, fmt.Errorf("%w: unsafe pin directory", ErrInvalidPin)
		}
		next, err := root.OpenRoot(component)
		if err != nil {
			return IdentityPin{}, fmt.Errorf("%w: open pin directory", ErrInvalidPin)
		}
		after, err := next.Stat(".")
		if err != nil || !os.SameFile(before, after) || !securePinPathInfo(after, true) {
			_ = next.Close()
			return IdentityPin{}, fmt.Errorf("%w: pin directory changed", ErrInvalidPin)
		}
		roots = append(roots, next)
		root = next
	}

	name := components[len(components)-1]
	before, err := root.Lstat(name)
	if err != nil || before.Mode()&os.ModeSymlink != 0 || !securePinPathInfo(before, false) || before.Size() > maxIdentityPinBytes {
		return IdentityPin{}, fmt.Errorf("%w: unsafe pin file", ErrInvalidPin)
	}
	file, err := root.Open(name)
	if err != nil {
		return IdentityPin{}, fmt.Errorf("%w: open pin file", ErrInvalidPin)
	}
	defer file.Close()
	after, err := file.Stat()
	if err != nil || !os.SameFile(before, after) || !securePinPathInfo(after, false) || after.Size() > maxIdentityPinBytes {
		return IdentityPin{}, fmt.Errorf("%w: pin file changed", ErrInvalidPin)
	}
	raw, err := io.ReadAll(io.LimitReader(file, maxIdentityPinBytes+1))
	if err != nil || len(raw) > maxIdentityPinBytes || int64(len(raw)) != after.Size() {
		return IdentityPin{}, fmt.Errorf("%w: read pin file", ErrInvalidPin)
	}
	return ParseIdentityPin(raw)
}

func securePinPathInfo(info os.FileInfo, directory bool) bool {
	if info == nil || info.Mode()&0o022 != 0 {
		return false
	}
	if directory {
		if !info.IsDir() {
			return false
		}
	} else if !info.Mode().IsRegular() {
		return false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return false
	}
	uid := uint32(os.Geteuid())
	return stat.Uid == 0 || stat.Uid == uid
}
