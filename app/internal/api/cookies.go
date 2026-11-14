package api

import (
	"net/http"
	"strings"
	"time"

	"github.com/parsoFish/simplarr/app/internal/auth"
)

const (
	sessionCookieName = "simplarr_session"
	csrfCookieName    = "simplarr_csrf"
	csrfHeaderName    = "X-CSRF-Token"
)

// isHTTPS reports whether the browser reached nginx over HTTPS. nginx sets
// X-Forwarded-Proto; the Secure flag is only added then, so plain-HTTP LAN
// use keeps working.
func isHTTPS(r *http.Request) bool {
	return strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https")
}

func newCookie(name, value string, maxAge int, httpOnly, secure bool) *http.Cookie {
	return &http.Cookie{
		Name:     name,
		Value:    value,
		Path:     "/",
		MaxAge:   maxAge,
		HttpOnly: httpOnly,
		Secure:   secure,
		SameSite: http.SameSiteStrictMode,
	}
}

// setSessionCookies sets the HttpOnly session cookie and the CSRF cookie. The
// CSRF cookie must stay readable by the SPA so it can echo the value in the
// X-CSRF-Token header.
func setSessionCookies(w http.ResponseWriter, r *http.Request, s auth.Session, ttl time.Duration) {
	maxAge := int(ttl.Seconds())
	secure := isHTTPS(r)
	http.SetCookie(w, newCookie(sessionCookieName, s.ID, maxAge, true, secure))
	http.SetCookie(w, newCookie(csrfCookieName, s.CSRF, maxAge, false, secure))
}

func clearSessionCookies(w http.ResponseWriter, r *http.Request) {
	secure := isHTTPS(r)
	http.SetCookie(w, newCookie(sessionCookieName, "", -1, true, secure))
	http.SetCookie(w, newCookie(csrfCookieName, "", -1, false, secure))
}

// cookieValue returns the named cookie's value, or "" when it is absent.
func cookieValue(r *http.Request, name string) string {
	c, err := r.Cookie(name)
	if err != nil { // the only error is http.ErrNoCookie
		return ""
	}
	return c.Value
}
