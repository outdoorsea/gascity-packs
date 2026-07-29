package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// openBeneath opens rel (a Clean, root-relative path containing no
// "..") beneath rootAbs, refusing any resolution that would leave
// rootAbs. It delegates the confined traversal to os.OpenInRoot, whose
// contract is that no component of the name may resolve outside the
// root: the standard library opens each component relative to the fd of
// the already-verified parent, so a directory swapped for an escaping
// symlink mid-walk cannot redirect the traversal. That is the same
// confinement guarantee openat2(RESOLVE_BENEATH) provides on Linux,
// reached instead by a portable userspace walk — the walk this file used
// to hand-roll, now maintained in os (with symlink-depth accounting)
// rather than here.
//
// The hand-rolled walk was Linux-only: syscall.Openat is absent from
// darwin's syscall package, so the whole package failed to compile on
// macOS and the CI file-upload gate could not be reproduced on a darwin
// workstation (gp-0m5). A runtime.GOOS guard cannot fix that — an
// undefined symbol fails at compile time regardless of any runtime
// branch. os.OpenInRoot (Go 1.24+) is portable and pulls in no module
// dependency, so the adapter's zero-dependency go.mod is preserved and
// darwin and Linux now exercise the same code path. That last part is
// the point: a local run that took a platform-specific branch would
// verify nothing about what CI actually runs.
//
// Symlink handling differs from the old walk in exactly one case. The
// walk set O_NOFOLLOW on every component, so ANY symlink beneath root
// was a hard failure. os.OpenInRoot rejects absolute symlinks and any
// symlink that escapes root, but follows a relative symlink that stays
// inside it. Confinement — the property readConfinedFile exists to
// enforce (gc-cby.10, and the parent-swap residual race gpk-1ta4) — is
// unchanged: an escaping link is still refused, and a link resolving
// within root reaches a file the caller could already read by its real
// path, so it is not an arbitrary-read escape. Legitimate callers are
// unaffected either way, because realPath arrives EvalSymlinks-resolved
// and so contains no symlink components at all.
//
// The rel validation below is deliberately not delegated: os.OpenInRoot
// accepts "." and opens the root directory itself, whereas this
// helper's callers require a file strictly inside root.
func openBeneath(rootAbs, rel string) (*os.File, error) {
	if rel == "" || rel == "." || filepath.IsAbs(rel) {
		return nil, fmt.Errorf("openBeneath: invalid relative path %q", rel)
	}
	clean := filepath.Clean(rel)
	for _, c := range strings.Split(clean, string(filepath.Separator)) {
		if c == "" || c == "." || c == ".." {
			return nil, fmt.Errorf("openBeneath: invalid path component %q in %q", c, rel)
		}
	}
	f, err := os.OpenInRoot(rootAbs, clean)
	if err != nil {
		return nil, fmt.Errorf("openBeneath: open %q beneath %q: %w", rel, rootAbs, err)
	}
	return f, nil
}
