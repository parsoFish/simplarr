// Package auth implements the admin password, first-run setup token, sessions,
// CSRF tokens and login rate limiting (spec §8.2).
package auth

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"golang.org/x/crypto/argon2"
)

// Params are the argon2id cost parameters. Memory is in KiB.
type Params struct {
	Memory  uint32
	Time    uint32
	Threads uint8
	SaltLen uint32
	KeyLen  uint32
}

// DefaultParams are the spec §8.2 values: 64 MiB, time 3, 2 threads,
// 16-byte salt, 32-byte key.
var DefaultParams = Params{Memory: 64 * 1024, Time: 3, Threads: 2, SaltLen: 16, KeyLen: 32}

// ErrMalformedHash means a stored password hash could not be parsed.
var ErrMalformedHash = errors.New("auth: malformed password hash")

// Limits applied when parsing a stored hash, so a corrupt admin.json cannot
// make Verify use unbounded memory or spin for minutes. maxMemoryKiB bounds a
// single hash to 1 GiB; with the default two concurrent hash slots (see
// NewHasher) a corrupt stored hash could therefore use up to 2 GiB in total.
const (
	maxMemoryKiB = 1 << 20 // 1 GiB
	maxTime      = 20
	minKeyLen    = 16
	maxFieldLen  = 1024
)

// Hasher hashes and verifies passwords with argon2id. Each hash needs
// Params.Memory of RAM, so at most maxConcurrent run at once; the rest wait,
// or give up when their context ends. That keeps a flood of login attempts
// from exhausting memory.
type Hasher struct {
	params Params
	sem    chan struct{}
}

// NewHasher returns a Hasher. maxConcurrent below 1 is treated as 1.
func NewHasher(p Params, maxConcurrent int) *Hasher {
	if maxConcurrent < 1 {
		maxConcurrent = 1
	}
	return &Hasher{params: p, sem: make(chan struct{}, maxConcurrent)}
}

func (h *Hasher) acquire(ctx context.Context) error {
	select {
	case h.sem <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (h *Hasher) release() { <-h.sem }

// Hash returns a PHC-format argon2id string that records its own parameters:
//
//	$argon2id$v=19$m=65536,t=3,p=2$<salt>$<key>
//
// so the parameters can be raised later without invalidating existing hashes.
func (h *Hasher) Hash(ctx context.Context, password string) (string, error) {
	if err := h.acquire(ctx); err != nil {
		return "", err
	}
	defer h.release()

	salt := make([]byte, h.params.SaltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", fmt.Errorf("auth: generate salt: %w", err)
	}
	key := argon2.IDKey([]byte(password), salt, h.params.Time, h.params.Memory, h.params.Threads, h.params.KeyLen)
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, h.params.Memory, h.params.Time, h.params.Threads,
		base64.RawStdEncoding.EncodeToString(salt),
		base64.RawStdEncoding.EncodeToString(key)), nil
}

// Verify reports whether password matches encoded, using the parameters stored
// in encoded (not the Hasher's). It returns ErrMalformedHash when encoded
// cannot be parsed.
func (h *Hasher) Verify(ctx context.Context, encoded, password string) (bool, error) {
	if err := h.acquire(ctx); err != nil {
		return false, err
	}
	defer h.release()

	p, salt, want, err := decodeHash(encoded)
	if err != nil {
		return false, err
	}
	got := argon2.IDKey([]byte(password), salt, p.Time, p.Memory, p.Threads, uint32(len(want)))
	return subtle.ConstantTimeCompare(got, want) == 1, nil
}

// decodeHash parses and range-checks a PHC argon2id string.
func decodeHash(encoded string) (Params, []byte, []byte, error) {
	parts := strings.Split(encoded, "$")
	switch {
	case len(parts) != 6 || parts[0] != "":
		return malformed("expected $argon2id$v=..$m=..,t=..,p=..$salt$key")
	case parts[1] != "argon2id":
		return malformed("algorithm is not argon2id")
	case parts[2] != "v="+strconv.Itoa(argon2.Version):
		return malformed("unsupported argon2 version " + parts[2])
	}
	p, err := parseParams(parts[3])
	if err != nil {
		return Params{}, nil, nil, err
	}
	salt, err := decodeField(parts[4], 1)
	if err != nil {
		return Params{}, nil, nil, fmt.Errorf("%w: salt is not valid", ErrMalformedHash)
	}
	key, err := decodeField(parts[5], minKeyLen)
	if err != nil {
		return Params{}, nil, nil, fmt.Errorf("%w: key is not valid", ErrMalformedHash)
	}
	return p, salt, key, nil
}

func malformed(why string) (Params, []byte, []byte, error) {
	return Params{}, nil, nil, fmt.Errorf("%w: %s", ErrMalformedHash, why)
}

// parseParams reads "m=..,t=..,p=.." and range-checks the numbers.
func parseParams(s string) (Params, error) {
	bad := func(why string) (Params, error) {
		return Params{}, fmt.Errorf("%w: %s", ErrMalformedHash, why)
	}
	fields := strings.Split(s, ",")
	if len(fields) != 3 {
		return bad("parameters must be m=..,t=..,p=..")
	}
	var nums [3]uint64
	for i, name := range []string{"m", "t", "p"} {
		v, ok := strings.CutPrefix(fields[i], name+"=")
		if !ok {
			return bad("parameters must be m=..,t=..,p=..")
		}
		bits := 32
		if name == "p" {
			bits = 8
		}
		n, err := strconv.ParseUint(v, 10, bits)
		if err != nil {
			return bad("parameter " + name + " is not a valid number")
		}
		nums[i] = n
	}
	p := Params{Memory: uint32(nums[0]), Time: uint32(nums[1]), Threads: uint8(nums[2])}
	if p.Time < 1 || p.Time > maxTime || p.Threads < 1 || p.Memory < 8*uint32(p.Threads) || p.Memory > maxMemoryKiB {
		return bad("parameters out of range")
	}
	return p, nil
}

// decodeField decodes unpadded base64 and enforces minLen <= len <= maxFieldLen.
func decodeField(s string, minLen int) ([]byte, error) {
	b, err := base64.RawStdEncoding.DecodeString(s)
	if err != nil {
		return nil, err
	}
	if len(b) < minLen || len(b) > maxFieldLen {
		return nil, fmt.Errorf("length %d outside %d..%d", len(b), minLen, maxFieldLen)
	}
	return b, nil
}
