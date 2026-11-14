package auth

import (
	"context"
	"encoding/base64"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestDefaultParamsMatchSpec(t *testing.T) {
	// Spec §8.2: memory 64 MiB, time 3, threads 2, 16-byte salt, 32-byte key.
	want := Params{Memory: 64 * 1024, Time: 3, Threads: 2, SaltLen: 16, KeyLen: 32}
	if DefaultParams != want {
		t.Errorf("DefaultParams = %+v, want %+v", DefaultParams, want)
	}
}

func TestHashAndVerify(t *testing.T) {
	h := newTestHasher()
	ctx := context.Background()
	enc, err := h.Hash(ctx, "correct horse battery")
	mustNoErr(t, err)

	ok, err := h.Verify(ctx, enc, "correct horse battery")
	if err != nil || !ok {
		t.Fatalf("Verify(correct) = %v, %v; want true, nil", ok, err)
	}
	ok, err = h.Verify(ctx, enc, "wrong horse battery")
	if err != nil || ok {
		t.Fatalf("Verify(wrong) = %v, %v; want false, nil", ok, err)
	}
}

func TestHashesAreSalted(t *testing.T) {
	h := newTestHasher()
	a, err := h.Hash(context.Background(), "same password 123")
	mustNoErr(t, err)
	b, err := h.Hash(context.Background(), "same password 123")
	mustNoErr(t, err)
	if a == b {
		t.Error("two hashes of the same password are identical: salt is not random")
	}
}

func TestEncodedHashRecordsParameters(t *testing.T) {
	enc, err := NewHasher(DefaultParams, 1).Hash(context.Background(), "a long enough password")
	mustNoErr(t, err)
	if !strings.HasPrefix(enc, "$argon2id$v=19$m=65536,t=3,p=2$") {
		t.Fatalf("encoded = %q", enc)
	}
	parts := strings.Split(enc, "$")
	salt, err := base64.RawStdEncoding.DecodeString(parts[4])
	mustNoErr(t, err)
	key, err := base64.RawStdEncoding.DecodeString(parts[5])
	mustNoErr(t, err)
	if len(salt) != 16 || len(key) != 32 {
		t.Errorf("salt/key lengths = %d/%d, want 16/32", len(salt), len(key))
	}
	// A parameter bump must not lock the admin out: the hash this hasher
	// emitted for DefaultParams has to verify with the same hasher.
	h := NewHasher(DefaultParams, 1)
	ok, err := h.Verify(context.Background(), enc, "a long enough password")
	if err != nil || !ok {
		t.Errorf("Verify(DefaultParams hash) = %v, %v; want true, nil", ok, err)
	}
}

func TestVerifyUsesParametersStoredWithTheHash(t *testing.T) {
	old := NewHasher(Params{Memory: 64, Time: 1, Threads: 1, SaltLen: 16, KeyLen: 32}, 1)
	enc, err := old.Hash(context.Background(), "an older password hash")
	mustNoErr(t, err)

	raised := NewHasher(Params{Memory: 128, Time: 2, Threads: 2, SaltLen: 16, KeyLen: 32}, 1)
	ok, err := raised.Verify(context.Background(), enc, "an older password hash")
	if err != nil || !ok {
		t.Fatalf("Verify with raised params = %v, %v; want true, nil", ok, err)
	}
}

func TestVerifyRejectsMalformedHashes(t *testing.T) {
	good, err := newTestHasher().Hash(context.Background(), "a long enough password")
	mustNoErr(t, err)
	parts := strings.Split(good, "$") // "", argon2id, v=19, params, salt, key

	with := func(i int, v string) string {
		c := append([]string(nil), parts...)
		c[i] = v
		return strings.Join(c, "$")
	}
	tests := map[string]string{
		"empty":                  "",
		"plain text":             "not-a-hash",
		"wrong algorithm":        with(1, "argon2i"),
		"wrong version":          with(2, "v=18"),
		"no params":              with(3, ""),
		"param order":            with(3, "t=1,m=64,p=1"),
		"zero time":              with(3, "m=64,t=0,p=1"),
		"zero threads":           with(3, "m=64,t=1,p=0"),
		"memory too low":         with(3, "m=4,t=1,p=1"),
		"memory absurd":          with(3, "m=4294967295,t=1,p=1"),
		"time absurd":            with(3, "m=64,t=1000,p=1"),
		"salt not b64":           with(4, "!!!"),
		"salt empty":             with(4, ""),
		"key not b64":            with(5, "!!!"),
		"key too short":          with(5, "AAAA"),
		"extra field":            good + "$extra",
		"threads overflow":       with(3, "m=64,t=1,p=256"),
		"memory below 8*threads": with(3, "m=8,t=1,p=2"),
		"salt too long":          with(4, base64.RawStdEncoding.EncodeToString(make([]byte, 1025))),
		"key too long":           with(5, base64.RawStdEncoding.EncodeToString(make([]byte, 1025))),
	}
	for name, enc := range tests {
		t.Run(name, func(t *testing.T) {
			ok, err := newTestHasher().Verify(context.Background(), enc, "a long enough password")
			if ok || !errors.Is(err, ErrMalformedHash) {
				t.Errorf("Verify = %v, %v; want false, ErrMalformedHash", ok, err)
			}
		})
	}
}

func TestHasherIsCorrectUnderConcurrentUse(t *testing.T) {
	h := NewHasher(testParams, 2)
	enc, err := h.Hash(context.Background(), "concurrent password")
	mustNoErr(t, err)

	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ok, err := h.Verify(context.Background(), enc, "concurrent password")
			if err != nil || !ok {
				t.Errorf("Verify = %v, %v", ok, err)
			}
		}()
	}
	wg.Wait()
}

func TestHasherCapacityIsEnforced(t *testing.T) {
	h := NewHasher(testParams, 2)
	ctx := func() (context.Context, context.CancelFunc) {
		return context.WithTimeout(context.Background(), 5*time.Second)
	}

	h.sem <- struct{}{} // occupy 1 of 2 slots
	c1, cancel1 := ctx()
	defer cancel1()
	_, err := h.Hash(c1, "capacity password")
	mustNoErr(t, err) // one slot is free, so this succeeds and releases its slot

	h.sem <- struct{}{} // fill the second slot: both are now occupied
	if len(h.sem) != 2 {
		t.Fatalf("len(sem) = %d, want 2 before the blocked call", len(h.sem))
	}
	short, cancelShort := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancelShort()
	if _, err := h.Hash(short, "capacity password"); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Hash with both slots full: err = %v, want context.DeadlineExceeded", err)
	}

	<-h.sem // free one slot
	c2, cancel2 := ctx()
	defer cancel2()
	_, err = h.Hash(c2, "capacity password")
	mustNoErr(t, err)
}

func TestNewHasherClampsConcurrencyToAtLeastOne(t *testing.T) {
	for _, n := range []int{0, -1} {
		h := NewHasher(testParams, n)
		if cap(h.sem) != 1 {
			t.Fatalf("NewHasher(_, %d): cap(sem) = %d, want 1", n, cap(h.sem))
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		enc, err := h.Hash(ctx, "clamped password")
		mustNoErr(t, err)
		ok, err := h.Verify(ctx, enc, "clamped password")
		cancel()
		if err != nil || !ok {
			t.Fatalf("NewHasher(_, %d): Verify = %v, %v; want true, nil", n, ok, err)
		}
	}
}

func TestHasherWaitHonoursContext(t *testing.T) {
	h := NewHasher(testParams, 1)
	h.sem <- struct{}{} // occupy the only slot
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := h.Hash(ctx, "whatever password"); !errors.Is(err, context.Canceled) {
		t.Errorf("Hash err = %v, want context.Canceled", err)
	}
	if _, err := h.Verify(ctx, "$argon2id$v=19$m=64,t=1,p=1$c2FsdHNhbHRzYWx0$a2V5a2V5a2V5a2V5a2V5a2V5a2V5a2V5", "x"); !errors.Is(err, context.Canceled) {
		t.Errorf("Verify err = %v, want context.Canceled", err)
	}
}
