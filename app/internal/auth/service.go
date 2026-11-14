package auth

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/parsoFish/simplarr/app/internal/store"
)

const (
	adminFileName    = "admin.json"
	adminFileVersion = 1
	adminFileMode    = os.FileMode(0o600)

	minPasswordRunes = 12
	maxPasswordBytes = 1024
)

// Errors the API layer maps to responses.
var (
	ErrSetupRequired      = errors.New("auth: first-run setup has not been completed")
	ErrSetupComplete      = errors.New("auth: first-run setup is already complete")
	ErrInvalidSetupToken  = errors.New("auth: invalid setup token")
	ErrInvalidCredentials = errors.New("auth: invalid password")
	ErrWeakPassword       = errors.New("auth: password does not meet the policy")
)

// adminFile is the on-disk shape of /data/admin.json.
type adminFile struct {
	Version      int    `json:"version"`
	PasswordHash string `json:"passwordHash"`
}

// ServiceConfig carries Service's dependencies.
type ServiceConfig struct {
	DataDir  string
	Hasher   *Hasher
	Sessions *Sessions
	Logger   *slog.Logger
}

// Service owns the single admin account: the first-run setup token, the
// password hash on disk, and login/logout.
type Service struct {
	adminPath string
	hasher    *Hasher
	sessions  *Sessions

	setupMu sync.Mutex // serialises Setup so two callers cannot both win

	mu         sync.RWMutex
	hash       string // empty until setup is complete
	setupToken string // empty once setup is complete; memory only
}

// NewService loads /data/admin.json. If it is missing the service starts in
// setup mode with a new random setup token. A file that exists but cannot be
// parsed is a fatal error (it must never silently re-open setup).
func NewService(c ServiceConfig) (*Service, error) {
	s := &Service{
		adminPath: filepath.Join(c.DataDir, adminFileName),
		hasher:    c.Hasher,
		sessions:  c.Sessions,
	}
	if err := store.EnforceMode(s.adminPath, adminFileMode, c.Logger); err != nil {
		return nil, err
	}

	data, err := os.ReadFile(s.adminPath)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		tok, err := NewSetupToken()
		if err != nil {
			return nil, err
		}
		s.setupToken = tok
	case err != nil:
		return nil, fmt.Errorf("auth: read %s: %w", s.adminPath, err)
	default:
		hash, err := parseAdminFile(data)
		if err != nil {
			return nil, fmt.Errorf("auth: %s is not a valid admin file: %w", s.adminPath, err)
		}
		s.hash = hash
	}
	return s, nil
}

func parseAdminFile(data []byte) (string, error) {
	var f adminFile
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&f); err != nil {
		return "", err
	}
	if f.Version != adminFileVersion {
		return "", fmt.Errorf("unsupported version %d", f.Version)
	}
	if _, _, _, err := decodeHash(f.PasswordHash); err != nil {
		return "", err
	}
	return f.PasswordHash, nil
}

// SetupRequired reports whether no admin password has been set yet.
func (s *Service) SetupRequired() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.hash == ""
}

// PendingSetupToken returns the token to announce in the logs, if setup is
// still pending.
func (s *Service) PendingSetupToken() (string, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.setupToken, s.setupToken != ""
}

// SessionTTL is the session lifetime, for cookie expiry.
func (s *Service) SessionTTL() time.Duration { return s.sessions.TTL() }

// ValidatePassword enforces the admin password policy: at least 12
// characters (not bytes), at most 1024 bytes.
func ValidatePassword(p string) error {
	if utf8.RuneCountInString(p) < minPasswordRunes {
		return fmt.Errorf("%w: use at least %d characters", ErrWeakPassword, minPasswordRunes)
	}
	if len(p) > maxPasswordBytes {
		return fmt.Errorf("%w: use at most %d bytes", ErrWeakPassword, maxPasswordBytes)
	}
	return nil
}

// Setup completes first-run setup: it checks the setup token, applies the
// password policy, writes admin.json atomically with mode 0600, and
// invalidates the token. It does not log the user in.
func (s *Service) Setup(ctx context.Context, token, password string) error {
	s.setupMu.Lock()
	defer s.setupMu.Unlock()

	s.mu.RLock()
	complete, want := s.hash != "", s.setupToken
	s.mu.RUnlock()
	if complete {
		return ErrSetupComplete
	}
	if token == "" || subtle.ConstantTimeCompare([]byte(token), []byte(want)) != 1 {
		return ErrInvalidSetupToken
	}
	if err := ValidatePassword(password); err != nil {
		return err
	}

	hash, err := s.hasher.Hash(ctx, password)
	if err != nil {
		return fmt.Errorf("auth: hash admin password: %w", err)
	}
	data, err := json.MarshalIndent(adminFile{Version: adminFileVersion, PasswordHash: hash}, "", "  ")
	if err != nil {
		return fmt.Errorf("auth: encode admin file: %w", err)
	}
	if err := store.WriteFileAtomic(s.adminPath, data, adminFileMode); err != nil {
		return err
	}

	s.mu.Lock()
	s.hash, s.setupToken = hash, ""
	s.mu.Unlock()
	return nil
}

// Login checks the admin password and starts a session.
func (s *Service) Login(ctx context.Context, password string) (Session, error) {
	s.mu.RLock()
	hash := s.hash
	s.mu.RUnlock()
	if hash == "" {
		return Session{}, ErrSetupRequired
	}
	ok, err := s.hasher.Verify(ctx, hash, password)
	if err != nil {
		return Session{}, fmt.Errorf("auth: verify password: %w", err)
	}
	if !ok {
		return Session{}, ErrInvalidCredentials
	}
	return s.sessions.Create()
}

// Session returns the live session for id.
func (s *Service) Session(id string) (Session, bool) { return s.sessions.Get(id) }

// Logout ends a session.
func (s *Service) Logout(id string) { s.sessions.Delete(id) }
