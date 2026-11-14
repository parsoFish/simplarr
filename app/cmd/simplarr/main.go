// Command simplarr is the control-plane UI and API for a simplarr stack.
package main

import (
	"fmt"
	"io"
	"os"
)

// version is set at build time: -ldflags "-X main.version=1.2.3".
var version = "dev"

const usage = `usage: simplarr [command]

commands:
  serve        run the web UI and API (the default)
  healthcheck  exit 0 if the local server answers /healthz
  version      print the version
`

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr, os.Getenv))
}

// run is main with its inputs injected, so tests can drive it. It returns the
// process exit code.
func run(args []string, stdout, stderr io.Writer, getenv func(string) string) int {
	cmd := "serve"
	if len(args) > 0 {
		cmd = args[0]
	}
	if len(args) > 1 {
		fmt.Fprintf(stderr, "simplarr: %s takes no arguments\n\n%s", cmd, usage)
		return 2
	}

	switch cmd {
	case "serve":
		return cmdServe(stdout, stderr, getenv)
	case "healthcheck":
		return cmdHealthcheck(stderr, getenv)
	case "version":
		fmt.Fprintln(stdout, version)
		return 0
	case "help", "-h", "--help":
		fmt.Fprint(stdout, usage)
		return 0
	default:
		fmt.Fprintf(stderr, "simplarr: unknown command %q\n\n%s", cmd, usage)
		return 2
	}
}
