package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
)

func TestSecurityHeadersOnEveryResponse(t *testing.T) {
	e := newEnv(t, fstest.MapFS{"index.html": {Data: []byte("<html></html>")}})
	for _, path := range []string{"/healthz", statePath, "/api/v1/nope", "/", "/login"} {
		resp, _ := e.do("GET", path, nil)
		want := map[string]string{
			"X-Content-Type-Options": "nosniff",
			"X-Frame-Options":        "DENY",
			"Referrer-Policy":        "no-referrer",
		}
		for h, v := range want {
			if got := resp.Header.Get(h); got != v {
				t.Errorf("%s: %s = %q, want %q", path, h, got, v)
			}
		}
		csp := resp.Header.Get("Content-Security-Policy")
		for _, directive := range []string{
			"default-src 'self'", "frame-ancestors 'none'",
			"base-uri 'none'", "form-action 'self'", "img-src 'self' data:",
		} {
			if !strings.Contains(csp, directive) {
				t.Errorf("%s: CSP %q is missing %q", path, csp, directive)
			}
		}
		for _, banned := range []string{"unsafe-inline", "unsafe-eval"} {
			if strings.Contains(csp, banned) {
				t.Errorf("%s: CSP %q must not contain %q", path, csp, banned)
			}
		}
	}
	for _, path := range []string{"/healthz", statePath, "/api/v1/nope"} {
		resp, _ := e.do("GET", path, nil)
		if got := resp.Header.Get("Cache-Control"); got != "no-store" {
			t.Errorf("%s: Cache-Control = %q, want no-store", path, got)
		}
	}
}

func TestUnknownAPIPathIsJSON404(t *testing.T) {
	e := newEnv(t, fstest.MapFS{"index.html": {Data: []byte("<html></html>")}})
	resp, body := e.do("GET", "/api/v1/nope", nil)
	wantError(t, resp, body, 404, "not_found")
}

// protected is the gate every later session-only route will use. Logout is the
// only POST route in this plan, so the GET behaviour is tested directly.
func TestProtectedChecksCSRFOnlyForUnsafeMethods(t *testing.T) {
	e := newEnv(t, nil)
	e.completeSetup()
	sess, err := e.svc.Login(t.Context(), testPassword)
	if err != nil {
		t.Fatal(err)
	}
	s := &server{auth: e.svc}
	handler := s.protected(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got, ok := sessionFrom(r.Context())
		if !ok || got.ID != sess.ID {
			t.Errorf("session not in context: %+v, %v", got, ok)
		}
		w.WriteHeader(http.StatusNoContent)
	}))

	call := func(method string, withSession bool, csrfHeader string) int {
		req := httptest.NewRequest(method, "/x", nil)
		if withSession {
			req.AddCookie(&http.Cookie{Name: sessionCookieName, Value: sess.ID})
			req.AddCookie(&http.Cookie{Name: csrfCookieName, Value: sess.CSRF})
		}
		if csrfHeader != "" {
			req.Header.Set(csrfHeaderName, csrfHeader)
		}
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		return rec.Code
	}

	tests := []struct {
		name        string
		method      string
		withSession bool
		header      string
		want        int
	}{
		{"GET with session, no csrf", "GET", true, "", 204},
		{"HEAD with session, no csrf", "HEAD", true, "", 204},
		{"GET without session", "GET", false, "", 401},
		{"POST with session and csrf", "POST", true, sess.CSRF, 204},
		{"POST without csrf header", "POST", true, "", 403},
		{"POST with wrong csrf", "POST", true, "nope", 403},
		{"PUT without csrf header", "PUT", true, "", 403},
		{"DELETE without csrf header", "DELETE", true, "", 403},
		{"POST without session", "POST", false, sess.CSRF, 401},
	}
	for _, tc := range tests {
		if got := call(tc.method, tc.withSession, tc.header); got != tc.want {
			t.Errorf("%s: status = %d, want %d", tc.name, got, tc.want)
		}
	}
}

// The csrf cookie is half of the double-submit pair: a correct header with the
// cookie missing or planted must still be refused, and a safe method needs none
// of it.
func TestProtectedRequiresTheCSRFCookieToo(t *testing.T) {
	e := newEnv(t, nil)
	e.completeSetup()
	sess, err := e.svc.Login(t.Context(), testPassword)
	if err != nil {
		t.Fatal(err)
	}
	s := &server{auth: e.svc}
	handler := s.protected(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))

	tests := []struct {
		name       string
		method     string
		csrfCookie string // "" means no csrf cookie is sent
		header     string
		want       int
	}{
		{"correct header, no csrf cookie", "POST", "", sess.CSRF, 403},
		{"correct header, planted csrf cookie", "POST", "attacker-token", sess.CSRF, 403},
		{"OPTIONS with session only", "OPTIONS", "", "", 204},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(tc.method, "/x", nil)
			req.AddCookie(&http.Cookie{Name: sessionCookieName, Value: sess.ID})
			if tc.csrfCookie != "" {
				req.AddCookie(&http.Cookie{Name: csrfCookieName, Value: tc.csrfCookie})
			}
			if tc.header != "" {
				req.Header.Set(csrfHeaderName, tc.header)
			}
			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, req)
			if rec.Code != tc.want {
				t.Errorf("status = %d, want %d", rec.Code, tc.want)
			}
		})
	}
}

func TestClientIP(t *testing.T) {
	tests := []struct {
		name       string
		realIP     string
		remoteAddr string
		want       string
	}{
		{"header wins", "203.0.113.7", "172.18.0.2:5555", "203.0.113.7"},
		{"header trimmed", " 203.0.113.7 ", "172.18.0.2:5555", "203.0.113.7"},
		{"ipv6 header", "2001:db8::1", "172.18.0.2:5555", "2001:db8::1"},
		{"ipv4-mapped ipv6 is unmapped", "::ffff:203.0.113.7", "172.18.0.2:5555", "203.0.113.7"},
		{"invalid header falls back", "not-an-ip", "172.18.0.2:5555", "172.18.0.2"},
		{"no header", "", "172.18.0.2:5555", "172.18.0.2"},
		{"ipv6 remote", "", "[2001:db8::2]:5555", "2001:db8::2"},
		{"remote without port", "", "172.18.0.2", "172.18.0.2"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest("GET", "/", nil)
			req.RemoteAddr = tc.remoteAddr
			if tc.realIP != "" {
				req.Header.Set("X-Real-IP", tc.realIP)
			}
			if got := clientIP(req); got != tc.want {
				t.Errorf("clientIP = %q, want %q", got, tc.want)
			}
		})
	}
}
