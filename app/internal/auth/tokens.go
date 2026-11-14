package auth

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"log/slog"
)

// GenerateToken returns 256 random bits as unpadded base64url. It is used for
// session IDs and CSRF tokens.
func GenerateToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("auth: generate token: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// NewSetupToken returns the 128-bit first-run setup token as 32 hex characters.
func NewSetupToken() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("auth: generate setup token: %w", err)
	}
	return hex.EncodeToString(b), nil
}

// TokensMatch implements the double-submit CSRF check, bound to the session:
// the token stored in the session, the one in the CSRF cookie and the one in
// the X-CSRF-Token header must all be present and equal.
func TokensMatch(session, cookie, header string) bool {
	if session == "" {
		return false
	}
	a := subtle.ConstantTimeCompare([]byte(session), []byte(cookie))
	b := subtle.ConstantTimeCompare([]byte(session), []byte(header))
	return a&b == 1
}

// AnnounceSetupToken logs the setup token once at WARN so the operator can
// read it from `docker logs`. The token goes in the message text on purpose:
// the logging package redacts attributes named like secrets, so it would
// vanish from an attribute. This is the only place a secret is logged.
func AnnounceSetupToken(log *slog.Logger, token string) {
	log.Warn("First-run setup token: " + token + " (enter it at http://<host>/setup)")
}
