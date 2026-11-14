package api

import (
	"io/fs"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"testing/fstest"
)

func testUI() fstest.MapFS {
	return fstest.MapFS{
		"index.html":           {Data: []byte("<html><body>simplarr-shell</body></html>")},
		"assets/app-abc123.js": {Data: []byte("console.log('hi')")},
		"favicon.svg":          {Data: []byte("<svg/>")},
	}
}

func serve(h http.Handler, method, path string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(method, path, nil))
	return rec
}

func TestSPAServesIndexForClientRoutes(t *testing.T) {
	h := spaHandler(testUI())
	for _, path := range []string{"/", "/index.html", "/login", "/setup", "/services/radarr", "/deep/client/route"} {
		rec := serve(h, "GET", path)
		if rec.Code != 200 || !strings.Contains(rec.Body.String(), "simplarr-shell") {
			t.Errorf("%s: %d %q", path, rec.Code, rec.Body.String())
		}
		if got := rec.Header().Get("Cache-Control"); got != "no-cache" {
			t.Errorf("%s: Cache-Control = %q, want no-cache", path, got)
		}
		if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
			t.Errorf("%s: Content-Type = %q", path, ct)
		}
	}
}

func TestSPAServesAssetsWithLongCache(t *testing.T) {
	h := spaHandler(testUI())

	rec := serve(h, "GET", "/assets/app-abc123.js")
	if rec.Code != 200 || rec.Body.String() != "console.log('hi')" {
		t.Fatalf("asset: %d %q", rec.Code, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "javascript") {
		t.Errorf("Content-Type = %q", ct)
	}
	if cc := rec.Header().Get("Cache-Control"); !strings.Contains(cc, "immutable") || !strings.Contains(cc, "max-age=31536000") {
		t.Errorf("Cache-Control = %q", cc)
	}

	rec = serve(h, "GET", "/favicon.svg")
	if rec.Code != 200 || rec.Header().Get("Cache-Control") != "" {
		t.Errorf("non-assets file: %d, Cache-Control %q", rec.Code, rec.Header().Get("Cache-Control"))
	}
}

func TestSPAMissingFileIs404NotHTML(t *testing.T) {
	h := spaHandler(testUI())
	for _, path := range []string{"/assets/missing.js", "/nothing.png", "/assets/", "/assets", "/assets/sub/dir"} {
		rec := serve(h, "GET", path)
		if rec.Code != 404 {
			t.Errorf("%s: status %d, want 404", path, rec.Code)
		}
		wantError(t, rec.Result(), rec.Body.Bytes(), 404, "not_found")
		if strings.Contains(rec.Body.String(), "simplarr-shell") {
			t.Errorf("%s returned the HTML shell", path)
		}
	}
}

// spyFS records every name opened, so a test can prove the handler never asks
// the file system for an invalid (traversing) path.
type spyFS struct {
	fs.FS
	mu    sync.Mutex
	names []string
}

func (s *spyFS) Open(name string) (fs.File, error) {
	s.mu.Lock()
	s.names = append(s.names, name)
	s.mu.Unlock()
	return s.FS.Open(name)
}

func TestSPAPathTraversalNeverReachesTheFS(t *testing.T) {
	paths := []string{"/../../etc/passwd", "../../etc/passwd", "/assets/../../etc/passwd", "/..", "/a/../../b"}
	for _, p := range paths {
		spy := &spyFS{FS: testUI()}
		h := spaHandler(spy)
		rec := httptest.NewRecorder()
		req := httptest.NewRequest("GET", "/", nil)
		req.URL.Path = p // bypasses the mux's own cleaning
		h.ServeHTTP(rec, req)

		spy.mu.Lock()
		for _, name := range spy.names {
			if !fs.ValidPath(name) {
				t.Errorf("path %q: handler asked the FS to open invalid path %q", p, name)
			}
		}
		spy.mu.Unlock()
		if rec.Code != 200 || !strings.Contains(rec.Body.String(), "simplarr-shell") {
			t.Errorf("path %q: %d %q, want the HTML shell", p, rec.Code, rec.Body.String())
		}
	}
}

func TestSPAOnlyAllowsGetAndHead(t *testing.T) {
	h := spaHandler(testUI())
	if rec := serve(h, "HEAD", "/login"); rec.Code != 200 || rec.Body.Len() != 0 {
		t.Errorf("HEAD: %d, body %d bytes", rec.Code, rec.Body.Len())
	}
	rec := serve(h, "POST", "/")
	wantError(t, rec.Result(), rec.Body.Bytes(), 405, "method_not_allowed")
	if rec.Header().Get("Allow") != "GET, HEAD" {
		t.Errorf("Allow = %q", rec.Header().Get("Allow"))
	}
}

func TestSPAWithoutBuiltUIExplainsHowToBuildIt(t *testing.T) {
	cases := map[string]fs.FS{
		"nil":      nil,
		"no index": fstest.MapFS{"assets/x.js": {Data: []byte("x")}},
	}
	for name, fsys := range cases {
		t.Run(name, func(t *testing.T) {
			rec := serve(spaHandler(fsys), "GET", "/")
			wantError(t, rec.Result(), rec.Body.Bytes(), 503, "ui_not_built")
			if !strings.Contains(rec.Body.String(), "webdist") {
				t.Errorf("fix text should mention the webdist build tag: %s", rec.Body.String())
			}
		})
	}
}
