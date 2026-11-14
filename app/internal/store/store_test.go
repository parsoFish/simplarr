package store

import (
	"bytes"
	"log/slog"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestWriteFileAtomicCreatesWithMode(t *testing.T) {
	path := filepath.Join(t.TempDir(), "admin.json")
	if err := WriteFileAtomic(path, []byte(`{"a":1}`), 0o600); err != nil {
		t.Fatalf("WriteFileAtomic: %v", err)
	}
	got, err := os.ReadFile(path)
	if err != nil || string(got) != `{"a":1}` {
		t.Fatalf("content = %q, err = %v", got, err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("mode = %o, want 600 regardless of umask", info.Mode().Perm())
	}

	// os.CreateTemp makes 0600 files, so a 0644 result proves the explicit chmod ran.
	wide := filepath.Join(t.TempDir(), "public.json")
	if err := WriteFileAtomic(wide, []byte("x"), 0o644); err != nil {
		t.Fatalf("WriteFileAtomic 0644: %v", err)
	}
	wideInfo, err := os.Stat(wide)
	if err != nil {
		t.Fatal(err)
	}
	if wideInfo.Mode().Perm() != 0o644 {
		t.Errorf("mode = %o, want exactly 644", wideInfo.Mode().Perm())
	}
}

func TestWriteFileAtomicReplacesAndLeavesNoTempFiles(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "secrets.json")
	for _, content := range []string{"one", "two-longer", "3"} {
		if err := WriteFileAtomic(path, []byte(content), 0o600); err != nil {
			t.Fatalf("WriteFileAtomic(%q): %v", content, err)
		}
		got, _ := os.ReadFile(path)
		if string(got) != content {
			t.Fatalf("content = %q, want %q", got, content)
		}
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != "secrets.json" {
		names := []string{}
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Errorf("dir contains %v, want only secrets.json", names)
	}
}

func TestWriteFileAtomicMissingDirFailsCleanly(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nope", "file.json")
	err := WriteFileAtomic(path, []byte("x"), 0o600)
	if err == nil || !strings.Contains(err.Error(), "nope") {
		t.Fatalf("err = %v, want error naming the missing directory", err)
	}
}

func TestEnforceModeNarrowsWideFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "secrets.json")
	if err := os.WriteFile(path, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o644); err != nil { // WriteFile is subject to umask, Chmod is not
		t.Fatal(err)
	}
	var buf bytes.Buffer
	if err := EnforceMode(path, 0o600, slog.New(slog.NewTextHandler(&buf, nil))); err != nil {
		t.Fatalf("EnforceMode: %v", err)
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0o600 {
		t.Errorf("mode = %o, want 600", info.Mode().Perm())
	}
	if !strings.Contains(buf.String(), path) || !strings.Contains(buf.String(), "WARN") {
		t.Errorf("expected a WARN naming the file, got %q", buf.String())
	}
}

func TestEnforceModeLeavesTightFileAndMissingFileAlone(t *testing.T) {
	dir := t.TempDir()
	tight := filepath.Join(dir, "tight.json")
	if err := os.WriteFile(tight, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(tight, 0o400); err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	log := slog.New(slog.NewTextHandler(&buf, nil))
	if err := EnforceMode(tight, 0o600, log); err != nil {
		t.Fatalf("tight file: %v", err)
	}
	if err := EnforceMode(filepath.Join(dir, "missing.json"), 0o600, log); err != nil {
		t.Fatalf("missing file: %v", err)
	}
	if buf.Len() != 0 {
		t.Errorf("unexpected log output: %s", buf.String())
	}
	if info, _ := os.Stat(tight); info.Mode().Perm() != 0o400 {
		t.Errorf("narrower mode was widened to %o", info.Mode().Perm())
	}
}

func TestEnsureDir(t *testing.T) {
	root := t.TempDir()

	created := filepath.Join(root, "a", "b")
	if err := EnsureDir(created); err != nil {
		t.Fatalf("create: %v", err)
	}
	if info, err := os.Stat(created); err != nil || !info.IsDir() {
		t.Fatalf("directory not created: %v", err)
	}
	entries, _ := os.ReadDir(created)
	if len(entries) != 0 {
		t.Errorf("write probe left files behind: %v", entries)
	}

	file := filepath.Join(root, "file")
	if err := os.WriteFile(file, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := EnsureDir(file); err == nil || !strings.Contains(err.Error(), file) {
		t.Errorf("file path: err = %v, want error naming %s", err, file)
	}
}

func TestEnsureDirReportsUnwritable(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root ignores directory permissions")
	}
	dir := filepath.Join(t.TempDir(), "ro")
	if err := os.Mkdir(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	if err := EnsureDir(dir); err == nil || !strings.Contains(err.Error(), dir) {
		t.Errorf("err = %v, want error naming %s", err, dir)
	}
}

func TestWriteFileAtomicRenameFailureLeavesNoTempFile(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "admin.json")
	// A non-empty directory at the target makes os.Rename fail.
	if err := os.MkdirAll(filepath.Join(target, "child"), 0o700); err != nil {
		t.Fatal(err)
	}
	err := WriteFileAtomic(target, []byte("x"), 0o600)
	if err == nil || !strings.Contains(err.Error(), target) {
		t.Fatalf("err = %v, want error naming %s", err, target)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != "admin.json" {
		names := []string{}
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Errorf("dir contains %v, want only admin.json", names)
	}
}

func TestEnforceModeChmodFailureNamesTheFile(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("relies on /proc/self/status, which exists only on Linux")
	}
	if os.Geteuid() == 0 {
		t.Skip("root can chmod any file, so chmod cannot fail")
	}
	const path = "/proc/self/status"
	if _, err := os.Stat(path); err != nil {
		t.Skipf("%s not available: %v", path, err)
	}
	var buf bytes.Buffer
	err := EnforceMode(path, 0o600, slog.New(slog.NewTextHandler(&buf, nil)))
	if err == nil || !strings.Contains(err.Error(), path) || !strings.Contains(err.Error(), "chmod failed") {
		t.Fatalf("err = %v, want chmod failure naming %s", err, path)
	}
}

func TestEnforceModeStatErrorNamesTheFile(t *testing.T) {
	file := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(file, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	child := filepath.Join(file, "child") // ENOTDIR, not ErrNotExist
	var buf bytes.Buffer
	err := EnforceMode(child, 0o600, slog.New(slog.NewTextHandler(&buf, nil)))
	if err == nil || !strings.Contains(err.Error(), "store: stat") || !strings.Contains(err.Error(), child) {
		t.Fatalf("err = %v, want stat error naming %s", err, child)
	}
}
