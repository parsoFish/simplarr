package auth

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const (
	testMaxAttempts = 5
	testWindow      = 15 * time.Minute
)

func newTestLimiter(clock *fakeClock) *Limiter {
	return NewLimiter(testMaxAttempts, testWindow, clock.Now)
}

func TestLimiterRefusesTheAttemptAfterMax(t *testing.T) {
	l := newTestLimiter(newFakeClock())

	for i := 1; i <= testMaxAttempts; i++ {
		if ok, _ := l.Allow("10.0.0.1"); !ok {
			t.Fatalf("attempt %d refused, want it allowed", i)
		}
	}
	ok, retry := l.Allow("10.0.0.1")
	if ok {
		t.Fatal("attempt 6 allowed, want it refused")
	}
	if retry <= 0 || retry > testWindow {
		t.Errorf("retryAfter = %v, want in (0, 15m]", retry)
	}
}

func TestLimiterTracksEachKeySeparately(t *testing.T) {
	l := newTestLimiter(newFakeClock())
	for i := 0; i < testMaxAttempts; i++ {
		l.Allow("10.0.0.1")
	}
	if ok, _ := l.Allow("10.0.0.2"); !ok {
		t.Error("a different IP was refused")
	}
}

func TestLimiterAttemptsExpire(t *testing.T) {
	clock := newFakeClock()
	l := newTestLimiter(clock)
	for i := 0; i < testMaxAttempts; i++ {
		l.Allow("10.0.0.1")
	}
	clock.Advance(testWindow - time.Second)
	if ok, retry := l.Allow("10.0.0.1"); ok || retry != time.Second {
		t.Errorf("Allow = %v, %v; want false, 1s", ok, retry)
	}
	clock.Advance(time.Second)
	if ok, _ := l.Allow("10.0.0.1"); !ok {
		t.Error("still refused after the window")
	}
}

func TestLimiterRefusedAttemptsDoNotExtendTheBlock(t *testing.T) {
	clock := newFakeClock()
	l := newTestLimiter(clock)
	for i := 0; i < testMaxAttempts; i++ {
		l.Allow("ip")
	}
	clock.Advance(10 * time.Minute)
	for i := 0; i < 20; i++ { // hammering while blocked
		l.Allow("ip")
	}
	clock.Advance(5*time.Minute + time.Second) // the first five have now left the window
	if ok, _ := l.Allow("ip"); !ok {
		t.Error("refused attempts extended the block")
	}
}

func TestLimiterWindowSlides(t *testing.T) {
	clock := newFakeClock()
	l := newTestLimiter(clock)
	for i := 0; i < testMaxAttempts-1; i++ { // 4 attempts at t=0
		l.Allow("ip")
	}
	clock.Advance(10 * time.Minute)
	if ok, _ := l.Allow("ip"); !ok { // 5th at t=10m
		t.Fatal("5th attempt refused")
	}
	if ok, _ := l.Allow("ip"); ok {
		t.Fatal("6th attempt allowed")
	}
	clock.Advance(5*time.Minute + time.Second) // t=15m01s: the four old ones expired
	for i := 0; i < testMaxAttempts-1; i++ {
		if ok, _ := l.Allow("ip"); !ok {
			t.Fatalf("attempt %d after the window slid was refused", i+1)
		}
	}
	if ok, _ := l.Allow("ip"); ok {
		t.Error("allowed more than max inside the window")
	}
}

func TestLimiterResetClearsAttempts(t *testing.T) {
	l := newTestLimiter(newFakeClock())
	for i := 0; i < testMaxAttempts; i++ {
		l.Allow("ip")
	}
	l.Reset("ip")
	if ok, _ := l.Allow("ip"); !ok {
		t.Error("refused after Reset")
	}
	l.Reset("never seen") // must not panic
}

func TestLimiterIsAtomicUnderConcurrency(t *testing.T) {
	const callers, rounds = 64, 200
	for round := 0; round < rounds; round++ {
		l := newTestLimiter(newFakeClock())
		start := make(chan struct{})
		var wg sync.WaitGroup
		var allowed atomic.Int32
		for i := 0; i < callers; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				<-start // release every caller at the same instant
				if ok, _ := l.Allow("ip"); ok {
					allowed.Add(1)
				}
			}()
		}
		close(start)
		wg.Wait()
		if got := allowed.Load(); got != testMaxAttempts {
			t.Fatalf("round %d: allowed = %d, want exactly %d", round, got, testMaxAttempts)
		}
	}
}

func TestLimiterCapsTrackedKeys(t *testing.T) {
	clock := newFakeClock()
	l := newTestLimiter(clock)
	l.maxKeys = 3

	l.Allow("a")
	clock.Advance(time.Second)
	l.Allow("b")
	clock.Advance(time.Second)
	l.Allow("c")
	clock.Advance(time.Second)
	l.Allow("d") // at the cap: evicts the key with the oldest attempt ("a")

	if len(l.attempts) != 3 {
		t.Fatalf("tracked keys = %d, want 3", len(l.attempts))
	}
	if _, ok := l.attempts["a"]; ok {
		t.Error("oldest key was not evicted")
	}
	if _, ok := l.attempts["d"]; !ok {
		t.Error("new key was not tracked")
	}
}

func TestLimiterCapEvictionDropsExpiredFirst(t *testing.T) {
	clock := newFakeClock()
	l := newTestLimiter(clock)
	l.maxKeys = 2
	l.Allow("old1")
	l.Allow("old2")
	clock.Advance(testWindow + time.Second)
	l.Allow("fresh")
	if len(l.attempts) != 1 {
		t.Errorf("tracked keys = %d, want 1 (both expired keys swept)", len(l.attempts))
	}
}
