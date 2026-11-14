package api

import (
	"bytes"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestWriteJSONLogsAndAnswers500WhenEncodingFails(t *testing.T) {
	var logs bytes.Buffer
	old := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&logs, nil)))
	t.Cleanup(func() { slog.SetDefault(old) })

	rec := httptest.NewRecorder()
	writeJSON(rec, http.StatusOK, make(chan int)) // channels cannot be JSON-encoded
	wantError(t, rec.Result(), rec.Body.Bytes(), 500, "internal")
	if !strings.Contains(logs.String(), "encoding response") {
		t.Errorf("encoding failure was not logged: %q", logs.String())
	}
}
