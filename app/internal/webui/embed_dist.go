//go:build webdist

// Package webui exposes the built single-page app to the Go binary.
package webui

import (
	"embed"
	"io/fs"
)

// The dist directory is produced by `npm run build` and is not committed.
// The webdist build tag opts in, so `go build` and `go test` work on a fresh
// checkout without Node.
//
//go:embed all:dist
var dist embed.FS

// Dist returns the built UI rooted at index.html.
func Dist() fs.FS {
	sub, err := fs.Sub(dist, "dist")
	if err != nil {
		// Unreachable: "dist" is a literal that embed already validated.
		panic("webui: " + err.Error())
	}
	return sub
}
