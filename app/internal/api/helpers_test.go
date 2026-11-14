package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// wantError asserts the response is the standard error envelope with code.
func wantError(t *testing.T, resp *http.Response, body []byte, status int, code string) {
	t.Helper()
	if resp.StatusCode != status {
		t.Fatalf("status = %d, want %d; body %s", resp.StatusCode, status, body)
	}
	var env struct {
		Error struct{ Code, Message, Fix string } `json:"error"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		t.Fatalf("body is not the error envelope: %v\n%s", err, body)
	}
	if env.Error.Code != code {
		t.Errorf("error code = %q, want %q (body %s)", env.Error.Code, code, body)
	}
	if strings.TrimSpace(env.Error.Message) == "" {
		t.Errorf("error message is empty: %s", body)
	}
	if ct := resp.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Errorf("Content-Type = %q, want application/json", ct)
	}
}
