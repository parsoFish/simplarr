package auth

import (
	"crypto/sha256"
	"sync"
	"time"
)

// Session is one logged-in browser. CSRF is the token that the csrf cookie and
// the X-CSRF-Token header must both equal.
type Session struct {
	ID      string
	CSRF    string
	Expires time.Time
}

// entry is what the store keeps per session. It has no ID field on purpose:
// the map key is the SHA-256 digest of the ID, so a memory dump yields
// digests, which cannot be turned back into session cookies. The CSRF token
// is stored, but it is useless without the session cookie.
type entry struct {
	csrf    string
	expires time.Time
}

// Sessions is an in-memory session store with an absolute TTL. A restart logs
// everyone out, which is acceptable in milestone 1 (spec §8.2). IDs are never
// stored: the map is keyed by their SHA-256 digest and the value has no ID.
type Sessions struct {
	mu  sync.Mutex
	ttl time.Duration
	now func() time.Time
	m   map[[32]byte]entry
}

// NewSessions returns an empty store. now is injected so tests control time.
func NewSessions(ttl time.Duration, now func() time.Time) *Sessions {
	return &Sessions{ttl: ttl, now: now, m: make(map[[32]byte]entry)}
}

// TTL is how long a session lives, for cookie lifetimes.
func (s *Sessions) TTL() time.Duration { return s.ttl }

func sessionKey(id string) [32]byte { return sha256.Sum256([]byte(id)) }

// Create starts a session with a fresh 256-bit ID and CSRF token. A new ID on
// every login means a pre-login session ID is never reused (no fixation).
func (s *Sessions) Create() (Session, error) {
	id, err := GenerateToken()
	if err != nil {
		return Session{}, err
	}
	csrf, err := GenerateToken()
	if err != nil {
		return Session{}, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	s.sweepLocked(now)
	sess := Session{ID: id, CSRF: csrf, Expires: now.Add(s.ttl)}
	s.m[sessionKey(id)] = entry{csrf: csrf, expires: sess.Expires}
	return sess, nil
}

// Get returns the live session for id. An expired session is removed. The ID
// is re-attached from the argument, since the store does not hold it.
func (s *Sessions) Get(id string) (Session, bool) {
	if id == "" {
		return Session{}, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	key := sessionKey(id)
	e, ok := s.m[key]
	if !ok {
		return Session{}, false
	}
	if !s.now().Before(e.expires) {
		delete(s.m, key)
		return Session{}, false
	}
	return Session{ID: id, CSRF: e.csrf, Expires: e.expires}, true
}

// Delete ends a session. Deleting an unknown ID is a no-op.
func (s *Sessions) Delete(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.m, sessionKey(id))
}

func (s *Sessions) sweepLocked(now time.Time) {
	for k, e := range s.m {
		if !now.Before(e.expires) {
			delete(s.m, k)
		}
	}
}
