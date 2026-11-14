package auth

import (
	"bytes"
	"encoding/hex"
	"log/slog"
	"strings"
	"testing"

	"github.com/parsoFish/simplarr/app/internal/logging"
)

func TestGenerateTokenIsRandomAndURLSafe(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 50; i++ {
		tok, err := GenerateToken()
		mustNoErr(t, err)
		if len(tok) != 43 { // 32 bytes, unpadded base64url
			t.Fatalf("len(token) = %d, want 43 (256 bits)", len(tok))
		}
		if strings.ContainsAny(tok, "+/=") {
			t.Fatalf("token %q is not URL-safe", tok)
		}
		if seen[tok] {
			t.Fatalf("duplicate token %q", tok)
		}
		seen[tok] = true
	}
}

func TestNewSetupTokenIs128BitHex(t *testing.T) {
	tok, err := NewSetupToken()
	mustNoErr(t, err)
	raw, err := hex.DecodeString(tok)
	if err != nil || len(raw) != 16 {
		t.Errorf("token %q: want 32 hex chars (128 bits), decode err %v, %d bytes", tok, err, len(raw))
	}
}

func TestTokensMatch(t *testing.T) {
	tests := []struct {
		name                  string
		session, cookie, head string
		want                  bool
	}{
		{"all equal", "abc", "abc", "abc", true},
		{"header differs", "abc", "abc", "abd", false},
		{"cookie differs", "abc", "abd", "abc", false},
		{"session differs", "abd", "abc", "abc", false},
		{"cookie and header equal but not session", "xyz", "abc", "abc", false},
		{"header missing", "abc", "abc", "", false},
		{"cookie missing", "abc", "", "abc", false},
		{"all empty", "", "", "", false},
		{"length differs", "abc", "abc", "abcd", false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := TokensMatch(tc.session, tc.cookie, tc.head); got != tc.want {
				t.Errorf("TokensMatch = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestAnnounceSetupTokenWritesTheTokenToTheMessage(t *testing.T) {
	var buf bytes.Buffer
	AnnounceSetupToken(logging.New(&buf, slog.LevelInfo), "0123456789abcdef0123456789abcdef")
	out := buf.String()
	for _, want := range []string{`"level":"WARN"`, "First-run setup token: 0123456789abcdef0123456789abcdef", "/setup"} {
		if !strings.Contains(out, want) {
			t.Errorf("output %q missing %q", out, want)
		}
	}
}

func TestSetupTokenAsAttributeIsRedacted(t *testing.T) {
	var buf bytes.Buffer
	logging.New(&buf, slog.LevelInfo).Warn("setup", "setupToken", "0123456789abcdef0123456789abcdef")
	if strings.Contains(buf.String(), "0123456789abcdef") {
		t.Errorf("token leaked through an attribute: %s", buf.String())
	}
}
