package logging

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"strings"
	"testing"
)

func logLine(t *testing.T, fn func(*slog.Logger)) map[string]any {
	t.Helper()
	var buf bytes.Buffer
	fn(New(&buf, slog.LevelInfo))
	var out map[string]any
	if err := json.Unmarshal(buf.Bytes(), &out); err != nil {
		t.Fatalf("log output is not one JSON object: %v\n%s", err, buf.String())
	}
	return out
}

func TestSensitiveKeysAreDropped(t *testing.T) {
	keys := []string{
		"password", "Password", "newPassword", "token", "setupToken", "csrf_token",
		"secret", "clientSecret", "key", "apiKey", "api_key", "X-Api-Key",
	}
	for _, k := range keys {
		t.Run(k, func(t *testing.T) {
			out := logLine(t, func(l *slog.Logger) { l.Info("event", k, "hunter2hunter2") })
			if _, found := out[k]; found {
				t.Errorf("attribute %q was logged: %v", k, out)
			}
		})
	}
}

func TestSafeKeysSurvive(t *testing.T) {
	out := logLine(t, func(l *slog.Logger) { l.Info("login failed", "ip", "10.0.0.7", "status", 401) })
	if out["ip"] != "10.0.0.7" || out["status"] != float64(401) || out["msg"] != "login failed" {
		t.Errorf("unexpected output: %v", out)
	}
	if out["level"] != "INFO" || out["time"] == nil {
		t.Errorf("built-in attributes missing: %v", out)
	}
}

func TestGroupsAreChecked(t *testing.T) {
	out := logLine(t, func(l *slog.Logger) {
		l.Info("event",
			slog.Group("req", slog.String("path", "/x"), slog.String("apiKey", "abc")),
			slog.Group("secrets", slog.String("a", "b")),
		)
	})
	req, _ := out["req"].(map[string]any)
	if req["path"] != "/x" {
		t.Errorf("req.path missing: %v", out)
	}
	if _, found := req["apiKey"]; found {
		t.Errorf("nested apiKey logged: %v", out)
	}
	if _, found := out["secrets"]; found {
		t.Errorf("sensitive group logged: %v", out)
	}
}

func TestPreAttachedAttrsAndGroupsAreRedacted(t *testing.T) {
	var buf bytes.Buffer
	l := New(&buf, slog.LevelInfo).With("password", "p").WithGroup("tokens").With("a", "b")
	l.Info("event", "c", "d")
	if strings.Contains(buf.String(), `"p"`) || strings.Contains(buf.String(), `"a"`) || strings.Contains(buf.String(), `"c"`) {
		t.Errorf("pre-attached sensitive data leaked: %s", buf.String())
	}
	if !strings.Contains(buf.String(), `"msg":"event"`) {
		t.Errorf("log line missing, so the redaction check proves nothing: %s", buf.String())
	}
}

func TestLevelIsHonoured(t *testing.T) {
	var buf bytes.Buffer
	New(&buf, slog.LevelWarn).Info("quiet")
	if buf.Len() != 0 {
		t.Errorf("INFO line written at WARN level: %s", buf.String())
	}
}
