// Package store holds simplarr's file-system primitives: atomic writes,
// permission enforcement and the data-directory check (spec §3.1, §5.3, D7).
package store

import (
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"syscall"
)

// WriteFileAtomic writes data to path so that readers see either the old file
// or the complete new one, never a partial write. It writes a temp file in the
// same directory, applies perm explicitly (umask does not apply), fsyncs, then
// renames over the target. An error from the final directory sync means the
// rename already happened, so the new content is in place but may not survive
// power loss.
func WriteFileAtomic(path string, data []byte, perm os.FileMode) (err error) {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp-*")
	if err != nil {
		return fmt.Errorf("store: create temp file in %s: %w", dir, err)
	}
	tmpName := tmp.Name()
	renamed := false
	defer func() {
		if renamed {
			return
		}
		// Only our own temp file is removed; a failed removal is reported.
		if rmErr := os.Remove(tmpName); rmErr != nil && !errors.Is(rmErr, fs.ErrNotExist) {
			err = errors.Join(err, fmt.Errorf("store: remove temp file %s: %w", tmpName, rmErr))
		}
	}()

	if err := tmp.Chmod(perm); err != nil {
		return errors.Join(fmt.Errorf("store: chmod %s: %w", tmpName, err), tmp.Close())
	}
	if _, err := tmp.Write(data); err != nil {
		return errors.Join(fmt.Errorf("store: write %s: %w", tmpName, err), tmp.Close())
	}
	if err := tmp.Sync(); err != nil {
		return errors.Join(fmt.Errorf("store: sync %s: %w", tmpName, err), tmp.Close())
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("store: close %s: %w", tmpName, err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("store: rename %s to %s: %w", tmpName, path, err)
	}
	renamed = true
	return syncDir(dir)
}

// syncDir makes the rename durable. Some bind-mount file systems reject fsync
// on a directory with EINVAL or ENOTSUP; the rename has already happened, so
// only those two "not supported" answers are tolerated.
func syncDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return fmt.Errorf("store: open dir %s: %w", dir, err)
	}
	syncErr := d.Sync()
	closeErr := d.Close()
	if syncErr != nil && !errors.Is(syncErr, syscall.EINVAL) && !errors.Is(syncErr, syscall.ENOTSUP) {
		return fmt.Errorf("store: sync dir %s: %w", dir, syncErr)
	}
	if closeErr != nil {
		return fmt.Errorf("store: close dir %s: %w", dir, closeErr)
	}
	return nil
}

// EnforceMode makes sure the file at path is no more permissive than want
// (spec §5.3). A file that is already tighter is left alone, and a missing
// file is not an error. A wider file is logged at WARN and chmodded to want;
// if the chmod fails the error names the file so the caller can refuse to
// start. There is deliberately no ownership check: Docker Desktop bind mounts
// report ownership differently from native Linux.
func EnforceMode(path string, want os.FileMode, log *slog.Logger) error {
	info, err := os.Stat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("store: stat %s: %w", path, err)
	}
	have := info.Mode().Perm()
	if have&^want == 0 {
		return nil
	}
	log.Warn("file permissions too wide, tightening", "path", path, "have", fmt.Sprintf("%04o", have), "want", fmt.Sprintf("%04o", want))
	if err := os.Chmod(path, want); err != nil {
		return fmt.Errorf("store: %s has mode %04o, wider than %04o, and chmod failed: %w", path, have, want, err)
	}
	return nil
}

// EnsureDir creates dir if needed and proves it is writable by creating and
// removing a probe file. It fails fast with a message naming the directory.
func EnsureDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("store: data directory %s: %w", dir, err)
	}
	probe, err := os.CreateTemp(dir, ".write-check-*")
	if err != nil {
		return fmt.Errorf("store: data directory %s is not writable: %w", dir, err)
	}
	name := probe.Name()
	closeErr := probe.Close()
	rmErr := os.Remove(name)
	if err := errors.Join(closeErr, rmErr); err != nil {
		return fmt.Errorf("store: data directory %s write probe: %w", dir, err)
	}
	return nil
}
