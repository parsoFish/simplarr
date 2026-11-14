package api

import (
	"context"
	"errors"
	"fmt"
	"math"
	"net/http"
	"strconv"
	"strings"

	"github.com/parsoFish/simplarr/app/internal/auth"
)

type stateResponse struct {
	SetupRequired bool `json:"setupRequired"`
	Authenticated bool `json:"authenticated"`
}

func (s *server) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// authState tells the SPA which screen to show. It is open to anyone: it
// reveals only whether setup is pending and whether the caller is signed in.
func (s *server) authState(w http.ResponseWriter, r *http.Request) {
	_, authed := s.sessionFromRequest(r)
	writeJSON(w, http.StatusOK, stateResponse{SetupRequired: s.auth.SetupRequired(), Authenticated: authed})
}

// rejectIfLimited charges one attempt against ip and answers 429 (returning
// true) when ip has used up its attempts. It runs after the body is parsed and
// before any password work, so a limited client cannot burn CPU, cannot learn
// whether a guess was right, and cannot beat the limit with a parallel burst
// (see auth.Limiter).
func (s *server) rejectIfLimited(w http.ResponseWriter, ip string) bool {
	ok, retry := s.limiter.Allow(ip)
	if ok {
		return false
	}
	seconds := int(math.Ceil(retry.Seconds()))
	minutes := int(math.Ceil(float64(seconds) / 60))
	w.Header().Set("Retry-After", strconv.Itoa(seconds))
	s.log.Warn("rate limited", "ip", ip, "retryAfterSeconds", seconds)
	writeError(w, http.StatusTooManyRequests, "rate_limited",
		"Too many failed attempts.", fmt.Sprintf("Wait %d minute(s) and try again.", minutes))
	return true
}

func (s *server) internalError(w http.ResponseWriter, r *http.Request, what string, err error) {
	s.log.Error(what, "path", r.URL.Path, "err", err)
	writeError(w, http.StatusInternalServerError, "internal",
		"Something went wrong on the server.", "Check the simplarr container logs.")
}

func (s *server) authSetup(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Token    string `json:"token"`
		Password string `json:"password"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	ip := clientIP(r)
	if s.rejectIfLimited(w, ip) {
		return
	}

	err := s.auth.Setup(r.Context(), req.Token, req.Password)
	switch {
	case err == nil:
		s.limiter.Reset(ip)
		s.log.Info("admin password set", "ip", ip)
		writeJSON(w, http.StatusOK, stateResponse{})
	case errors.Is(err, auth.ErrSetupComplete):
		writeError(w, http.StatusConflict, "setup_complete",
			"Setup has already been completed.", "Sign in at /login.")
	case errors.Is(err, auth.ErrInvalidSetupToken):
		s.log.Warn("setup token rejected", "ip", ip)
		writeError(w, http.StatusForbidden, "invalid_setup_token",
			"The setup token is wrong.", "Copy it from the container logs: docker logs simplarr")
	case errors.Is(err, auth.ErrWeakPassword):
		reason := strings.TrimPrefix(err.Error(), auth.ErrWeakPassword.Error()+": ")
		writeError(w, http.StatusBadRequest, "weak_password", "Password rejected: "+reason+".", "")
	case errors.Is(err, context.Canceled):
		// The client went away; nothing to answer.
	default:
		s.internalError(w, r, "setup failed", err)
	}
}

func (s *server) authLogin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Password string `json:"password"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	ip := clientIP(r)
	if s.rejectIfLimited(w, ip) {
		return
	}

	sess, err := s.auth.Login(r.Context(), req.Password)
	switch {
	case err == nil:
		s.limiter.Reset(ip)
		setSessionCookies(w, r, sess, s.auth.SessionTTL())
		s.log.Info("login succeeded", "ip", ip)
		writeJSON(w, http.StatusOK, stateResponse{Authenticated: true})
	case errors.Is(err, auth.ErrSetupRequired):
		writeError(w, http.StatusConflict, "setup_required",
			"No admin password has been set yet.", "Open /setup and enter the setup token from the container logs.")
	case errors.Is(err, auth.ErrInvalidCredentials):
		s.log.Warn("login failed", "ip", ip)
		writeError(w, http.StatusUnauthorized, "invalid_credentials", "Incorrect password.", "")
	case errors.Is(err, context.Canceled):
		// The client went away; nothing to answer.
	default:
		s.internalError(w, r, "login failed unexpectedly", err)
	}
}

func (s *server) authLogout(w http.ResponseWriter, r *http.Request) {
	if sess, ok := sessionFrom(r.Context()); ok {
		s.auth.Logout(sess.ID)
	}
	clearSessionCookies(w, r)
	writeJSON(w, http.StatusOK, stateResponse{})
}
