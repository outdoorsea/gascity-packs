package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// openBeneath is the confined open backing readConfinedFile, delegating
// the traversal to os.OpenInRoot. These tests pin the confinement
// contract: legitimate nested paths open; a symlink that escapes root is
// a hard failure whether it is absolute or relative, and whether it sits
// at the leaf or at an intermediate component (the stand-in for a parent
// directory swapped mid-flight); and a relative symlink that stays
// inside root is followed.
//
// That last case is the one behavioural difference from the older
// component-wise syscall.Openat walk, which set O_NOFOLLOW on every
// component and so refused every symlink. It is pinned here rather than
// left implicit: resolving within root reaches a file the caller could
// already read by its real path, so confinement is intact, but a future
// reader should not have to rediscover which of the two contracts is in
// force.

func TestOpenBeneathReadsNestedFile(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "a", "b"), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "a", "b", "f.txt"), []byte("payload"), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}

	f, err := openBeneath(root, filepath.Join("a", "b", "f.txt"))
	if err != nil {
		t.Fatalf("openBeneath: %v", err)
	}
	defer f.Close()
	buf := make([]byte, 16)
	n, _ := f.Read(buf)
	if got := string(buf[:n]); got != "payload" {
		t.Errorf("read %q, want %q", got, "payload")
	}
}

func TestOpenBeneathRefusesEscapingSymlinkComponents(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	secret := filepath.Join(outside, "secret")
	if err := os.WriteFile(secret, []byte("loot"), 0o600); err != nil {
		t.Fatalf("write outside: %v", err)
	}

	// Intermediate component is a symlink to a directory outside root —
	// the post-swap shape of the parent-directory race.
	if err := os.Symlink(outside, filepath.Join(root, "swapped")); err != nil {
		t.Fatalf("symlink dir: %v", err)
	}
	if _, err := openBeneath(root, filepath.Join("swapped", "secret")); err == nil {
		t.Error("openBeneath followed a symlinked intermediate directory, want failure")
	}

	// Leaf component is a symlink out of root.
	if err := os.Symlink(secret, filepath.Join(root, "leaf")); err != nil {
		t.Fatalf("symlink leaf: %v", err)
	}
	if _, err := openBeneath(root, "leaf"); err == nil {
		t.Error("openBeneath followed a leaf symlink out of root, want failure")
	}

	// Relative escapes, not just absolute ones. os.OpenInRoot rejects
	// absolute symlink targets outright, so an absolute-only test would
	// pass even if escape detection were broken; these carry the real
	// guarantee.
	relSecret, err := filepath.Rel(root, secret)
	if err != nil {
		t.Fatalf("rel secret: %v", err)
	}
	relOutside, err := filepath.Rel(root, outside)
	if err != nil {
		t.Fatalf("rel outside: %v", err)
	}
	if !strings.HasPrefix(relSecret, "..") {
		t.Fatalf("relSecret %q should climb out of root %q", relSecret, root)
	}
	if err := os.Symlink(relSecret, filepath.Join(root, "relleaf")); err != nil {
		t.Fatalf("symlink relative leaf: %v", err)
	}
	if _, err := openBeneath(root, "relleaf"); err == nil {
		t.Error("openBeneath followed a relative leaf symlink out of root, want failure")
	}
	if err := os.Symlink(relOutside, filepath.Join(root, "reldir")); err != nil {
		t.Fatalf("symlink relative dir: %v", err)
	}
	if _, err := openBeneath(root, filepath.Join("reldir", "secret")); err == nil {
		t.Error("openBeneath followed a relative intermediate symlink out of root, want failure")
	}
}

func TestOpenBeneathFollowsInRootSymlinkButNotAbsoluteOnes(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "a"), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	target := filepath.Join(root, "a", "real.txt")
	if err := os.WriteFile(target, []byte("inroot"), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}

	// Relative link staying inside root: followed. Reaches a file the
	// caller could already read by its real path, so confinement holds.
	if err := os.Symlink(filepath.Join("a", "real.txt"), filepath.Join(root, "rel")); err != nil {
		t.Fatalf("symlink relative in-root: %v", err)
	}
	f, err := openBeneath(root, "rel")
	if err != nil {
		t.Fatalf("openBeneath on in-root relative symlink: %v", err)
	}
	defer f.Close()
	buf := make([]byte, 16)
	n, _ := f.Read(buf)
	if got := string(buf[:n]); got != "inroot" {
		t.Errorf("read %q, want %q", got, "inroot")
	}

	// Absolute link is refused even though its target is inside root:
	// os.OpenInRoot rejects absolute symlink targets unconditionally.
	if err := os.Symlink(target, filepath.Join(root, "abs")); err != nil {
		t.Fatalf("symlink absolute in-root: %v", err)
	}
	if _, err := openBeneath(root, "abs"); err == nil {
		t.Error("openBeneath followed an absolute symlink, want failure")
	}
}

func TestOpenBeneathRejectsInvalidRel(t *testing.T) {
	root := t.TempDir()
	// "a/../b" is absent: filepath.Clean collapses it to "b" before the
	// component check, which is correct — the cleaned form is beneath root.
	//
	// "." matters most here: os.OpenInRoot would happily open the root
	// directory itself, so openBeneath's own guard is what keeps the
	// "a file strictly inside root" contract.
	for _, rel := range []string{"", ".", "/etc/passwd", "..", filepath.Join("..", "x")} {
		if _, err := openBeneath(root, rel); err == nil {
			t.Errorf("openBeneath(%q) succeeded, want rejection", rel)
		}
	}
}

// readConfinedFile's confinement check EvalSymlinks-resolves the root but
// not the path, so the temp root is canonicalized here for the same reason
// as TestConfineFileUploadPath: on a platform whose temp dir is reached
// through a symlink (macOS /var -> /private/var) an unresolved root sends
// filepath.Rel down a "../"-prefixed result and the read case fails as
// "outside root".
func TestReadConfinedFileStillReadsAndStillConfines(t *testing.T) {
	root := t.TempDir()
	if resolved, err := filepath.EvalSymlinks(root); err == nil {
		root = resolved
	}
	sub := filepath.Join(root, "files")
	if err := os.MkdirAll(sub, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	path := filepath.Join(sub, "report.txt")
	if err := os.WriteFile(path, []byte("contents"), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}

	got, err := readConfinedFile(root, path)
	if err != nil {
		t.Fatalf("readConfinedFile: %v", err)
	}
	if string(got) != "contents" {
		t.Errorf("read %q, want %q", got, "contents")
	}

	if _, err := readConfinedFile(root, "/etc/passwd"); err == nil ||
		!strings.Contains(err.Error(), "outside root") {
		t.Errorf("escape attempt error = %v, want outside-root rejection", err)
	}
}
