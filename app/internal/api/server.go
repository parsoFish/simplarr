package api

import (
	"io/fs"
	"log/slog"
	"net/http"

	"github.com/parsoFish/simplarr/app/internal/auth"
)

// Deps are everything the handlers need. All fields except Static are required.
type Deps struct {
	Auth    *auth.Service
	Limiter *auth.Limiter
	Logger  *slog.Logger
	// Static is the built SPA, or nil when the binary has no UI.
	Static fs.FS
}

type server struct {
	auth    *auth.Service
	limiter *auth.Limiter
	log     *slog.Logger
}

// NewHandler returns the complete HTTP handler: the API under /api/v1,
// /healthz, and the SPA for everything else.
//
// Client routes of the SPA must not start with a prefix nginx routes to
// another service (/radarr, /sonarr, /prowlarr, /overseerr, /torrent,
// /tautulli, /plex, /health/): spec §3.3.
func NewHandler(d Deps) http.Handler {
	s := &server{auth: d.Auth, limiter: d.Limiter, log: d.Logger}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("GET /api/v1/auth/state", s.authState)
	mux.HandleFunc("POST /api/v1/auth/setup", s.authSetup)
	mux.HandleFunc("POST /api/v1/auth/login", s.authLogin)
	mux.Handle("POST /api/v1/auth/logout", s.protected(http.HandlerFunc(s.authLogout)))
	mux.HandleFunc("/api/", func(w http.ResponseWriter, _ *http.Request) {
		writeError(w, http.StatusNotFound, "not_found", "No such API endpoint.", "")
	})
	mux.Handle("/", spaHandler(d.Static))
	return securityHeaders(mux)
}
