package auth

import (
	"sync"
	"time"
)

const defaultMaxTrackedKeys = 10_000

// Limiter allows each key (a client IP) at most max attempts inside a sliding
// window (spec §8.2: 5 failures per 15 minutes). golang.org/x/time/rate is a
// token bucket and cannot express "block after N attempts, reset on success";
// this is a fixed rule in about 70 lines.
//
// Allow checks and charges in one step, before the password is verified.
// Recording failures afterwards would leave a gap in which a burst of parallel
// requests all pass a "not blocked yet" check; charging first closes it. A
// successful login calls Reset, so honest users never accumulate attempts.
type Limiter struct {
	mu       sync.Mutex
	max      int
	window   time.Duration
	now      func() time.Time
	maxKeys  int
	attempts map[string][]time.Time // ascending attempt times per key
}

// NewLimiter returns a Limiter. now is injected so tests control time.
func NewLimiter(max int, window time.Duration, now func() time.Time) *Limiter {
	return &Limiter{
		max: max, window: window, now: now,
		maxKeys:  defaultMaxTrackedKeys,
		attempts: make(map[string][]time.Time),
	}
}

// Allow records an attempt for key and reports whether it may proceed. When
// it may not, retryAfter is how long until the oldest attempt leaves the
// window. A refused attempt is not recorded, so a block never extends itself.
func (l *Limiter) Allow(key string) (ok bool, retryAfter time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	recent := l.pruneLocked(key, now)
	if len(recent) >= l.max {
		return false, recent[0].Add(l.window).Sub(now)
	}
	if _, tracked := l.attempts[key]; !tracked && len(l.attempts) >= l.maxKeys {
		l.makeRoomLocked(now)
	}
	l.attempts[key] = append(recent, now)
	return true, 0
}

// Reset forgets key's attempts, after a successful login or setup.
func (l *Limiter) Reset(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.attempts, key)
}

// pruneLocked drops attempts that left the window and returns what remains.
func (l *Limiter) pruneLocked(key string, now time.Time) []time.Time {
	ts, ok := l.attempts[key]
	if !ok {
		return nil
	}
	cutoff := now.Add(-l.window)
	i := 0
	for i < len(ts) && !ts[i].After(cutoff) {
		i++
	}
	if i == len(ts) {
		delete(l.attempts, key)
		return nil
	}
	kept := append([]time.Time(nil), ts[i:]...)
	l.attempts[key] = kept
	return kept
}

// makeRoomLocked frees one slot: expired keys first, otherwise the key whose
// newest attempt is oldest. That bounds memory even if a client can vary the
// key it presents.
func (l *Limiter) makeRoomLocked(now time.Time) {
	for k := range l.attempts {
		l.pruneLocked(k, now)
	}
	if len(l.attempts) < l.maxKeys {
		return
	}
	var oldestKey string
	var oldest time.Time
	first := true
	for k, ts := range l.attempts {
		newest := ts[len(ts)-1]
		if first || newest.Before(oldest) {
			oldestKey, oldest, first = k, newest, false
		}
	}
	delete(l.attempts, oldestKey)
}
