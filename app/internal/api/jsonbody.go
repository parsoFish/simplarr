package api

import (
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
)

// maxBodyBytes caps request bodies. Every body in this API is a small JSON
// document.
const maxBodyBytes = 64 << 10

// decodeJSON reads one JSON object from the request into dst. It requires
// Content-Type: application/json (a cross-site HTML form cannot send that),
// caps the body size, and rejects unknown fields and trailing data. On
// failure it has already written the error response and returns false.
func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) bool {
	mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		writeError(w, http.StatusUnsupportedMediaType, "unsupported_media_type",
			"The request body must be JSON.", "Send the header Content-Type: application/json.")
		return false
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			writeError(w, http.StatusRequestEntityTooLarge, "request_too_large",
				"The request body is too large.", "")
			return false
		}
		writeError(w, http.StatusBadRequest, "invalid_request",
			"The request body is not valid for this endpoint.", "Check the field names and types.")
		return false
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "invalid_request",
			"The request body must contain exactly one JSON object.", "")
		return false
	}
	return true
}
