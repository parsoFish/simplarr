// Package logging builds the process logger: slog JSON with secret redaction
// (spec §10).
package logging

import (
	"io"
	"log/slog"
	"regexp"
)

// sensitiveKey matches attribute and group names that may carry a secret.
// It deliberately over-matches (for example "monkey"): a dropped harmless
// attribute costs nothing, a leaked credential costs a lot.
var sensitiveKey = regexp.MustCompile(`(?i)key|token|password|secret`)

// ReplaceAttr drops any attribute whose key, or whose enclosing group name,
// looks sensitive. Use it as slog.HandlerOptions.ReplaceAttr. It also covers
// attributes attached with With and WithGroup.
//
// It does not inspect message text or values: callers must never put a secret
// in either. The one deliberate exception is the first-run setup token, which
// auth.AnnounceSetupToken writes into the message so the operator can read it.
func ReplaceAttr(groups []string, a slog.Attr) slog.Attr {
	for _, g := range groups {
		if sensitiveKey.MatchString(g) {
			return slog.Attr{}
		}
	}
	if sensitiveKey.MatchString(a.Key) {
		return slog.Attr{}
	}
	return a
}

// New returns a JSON logger that writes to w at the given level with
// redaction applied.
func New(w io.Writer, level slog.Level) *slog.Logger {
	return slog.New(slog.NewJSONHandler(w, &slog.HandlerOptions{
		Level:       level,
		ReplaceAttr: ReplaceAttr,
	}))
}
