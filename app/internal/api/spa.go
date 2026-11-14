package api

import (
	"bytes"
	"io/fs"
	"net/http"
	"path"
	"strings"
	"time"
)

const uiNotBuiltFix = "Build the UI first: cd app/web && npm ci && npm run build, then " +
	"go build -tags webdist ./cmd/simplarr. The official container image already includes the UI."

// spaHandler serves the built React app from fsys: real files as themselves,
// and every other extension-less path as index.html so client-side routes
// (/login, /services/radarr) survive a reload. A missing file with an
// extension, or anything under assets/, is a 404 and never the HTML shell, so
// a broken asset URL fails loudly.
//
// fsys is nil, or has no index.html, when the binary was built without the
// webdist tag; every request then gets a 503 that says how to fix it.
func spaHandler(fsys fs.FS) http.Handler {
	var index []byte
	if fsys != nil {
		if b, err := fs.ReadFile(fsys, "index.html"); err == nil {
			index = b
		}
	}
	if index == nil {
		return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			writeError(w, http.StatusServiceUnavailable, "ui_not_built",
				"The web UI is not built into this binary.", uiNotBuiltFix)
		})
	}

	serveIndex := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-cache")
		http.ServeContent(w, r, "index.html", time.Time{}, bytes.NewReader(index))
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "Only GET and HEAD are allowed here.", "")
			return
		}
		// Clean against a rooted path so ".." can never leave the FS.
		name := strings.TrimPrefix(path.Clean("/"+r.URL.Path), "/")
		if name == "" || name == "index.html" {
			serveIndex(w, r)
			return
		}
		if info, err := fs.Stat(fsys, name); err == nil && !info.IsDir() {
			if strings.HasPrefix(name, "assets/") {
				// Vite content-hashes everything under assets/.
				w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
			}
			http.ServeFileFS(w, r, fsys, name)
			return
		}
		if path.Ext(name) != "" || name == "assets" || strings.HasPrefix(name, "assets/") {
			writeError(w, http.StatusNotFound, "not_found", "No such file.", "")
			return
		}
		serveIndex(w, r)
	})
}
