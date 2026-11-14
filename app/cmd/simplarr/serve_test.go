package main

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/parsoFish/simplarr/app/internal/logging"
)

type getResult struct {
	status int
	body   string
	err    error
}

// startGet issues a GET in the background and delivers its outcome on the
// returned channel.
func startGet(url string) <-chan getResult {
	got := make(chan getResult, 1)
	go func() {
		client := &http.Client{Timeout: 10 * time.Second}
		resp, err := client.Get(url)
		if err != nil {
			got <- getResult{err: err}
			return
		}
		defer resp.Body.Close()
		body, err := io.ReadAll(resp.Body)
		got <- getResult{status: resp.StatusCode, body: string(body), err: err}
	}()
	return got
}

// waitUntilRefused polls addr until a new connection fails, which proves the
// listener is closed. It fails the test if connections are still accepted
// after the timeout.
func waitUntilRefused(t *testing.T, addr string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		conn, err := net.DialTimeout("tcp", addr, 200*time.Millisecond)
		if err != nil {
			return
		}
		_ = conn.Close()
		if time.Now().After(deadline) {
			t.Fatal("the listener still accepts connections after shutdown began")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestServeHTTPShutdownClosesTheListenerAndDrainsInFlightRequests(t *testing.T) {
	restoreDefaultLogger(t)

	entered := make(chan struct{})
	release := make(chan struct{})
	var releaseOnce sync.Once
	doRelease := func() { releaseOnce.Do(func() { close(release) }) }
	t.Cleanup(doRelease) // never leave the handler blocked if an assertion fails

	mux := http.NewServeMux()
	mux.HandleFunc("/slow", func(w http.ResponseWriter, _ *http.Request) {
		close(entered)
		<-release
		_, _ = io.WriteString(w, "done")
	})

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)

	serveDone := make(chan error, 1)
	go func() { serveDone <- serveHTTP(ctx, ln, mux, logging.New(io.Discard, slog.LevelInfo)) }()

	got := startGet("http://" + addr + "/slow")

	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("the in-flight request never reached the handler")
	}
	cancel()

	// (a) A request is still in flight, so the server must keep running.
	select {
	case err := <-serveDone:
		t.Fatalf("serveHTTP returned (%v) while a request was still in flight", err)
	case <-time.After(100 * time.Millisecond):
	}

	// (b) Shutdown closes the listener at once: new connections must fail.
	waitUntilRefused(t, addr, 3*time.Second)

	// (c) The in-flight request is drained, not dropped.
	doRelease()
	select {
	case r := <-got:
		if r.err != nil || r.status != http.StatusOK || r.body != "done" {
			t.Errorf("in-flight request = %d %q, err %v; want 200 \"done\"", r.status, r.body, r.err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the in-flight request never completed")
	}

	// (d) Only then does serveHTTP return, cleanly.
	select {
	case err := <-serveDone:
		if err != nil {
			t.Errorf("serveHTTP returned %v after a clean shutdown", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("serveHTTP did not return after the in-flight request finished")
	}
}

func TestBuildHandlerPreparesTheDataDir(t *testing.T) {
	t.Run("missing data dir is created", func(t *testing.T) {
		restoreDefaultLogger(t)
		cfg := testConfig(t)
		cfg.DataDir = filepath.Join(t.TempDir(), "nested", "data")

		if _, err := buildHandler(cfg, logging.New(io.Discard, slog.LevelInfo), nil); err != nil {
			t.Fatalf("buildHandler: %v", err)
		}
		info, err := os.Stat(cfg.DataDir)
		if err != nil {
			t.Fatalf("data dir was not created: %v", err)
		}
		if !info.IsDir() {
			t.Errorf("%s is not a directory", cfg.DataDir)
		}
	})

	t.Run("read-only data dir fails naming the dir", func(t *testing.T) {
		restoreDefaultLogger(t)
		if os.Geteuid() == 0 {
			t.Skip("root ignores directory permissions")
		}
		cfg := testConfig(t)
		dir := filepath.Join(t.TempDir(), "readonly")
		if err := os.Mkdir(dir, 0o500); err != nil {
			t.Fatal(err)
		}
		cfg.DataDir = dir

		_, err := buildHandler(cfg, logging.New(io.Discard, slog.LevelInfo), nil)
		if err == nil || !strings.Contains(err.Error(), dir) || !strings.Contains(err.Error(), "store: data directory") {
			t.Errorf("err = %v, want a store data-directory error naming %s", err, dir)
		}
	})
}

// runServeWithTimeout drives `simplarr serve` and fails the test instead of
// hanging if the command unexpectedly starts serving.
func runServeWithTimeout(t *testing.T, env map[string]string) (code int, stdout, stderr string) {
	t.Helper()
	type result struct {
		code        int
		out, errOut string
	}
	done := make(chan result, 1)
	go func() {
		var out, errOut bytes.Buffer
		c := run([]string{"serve"}, &out, &errOut, envMap(env))
		done <- result{c, out.String(), errOut.String()}
	}()
	select {
	case r := <-done:
		return r.code, r.out, r.errOut
	case <-time.After(10 * time.Second):
		t.Fatal("simplarr serve did not exit; it should have failed fast")
		return 0, "", ""
	}
}

// freeAddr returns a valid loopback host:port that nothing is listening on.
// The config validator rejects port 0, so tests cannot pass "127.0.0.1:0".
func freeAddr(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	if err := ln.Close(); err != nil {
		t.Fatal(err)
	}
	return addr
}

func TestServeCommandFailsFast(t *testing.T) {
	t.Run("corrupt admin.json stops startup", func(t *testing.T) {
		restoreDefaultLogger(t)
		dir := t.TempDir()
		path := filepath.Join(dir, "admin.json")
		if err := os.WriteFile(path, []byte("{{{"), 0o600); err != nil {
			t.Fatal(err)
		}

		code, stdout, stderr := runServeWithTimeout(t, map[string]string{
			"SIMPLARR_DATA_DIR":   dir,
			"SIMPLARR_CONFIG_DIR": dir,
			"SIMPLARR_LISTEN":     freeAddr(t),
		})
		if code != 1 {
			t.Errorf("exit code = %d, want 1 (stderr %q)", code, stderr)
		}
		if !strings.Contains(stdout, path) {
			t.Errorf("stdout = %q (stderr %q), want it to name %s", stdout, stderr, path)
		}
	})

	t.Run("listen address already in use", func(t *testing.T) {
		restoreDefaultLogger(t)
		held, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = held.Close() })
		dir := t.TempDir()

		code, stdout, stderr := runServeWithTimeout(t, map[string]string{
			"SIMPLARR_DATA_DIR":   dir,
			"SIMPLARR_CONFIG_DIR": dir,
			"SIMPLARR_LISTEN":     held.Addr().String(),
		})
		if code != 1 {
			t.Errorf("exit code = %d, want 1 (stderr %q)", code, stderr)
		}
		if !strings.Contains(stdout, "cannot listen") {
			t.Errorf("stdout = %q (stderr %q), want it to contain %q", stdout, stderr, "cannot listen")
		}
	})
}
