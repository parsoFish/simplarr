package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/parsoFish/simplarr/app/internal/config"
	"github.com/parsoFish/simplarr/app/internal/logging"
)

func envMap(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

// restoreDefaultLogger puts back everything slog.SetDefault changes. SetDefault
// also redirects the standard log package, so the log flags and writer are
// restored along with the slog default.
func restoreDefaultLogger(t *testing.T) {
	t.Helper()
	oldLogger, oldFlags, oldWriter := slog.Default(), log.Flags(), log.Writer()
	t.Cleanup(func() {
		slog.SetDefault(oldLogger)
		log.SetFlags(oldFlags)
		log.SetOutput(oldWriter)
	})
}

func TestRunDispatch(t *testing.T) {
	restoreDefaultLogger(t)
	tests := []struct {
		name     string
		args     []string
		env      map[string]string
		wantCode int
		wantOut  string
		wantErr  string
	}{
		{"version", []string{"version"}, nil, 0, version + "\n", ""},
		{"help", []string{"help"}, nil, 0, "usage: simplarr", ""},
		{"unknown command", []string{"frobnicate"}, nil, 2, "", `unknown command "frobnicate"`},
		{"extra args", []string{"version", "now"}, nil, 2, "", "takes no arguments"},
		{"serve with bad config", []string{"serve"}, map[string]string{"SIMPLARR_LISTEN": "nonsense"}, 1, "", "SIMPLARR_LISTEN"},
		{"default command is serve", nil, map[string]string{"RADARR_PORT": "0"}, 1, "", "RADARR_PORT"},
		{"healthcheck with bad config", []string{"healthcheck"}, map[string]string{"SIMPLARR_LISTEN": "nonsense"}, 1, "", "SIMPLARR_LISTEN"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var out, errOut bytes.Buffer
			code := run(tc.args, &out, &errOut, envMap(tc.env))
			if code != tc.wantCode {
				t.Errorf("exit code = %d, want %d (stderr %q)", code, tc.wantCode, errOut.String())
			}
			if !strings.Contains(out.String(), tc.wantOut) {
				t.Errorf("stdout = %q, want it to contain %q", out.String(), tc.wantOut)
			}
			if !strings.Contains(errOut.String(), tc.wantErr) {
				t.Errorf("stderr = %q, want it to contain %q", errOut.String(), tc.wantErr)
			}
		})
	}
}

func testConfig(t *testing.T) config.Config {
	t.Helper()
	cfg, err := config.Load(envMap(map[string]string{"SIMPLARR_DATA_DIR": t.TempDir()}))
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}

func TestServeEndToEndAndGracefulShutdown(t *testing.T) {
	restoreDefaultLogger(t)
	cfg := testConfig(t)
	var logs bytes.Buffer
	logger := logging.New(&logs, slog.LevelInfo)

	handler, err := buildHandler(cfg, logger, nil)
	if err != nil {
		t.Fatalf("buildHandler: %v", err)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- serveHTTP(ctx, ln, handler, logger) }()

	base := "http://" + ln.Addr().String()
	var state struct{ SetupRequired, Authenticated bool }
	for path, into := range map[string]any{"/healthz": &map[string]bool{}, "/api/v1/auth/state": &state} {
		resp, err := http.Get(base + path)
		if err != nil {
			t.Fatalf("GET %s: %v", path, err)
		}
		if err := json.NewDecoder(resp.Body).Decode(into); err != nil || resp.StatusCode != 200 {
			t.Fatalf("GET %s: %d, decode err %v", path, resp.StatusCode, err)
		}
		resp.Body.Close()
	}
	if !state.SetupRequired || state.Authenticated {
		t.Errorf("state = %+v, want setupRequired on a fresh data dir", state)
	}

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("serveHTTP returned %v after shutdown", err)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("server did not shut down")
	}

	if n := strings.Count(logs.String(), "First-run setup token: "); n != 1 {
		t.Errorf("setup token announced %d times, want exactly once:\n%s", n, logs.String())
	}
}

func TestBuildHandlerDoesNotAnnounceTokenWhenAdminExists(t *testing.T) {
	restoreDefaultLogger(t)
	cfg := testConfig(t)
	// A valid admin.json from a first run: build once, complete setup via the
	// service is covered elsewhere, so write the file through the API.
	var logs bytes.Buffer
	logger := logging.New(&logs, slog.LevelInfo)
	handler, err := buildHandler(cfg, logger, nil)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	token := between(logs.String(), "First-run setup token: ", " ")
	body := `{"token":"` + token + `","password":"a perfectly good password"}`
	resp, err := http.Post(srv.URL+"/api/v1/auth/setup", "application/json", strings.NewReader(body))
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("setup: %v %v", resp, err)
	}
	resp.Body.Close()

	logs.Reset()
	if _, err := buildHandler(cfg, logger, nil); err != nil {
		t.Fatalf("second buildHandler: %v", err)
	}
	if strings.Contains(logs.String(), "First-run setup token") {
		t.Errorf("token announced although an admin exists:\n%s", logs.String())
	}
}

func between(s, after, until string) string {
	i := strings.Index(s, after)
	if i < 0 {
		return ""
	}
	s = s[i+len(after):]
	if j := strings.Index(s, until); j >= 0 {
		return s[:j]
	}
	return s
}

func TestBuildHandlerFailsFast(t *testing.T) {
	t.Run("corrupt admin.json", func(t *testing.T) {
		restoreDefaultLogger(t)
		cfg := testConfig(t)
		path := filepath.Join(cfg.DataDir, "admin.json")
		if err := os.WriteFile(path, []byte("{{{"), 0o600); err != nil {
			t.Fatal(err)
		}
		_, err := buildHandler(cfg, logging.New(io.Discard, slog.LevelInfo), nil)
		if err == nil || !strings.Contains(err.Error(), path) {
			t.Errorf("err = %v, want error naming %s", err, path)
		}
	})
	t.Run("data dir is a file", func(t *testing.T) {
		restoreDefaultLogger(t)
		cfg := testConfig(t)
		file := filepath.Join(cfg.DataDir, "afile")
		if err := os.WriteFile(file, nil, 0o600); err != nil {
			t.Fatal(err)
		}
		cfg.DataDir = file
		_, err := buildHandler(cfg, logging.New(io.Discard, slog.LevelInfo), nil)
		if err == nil || !strings.Contains(err.Error(), file) || !strings.Contains(err.Error(), "store: data directory") {
			t.Errorf("err = %v, want a store data-directory error naming %s", err, file)
		}
	})
}

func TestBuildHandlerInstallsTheRedactingLoggerAsDefault(t *testing.T) {
	restoreDefaultLogger(t)

	cfg := testConfig(t)
	var logs bytes.Buffer
	if _, err := buildHandler(cfg, logging.New(&logs, slog.LevelInfo), nil); err != nil {
		t.Fatalf("buildHandler: %v", err)
	}
	slog.Info("probe", "password", "hunter2hunter2", "ip", "10.0.0.7")
	out := logs.String()
	if !strings.Contains(out, `"msg":"probe"`) || !strings.Contains(out, "10.0.0.7") {
		t.Errorf("default logger does not write to the app logger: %q", out)
	}
	if strings.Contains(out, "hunter2hunter2") {
		t.Errorf("default logger did not redact the password: %q", out)
	}
}

func TestProbeURL(t *testing.T) {
	tests := map[string]string{
		":8080":          "http://127.0.0.1:8080/healthz",
		"0.0.0.0:9000":   "http://127.0.0.1:9000/healthz",
		"[::]:9000":      "http://127.0.0.1:9000/healthz",
		"127.0.0.1:8081": "http://127.0.0.1:8081/healthz",
		"10.0.0.5:8080":  "http://10.0.0.5:8080/healthz",
	}
	for listen, want := range tests {
		got, err := probeURL(listen)
		if err != nil || got != want {
			t.Errorf("probeURL(%q) = %q, %v; want %q", listen, got, err, want)
		}
	}
	if _, err := probeURL("nonsense"); err == nil {
		t.Error("probeURL(nonsense) succeeded")
	}
}

func TestProbe(t *testing.T) {
	ok := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) }))
	defer ok.Close()
	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(503) }))
	defer bad.Close()
	client := &http.Client{Timeout: time.Second}

	// Only 200 counts as healthy: other 2xx and 4xx answers are failures.
	for _, status := range []int{http.StatusNoContent, http.StatusNotFound} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(status) }))
		err := probe(client, srv.URL)
		srv.Close()
		if err == nil || !strings.Contains(err.Error(), strconv.Itoa(status)) {
			t.Errorf("status %d: err = %v, want one naming %d", status, err, status)
		}
	}

	if err := probe(client, ok.URL); err != nil {
		t.Errorf("healthy server: %v", err)
	}
	if err := probe(client, bad.URL); err == nil || !strings.Contains(err.Error(), "503") {
		t.Errorf("unhealthy server: err = %v, want one naming 503", err)
	}
	closed := httptest.NewServer(http.NotFoundHandler())
	url := closed.URL
	closed.Close()
	if err := probe(client, url); err == nil {
		t.Error("closed server: want error")
	}
}
