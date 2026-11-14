// Package api holds simplarr's HTTP handlers, JSON shapes and error mapping
// (spec §8).
package api

import (
	"encoding/json"
	"log/slog"
	"net/http"
)

// apiError is the one error shape every endpoint uses (spec §8.1):
// {"error":{"code":"…","message":"…","fix":"…"}}.
type apiError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Fix     string `json:"fix,omitempty"`
}

type errorEnvelope struct {
	Error apiError `json:"error"`
}

// writeJSON sends v as JSON. A failed write means the client went away, so
// there is nobody to report it to.
func writeJSON(w http.ResponseWriter, status int, v any) {
	body, err := json.Marshal(v)
	if err != nil {
		slog.Error("encoding response", "err", err)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":{"code":"internal","message":"Could not encode the response."}}`))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

func writeError(w http.ResponseWriter, status int, code, message, fix string) {
	writeJSON(w, status, errorEnvelope{Error: apiError{Code: code, Message: message, Fix: fix}})
}
