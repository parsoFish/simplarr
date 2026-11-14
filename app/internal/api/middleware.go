package api

import (
	"context"
	"net/http"
	"strings"

	"github.com/parsoFish/simplarr/app/internal/auth"
)

type ctxKey struct{}

// sessionFrom returns the session that protected stored on the request.
func sessionFrom(ctx context.Context) (auth.Session, bool) {
	s, ok := ctx.Value(ctxKey{}).(auth.Session)
	return s, ok
}

// contentSecurityPolicy lets the page load only its own scripts, styles and
// images. It has no inline allowance: the SPA must not rely on inline styles
// or scripts (revisit in the web UI plan if a component library needs them).
const contentSecurityPolicy = "default-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"

// securityHeaders adds the baseline response headers and marks API and health
// responses uncacheable.
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Content-Security-Policy", contentSecurityPolicy)
		if r.URL.Path == "/healthz" || strings.HasPrefix(r.URL.Path, "/api/") {
			h.Set("Cache-Control", "no-store")
		}
		next.ServeHTTP(w, r)
	})
}

func isSafeMethod(m string) bool {
	return m == http.MethodGet || m == http.MethodHead || m == http.MethodOptions
}

// sessionFromRequest looks up the session named by the session cookie.
func (s *server) sessionFromRequest(r *http.Request) (auth.Session, bool) {
	return s.auth.Session(cookieValue(r, sessionCookieName))
}

// protected requires a valid session, and for every non-GET request also a
// CSRF token (spec §8.2). The token in the csrf cookie, the one in the
// X-CSRF-Token header and the one stored in the session must all match, so a
// cookie planted by an attacker is not enough. Every future session-only
// route is wrapped with this.
func (s *server) protected(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sess, ok := s.sessionFromRequest(r)
		if !ok {
			writeError(w, http.StatusUnauthorized, "unauthorized",
				"You are not signed in.", "Open /login and sign in with the admin password.")
			return
		}
		if !isSafeMethod(r.Method) &&
			!auth.TokensMatch(sess.CSRF, cookieValue(r, csrfCookieName), r.Header.Get(csrfHeaderName)) {
			writeError(w, http.StatusForbidden, "csrf_failed",
				"The request was missing a valid CSRF token.", "Reload the page and try again.")
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxKey{}, sess)))
	})
}
