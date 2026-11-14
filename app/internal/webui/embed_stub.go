//go:build !webdist

// Package webui exposes the built single-page app to the Go binary.
package webui

import "io/fs"

// Dist returns nil: this binary was built without the webdist tag, so it has
// no UI. The API still works, and the HTTP handler answers every UI request
// with a 503 that explains how to build the UI.
func Dist() fs.FS { return nil }
