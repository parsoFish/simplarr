package auth

import (
	"crypto/sha256"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"
)

const testTTL = 7 * 24 * time.Hour

func TestSessionKeyIsSHA256OfTheID(t *testing.T) {
	if got, want := sessionKey("abc"), sha256.Sum256([]byte("abc")); got != want {
		t.Errorf("sessionKey(abc) = %x, want %x", got, want)
	}
}

func TestSessionStoreHoldsNoRawID(t *testing.T) {
	s := NewSessions(testTTL, newFakeClock().Now)
	sess, err := s.Create()
	mustNoErr(t, err)

	if len(s.m) != 1 {
		t.Fatalf("entries = %d, want 1", len(s.m))
	}
	for k := range s.m {
		if k != sessionKey(sess.ID) {
			t.Errorf("map key = %x, want SHA-256 of the ID", k)
		}
	}
	if dump := fmt.Sprintf("%v", s.m); strings.Contains(dump, sess.ID) {
		t.Errorf("store dump contains the raw session ID: %s", dump)
	}
	got, ok := s.Get(sess.ID)
	if !ok || got != sess {
		t.Errorf("Get = %+v, %v; want %+v, true", got, ok, sess)
	}
}

func TestSessionCreateAndGet(t *testing.T) {
	clock := newFakeClock()
	s := NewSessions(testTTL, clock.Now)

	a, err := s.Create()
	mustNoErr(t, err)
	b, err := s.Create()
	mustNoErr(t, err)

	if a.ID == b.ID || a.CSRF == b.CSRF || a.ID == a.CSRF {
		t.Errorf("sessions must have distinct random IDs and CSRF tokens: %+v %+v", a, b)
	}
	if !a.Expires.Equal(clock.Now().Add(testTTL)) {
		t.Errorf("Expires = %v, want now+7d", a.Expires)
	}
	got, ok := s.Get(a.ID)
	if !ok || got != a {
		t.Errorf("Get = %+v, %v; want %+v, true", got, ok, a)
	}
	if _, ok := s.Get("unknown"); ok {
		t.Error("Get(unknown) = true")
	}
	if _, ok := s.Get(""); ok {
		t.Error("Get(\"\") = true")
	}
}

func TestSessionExpires(t *testing.T) {
	clock := newFakeClock()
	s := NewSessions(testTTL, clock.Now)
	sess, err := s.Create()
	mustNoErr(t, err)

	clock.Advance(testTTL - time.Second)
	if _, ok := s.Get(sess.ID); !ok {
		t.Fatal("session expired early")
	}
	clock.Advance(time.Second)
	if _, ok := s.Get(sess.ID); ok {
		t.Fatal("session still valid at its expiry time")
	}
	if len(s.m) != 0 {
		t.Errorf("expired session was not removed: %d entries", len(s.m))
	}
}

func TestSessionDelete(t *testing.T) {
	s := NewSessions(testTTL, newFakeClock().Now)
	sess, err := s.Create()
	mustNoErr(t, err)
	s.Delete(sess.ID)
	if _, ok := s.Get(sess.ID); ok {
		t.Error("session survived Delete")
	}
	s.Delete("never existed") // must not panic
}

func TestSessionCreateSweepsExpired(t *testing.T) {
	clock := newFakeClock()
	s := NewSessions(time.Hour, clock.Now)
	for i := 0; i < 5; i++ {
		_, err := s.Create()
		mustNoErr(t, err)
	}
	clock.Advance(2 * time.Hour)
	_, err := s.Create()
	mustNoErr(t, err)
	if len(s.m) != 1 {
		t.Errorf("entries = %d, want 1 after sweep", len(s.m))
	}
}

func TestSessionsAreSafeForConcurrentUse(t *testing.T) {
	s := NewSessions(testTTL, newFakeClock().Now)
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			sess, err := s.Create()
			if err != nil {
				t.Error(err)
				return
			}
			if _, ok := s.Get(sess.ID); !ok {
				t.Error("own session not found")
			}
			s.Delete(sess.ID)
		}()
	}
	wg.Wait()
}
