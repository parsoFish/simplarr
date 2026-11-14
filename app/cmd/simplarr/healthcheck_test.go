package main

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHealthcheckCommandExitCodes(t *testing.T) {
	// answers 200 only on /healthz, so the test also proves the probe path.
	healthy := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/healthz" {
			http.NotFound(w, r)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	unhealthy := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	})

	tests := []struct {
		name     string
		handler  http.Handler
		closed   bool
		wantCode int
		wantErr  string
	}{
		{"healthy server", healthy, false, 0, ""},
		{"unhealthy server", unhealthy, false, 1, "503"},
		{"server that is down", healthy, true, 1, "healthcheck:"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(tc.handler)
			addr := srv.Listener.Addr().String()
			if tc.closed {
				srv.Close()
			} else {
				defer srv.Close()
			}

			var out, errOut bytes.Buffer
			code := run([]string{"healthcheck"}, &out, &errOut, envMap(map[string]string{"SIMPLARR_LISTEN": addr}))
			if code != tc.wantCode {
				t.Errorf("exit code = %d, want %d (stderr %q)", code, tc.wantCode, errOut.String())
			}
			if !strings.Contains(errOut.String(), tc.wantErr) {
				t.Errorf("stderr = %q, want it to contain %q", errOut.String(), tc.wantErr)
			}
			if tc.wantCode == 0 && errOut.Len() != 0 {
				t.Errorf("stderr = %q, want it empty on success", errOut.String())
			}
		})
	}
}
